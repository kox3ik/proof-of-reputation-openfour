// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CashbackPool} from "../src/CashbackPool.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";
import {ReputationTradeModule} from "../src/ReputationTradeModule.sol";
import {Components, Config} from "../src/ReputationTypes.sol";
import {OpenFourTypes} from "../src/vendor/openfour/libraries/OpenFourTypes.sol";

contract QuoteToken is ERC20 {
    constructor() ERC20("WBNB", "WBNB") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }
}

/// @dev Quote asset that tries to re-enter `claim` while the pool pays out.
contract EvilQuote is QuoteToken {
    CashbackPool public pool;
    address public victim;
    bool public armed;

    function arm(CashbackPool p, address v) external {
        pool = p;
        victim = v;
        armed = true;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        if (armed) {
            armed = false;
            pool.claim(address(this), address(0), victim); // must revert: pool is mid-claim
        }
        return super.transfer(to, v);
    }
}

contract Terminal {} // any contract trader (router): priced by tx.origin

/// @dev Stand-in for OpenFourCore: same fee arithmetic (curveQuote * bps / 10000 per tier, rounded down), pays the
///      tiers in the quote asset, then calls the token's customData `afterHook`, like the real Core.
contract MockCore {
    struct Info {
        uint256 presetId;
        address quote;
        address customData;
        ReputationTradeModule module;
        bool exists;
    }

    mapping(address => Info) public info;

    function register(address token, uint256 presetId, address quote, address cd, ReputationTradeModule m) external {
        info[token] = Info(presetId, quote, cd, m, true);
    }

    function tokens(address t)
        external
        view
        returns (
            uint32, address, uint256 presetId, address, string memory, string memory, uint256, uint256, uint256,
            address quote, address, address, address, address, address, address cd, uint256, bool exists, bool, bool
        )
    {
        Info memory i = info[t];
        return (1, address(0), i.presetId, t, "", "", 0, 0, 0, i.quote, address(0), address(0), address(0), address(0),
            address(0), i.customData, 0, i.exists, false, false);
    }

    function trade(address token, address trader, bool isBuy, uint256 curveQuote, uint256 amount) external {
        Info memory i = info[token];
        OpenFourTypes.TradeContext memory tc;
        tc.token = token;
        tc.trader = trader;
        tc.amount = amount;
        tc.isBuy = isBuy;
        tc.timestamp = block.timestamp;
        tc.blockNumber = block.number;
        OpenFourTypes.TradeResult memory r = i.module.evaluate(tc);
        for (uint256 k; k < r.fees.length; ++k) {
            ERC20(i.quote).transfer(r.fees[k].recipient, curveQuote * r.fees[k].bps / 10_000);
        }
        OpenFourTypes.TradeHookContext memory h;
        h.token = token;
        h.trader = trader;
        h.requestedAmount = amount;
        h.executedAmount = amount;
        h.isBuy = isBuy;
        h.timestamp = block.timestamp;
        h.blockNumber = block.number;
        h.curveQuote = curveQuote;
        ReputationLedger(i.customData).afterHook(h);
    }

    function migrate(address token) external {
        OpenFourTypes.MigrateHookContext memory m;
        m.token = token;
        m.timestamp = block.timestamp;
        ReputationLedger(info[token].customData).onMigrate(m);
    }
}

