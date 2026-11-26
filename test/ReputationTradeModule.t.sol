// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {ReputationTradeModule} from "../src/ReputationTradeModule.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {Config} from "../src/ReputationTypes.sol";
import {OpenFourTypes, ModuleEncodeSchema} from "../src/vendor/openfour/libraries/OpenFourTypes.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract ReputationTradeModuleTest is Base {
    address internal token = makeAddr("token");
    address internal core = makeAddr("core");
    address internal router = address(new Dummy());
    ReputationTradeModule internal module;

    function setUp() public {
        _deploy(defaultConfig());
        ReputationTradeModule impl = new ReputationTradeModule(registry);
        module = ReputationTradeModule(Clones.clone(address(impl)));
        module.init(token, core, "", "1.0.0");
    }

    function _ctx(address trader, bool isBuy) internal view returns (OpenFourTypes.TradeContext memory c) {
        c.token = token;
        c.trader = trader;
        c.amount = 1 ether;
        c.isBuy = isBuy;
        c.timestamp = block.timestamp;
        c.blockNumber = block.number;
    }

    // ── init ──

    function test_cloneSharesImmutableRegistry() public view {
        assertEq(address(module.REGISTRY()), address(registry));
        assertEq(module.boundToken(), token);
        (, string memory tag, string memory v) = module.descriptor();
        assertEq(tag, "module.trade.reputation");
        assertEq(v, "1.0.0");
        ModuleEncodeSchema memory s = module.moduleEncodeSchema();
        assertEq(s.params.length, 0);
        assertEq(module.getInitParams().length, 0);
    }

    function test_initTwiceFails() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        module.init(token, core, "", "1.0.0");
    }

    function test_implementationCannotBeInitialized() public {
        ReputationTradeModule impl = new ReputationTradeModule(registry);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.init(token, core, "", "1");
    }

    function test_nonEmptyParamsFail() public {
        ReputationTradeModule m = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        vm.expectRevert("Trade: params not empty");
        m.init(token, core, hex"01", "1");
    }

    function test_zeroCoreAndZeroRegistryFail() public {
        ReputationTradeModule m = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        vm.expectRevert("Trade: zero fourCore");
        m.init(token, address(0), "", "1");
        vm.expectRevert("Trade: zero registry");
        new ReputationTradeModule(ReputationRegistry(address(0)));
    }

    function test_wrongTokenAndUninitializedRevert() public {
        OpenFourTypes.TradeContext memory c = _ctx(alice, true);
        c.token = makeAddr("other");
        vm.expectRevert("Trade: wrong token");
        module.evaluate(c);

        ReputationTradeModule fresh = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        vm.expectRevert("Trade: not initialized");
        fresh.evaluate(_ctx(alice, true));
    }

    // ── evaluate ──

    function test_freshWalletBuyPaysSplitSurcharge() public view {
        OpenFourTypes.TradeResult memory r = module.evaluate(_ctx(alice, true));
        assertTrue(r.allowed);
        assertEq(r.maxAmount, type(uint256).max);
        assertEq(r.fees.length, 2);
        assertEq(r.fees[0].recipient, treasury);
        assertEq(r.fees[1].recipient, rewards);
        assertEq(uint256(r.fees[0].bps) + r.fees[1].bps, 300);
    }

    function test_allFeesBounded_buyAndSellAllScores() public {
        for (uint16 s; s <= 1000; s += 5) {
            _publish(alice, s, 0);
            for (uint256 k; k < 2; ++k) {
                OpenFourTypes.TradeResult memory r = module.evaluate(_ctx(alice, k == 0));
                uint256 sum;
                for (uint256 i; i < r.fees.length; ++i) {
                    assertTrue(r.fees[i].recipient != address(0));
                    assertGt(r.fees[i].bps, 0);
                    sum += r.fees[i].bps;
                }
                assertEq(sum, registry.quoteFeeBps(alice, k == 0));
                assertLe(sum, 1000);
                assertLe(r.fees.length, 2);
                if (k == 1) assertLe(sum, 100);
            }
        }
    }

    function test_topScoreHasNoFees() public {
        _publish(alice, 1000, 0);
        assertEq(module.evaluate(_ctx(alice, true)).fees.length, 0);
    }

    function test_zeroShareTierSkipped() public {
        Config memory c = defaultConfig();
        c.treasuryShareBps = 0;
        _deploy(c);
        module = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        module.init(token, core, "", "1");
        OpenFourTypes.TradeResult memory r = module.evaluate(_ctx(alice, true));
        assertEq(r.fees.length, 1);
        assertEq(r.fees[0].recipient, rewards);
        assertEq(r.fees[0].bps, 300);

        c.treasuryShareBps = 10_000;
        _deploy(c);
        module = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        module.init(token, core, "", "1");
        r = module.evaluate(_ctx(alice, true));
        assertEq(r.fees.length, 1);
        assertEq(r.fees[0].recipient, treasury);
    }

    function _sum(OpenFourTypes.TradeResult memory r) internal pure returns (uint256 sum) {
        for (uint256 i; i < r.fees.length; ++i) sum += r.fees[i].bps;
    }

    function test_flaggedBuyIsAllowedAndPaysItsCurveFee() public {
        _publish(alice, 900, 800); // penalty >= flagThreshold, score 100
        assertTrue(registry.isFlagged(alice));
        OpenFourTypes.TradeResult memory r = module.evaluate(_ctx(alice, true));
        assertTrue(r.allowed);
        assertEq(r.revertData.length, 0);
        assertEq(registry.scoreOf(alice), 100);
        assertEq(_sum(r), registry.quoteFeeBps(alice, true));
        assertGt(_sum(r), 100); // penalised wallet pays more than a neutral one
    }

    function test_flaggedAndCleanSameScorePayTheSame() public {
        address clean = makeAddr("clean");
        _publish(alice, 900, 800);
        _publish(clean, 100, 0);
        assertEq(registry.scoreOf(alice), registry.scoreOf(clean));
        assertEq(_sum(module.evaluate(_ctx(alice, true))), _sum(module.evaluate(_ctx(clean, true))));
    }

    function test_sameAddressTiersCollapseToOne() public {
        Config memory c = defaultConfig();
        c.rewardsPool = c.treasury;
        _deploy(c);
        module = ReputationTradeModule(Clones.clone(address(new ReputationTradeModule(registry))));
        module.init(token, core, "", "1");
        OpenFourTypes.TradeResult memory r = module.evaluate(_ctx(alice, true)); // fresh wallet, 300 bps
        assertEq(r.fees.length, 1);
        assertEq(r.fees[0].recipient, treasury);
        assertEq(r.fees[0].bps, 300);
        _publish(alice, 1000, 0);
        assertEq(module.evaluate(_ctx(alice, true)).fees.length, 0);
    }

    function test_flaggedSellAllowedUncapped() public {
        _publish(alice, 0, 800);
        OpenFourTypes.TradeResult memory r = module.evaluate(_ctx(alice, false));
        assertTrue(r.allowed);
        uint256 sum;
        for (uint256 i; i < r.fees.length; ++i) sum += r.fees[i].bps;
        assertEq(sum, 300); // flagged: no sell cap
    }

    // ── wallet resolution ──

    function test_contractTraderUsesTxOrigin() public {
        _publish(alice, 1000, 0); // alice: top reputation
        // router (contract) trades, origin is alice -> no fee
        vm.prank(router, alice);
        assertEq(module.evaluate(_ctx(router, true)).fees.length, 0);
        // origin is a fresh wallet -> full fee even though alice is good
        vm.prank(router, makeAddr("fresh"));
        assertEq(module.evaluate(_ctx(router, true)).fees.length, 2);
        assertEq(module.resolveWallet(router), tx.origin);
    }

    function test_eoaTraderUsesCtxTrader() public {
        _publish(alice, 1000, 0);
        vm.prank(alice, makeAddr("someOrigin"));
        assertEq(module.evaluate(_ctx(alice, true)).fees.length, 0);
        address bob = makeAddr("bob");
        vm.prank(bob, alice); // origin has great reputation, trader EOA does not
        assertEq(module.evaluate(_ctx(bob, true)).fees.length, 2);
    }

    function test_penaltyUsesResolvedWallet() public {
        address bad = makeAddr("bad");
        _publish(bad, 0, 900);
        vm.prank(router, bad);
        assertTrue(module.evaluate(_ctx(router, true)).allowed);
        vm.prank(router, bad);
        uint256 badFee = _sum(module.evaluate(_ctx(router, true)));
        _publish(alice, 1000, 0);
        vm.prank(router, alice);
        assertLt(_sum(module.evaluate(_ctx(router, true))), badFee);
    }

    function test_quoteFeeBpsHelper() public {
        _publish(alice, 400, 0);
        assertEq(module.quoteFeeBps(alice, true), 100);
    }
}

contract Dummy {}
