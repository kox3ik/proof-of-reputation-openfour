// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Base} from "./Base.t.sol";
import {Config, FeeQuote} from "../src/ReputationTypes.sol";
import {ReputationMath} from "../src/ReputationMath.sol";

/// @dev Fresh-wallet deposit and flag penalty in the registry quote.
contract FeeExtrasTest is Base {
    function setUp() public {
        Config memory c = defaultConfig();
        c.freshDepositBps = 150;
        c.penaltyBps = 500;
        _deploy(c);
    }

    function test_freshWalletPaysDepositOnTopToPool() public view {
        FeeQuote memory q = registry.quoteDetailed(alice, true);
        assertTrue(registry.isFresh(alice));
        assertEq(q.regularBps, 300);
        assertEq(q.depositBps, 150);
        assertEq(q.treasuryBps, 150); // 50% of regular
        assertEq(q.poolBps, 150 + 150); // regular pool part + deposit
        assertEq(registry.quoteFeeBps(alice, true), 450);
        (uint256 total, uint256 tr, uint256 rw,,) = registry.quote(alice, true);
        assertEq(total, 450);
        assertEq(tr, 150);
        assertEq(rw, 300);
    }

    function test_freshSellPaysNoDepositAndSellCapStillApplies() public view {
        FeeQuote memory q = registry.quoteDetailed(alice, false);
        assertEq(q.regularBps, 100);
        assertEq(q.depositBps, 0);
    }

    function test_walletWithHistoryIsNotFresh() public {
        _publish(alice, 100, 0);
        assertFalse(registry.isFresh(alice));
        assertEq(registry.quoteDetailed(alice, true).depositBps, 0);
    }

    function test_flaggedPaysPenaltyNoDepositNoSellCap() public {
        _publish(alice, 0, 900);
        FeeQuote memory b = registry.quoteDetailed(alice, true);
        FeeQuote memory s = registry.quoteDetailed(alice, false);
        assertEq(b.penaltyBps, 500);
        assertEq(b.depositBps, 0);
        assertEq(s.regularBps, b.regularBps); // sell uncapped
        assertEq(s.treasuryBps, (b.regularBps + 500) * 5000 / 10_000); // penalty splits like the regular fee
        assertEq(s.poolBps, b.regularBps + 500 - s.treasuryBps);
    }

    function test_configRejectsFeePlusExtraAboveCap() public {
        Config memory c = defaultConfig();
        c.penaltyBps = uint16(ReputationMath.MAX_TOTAL_BPS - c.zeroBps + 1);
        vm.expectRevert();
        _deploy(c);
        c.penaltyBps = uint16(ReputationMath.MAX_TOTAL_BPS - c.zeroBps);
        _deploy(c);
    }

    /// @dev The two owner options for the testnet redeploy both pass `ReputationMath.validate` (deposit = penalty).
    function test_ownerOptionsAreValidConfigs() public {
        Config memory a = defaultConfig(); // option A: 9 %
        a.zeroBps = 50;
        a.neutralBps = 50; // as in script/Deploy.s.sol
        a.freshDepositBps = 900;
        a.penaltyBps = 900;
        _deploy(a);
        assertEq(registry.quoteDetailed(alice, true).regularBps + registry.quoteDetailed(alice, true).depositBps, 950);
        Config memory b = defaultConfig(); // option B: 6.4 %, same 0.5 % base fee
        b.zeroBps = 50;
        b.neutralBps = 50;
        b.freshDepositBps = 640;
        b.penaltyBps = 640;
        _deploy(b);
        assertEq(registry.quoteFeeBps(alice, true), 690);
        Config memory bad = defaultConfig(); // one bps over the cap is rejected
        bad.zeroBps = 51;
        bad.neutralBps = 50;
        bad.freshDepositBps = 900;
        bad.penaltyBps = 900;
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "fee + deposit/penalty > cap"));
        _deploy(bad);
    }

    /// @dev Defect 3: the refundable fresh-wallet deposit is charged on buys only; sells and transfers pay the regular fee.
    function test_freshDepositIsChargedOnBuysOnly() public {
        Config memory c = registry.config();
        c.freshDepositBps = 150;
        vm.prank(admin);
        registry.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(admin);
        registry.activateConfig();
        FeeQuote memory b = registry.quoteDetailed(alice, true);
        FeeQuote memory s = registry.quoteDetailed(alice, false);
        assertEq(b.depositBps, 150);
        assertEq(s.depositBps, 0);
        assertEq(registry.quoteFeeBps(alice, false), s.regularBps);
        assertEq(s.treasuryBps + s.poolBps, s.regularBps);
    }
}