contract CashbackPoolTest is Base {
    uint256 internal constant PRESET = 1795685685090;
    uint256 internal constant CQ = 3_963_535_470_870_327; // curveQuote of the real testnet trade
    uint256 internal constant AMT = 100e18;

    address internal owner = makeAddr("owner");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    MockCore internal core;
    CashbackPool internal pool;
    QuoteToken internal wbnb;
    EvilQuote internal evil;
    ReputationTradeModule internal module;
    UpgradeableBeacon internal beacon;
    address internal token = makeAddr("token");
    ReputationLedger internal ledger;
    Terminal internal router = new Terminal();

    function setUp() public virtual {
        vm.warp(100 days);
        core = new MockCore();
        wbnb = new QuoteToken();
        evil = new EvilQuote();
        Config memory c = defaultConfig();
        c.freshDepositBps = 150;
        c.penaltyBps = 500;
        c.rewardsPool = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        _deploy(c); // nonce n
        pool = new CashbackPool(owner, address(core), address(registry), _assets()); // nonce n+1
        assertEq(address(pool), c.rewardsPool);
        module = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        module.init(token, address(core), "", "1");
        beacon = new UpgradeableBeacon(address(new ReputationLedger(registry, pool)), address(this));
        ledger = ReputationLedger(address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (token, address(core), "", "1")))));
        core.register(token, PRESET, address(wbnb), address(ledger), module);
        wbnb.mint(address(core), 1000 ether);
        vm.prank(owner);
        pool.bindPreset(PRESET);
    }

    function _assets() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = address(wbnb);
        a[1] = address(evil);
    }

    function _claim(address w) internal returns (uint256 d, uint256 c) {
        vm.prank(w);
        return pool.claim(address(wbnb), token, w);
    }

    function _buy(address w, uint256 cq, uint256 amt) internal {
        core.trade(token, w, true, cq, amt);
    }

    function _sell(address w, uint256 cq, uint256 amt) internal {
        core.trade(token, w, false, cq, amt);
    }

    /// @dev A complete registry publication (batch + finalizeEpoch) covering everything up to the previous block.
    function _publishLater() internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        _publish(makeAddr("anyone"), 50, 0);
        vm.prank(updater);
        registry.finalizeEpoch(1, uint64(vm.getBlockTimestamp() - 1)); // covers every trade before this block
    }

    function _unlocked(address w) internal view returns (uint256 d, uint256 f, uint64 ts) {
        (d, f,, ts) = pool.unlocked(address(wbnb), token, w);
    }

    function _bonusOf(address w) internal view returns (uint256 b) {
        (,, b,) = pool.unlocked(address(wbnb), token, w);
    }

    uint256 internal constant DEP = CQ * 150 / 10_000;
    uint256 internal constant FEE_BUY = CQ * 300 / 10_000 - DEP; // pool tier (150 regular + 150 deposit bps) minus deposit
    uint256 internal constant FEE_SELL = CQ * 50 / 10_000; // sell pool tier of a fresh wallet: regular fee only, no deposit on sells

    // ── inflow ──

    function test_freshBuyRecordsInflowExactly() public {
        _buy(alice, CQ, AMT);
        assertEq(pool.depositPool(address(wbnb)), DEP);
        assertEq(pool.budgetPool(address(wbnb)), CQ * 300 / 10_000 - DEP); // pool tier = 150 regular + 150 deposit bps
        assertEq(wbnb.balanceOf(address(pool)), pool.depositPool(address(wbnb)) + pool.budgetPool(address(wbnb)) + pool.fund(address(wbnb)));
        assertEq(wbnb.balanceOf(treasury), CQ * 150 / 10_000);
        (uint256 p, uint256 d, uint256 f,) = ledger.positions(alice);
        assertEq(p, AMT);
        assertEq(d, DEP);
        assertEq(f, FEE_BUY);
        (uint256 ud, uint256 uf,) = _unlocked(alice);
        assertEq(ud + uf, 0); // buying unlocks nothing
    }

    function test_terminalTraderIsResolvedByTxOrigin() public {
        vm.prank(address(this), alice); // tx.origin = alice
        _buy(address(router), CQ, AMT);
        (uint256 pa,,,) = ledger.positions(alice);
        (uint256 pr,,,) = ledger.positions(address(router));
        assertEq(pa, AMT);
        assertEq(pr, 0);
        vm.prank(address(this), alice);
        _sell(address(router), CQ, AMT);
        (uint256 ud,,) = _unlocked(alice);
        assertGt(ud, 0);
    }

    // ── unlock on sell ──

    function test_partialSellUnlocksProportionally() public {
        _buy(alice, CQ, AMT);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _sell(alice, CQ, 25e18); // a quarter of the position
        // the sale's own deposit and fee join the open amounts first, then a quarter is released
        uint256 openDep = DEP; // the sale pays no deposit
        uint256 openFee = FEE_BUY + FEE_SELL;
        (uint256 ud, uint256 uf, uint64 ts) = _unlocked(alice);
        assertEq(ud, openDep * 25e18 / AMT);
        assertEq(uf, openFee * 25e18 / AMT);
        assertEq(ts, vm.getBlockTimestamp());
        (uint256 p, uint256 d, uint256 f,) = ledger.positions(alice);
        assertEq(p, 75e18);
        assertEq(d, openDep - ud);
        assertEq(f, openFee - uf);
        // second partial sell of 50 of the remaining 75: two thirds of what is open is released
        uint256 d2 = d;
        uint256 f2 = f + FEE_SELL;
        _sell(alice, CQ, 50e18);
        (uint256 ud2, uint256 uf2,) = _unlocked(alice);
        assertEq(ud2, ud + d2 * 50e18 / 75e18);
        assertEq(uf2, uf + f2 * 50e18 / 75e18);
    }

    function test_fullSellUnlocksEverything() public {
        _buy(alice, CQ, AMT);
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, 2 * AMT);
        (uint256 ud, uint256 uf,) = _unlocked(alice);
        assertEq(ud, 2 * DEP); // both buys' deposits (a sale pays none)
        assertEq(uf, 2 * FEE_BUY + FEE_SELL);
        (uint256 p, uint256 d, uint256 f,) = ledger.positions(alice);
        assertEq(p + d + f, 0);
        // overselling is clamped to the position
        _buy(bob, CQ, AMT);
        _sell(bob, CQ, 5 * AMT);
        (uint256 bd,,) = _unlocked(bob);
        assertEq(bd, DEP);
    }

    function test_transferUnlocksNothing() public {
        _buy(alice, CQ, AMT);
        // alice moves her tokens to bob by plain transfer: the ledger never hears of it. Bob sells them.
        _sell(bob, CQ, AMT);
        (uint256 ud,,) = _unlocked(alice);
        (uint256 p, uint256 d,,) = ledger.positions(alice);
        assertEq(ud, 0);
        assertEq(p, AMT);
        assertEq(d, DEP);
        // bob had no tracked position: only what his own sale paid is released
        (uint256 bd, uint256 bf,) = _unlocked(bob);
        assertEq(bd, 0);
        assertEq(bf, FEE_SELL);
    }

    function test_migrationUnlocksNothing() public {
        _buy(alice, CQ, AMT);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        core.migrate(token);
        assertGt(ledger.migratedAt(), 0);
        (uint256 ud, uint256 uf,) = _unlocked(alice);
        assertEq(ud + uf, 0); // holding through migration releases no deposit
        (uint256 p, uint256 d,,) = ledger.positions(alice);
        assertEq(p, AMT);
        assertEq(d, DEP);
    }

    // ── claim ──

    function test_claimRefundsDepositAndCashbackCappedAtOwnFees() public {
        _publish(carol, 300, 0); // honest, known: her pool share fills the budget
        _buy(carol, 1 ether, AMT);
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        uint256 feeA = FEE_BUY + FEE_SELL;
        assertGt(pool.budgetPool(address(wbnb)), feeA);
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep, DEP);
        assertEq(cb, feeA);
        assertEq(wbnb.balanceOf(alice), DEP + feeA);
        (dep, cb) = _claim(alice); // only the unpaid bonus right (empty fund) is left: nothing more is paid
        assertEq(dep + cb, 0);
        assertEq(wbnb.balanceOf(alice), DEP + feeA);
    }

    function test_cashbackEqualsOwnPoolPartAndDepositAlwaysRefunded() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        uint256 budget = pool.budgetPool(address(wbnb));
        assertEq(budget, FEE_BUY + FEE_SELL); // the budget holds exactly the pool parts that arrived
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep, DEP);
        assertEq(cb, budget);
        assertEq(pool.budgetPool(address(wbnb)), 0);
        assertEq(pool.depositPool(address(wbnb)), 0);
        assertEq(wbnb.balanceOf(address(pool)), 0); // solvent to the last wei
    }

    function test_claimBeforeCoveringPublicationReverts() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        _claim(alice); // nothing published at all
        vm.warp(saleTs + 1);
        _publish(bob, 50, 0); // a score batch alone never opens claims
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        _claim(alice);
        address[] memory w = new address[](0);
        Components[] memory cs = new Components[](0);
        vm.prank(updater);
        registry.setScores(1, w, cs); // an empty batch does not either
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        _claim(alice);
        vm.prank(updater);
        registry.finalizeEpoch(1, saleTs - 1); // coverage that ends before the sale
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        _claim(alice);
        vm.prank(updater);
        registry.finalizeEpoch(1, saleTs); // covers the sale
        _claim(alice);
    }

    function test_finalizeEpochGuards() public {
        _publish(bob, 50, 0);
        vm.startPrank(updater);
        vm.expectRevert(ReputationRegistry.BadFinalization.selector);
        registry.finalizeEpoch(2, uint64(vm.getBlockTimestamp() - 1)); // not the published epoch
        vm.expectRevert(ReputationRegistry.BadFinalization.selector);
        registry.finalizeEpoch(1, uint64(vm.getBlockTimestamp())); // not in the past
        registry.finalizeEpoch(1, uint64(vm.getBlockTimestamp() - 10));
        vm.expectRevert(ReputationRegistry.BadFinalization.selector);
        registry.finalizeEpoch(1, uint64(vm.getBlockTimestamp() - 11)); // never moves back
        vm.stopPrank();
        vm.expectRevert(ReputationRegistry.NotUpdater.selector);
        registry.finalizeEpoch(1, uint64(vm.getBlockTimestamp() - 1));
    }

    function test_forfeitNeedsAFlag() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        vm.prank(bob);
        vm.expectRevert(CashbackPool.NotFlagged.selector); // honest wallet cannot be confiscated by anyone
        pool.forfeit(address(wbnb), token, alice);
        _claim(alice);
    }

    function test_thirdPartyClaimPaysOnlyTheWallet() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        uint256 bobBefore = wbnb.balanceOf(bob);
        uint256 aliceBefore = wbnb.balanceOf(alice);
        vm.expectEmit(true, true, true, true);
        emit CashbackPool.Claimed(address(wbnb), alice, bob, DEP, FEE_BUY + FEE_SELL, 0);
        vm.prank(bob);
        (uint256 dep, uint256 cb) = pool.claim(address(wbnb), token, alice);
        assertEq(dep, DEP);
        assertEq(cb, FEE_BUY + FEE_SELL);
        assertEq(wbnb.balanceOf(alice), aliceBefore + dep + cb);
        assertEq(wbnb.balanceOf(bob), bobBefore); // caller gets nothing
        vm.prank(bob);
        vm.expectRevert(CashbackPool.NothingToClaim.selector); // and cannot claim "for itself"
        pool.claim(address(wbnb), token, bob);
    }

    function test_thirdPartyClaimBeforeCoverageReverts() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        vm.prank(bob);
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        pool.claim(address(wbnb), token, alice);
    }

    function test_thirdPartyClaimOfFlaggedWalletPaysNothing() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1)); // the rug started with this sale
        vm.prank(bob);
        (uint256 dep, uint256 cb) = pool.claim(address(wbnb), token, alice);
        assertEq(dep + cb, 0);
        assertEq(wbnb.balanceOf(alice), 0);
        assertEq(wbnb.balanceOf(bob), 0);
        assertEq(pool.fund(address(wbnb)), DEP + FEE_BUY + FEE_SELL);
    }

    function test_anyoneCanForfeitAFlaggedWallet() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1)); // the rug started with this sale
        uint256 budget = pool.budgetPool(address(wbnb));
        vm.prank(bob);
        pool.forfeit(address(wbnb), token, alice);
        // deposit and the cashback right move from deposits / budget to the fund
        assertEq(pool.fund(address(wbnb)), DEP + FEE_BUY + FEE_SELL);
        assertEq(pool.budgetPool(address(wbnb)), budget - FEE_BUY - FEE_SELL);
        assertEq(pool.depositPool(address(wbnb)), 0);
        assertEq(wbnb.balanceOf(alice), 0);
    }

    function test_fullClaimLeavesNothingToClaimLater() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep, DEP);
        assertEq(cb, FEE_BUY + FEE_SELL);
        (uint256 ud, uint256 uf,) = _unlocked(alice);
        assertEq(ud, 0);
        assertEq(uf, 0);
        // the unpaid bonus right (empty fund) stays owed; a second claim pays nothing more
        assertGt(_bonusOf(alice), 0);
        (dep, cb) = _claim(alice);
        assertEq(dep + cb, 0);
    }

    function test_saleInDumpFlaggedAtNextPublicationGetsNothing() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint256 depositBefore = pool.depositPool(address(wbnb));
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1)); // the publication after the sale flags the wallet, rug start = sale
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep + cb, 0);
        assertEq(wbnb.balanceOf(alice), 0);
        // its deposit stays in the pool and joins the cashback budget
        assertEq(pool.depositPool(address(wbnb)), depositBefore - DEP);
        assertEq(pool.fund(address(wbnb)), DEP + FEE_BUY + FEE_SELL);
        assertEq(wbnb.balanceOf(address(pool)), pool.depositPool(address(wbnb)) + pool.budgetPool(address(wbnb)) + pool.fund(address(wbnb)));
    }

    // ── flag history: the flag acts as of the sale, not as of now ──

    function test_unflaggingAfterTheDumpDoesNotReleaseTheDeposit() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1));
        assertEq(registry.flaggedFrom(alice), saleTs);
        vm.warp(saleTs + 10);
        address[] memory uw = new address[](1);
        Components[] memory uc = new Components[](1);
        uw[0] = alice;
        uc[0] = Components(900, 0, 0, 0, 0);
        vm.prank(updater);
        registry.setScores(5_000, uw, uc); // the updater removes the penalty again
        assertFalse(registry.isFlagged(alice));
        assertEq(registry.flaggedFrom(alice), saleTs, "history is append-only");
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep + cb, 0);
        assertEq(wbnb.balanceOf(alice), 0);
        assertEq(pool.fund(address(wbnb)), DEP + FEE_BUY + FEE_SELL);
    }

    function test_honestEarlierSaleStaysClaimableWhenFlaggedLater() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 100);
        _flagSince(alice, saleTs + 50, uint64(vm.getBlockTimestamp() - 1)); // rug activity began after the honest sale
        assertTrue(registry.isFlagged(alice));
        vm.prank(bob);
        vm.expectRevert(CashbackPool.NotFlagged.selector); // nobody can confiscate the earlier sale
        pool.forfeit(address(wbnb), token, alice);
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep, DEP);
        assertEq(cb, FEE_BUY + FEE_SELL);
    }

    function _addToken(string memory name) internal returns (address t2) {
        t2 = makeAddr(name);
        ReputationTradeModule m2 = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        m2.init(t2, address(core), "", "1");
        address cd = address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (t2, address(core), "", "1"))));
        core.register(t2, PRESET, address(wbnb), cd, m2);
    }

    /// @dev Defect 2: a rug sale on token B must not strip the refund of an honest, already closed position on token A.
    function test_lateRugSaleOnAnotherTokenKeepsEarlierRefund() public {
        address tokB = _addToken("tokenB");
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT); // honest round trip on token A
        uint64 saleA = uint64(vm.getBlockTimestamp());
        vm.warp(saleA + 100);
        core.trade(tokB, alice, true, CQ, AMT);
        core.trade(tokB, alice, false, CQ, AMT); // sale on token B after the rug started
        vm.warp(vm.getBlockTimestamp() + 1);
        _flagSince(alice, saleA + 50, uint64(vm.getBlockTimestamp() - 1));
        vm.prank(bob);
        pool.forfeit(address(wbnb), tokB, alice); // the rug sale on B is confiscated by anyone
        vm.prank(alice);
        (uint256 dep, uint256 cb) = pool.claim(address(wbnb), token, alice); // but token A's refund is intact
        assertEq(dep, DEP);
        assertEq(cb, FEE_BUY + FEE_SELL);
    }

    function test_flagCanMoveEarlierButNeverLater() public {
        address[] memory w = new address[](1);
        Components[] memory c = new Components[](1);
        uint64[] memory since = new uint64[](1);
        w[0] = alice;
        c[0] = Components(0, 0, 0, 0, 1000);
        uint64 t0 = uint64(vm.getBlockTimestamp());
        vm.warp(t0 + 20_000);
        since[0] = t0 + 15_000;
        vm.prank(updater);
        registry.publish(1, w, c, t0 + 19_000, uint64(block.number - 1), blockhash(block.number - 1), since);
        assertEq(registry.flaggedFrom(alice), t0 + 15_000);
        since[0] = t0 + 18_000; // later: ignored
        vm.prank(updater);
        registry.publish(2, w, c, t0 + 19_001, uint64(block.number - 1), blockhash(block.number - 1), since);
        assertEq(registry.flaggedFrom(alice), t0 + 15_000);
        since[0] = t0 + 12_000; // earlier: taken
        vm.prank(updater);
        registry.publish(3, w, c, t0 + 19_002, uint64(block.number - 1), blockhash(block.number - 1), since);
        assertEq(registry.flaggedFrom(alice), t0 + 12_000);
        since[0] = 0; // zero, after coverage, or before the registry existed: rejected
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.BadFlagTime.selector, alice));
        registry.publish(4, w, c, t0 + 19_003, uint64(block.number - 1), blockhash(block.number - 1), since);
        since[0] = t0 + 19_500;
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.BadFlagTime.selector, alice));
        registry.publish(4, w, c, t0 + 19_003, uint64(block.number - 1), blockhash(block.number - 1), since);
    }

    function test_flagCorrectionIsOwnerOnlyTimelockedAndLogged() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1));
        vm.prank(updater);
        vm.expectRevert(); // the updater cannot correct
        registry.proposeFlagCorrection(alice, 0);
        vm.prank(admin);
        registry.proposeFlagCorrection(alice, 0); // wrongful flag: clear it
        uint64 delay = registry.config().configDelay;
        vm.expectRevert();
        registry.activateFlagCorrection(alice); // too early
        assertEq(registry.flaggedFrom(alice), saleTs);
        vm.warp(vm.getBlockTimestamp() + delay);
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.FlagCorrected(alice, saleTs, 0);
        registry.activateFlagCorrection(alice);
        assertEq(registry.flaggedFrom(alice), 0);
        (uint256 dep,) = _claim(alice);
        assertEq(dep, DEP, "the corrected wallet is paid");
        vm.prank(admin);
        registry.proposeFlagCorrection(alice, 5);
        vm.prank(admin);
        registry.cancelFlagCorrection(alice);
        vm.expectRevert();
        registry.activateFlagCorrection(alice);
    }

    function test_flagHistoryAndCoverageInteract() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        // a flag dated at the sale but published with coverage that does not reach the sale: nothing is claimable yet
        vm.warp(saleTs + 5);
        address[] memory w = new address[](0);
        Components[] memory c = new Components[](0);
        vm.prank(updater);
        registry.setScores(1, w, c);
        vm.prank(updater);
        registry.finalizeEpoch(1, saleTs - 1);
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        _claim(alice);
        // the covering publication brings the flag history with it: the sale is part of the rug
        _flagSince(alice, saleTs, saleTs + 4);
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep + cb, 0);
    }

    function test_laterSaleDelaysTheClaim() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, 40e18);
        _publishLater();
        vm.warp(vm.getBlockTimestamp() + 1);
        _sell(alice, CQ, 60e18); // newer unlocking sale folds into the bucket and moves its timestamp
        vm.expectRevert(CashbackPool.FlagsNotPublished.selector);
        _claim(alice);
    }

    // ── authenticity ──

    function _hook(address trader) internal view returns (OpenFourTypes.TradeHookContext memory h) {
        h.token = token;
        h.trader = trader;
        h.isBuy = true;
        h.curveQuote = CQ;
        h.executedAmount = AMT;
    }

    function test_directReportFromStrangerRejected() public {
        vm.expectRevert(CashbackPool.NotOurLedger.selector);
        pool.report(token, alice, 1, 1, 0, 0, 1, 1, 0, 1);
    }

    function test_fakeLedgerForRealTokenRejected() public {
        address fake = address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (token, address(this), "", "1"))));
        vm.expectRevert(CashbackPool.NotOurLedger.selector); // Core says the token's customData is `ledger`, not `fake`
        ReputationLedger(fake).afterHook(_hook(alice));
    }

    function test_tokenOfAnotherPresetRejected() public {
        address other = makeAddr("otherToken");
        address cd = address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (other, address(core), "", "1"))));
        core.register(other, PRESET + 1, address(wbnb), cd, module);
        OpenFourTypes.TradeHookContext memory h = _hook(alice);
        h.token = other;
        vm.prank(address(core));
        vm.expectRevert(CashbackPool.NotOurLedger.selector);
        ReputationLedger(cd).afterHook(h);
    }

    function test_unknownTokenRejectedAndPresetMustBeBound() public {
        CashbackPool p2 = new CashbackPool(owner, address(core), address(registry), _assets());
        vm.expectRevert(CashbackPool.PresetNotBound.selector);
        p2.report(token, alice, 1, 1, 0, 0, 0, 0, 0, 0);
        vm.startPrank(owner);
        p2.bindPreset(PRESET);
        vm.expectRevert(CashbackPool.PresetAlreadyBound.selector);
        p2.bindPreset(1);
        vm.stopPrank();
        vm.expectRevert(CashbackPool.NotOurLedger.selector);
        p2.report(makeAddr("nothing"), alice, 1, 1, 0, 0, 0, 0, 0, 0);
    }

    function test_underpaidPoolRevertsReport() public {
        // the core pays the pool tier before the hook; a trade whose payment fell short must not be recorded
        uint256 short = CQ * 300 / 10_000;
        OpenFourTypes.TradeHookContext memory h = _hook(alice);
        h.curveQuote = CQ;
        vm.prank(address(core));
        vm.expectRevert(CashbackPool.Underfunded.selector);
        ledger.afterHook(h);
        assertEq(wbnb.balanceOf(address(pool)), 0);
        assertGt(short, 0);
        // paying exactly what is reported makes the same hook pass
        wbnb.mint(address(pool), short);
        vm.prank(address(core));
        ledger.afterHook(h);
        assertEq(wbnb.balanceOf(address(pool)), pool.depositPool(address(wbnb)) + pool.budgetPool(address(wbnb)) + pool.fund(address(wbnb)));
    }

    function test_hugeAmountsPartialSellDoesNotOverflow() public {
        // depositOpen ~ 2^130 and sold ~ 2^130: the plain product depositOpen * sold would overflow 256 bits
        uint256 cq = 2 ** 140;
        uint256 amt = 2 ** 130;
        wbnb.mint(address(core), cq);
        _buy(alice, cq, amt);
        _sell(alice, cq, amt / 2);
        (uint256 p, uint256 d, uint256 f,) = ledger.positions(alice);
        assertEq(p, amt / 2);
        assertGt(d, 0);
        assertGt(f, 0);
        (uint256 ud, uint256 uf,) = _unlocked(alice);
        assertGt(ud, 0);
        assertGt(uf, 0);
    }

    function test_onlyCoreCanCallHooks() public {
        vm.expectRevert("Ledger: only core");
        ledger.afterHook(_hook(alice));
        OpenFourTypes.MigrateHookContext memory m;
        vm.expectRevert("Ledger: only core");
        ledger.onMigrate(m);
    }

    // ── reentrancy ──

    function test_reentrantQuoteAssetCannotReenterClaim() public {
        address t2 = makeAddr("t2");
        ReputationTradeModule m2 = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        m2.init(t2, address(core), "", "1");
        address cd = address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (t2, address(core), "", "1"))));
        core.register(t2, PRESET, address(evil), cd, m2);
        evil.mint(address(core), 100 ether);
        core.trade(t2, alice, true, CQ, AMT);
        core.trade(t2, alice, false, CQ, AMT);
        core.trade(t2, bob, true, CQ, AMT);
        core.trade(t2, bob, false, CQ, AMT);
        _publishLater();
        evil.arm(pool, bob);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        pool.claim(address(evil), t2, alice);
        assertEq(evil.balanceOf(alice), 0);
    }

    // ── config and gas ──

    function test_constructorZeroAddresses() public {
        vm.expectRevert(CashbackPool.ZeroAddress.selector);
        new CashbackPool(owner, address(0), address(registry), _assets());
        vm.expectRevert(CashbackPool.ZeroAddress.selector);
        new CashbackPool(owner, address(core), address(0), _assets());
    }

    // ── review fixes ──

    function test_hooksRejectAnotherToken() public {
        OpenFourTypes.TradeHookContext memory h = _hook(alice);
        h.token = makeAddr("other");
        vm.prank(address(core));
        vm.expectRevert("Ledger: wrong token");
        ledger.afterHook(h);
        OpenFourTypes.MigrateHookContext memory m;
        m.token = makeAddr("other");
        vm.prank(address(core));
        vm.expectRevert("Ledger: wrong token");
        ledger.onMigrate(m);
    }

    function test_recordedFeeNeverExceedsRoundedPoolTierMinusDeposit() public {
        uint256 cq = 3_963_535_470_870_134; // external-review counterexample: separate rounding gave +1 wei
        _buy(alice, cq, AMT); // fresh wallet: pool tier of the buy = regular pool part + 150 deposit bps
        _sell(alice, cq, AMT); // a sell pays no deposit; it releases what the position paid
        uint256 buyTier = cq * 300 / 10_000;
        uint256 dep = cq * 150 / 10_000;
        (uint256 ud, uint256 uf,) = _unlocked(alice);
        assertEq(ud, dep);
        assertEq(uf, buyTier - dep + cq * 50 / 10_000);
        assertLe(uf, cq * 200 / 10_000); // never more than charged
        assertEq(wbnb.balanceOf(address(pool)), pool.depositPool(address(wbnb)) + pool.budgetPool(address(wbnb)) + pool.fund(address(wbnb)));
    }

    function test_onlyAllowedQuoteAssets() public {
        QuoteToken other = new QuoteToken();
        address t3 = makeAddr("t3");
        ReputationTradeModule m3 = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        m3.init(t3, address(core), "", "1");
        address cd = address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (t3, address(core), "", "1"))));
        core.register(t3, PRESET, address(other), cd, m3);
        other.mint(address(core), 10 ether);
        vm.expectRevert(CashbackPool.NotOurLedger.selector);
        core.trade(t3, alice, true, CQ, AMT);
    }

    function test_sellStillUnlocksAfterRewardsPoolIsChanged() public {
        _buy(alice, CQ, AMT);
        Config memory c = registry.config();
        c.rewardsPool = makeAddr("newPool");
        vm.prank(admin);
        registry.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        registry.activateConfig();
        _sell(alice, CQ, AMT); // new fees no longer reach the pool, but the old deposit is released
        (uint256 ud,,) = _unlocked(alice);
        assertEq(ud, DEP);
    }

    function test_hookGas() public {
        _buy(alice, CQ, AMT); // first call verifies the ledger via Core and creates storage
        _buy(bob, CQ, AMT);
        wbnb.mint(address(pool), CQ); // the hooks below are called directly: back their reported inflow
        OpenFourTypes.TradeHookContext memory h = _hook(alice);
        vm.prank(address(core));
        uint256 g = gasleft();
        ledger.afterHook(h);
        emit log_named_uint("afterHook buy, existing position", g - gasleft());
        h.isBuy = false;
        h.executedAmount = 40e18;
        vm.prank(address(core));
        g = gasleft();
        ledger.afterHook(h);
        emit log_named_uint("afterHook partial sell (unlock)", g - gasleft());
        vm.prank(address(core));
        g = gasleft();
        ledger.afterHook(h);
        emit log_named_uint("afterHook second sell (bucket exists)", g - gasleft());
    }

    // ── cashback cap basis: only the POOL PART of the wallet's regular module fee (never the treasury part) ──

    function _regularRoundTrip(address w) internal returns (uint256 recorded, uint256 regularPool) {
        _publish(w, 400, 0); // known wallet at the knee: regular fee, no deposit, not flagged
        uint256 bps = registry.quoteDetailed(w, true).poolBps;
        assertGt(bps, 0);
        _buy(w, CQ, AMT);
        _sell(w, CQ, AMT);
        uint256 sellBps = registry.quoteDetailed(w, false).poolBps;
        regularPool = CQ * bps / 10_000 + CQ * sellBps / 10_000;
        (, recorded,) = _unlocked(w); // open fees are zero after a full sale; read the unlocked bucket
    }

    function test_regularWalletGetsPoolPartOfRegularFeeBackWithEnoughBudget() public {
        _publish(carol, 0, 900);
        _buy(carol, 1 ether, AMT); // flagged inflow fills the budget
        (uint256 rec, uint256 poolPart) = _regularRoundTrip(alice);
        assertLe(rec, poolPart); // never more than charged (tiers rounded separately)
        assertGe(rec + 2, poolPart); // within rounding of the pool part
        uint256 treasuryBefore = wbnb.balanceOf(treasury);
        _publishLater();
        (uint256 dep, uint256 cb) = _claim(alice);
        assertEq(dep, 0);
        assertEq(cb, rec);
        assertEq(wbnb.balanceOf(treasury), treasuryBefore); // claims never touch the treasury
    }

    function test_honestWalletNeverGetsMoreThanPoolPartEvenWithLargeBudget() public {
        _publish(carol, 300, 0);
        _buy(carol, 100 ether, AMT); // very large budget (honest pool share)
        (, uint256 poolPart) = _regularRoundTrip(alice);
        uint256 treasuryPart = CQ * registry.quoteDetailed(alice, true).treasuryBps / 10_000
            + CQ * registry.quoteDetailed(alice, false).treasuryBps / 10_000;
        assertGt(treasuryPart, 0);
        assertGt(pool.budgetPool(address(wbnb)), 10 * poolPart);
        uint256 treasuryBefore = wbnb.balanceOf(treasury);
        _publishLater();
        (, uint256 cb) = _claim(alice);
        assertLe(cb, poolPart);
        assertLt(cb, poolPart + treasuryPart);
        assertEq(wbnb.balanceOf(treasury), treasuryBefore);
    }

    function test_regularWalletCashbackIsExactlyItsPoolPartWhenBudgetHoldsOnlyIt() public {
        (uint256 rec,) = _regularRoundTrip(alice);
        uint256 budget = pool.budgetPool(address(wbnb));
        assertEq(budget, rec); // the treasury part never entered the budget
        uint256 treasuryBefore = wbnb.balanceOf(treasury);
        _publishLater();
        (, uint256 cb) = _claim(alice);
        assertEq(cb, budget);
        assertEq(pool.budgetPool(address(wbnb)), 0);
        assertEq(wbnb.balanceOf(treasury), treasuryBefore);
    }
}
