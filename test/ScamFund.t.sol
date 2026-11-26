// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CashbackPoolTest} from "./CashbackPool.t.sol";
import {CashbackPool} from "../src/CashbackPool.sol";
import {Config, FeeQuote} from "../src/ReputationTypes.sol";

/// @dev "Scam fund": flagged wallets' pool shares and confiscations pay the honest wallets' bonus; the surplus goes to
///      the treasury. (Inherits the pool fixture; its own tests run again, which is harmless.)
contract ScamFundTest is CashbackPoolTest {
    address internal dave = makeAddr("dave");

    function _a() internal view returns (address) {
        return address(wbnb);
    }

    function _quoteTreasury(address w, bool isBuy) internal view returns (uint256) {
        return CQ * registry.quoteDetailed(w, isBuy).treasuryBps / 10_000;
    }

    /// @dev Flagged carol pays a big pool share into the fund.
    function _fillFund(uint256 cq) internal {
        _publish(carol, 0, 900);
        _buy(carol, cq, AMT);
    }

    function _bonusReceived(address w) internal returns (uint256 dep, uint256 cb, uint256 bonus) {
        uint256 before_ = wbnb.balanceOf(w);
        (dep, cb) = _claim(w);
        bonus = wbnb.balanceOf(w) - before_ - dep - cb;
    }

    function test_flaggedTradeSharePoolGoesWhollyToFund() public {
        _publish(carol, 0, 900);
        FeeQuote memory q = registry.quoteDetailed(carol, true);
        assertGt(q.penaltyBps, 0);
        _buy(carol, CQ, AMT);
        uint256 share = CQ * q.poolBps / 10_000;
        assertEq(pool.fund(_a()), share);
        assertEq(pool.budgetPool(_a()), 0);
        assertEq(pool.depositPool(_a()), 0);
        assertEq(pool.bonusLiability(_a()), 0);
        (,, uint256 f, uint256 b) = ledger.positions(carol);
        assertEq(f, 0);
        assertEq(b, 0);
        assertEq(wbnb.balanceOf(address(pool)), share);
        assertEq(wbnb.balanceOf(treasury), CQ * q.treasuryBps / 10_000); // the penalty's treasury half is a normal fee
    }

    function test_honestWalletGetsDepositCashbackAndBonus() public {
        _fillFund(1 ether);
        uint256 bonusExpected = _quoteTreasury(alice, true) + _quoteTreasury(alice, false);
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        assertEq(pool.bonusLiability(_a()), bonusExpected);
        _publishLater();
        uint256 fundBefore = pool.fund(_a());
        (uint256 dep, uint256 cb, uint256 bonus) = _bonusReceived(alice);
        assertEq(dep, DEP);
        assertEq(cb, FEE_BUY + FEE_SELL);
        assertEq(bonus, bonusExpected);
        assertEq(pool.fund(_a()), fundBefore - bonusExpected);
        assertEq(pool.bonusLiability(_a()), 0);
        assertGe(wbnb.balanceOf(address(pool)), pool.depositPool(_a()) + pool.budgetPool(_a()) + pool.fund(_a()));
    }

    function _twoHonestRoundTrips() internal {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _buy(bob, CQ, AMT);
        _sell(bob, CQ, AMT);
        _publishLater();
    }

    function _partial(address w) internal returns (uint256 bonus) {
        uint256 before_ = wbnb.balanceOf(w);
        vm.prank(w);
        (uint256 dep, uint256 cb) = pool.claimBonusPartial(_a(), token);
        bonus = wbnb.balanceOf(w) - before_ - dep - cb;
    }

    /// @dev Defect 1: a third party claiming while the fund is short leaves the bonus fully owed; paid in full after a refill.
    function test_thirdPartyClaimKeepsUnpaidBonusOwed() public {
        _fillFund(CQ / 100); // fund far smaller than the bonus right
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        (,, uint256 owed,) = pool.unlocked(_a(), token, alice);
        assertGt(owed, pool.fund(_a()));
        uint256 f0 = pool.fund(_a());
        vm.prank(makeAddr("stranger"));
        pool.claim(_a(), token, alice);
        assertEq(wbnb.balanceOf(alice), DEP + FEE_BUY + FEE_SELL); // deposit and cashback only
        (,, uint256 left,) = pool.unlocked(_a(), token, alice);
        assertEq(left, owed);
        assertEq(pool.bonusLiability(_a()), owed);
        assertEq(pool.fund(_a()), f0);
        _fillFund(1 ether);
        (,, uint256 b2) = _bonusReceived(alice);
        assertEq(b2, owed);
        assertEq(pool.bonusLiability(_a()), 0);
    }

    /// @dev Repeated own claims with a short fund pay no bonus: the fund cannot be drained ahead of others.
    function test_repeatedClaimsWithShortFundPayNoBonus() public {
        _fillFund(CQ / 100);
        _twoHonestRoundTrips();
        uint256 f = pool.fund(_a());
        uint256 liab = pool.bonusLiability(_a());
        assertLt(f, liab);
        for (uint256 i; i < 3; ++i) {
            (,, uint256 b) = _bonusReceived(alice);
            assertEq(b, 0);
        }
        assertEq(pool.fund(_a()), f);
        assertEq(pool.bonusLiability(_a()), liab);
    }

    function test_partialClaimPaysProRataAndKeepsRatioAndOrderDoesNotMatter() public {
        _fillFund(CQ / 100);
        _twoHonestRoundTrips();
        uint256 f = pool.fund(_a());
        uint256 liab = pool.bonusLiability(_a());
        (,, uint256 aOwed,) = pool.unlocked(_a(), token, alice);
        uint256 snap = vm.snapshotState();
        uint256 aFirst = _partial(alice);
        assertEq(aFirst, f * aOwed / liab);
        assertApproxEqAbs(pool.fund(_a()) * liab, f * pool.bonusLiability(_a()), liab); // f / L unchanged
        uint256 bSecond = _partial(bob);
        assertEq(pool.bonusLiability(_a()), 0);
        vm.revertToState(snap);
        uint256 bFirst = _partial(bob);
        uint256 aSecond = _partial(alice);
        assertApproxEqAbs(aFirst, aSecond, 1);
        assertApproxEqAbs(bFirst, bSecond, 1);
        assertLe(aFirst + bSecond, f);
    }

    function test_partialClaimOnlyByTheWalletItself() public {
        _fillFund(CQ / 100);
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        _publishLater();
        vm.prank(bob); // it always acts for msg.sender: bob has no bucket, alice's right is out of reach
        vm.expectRevert(CashbackPool.NothingToClaim.selector);
        pool.claimBonusPartial(_a(), token);
        (,, uint256 owed,) = pool.unlocked(_a(), token, alice);
        assertGt(owed, 0);
        assertEq(pool.bonusLiability(_a()), owed);
    }

    function test_forfeitMovesDepositAndCashbackRightToFundAndWritesOffBonus() public {
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        uint256 bonus = _quoteTreasury(alice, true) + _quoteTreasury(alice, false);
        assertEq(pool.bonusLiability(_a()), bonus);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1));
        pool.forfeit(_a(), token, alice);
        assertEq(pool.fund(_a()), DEP + FEE_BUY + FEE_SELL);
        assertEq(pool.budgetPool(_a()), 0);
        assertEq(pool.depositPool(_a()), 0);
        assertEq(pool.bonusLiability(_a()), 0);
        (uint256 d, uint256 fe,,) = pool.unlocked(_a(), token, alice);
        assertEq(d + fe, 0);
    }

    function test_sweepSendsOnlySurplusAndNeverBreaksPayouts() public {
        _fillFund(CQ);
        _twoHonestRoundTrips();
        uint256 liab = pool.bonusLiability(_a());
        uint256 surplus = pool.fund(_a()) - liab;
        assertGt(surplus, 0);
        uint256 deposits = pool.depositPool(_a());
        uint256 budget = pool.budgetPool(_a());
        uint256 tBefore = wbnb.balanceOf(treasury);
        uint256 got = pool.sweepSurplus(_a());
        assertEq(got, surplus);
        assertEq(wbnb.balanceOf(treasury) - tBefore, surplus);
        assertEq(pool.fund(_a()), liab);
        assertEq(pool.depositPool(_a()), deposits);
        assertEq(pool.budgetPool(_a()), budget);
        vm.expectRevert(CashbackPool.NothingToSweep.selector);
        pool.sweepSurplus(_a());
        // both honest wallets still get everything
        (uint256 d1, uint256 c1, uint256 b1) = _bonusReceived(alice);
        (uint256 d2, uint256 c2, uint256 b2) = _bonusReceived(bob);
        assertEq(d1 + d2, 2 * DEP);
        assertEq(c1 + c2, 2 * (FEE_BUY + FEE_SELL));
        assertEq(b1 + b2, liab);
        assertEq(pool.fund(_a()), 0);
        assertEq(wbnb.balanceOf(address(pool)), 0);
    }

    function test_sweepNeedsASurplus() public {
        _buy(alice, CQ, AMT); // honest bonus right, empty fund
        vm.expectRevert(CashbackPool.NothingToSweep.selector);
        pool.sweepSurplus(_a());
    }

    function test_collapsedTreasuryGivesNoBonusRight() public {
        Config memory c = registry.config();
        c.treasury = address(pool);
        vm.prank(admin);
        registry.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(admin);
        registry.activateConfig();
        uint256 tBuy = CQ * registry.quoteDetailed(alice, true).treasuryBps / 10_000;
        _buy(alice, CQ, AMT);
        assertApproxEqAbs(pool.fund(_a()), tBuy, 1); // the treasury part of the single tier lands in the fund, not in the budget
        _sell(alice, CQ, AMT);
        assertEq(pool.bonusLiability(_a()), 0);
        (,,, uint256 bo) = ledger.positions(alice);
        assertEq(bo, 0);
        assertGe(wbnb.balanceOf(address(pool)), pool.depositPool(_a()) + pool.budgetPool(_a()) + pool.fund(_a()));
        // a flagged wallet's whole collapsed tier (treasury part included) is the fund
        _publish(carol, 0, 900);
        FeeQuote memory q = registry.quoteDetailed(carol, true);
        uint256 fundBefore = pool.fund(_a());
        _buy(carol, CQ, AMT);
        assertEq(pool.fund(_a()) - fundBefore, CQ * (q.treasuryBps + q.poolBps) / 10_000);
        assertGe(wbnb.balanceOf(address(pool)), pool.depositPool(_a()) + pool.budgetPool(_a()) + pool.fund(_a()));
    }

    /// @dev Random sequences of trades, claims and sweeps never leave the pool short of its cash obligations.
    function testFuzz_solvencyOnRandomSequences(uint256 seed) public {
        _publish(carol, 0, 900);
        address[3] memory honest = [alice, bob, dave];
        wbnb.mint(address(core), 100 ether);
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 kind = r % 6;
            address w = honest[(r >> 8) % 3];
            uint256 cq = CQ * (1 + (r >> 16) % 50);
            if (kind == 0) _buy(w, cq, AMT);
            else if (kind == 1) _buy(carol, cq, AMT);
            else if (kind == 2) _sell(w, cq, AMT / 2);
            else if (kind == 3) {
                _publishLater();
                vm.prank(w);
                try pool.claim(_a(), token, w) {} catch {}
            } else if (kind == 4) {
                try pool.sweepSurplus(_a()) {} catch {}
            } else {
                _sell(carol, cq, AMT);
            }
            assertGe(wbnb.balanceOf(address(pool)), pool.depositPool(_a()) + pool.budgetPool(_a()) + pool.fund(_a()));
        }
        // everything honest wallets can still claim never needs more than the pool holds
        _publishLater();
        for (uint256 i; i < 3; ++i) {
            vm.prank(honest[i]);
            try pool.claim(_a(), token, honest[i]) {} catch {}
        }
        assertGe(wbnb.balanceOf(address(pool)), pool.depositPool(_a()) + pool.budgetPool(_a()) + pool.fund(_a()));
    }

    function test_bonusOnlyBucketCanBeClaimed() public {
        // all fee to the treasury tier: the wallet gets no cashback right, only a bonus right
        Config memory c = registry.config();
        c.treasuryShareBps = 10_000;
        c.freshDepositBps = 0;
        vm.prank(admin);
        registry.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(admin);
        registry.activateConfig();
        _publish(alice, 300, 0);
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        (uint256 d, uint256 f, uint256 b,) = pool.unlocked(_a(), token, alice);
        assertEq(d + f, 0);
        assertGt(b, 0);
        assertEq(pool.bonusLiability(_a()), b);
        _publishLater();
        _claim(alice); // no NothingToClaim; the unfunded right is paid nothing and stays owed
        assertEq(pool.bonusLiability(_a()), b);
        (,, uint256 b2,) = pool.unlocked(_a(), token, alice);
        assertEq(b2, b);
    }

    function test_bonusOnlyBucketOfARugWalletIsForfeitedAndWrittenOff() public {
        Config memory c = registry.config();
        c.treasuryShareBps = 10_000;
        c.freshDepositBps = 0;
        vm.prank(admin);
        registry.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(admin);
        registry.activateConfig();
        _publish(alice, 300, 0);
        _buy(alice, CQ, AMT);
        _sell(alice, CQ, AMT);
        assertGt(pool.bonusLiability(_a()), 0);
        uint64 saleTs = uint64(vm.getBlockTimestamp());
        vm.warp(saleTs + 1);
        _flagSince(alice, saleTs, uint64(vm.getBlockTimestamp() - 1));
        pool.forfeit(_a(), token, alice);
        assertEq(pool.bonusLiability(_a()), 0);
    }

    function test_sweepRevertsWhenTreasuryIsThePool() public {
        _fillFund(CQ);
        Config memory c = registry.config();
        c.treasury = address(pool);
        vm.prank(admin);
        registry.proposeConfig(c);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(admin);
        registry.activateConfig();
        uint256 f = pool.fund(_a());
        vm.expectRevert(CashbackPool.NothingToSweep.selector);
        pool.sweepSurplus(_a());
        assertEq(pool.fund(_a()), f);
    }
}
