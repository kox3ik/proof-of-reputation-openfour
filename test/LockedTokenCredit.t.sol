// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LockedFixture, MockRouter, MockVault, MockCore} from "./LockedToken.t.sol";
import {ReputationLockedToken} from "../src/ReputationLockedToken.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {FeeQuote} from "../src/ReputationTypes.sol";

/// @dev Gives the vault credit to a router and reverts afterwards (credit must roll back with the call).
contract CreditThenRevert {
    function run(MockVault v, address router, uint256 amt) external {
        v.pay(router, amt);
        revert("rollback");
    }
}

/// @dev A registry stand-in that reports a zero fee recipient.
contract ZeroTreasuryRegistry {
    function quoteDetailed(address, bool) external pure returns (FeeQuote memory q) {
        q.regularBps = 100;
    }

    function isRouter(address) external pure returns (bool) {
        return false;
    }
}

event Transfer(address indexed from, address indexed to, uint256 value);

contract LockedTokenCreditTest is LockedFixture {
    MockRouter internal stale; // got credit in the setUp transaction

    function setUp() public override {
        setUpFixture();
        stale = new MockRouter(token);
        vault.pay(address(stale), 50e18); // credit exists only inside this (setUp) transaction
    }

    function _park(MockRouter r, uint256 amt) internal {
        vm.prank(alice);
        token.transfer(address(r), amt);
    }

    function test_creditDoesNotSurviveIntoLaterTransaction() public {
        // Foundry runs each test in its own transaction, so the setUp credit must be gone.
        vm.prank(address(stale), bob);
        stale.forward(bob, 50e18);
        assertGt(token.balanceOf(treasury), 0);
    }

    function test_creditSpentByAnotherExitCannotCoverOldBalance() public {
        MockRouter r = new MockRouter(token);
        _park(r, 100e18); // old balance, no credit
        vault.pay(address(r), 50e18); // credit 50
        vm.prank(address(r), bob);
        r.forward(address(vault), 50e18); // exit to the vault spends the credit
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(address(r), bob);
        r.forward(bob, 50e18); // would have been covered by the stale credit before
        assertGt(token.balanceOf(treasury), t0);
    }

    function test_creditSpentByTransferToThirdPartyToo() public {
        MockRouter r = new MockRouter(token);
        vault.pay(address(r), 50e18);
        vm.prank(address(r), bob);
        r.forward(makeAddr("other"), 50e18); // pays, and still uses up the credit
        uint256 t0 = token.balanceOf(treasury);
        _park(r, 100e18);
        vm.prank(address(r), bob);
        r.forward(bob, 50e18);
        assertGt(token.balanceOf(treasury), t0);
    }

    function test_nestedRevertRollsCreditBack() public {
        MockRouter r = new MockRouter(token);
        _park(r, 100e18);
        CreditThenRevert c = new CreditThenRevert();
        vm.expectRevert("rollback");
        c.run(vault, address(r), 50e18);
        uint256 t0 = token.balanceOf(treasury);
        vm.prank(address(r), bob);
        r.forward(bob, 50e18);
        assertGt(token.balanceOf(treasury), t0);
    }

    // ── listed router: the free pull is owed to a sale ──

    function test_listedRouterMovingPulledTokensElsewherePaysSignerRate() public {
        MockRouter r = new MockRouter(token);
        _listRouter(address(r));
        vm.prank(flaggedW);
        token.approve(address(r), 100e18);
        vm.prank(address(r), flaggedW);
        r.pullForward(flaggedW, bob, 100e18); // the pull is free, moving it on pays: signer's rate applies, not the router's own
        uint256 signerRate = registry.quoteFeeBps(flaggedW, false);
        assertTrue(signerRate != registry.quoteFeeBps(address(r), false));
        assertEq(token.balanceOf(treasury), 100e18 * signerRate / 10_000);
    }

    function test_fullBuyHandoffSellCycleIsFree() public {
        MockRouter r = new MockRouter(token);
        _listRouter(address(r));
        vm.prank(address(r), bob);
        r.payForward(vault, 60e18, bob, 60e18, 0); // Core -> router (purchase), hand-off to the signer
        vm.prank(bob);
        token.approve(address(r), 60e18);
        vm.prank(address(r), bob);
        r.pullForward(bob, address(vault), 60e18); // sale: pull from the signer, router -> Core/vault
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(bob), 0);
        // owed is cleared: moving tokens later is a plain (router-rate) transfer
        _park(r, 10e18);
        vm.prank(address(r), flaggedW);
        r.forward(bob, token.balanceOf(address(r)));
        assertEq(token.balanceOf(treasury), 10e18 * registry.quoteFeeBps(alice, false) / 10_000
            + (10e18 - 10e18 * registry.quoteFeeBps(alice, false) / 10_000) * registry.quoteFeeBps(address(r), false) / 10_000);
    }

    // ── events, balances, math ──

    function test_bothTransferEventsAndFeeEvent() public {
        uint256 fee = 100e18 * registry.quoteFeeBps(alice, false) / 10_000;
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, treasury, fee);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 100e18 - fee);
        vm.prank(alice);
        token.transfer(bob, 100e18);
    }

    function test_treasuryAsSenderCannotSpendMoreThanItHolds() public {
        vault.pay(treasury, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, treasury, 10e18, 11e18));
        vm.prank(treasury);
        token.transfer(bob, 11e18);
    }

    function test_hugeAmountDoesNotOverflowFee() public {
        MockVault v2 = new MockVault(address(core));
        ReputationLockedToken t2 = ReputationLockedToken(Clones.clone(address(new ReputationLockedToken(registry))));
        v2.bind(t2);
        uint256 big = 1 << 250; // amount * bps would overflow a plain multiplication
        t2.initialize(
            ReputationLockedToken.InitArgs(1, "Big", "BIG", address(v2), big, "", address(1), address(2), migrate, address(3), address(0), alice, address(0), "", "1")
        );
        v2.pay(alice, big);
        vm.prank(alice);
        t2.transfer(bob, big);
        uint256 fee = t2.balanceOf(treasury);
        assertEq(fee, big / 10_000 * registry.quoteFeeBps(alice, false) + (big % 10_000) * registry.quoteFeeBps(alice, false) / 10_000);
        assertEq(t2.balanceOf(bob) + fee, big);
    }

    function test_zeroFeeRecipientRejectedByToken() public {
        ReputationLockedToken t2 = ReputationLockedToken(
            Clones.clone(address(new ReputationLockedToken(ReputationRegistry(address(new ZeroTreasuryRegistry())))))
        );
        MockVault v2 = new MockVault(address(core));
        v2.bind(t2);
        t2.initialize(
            ReputationLockedToken.InitArgs(1, "Z", "Z", address(v2), 1000e18, "", address(1), address(2), migrate, address(3), address(0), alice, address(0), "", "1")
        );
        v2.pay(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(ReputationLockedToken.ZeroFeeRecipient.selector);
        t2.transfer(bob, 10e18);
    }
}
