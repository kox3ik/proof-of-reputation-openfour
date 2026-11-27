// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LockedFixture, MockRouter} from "./LockedToken.t.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {Config} from "../src/ReputationTypes.sol";
import {ReputationMath} from "../src/ReputationMath.sol";
import {OpenFourTypes} from "../src/vendor/openfour/OpenFourTypes.sol";

contract LockedTokenCustodyTest is LockedFixture {
    event TransferFee(address indexed from, address indexed treasury, uint256 amount);

    function _rate(address w) internal view returns (uint256) {
        return registry.quoteFeeBps(w, false);
    }

    // ── custody bypass ──

    function test_unlistedContractPullPaysFeeAtSignerRate() public {
        MockRouter custody = new MockRouter(token);
        vm.prank(alice);
        token.approve(address(custody), 100e18);
        vm.prank(address(custody), alice);
        custody.pullFrom(alice, 100e18);
        uint256 fee = 100e18 * _rate(alice) / 10_000;
        assertGt(fee, 0);
        assertEq(token.balanceOf(treasury), fee);
        assertEq(token.balanceOf(address(custody)), 100e18 - fee);
    }

    function test_laterWithdrawalToOtherOriginPaysFee() public {
        MockRouter custody = new MockRouter(token);
        vm.prank(alice);
        token.approve(address(custody), 100e18);
        vm.prank(address(custody), alice);
        custody.pullFrom(alice, 100e18);
        uint256 before = token.balanceOf(treasury);
        uint256 held = token.balanceOf(address(custody));
        vm.prank(address(custody), bob); // later tx, different origin: no same-tx credit
        custody.forward(bob, held);
        assertGt(token.balanceOf(treasury), before);
        assertLt(token.balanceOf(bob), held);
    }

    /// @dev Tokens put into a contract by a plain transfer carry no hand-off credit (foundry runs a test in one
    ///      transaction, so tokens bought from the vault in-test would still carry credit).
    function _park(MockRouter custody, uint256 amt) internal {
        vm.prank(alice);
        token.transfer(address(custody), amt);
    }

    function test_withdrawalToSameOriginWithoutCreditPays() public {
        MockRouter custody = new MockRouter(token);
        _park(custody, 100e18);
        uint256 held = token.balanceOf(address(custody));
        uint256 before = token.balanceOf(treasury);
        vm.prank(address(custody), alice);
        custody.forward(alice, held);
        assertGt(token.balanceOf(treasury), before);
    }

    function test_unlistedRouterBuyHandoffSameTxIsFree() public {
        MockRouter router = new MockRouter(token);
        vm.prank(address(router), bob);
        router.payForward(vault, 50e18, bob, 50e18, 0);
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_handoffCreditIsCappedByWhatWasReceived() public {
        MockRouter router = new MockRouter(token);
        _park(router, 100e18); // old custody balance, no credit
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(address(router), bob);
        router.payForward(vault, 10e18, bob, 10e18, 5e18); // credit 10 covers the first 10 (free); the extra 5 pays
        assertGt(token.balanceOf(treasury), t0);
        assertEq(token.balanceOf(treasury) - t0, 5e18 * registry.quoteFeeBps(address(router), false) / 10_000);
    }

    function test_sellThroughListedRouterHasNoTransferFee() public {
        MockRouter router = new MockRouter(token);
        _listRouter(address(router));
        vm.prank(alice);
        token.approve(address(router), 100e18);
        vm.prank(address(router), alice);
        router.pullFrom(alice, 100e18);
        assertEq(token.balanceOf(address(router)), 100e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_sellThroughUnlistedRouterPaysTransferFee() public {
        MockRouter router = new MockRouter(token);
        vm.prank(alice);
        token.approve(address(router), 100e18);
        vm.prank(address(router), alice);
        router.pullFrom(alice, 100e18);
        assertEq(token.balanceOf(treasury), 100e18 * _rate(alice) / 10_000);
        // the onward leg to the vault (Core sale) is free
        uint256 got = token.balanceOf(address(router));
        vm.prank(address(router), alice);
        router.forward(address(vault), got);
        assertEq(token.balanceOf(treasury), 100e18 * _rate(alice) / 10_000);
    }

    // ── router allowlist ──

    function test_routerAllowlistOwnerOnlyAndTimelocked() public {
        address r = makeAddr("router");
        vm.expectRevert();
        registry.proposeRouter(r);
        vm.prank(admin);
        vm.expectRevert(ReputationRegistry.ZeroAddress.selector);
        registry.proposeRouter(address(0));
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistry.RouterProposed(r, uint64(block.timestamp + 1 days));
        registry.proposeRouter(r);
        vm.expectRevert(abi.encodeWithSelector(ReputationRegistry.TooEarly.selector, uint64(block.timestamp + 1 days)));
        registry.activateRouter(r);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, false);
        emit ReputationRegistry.RouterAdded(r);
        registry.activateRouter(r);
        assertTrue(registry.isRouter(r));
        vm.expectRevert();
        registry.removeRouter(r);
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ReputationRegistry.RouterRemoved(r);
        registry.removeRouter(r);
        assertFalse(registry.isRouter(r));
        vm.expectRevert(ReputationRegistry.NothingPending.selector);
        registry.activateRouter(r);
    }

    function test_removeCancelsPendingRouter() public {
        address r = makeAddr("router");
        vm.startPrank(admin);
        registry.proposeRouter(r);
        registry.removeRouter(r);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(ReputationRegistry.NothingPending.selector);
        registry.activateRouter(r);
    }

    function test_removedRouterPaysAgain() public {
        MockRouter router = new MockRouter(token);
        _listRouter(address(router));
        vm.prank(admin);
        registry.removeRouter(address(router));
        vm.prank(alice);
        token.approve(address(router), 10e18);
        vm.prank(address(router), alice);
        router.pullFrom(alice, 10e18);
        assertGt(token.balanceOf(treasury), 0);
    }

    // ── phases ──

    function _feeInPhase(OpenFourTypes.Phase p) internal returns (uint256) {
        vault.setPhase(p);
        uint256 before = token.balanceOf(treasury);
        vm.prank(alice);
        token.transfer(bob, 100e18);
        return token.balanceOf(treasury) - before;
    }

    function test_feeAppliesInCreatedTradingSoldOutTerminal() public {
        assertGt(_feeInPhase(OpenFourTypes.Phase.Created), 0);
        assertGt(_feeInPhase(OpenFourTypes.Phase.Trading), 0);
        assertGt(_feeInPhase(OpenFourTypes.Phase.SoldOut), 0);
        assertGt(_feeInPhase(OpenFourTypes.Phase.Terminal), 0);
    }

    function test_feeContinuesInMigratePendingAndMigrated() public {
        assertGt(_feeInPhase(OpenFourTypes.Phase.MigratePending), 0);
        assertGt(_feeInPhase(OpenFourTypes.Phase.Migrated), 0);
        assertTrue(token.transfersUnlocked());
    }

    function test_postMigrationUnlistedContractPullPaysFee() public {
        vault.setPhase(OpenFourTypes.Phase.Migrated);
        MockRouter pool = new MockRouter(token);
        vm.prank(alice);
        token.approve(address(pool), 100e18);
        vm.prank(address(pool), alice);
        pool.pullFrom(alice, 100e18);
        assertLt(token.balanceOf(address(pool)), 100e18); // unlisted contract: the sender's sell rate, like before migration
        assertGt(token.balanceOf(treasury), 0);
    }

    // ── edges ──

    function test_zeroTreasuryRejected() public {
        Config memory c = defaultConfig();
        c.treasury = address(0);
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "zero recipient"));
        new ReputationRegistry(admin, updater, c);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationMath.InvalidConfig.selector, "zero recipient"));
        registry.proposeConfig(c);
    }

    function test_zeroAmountTransferIsHarmless() public {
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(alice), 1000e18);
    }

    function test_selfTransferPaysFeeToTreasury() public {
        vm.prank(alice);
        token.transfer(alice, 100e18);
        uint256 fee = 100e18 * _rate(alice) / 10_000;
        assertEq(token.balanceOf(alice), 1000e18 - fee);
        assertEq(token.balanceOf(treasury), fee);
    }

    function test_transferToTreasuryConservesAmount() public {
        vm.prank(alice);
        token.transfer(treasury, 100e18);
        assertEq(token.balanceOf(treasury), 100e18);
        assertEq(token.balanceOf(alice), 900e18);
    }

    function test_transferFeeEvent() public {
        uint256 fee = 100e18 * _rate(alice) / 10_000;
        vm.expectEmit(true, true, false, true);
        emit TransferFee(alice, treasury, fee);
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_unknownCoreRevertsExplicitly() public {
        vault.setCore(address(0));
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("InvalidCore()")));
        token.transfer(bob, 1e18);
    }

    function testFuzz_feeNeverExceedsAmountAndSupplyConserved(uint96 amount, uint8 who) public {
        address from = who % 3 == 0 ? alice : who % 3 == 1 ? flaggedW : goodW;
        uint256 amt = uint256(amount) % 1000e18;
        uint256 t0 = token.balanceOf(treasury);
        uint256 b0 = token.balanceOf(bob);
        vm.prank(from);
        token.transfer(bob, amt);
        uint256 fee = token.balanceOf(treasury) - t0;
        assertLe(fee, amt);
        assertEq(token.balanceOf(bob) - b0 + fee, amt);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
