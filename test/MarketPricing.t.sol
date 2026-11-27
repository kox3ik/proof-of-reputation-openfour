// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {CashbackPoolTest} from "./CashbackPool.t.sol";
import {MockVault} from "./LockedToken.t.sol";
import {ReputationLedger} from "../src/ReputationLedger.sol";
import {ReputationLockedToken} from "../src/ReputationLockedToken.sol";
import {ReputationTradeModule} from "../src/ReputationTradeModule.sol";
import {FeeQuote} from "../src/ReputationTypes.sol";
import {OpenFourTypes} from "../src/vendor/openfour/OpenFourTypes.sol";

/// @dev After migration the token prices trades against the migrated DEX pair like the curve: regular fee + deposit
///      (fresh, buys) + penalty (flagged), paid in tokens; positions unlock only on a real sale.
contract MarketPricingTest is CashbackPoolTest {
    ReputationLockedToken internal mt;
    ReputationLedger internal mledger;
    MockVault internal mvault;
    address internal pair = makeAddr("pair");
    address internal mig = makeAddr("migrateModule");
    address internal dave = makeAddr("dave");
    uint256 internal constant X = 1000e18;

    function setUp() public override {
        super.setUp();
        mvault = new MockVault(address(core));
        address impl = address(new ReputationLockedToken(registry));
        address predicted = Clones.predictDeterministicAddress(impl, bytes32(uint256(7)), address(this));
        mledger = ReputationLedger(address(new BeaconProxy(address(beacon), abi.encodeCall(ReputationLedger.init, (predicted, address(core), "", "1")))));
        mt = ReputationLockedToken(Clones.cloneDeterministic(impl, bytes32(uint256(7))));
        assertEq(address(mt), predicted);
        mvault.bind(mt);
        mt.initialize(
            ReputationLockedToken.InitArgs(1, "M", "M", address(mvault), 10_000_000e18, "", address(1), address(2), mig, address(3), address(mledger), alice, address(0), "", "1")
        );
        ReputationTradeModule m = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        m.init(address(mt), address(core), "", "1");
        core.register(address(mt), PRESET, address(wbnb), address(mledger), m);
        mvault.pay(pair, 1_000_000e18);
    }

    function _migrate() internal {
        core.migrate(address(mt));
        mvault.setPhase(OpenFourTypes.Phase.Migrated);
        vm.prank(mig);
        mt.setMigratedPool(pair, true);
    }

    function _pairBuy(address w, uint256 amt) internal {
        vm.prank(pair);
        mt.transfer(w, amt);
    }

    function _pairSell(address w, uint256 amt) internal {
        vm.prank(w);
        mt.transfer(pair, amt);
    }

    function _fee(address w, bool isBuy, uint256 amt) internal view returns (uint256 tr, uint256 po) {
        FeeQuote memory q = registry.quoteDetailed(w, isBuy);
        tr = amt * q.treasuryBps / 10_000;
        po = amt * q.poolBps / 10_000;
    }

    function test_holdingThroughMigrationReleasesNothing() public {
        core.trade(address(mt), alice, true, CQ, AMT);
        _migrate();
        (uint256 ud, uint256 uf,,) = pool.unlocked(address(wbnb), address(mt), alice);
        assertEq(ud + uf, 0);
        (uint256 p, uint256 d,,) = mledger.positions(alice);
        assertEq(p, AMT);
        assertEq(d, DEP);
    }

    function test_freshBuyFromPairPaysFeeAndDepositInTokens() public {
        _migrate();
        (uint256 tr, uint256 po) = _fee(carol, true, X);
        uint256 dep = X * registry.quoteDetailed(carol, true).depositBps / 10_000;
        assertGt(dep, 0);
        uint256 pairBefore = mt.balanceOf(pair);
        _pairBuy(carol, X);
        assertEq(pairBefore - mt.balanceOf(pair), X);
        assertEq(mt.balanceOf(carol), X - tr - po);
        assertEq(mt.balanceOf(treasury), tr);
        assertEq(mt.balanceOf(address(pool)), po);
        assertEq(pool.depositPool(address(mt)), dep);
        assertGe(mt.balanceOf(address(pool)), pool.depositPool(address(mt)) + pool.budgetPool(address(mt)) + pool.fund(address(mt)));
    }

    function test_honestSaleIntoPairRefundsDepositInTokens() public {
        _migrate();
        _pairBuy(carol, X);
        uint256 held = mt.balanceOf(carol);
        uint256 dep = pool.depositPool(address(mt));
        (uint256 tr, uint256 po) = _fee(carol, false, held);
        uint256 pairBefore = mt.balanceOf(pair);
        _pairSell(carol, held);
        assertEq(mt.balanceOf(pair) - pairBefore, held - tr - po);
        _publishLater();
        uint256 before_ = mt.balanceOf(carol);
        (uint256 d, uint256 c) = pool.claim(address(mt), address(mt), carol);
        assertEq(d, dep);
        assertGt(c, 0);
        assertEq(mt.balanceOf(carol) - before_, d + c);
        assertEq(pool.depositPool(address(mt)), 0);
    }

    function test_flaggedWalletPaysPenaltyAndForfeitsDepositOnRugSale() public {
        _publish(dave, 0, 900);
        FeeQuote memory q = registry.quoteDetailed(dave, true);
        assertGt(q.penaltyBps, 0);
        _migrate();
        _pairBuy(dave, X);
        assertEq(pool.fund(address(mt)), X * q.poolBps / 10_000);
        _pairBuy(carol, X);
        uint256 dep = pool.depositPool(address(mt));
        uint256 fundBefore = pool.fund(address(mt));
        uint256 held = mt.balanceOf(carol);
        vm.warp(vm.getBlockTimestamp() + 10);
        _pairSell(carol, held);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(carol, saleTs, uint64(vm.getBlockTimestamp() - 1));
        pool.forfeit(address(mt), address(mt), carol);
        assertEq(pool.depositPool(address(mt)), 0);
        assertGe(pool.fund(address(mt)), fundBefore + dep);
    }

    function test_migrationLiquidityIsNotTaxed() public {
        _migrate();
        uint256 b = mt.balanceOf(pair);
        mvault.pay(pair, X);
        assertEq(mt.balanceOf(pair) - b, X);
        mvault.pay(mig, X);
        vm.prank(mig);
        mt.transfer(pair, X);
        assertEq(mt.balanceOf(pair) - b, 2 * X);
        assertEq(mt.balanceOf(treasury), 0);
        assertEq(mt.balanceOf(address(pool)), 0);
    }

    function test_curvePositionUnlocksWhenSoldIntoPair() public {
        core.trade(address(mt), alice, true, CQ, AMT);
        mvault.pay(alice, AMT);
        _migrate();
        _pairSell(alice, AMT);
        (uint256 ud, uint256 uf,,) = pool.unlocked(address(wbnb), address(mt), alice);
        assertEq(ud, DEP);
        assertEq(uf, FEE_BUY);
    }

    /// @dev A flagged wallet cannot move tokens to a clean wallet for free after migration: the transfer pays its sell rate.
    function test_postMigrationTransferPaysSenderSellRate() public {
        _publish(dave, 0, 900);
        mvault.pay(dave, X);
        _migrate();
        FeeQuote memory q = registry.quoteDetailed(dave, false);
        assertGt(q.penaltyBps, 0);
        uint256 expected = X * (q.regularBps + q.depositBps + q.penaltyBps) / 10_000;
        uint256 tBefore = mt.balanceOf(treasury);
        vm.prank(dave);
        mt.transfer(carol, X);
        assertEq(mt.balanceOf(carol), X - expected);
        assertGe(mt.balanceOf(treasury) + mt.balanceOf(address(pool)) - tBefore, expected - 1);
    }
}
