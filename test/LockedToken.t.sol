// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";
import {ReputationLockedToken} from "../src/ReputationLockedToken.sol";
import {Base} from "./Base.t.sol";
import {Config} from "../src/ReputationTypes.sol";
import {OpenFourTypes} from "../src/vendor/openfour/OpenFourTypes.sol";

/// @dev Stands in for OpenFour's StandardVault: holds the supply, knows Core, can move tokens to buyers.
contract MockVault {
    address public fourCore;
    ReputationLockedToken public token;

    constructor(address core) {
        fourCore = core;
    }

    function bind(ReputationLockedToken t) external {
        token = t;
    }

    function setCore(address c) external {
        fourCore = c;
    }

    function pay(address to, uint256 amt) external {
        token.transfer(to, amt); // vault buy
    }

    function pull(address from, uint256 amt) external {
        token.transferFrom(from, address(this), amt);
    }

    function setPhase(OpenFourTypes.Phase p) external {
        token.setPhase(p);
    }
}

/// @dev Stands in for OpenFour Core: pulls tokens from the seller into the vault.
contract MockCore {
    function sell(ReputationLockedToken t, address vault, address seller, uint256 amt) external {
        t.transferFrom(seller, vault, amt);
    }
}

/// @dev A router: receives tokens from the vault (purchase) and forwards them to the signer / pulls them for a sale.
contract MockRouter {
    ReputationLockedToken public token;

    constructor(ReputationLockedToken t) {
        token = t;
    }

    function forward(address to, uint256 amt) external {
        token.transfer(to, amt);
    }

    function pullFrom(address from, uint256 amt) external {
        token.transferFrom(from, address(this), amt);
    }

    // Multi-step flows in ONE call. Credit and "owed" live in transient storage (one transaction); `forge test --gas-report`
    // runs every external call of a test as its own transaction (isolation mode), so a flow that is one transaction
    // on chain must also be one external call in the test.

    /// @dev purchase: vault pays this router, the router hands the tokens to the signer (and optionally more).
    function payForward(MockVault v, uint256 pay, address to, uint256 a1, uint256 a2) external {
        v.pay(address(this), pay);
        token.transfer(to, a1);
        if (a2 != 0) token.transfer(to, a2);
    }

    /// @dev sale: pull from the signer, then move the pulled tokens on.
    function pullForward(address from, address to, uint256 amt) external {
        token.transferFrom(from, address(this), amt);
        token.transfer(to, amt);
    }
}

abstract contract LockedFixture is Base {
    ReputationLockedToken internal token;
    MockVault internal vault;
    MockCore internal core;
    address internal bob = makeAddr("bob");
    address internal migrate = makeAddr("migrate");
    address internal flaggedW = makeAddr("flagged");
    address internal goodW = makeAddr("good");
    uint256 internal constant SUPPLY = 1_000_000e18;

    function setUp() public virtual {
        setUpFixture();
    }

    function setUpFixture() internal {
        Config memory c = defaultConfig();
        c.freshDepositBps = 150;
        c.penaltyBps = 500;
        _deploy(c);
        core = new MockCore();
        vault = new MockVault(address(core));
        address impl = address(new ReputationLockedToken(registry));
        token = ReputationLockedToken(Clones.clone(impl));
        vault.bind(token);
        token.initialize(
            ReputationLockedToken.InitArgs({
                requestId: 1,
                name: "Locked",
                symbol: "LCK",
                vault: address(vault),
                maxSupply: SUPPLY,
                tokenUri: "ipfs://x",
                curveModule: address(1),
                tradeModule: address(2),
                migrateModule: migrate,
                tokenModule: address(3),
                customDataModule: address(0),
                creator: alice,
                quoteAsset: address(0),
                tokenParams: "",
                tokenImplVersion: "1"
            })
        );
        vault.pay(alice, 1000e18); // vault buy: free
        vault.pay(flaggedW, 1000e18);
        vault.pay(goodW, 1000e18);
        _publish(flaggedW, 0, 900); // flagged
        _publish(goodW, 1000, 0); // top reputation
    }

    function _listRouter(address r) internal {
        vm.prank(admin);
        registry.proposeRouter(r);
        vm.warp(block.timestamp + 1 days);
        registry.activateRouter(r);
    }
}

contract LockedTokenTest is LockedFixture {
    function test_initialSupplyIsInVault() public view {
        assertEq(token.balanceOf(address(vault)), SUPPLY - 3000e18);
        assertEq(token.balanceOf(alice), 1000e18);
        (, string memory tag,) = token.descriptor();
        assertEq(tag, "token.reputation_locked");
    }

    // ── fee on wallet-to-wallet transfers before migration ──

    function test_freshSenderPaysItsRateToTreasury() public {
        uint256 bps = registry.quoteFeeBps(alice, false);
        assertGt(bps, 0);
        vm.prank(alice);
        token.transfer(bob, 100e18);
        uint256 fee = 100e18 * bps / 10_000;
        assertEq(token.balanceOf(treasury), fee); // goes to the registry treasury, not burned
        assertEq(token.balanceOf(bob), 100e18 - fee);
        assertEq(token.balanceOf(alice), 900e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_flaggedSenderPaysPenaltyRateToACleanWallet() public {
        uint256 bps = registry.quoteFeeBps(flaggedW, false);
        assertGe(bps, 500);
        vm.prank(flaggedW);
        token.transfer(bob, 100e18); // bob is a clean receiver: the SENDER's rate applies
        assertEq(token.balanceOf(treasury), 100e18 * bps / 10_000);
        assertEq(token.balanceOf(bob), 100e18 - 100e18 * bps / 10_000);
    }

    function test_goodSenderPaysItsLowRate() public {
        uint256 bps = registry.quoteFeeBps(goodW, false);
        assertLt(bps, registry.quoteFeeBps(alice, false));
        vm.prank(goodW);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(treasury), 100e18 * bps / 10_000);
    }

    function test_transferFromBySpenderAlsoPays() public {
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10e18); // spender == receiver, but from is an EOA: not a router pull
        assertGt(token.balanceOf(treasury), 0);
    }

    // ── free flows ──

    function test_coreSellToVaultIsFree() public {
        vm.prank(alice);
        token.approve(address(core), 400e18);
        core.sell(token, address(vault), alice, 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_userSendingDirectlyToVaultIsFree() public {
        vm.prank(alice);
        token.transfer(address(vault), 1e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_terminalBuyFlowPaysNothing() public {
        MockRouter router = new MockRouter(token);
        vm.prank(address(router), bob); // vault -> router (purchase), router -> signer, tx.origin == bob
        router.payForward(vault, 50e18, bob, 50e18, 0);
        assertEq(token.balanceOf(bob), 50e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_terminalSellFlowPaysNothing() public {
        MockRouter router = new MockRouter(token);
        _listRouter(address(router));
        vm.prank(alice);
        token.approve(address(router), 100e18);
        vm.prank(address(router), alice); // router pulls from the signer: from == tx.origin, msg.sender == to
        router.pullFrom(alice, 100e18);
        assertEq(token.balanceOf(address(router)), 100e18);
        // router -> vault (sale through Core) is free as well
        vm.prank(address(router), alice);
        token.transfer(address(vault), 100e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_routerCannotMoveTokensToSomeoneElseForFree() public {
        MockRouter router = new MockRouter(token);
        vault.pay(address(router), 50e18);
        vm.prank(address(router), alice); // to != tx.origin: normal fee, sender = router (a fresh address)
        router.forward(bob, 50e18);
        assertGt(token.balanceOf(treasury), 0);
    }

    // ── migration ──

    function test_noFeeAfterMigration() public {
        vault.setPhase(OpenFourTypes.Phase.MigratePending);
        vm.prank(alice);
        token.transfer(bob, 100e18);
        vault.setPhase(OpenFourTypes.Phase.Migrated);
        vm.prank(flaggedW);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 200e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_onlyVaultSetsPhase() public {
        vm.expectRevert("Token: only vault");
        token.setPhase(OpenFourTypes.Phase.Migrated);
    }

    function test_implementationCannotBeInitialized() public {
        ReputationLockedToken impl = new ReputationLockedToken(registry);
        vm.expectRevert();
        impl.initialize(
            ReputationLockedToken.InitArgs(1, "a", "b", address(vault), 1, "", address(1), address(2), address(3), address(4), address(0), alice, address(0), "", "1")
        );
        vm.expectRevert("Token: zero registry");
        new ReputationLockedToken(ReputationRegistry(address(0)));
    }

    function test_collectThenDumpCostsTheSellRateOnEveryHop() public {
        address[3] memory farm = [makeAddr("f1"), makeAddr("f2"), makeAddr("f3")];
        for (uint256 i; i < 3; ++i) vault.pay(farm[i], 10e18);
        for (uint256 i; i < 3; ++i) {
            vm.prank(farm[i]);
            token.transfer(bob, 10e18);
        }
        assertLt(token.balanceOf(bob), 30e18); // every collecting hop paid the sender's rate
        assertEq(token.balanceOf(treasury), 30e18 - token.balanceOf(bob));
    }
}
