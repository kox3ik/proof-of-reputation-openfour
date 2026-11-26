// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CashbackDistributor} from "../src/CashbackDistributor.sol";

contract TestToken is ERC20 {
    constructor() ERC20("T", "T") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }
}

/// @dev Tries to re-enter `claim` for another leaf while receiving its own cashback.
contract ReentrantReceiver {
    CashbackDistributor public d;
    uint64 public epoch;
    address public otherWallet;
    uint256 public otherAmount;
    bytes32[] public otherProof;

    function arm(CashbackDistributor d_, uint64 e, address w, uint256 a, bytes32[] memory p) external {
        d = d_;
        epoch = e;
        otherWallet = w;
        otherAmount = a;
        otherProof = p;
    }

    receive() external payable {
        d.claim(epoch, address(0), otherWallet, otherAmount, otherProof);
    }
}

contract CashbackDistributorTest is Test {
    CashbackDistributor internal d;
    TestToken internal tok;
    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    uint64 internal constant WINDOW = 30 days;
    address internal constant NATIVE = address(0);

    function setUp() public {
        vm.warp(1000 days); // epochs are UTC day numbers; fixtures use closed days below 1000
        d = new CashbackDistributor(owner, updater, WINDOW);
        tok = new TestToken();
        vm.deal(address(this), 100 ether);
    }

    // ── helpers: two-leaf tree ──
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _fundNative(uint256 v) internal {
        (bool ok,) = address(d).call{value: v}("");
        require(ok);
    }

    function _two(uint64 e, address asset, uint256 aAmt, uint256 bAmt)
        internal
        view
        returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb)
    {
        bytes32 la = d.leafOf(e, alice, asset, aAmt);
        bytes32 lb = d.leafOf(e, bob, asset, bAmt);
        root = _pair(la, lb);
        pa = new bytes32[](1);
        pb = new bytes32[](1);
        pa[0] = lb;
        pb[0] = la;
    }

    function _publishNative(uint64 e, uint256 a, uint256 b) internal returns (bytes32[] memory pa, bytes32[] memory pb) {
        bytes32 root;
        (root, pa, pb) = _two(e, NATIVE, a, b);
        vm.prank(updater);
        d.publishRoot(e, NATIVE, root, a + b);
    }

    // ── publish + claim ──
    function test_claimNative() public {
        _fundNative(10 ether);
        (bytes32[] memory pa, bytes32[] memory pb) = _publishNative(1, 1 ether, 2 ether);
        assertEq(d.allocated(NATIVE), 3 ether);
        assertEq(d.freeBalance(NATIVE), 7 ether);
        uint256 before_ = alice.balance;
        d.claim(1, NATIVE, alice, 1 ether, pa);
        assertEq(alice.balance - before_, 1 ether);
        assertEq(d.allocated(NATIVE), 2 ether);
        d.claim(1, NATIVE, bob, 2 ether, pb);
        assertEq(bob.balance, 2 ether);
        assertEq(d.allocated(NATIVE), 0);
        assertEq(d.roundOf(1, NATIVE).claimed, 3 ether);
    }

    function test_claimErc20() public {
        tok.mint(address(d), 100e18);
        (bytes32 root, bytes32[] memory pa,) = _two(1, address(tok), 5e18, 6e18);
        vm.prank(updater);
        d.publishRoot(1, address(tok), root, 11e18);
        d.claim(1, address(tok), alice, 5e18, pa);
        assertEq(tok.balanceOf(alice), 5e18);
        assertEq(d.allocated(address(tok)), 6e18);
    }

    function test_claimByThirdPartyPaysWallet() public {
        _fundNative(1 ether);
        (bytes32[] memory pa,) = _publishNative(1, 0.4 ether, 0.6 ether);
        vm.prank(carol);
        d.claim(1, NATIVE, alice, 0.4 ether, pa);
        assertEq(alice.balance, 0.4 ether);
        assertEq(carol.balance, 0);
    }

    function test_claimMany() public {
        _fundNative(1 ether);
        (bytes32[] memory pa, bytes32[] memory pb) = _publishNative(1, 0.4 ether, 0.6 ether);
        uint64[] memory es = new uint64[](2);
        address[] memory as_ = new address[](2);
        address[] memory ws = new address[](2);
        uint256[] memory am = new uint256[](2);
        bytes32[][] memory ps = new bytes32[][](2);
        es[0] = 1;
        es[1] = 1;
        ws[0] = alice;
        ws[1] = bob;
        am[0] = 0.4 ether;
        am[1] = 0.6 ether;
        ps[0] = pa;
        ps[1] = pb;
        d.claimMany(es, as_, ws, am, ps);
        assertEq(alice.balance, 0.4 ether);
        assertEq(bob.balance, 0.6 ether);
        ws = new address[](1);
        vm.expectRevert(CashbackDistributor.LengthMismatch.selector);
        d.claimMany(es, as_, ws, am, ps);
    }

    // ── failures ──
    function test_doubleClaimReverts() public {
        _fundNative(1 ether);
        (bytes32[] memory pa,) = _publishNative(1, 0.4 ether, 0.6 ether);
        d.claim(1, NATIVE, alice, 0.4 ether, pa);
        vm.expectRevert(CashbackDistributor.AlreadyClaimed.selector);
        d.claim(1, NATIVE, alice, 0.4 ether, pa);
    }

    function test_wrongProofOrAmountReverts() public {
        _fundNative(1 ether);
        (bytes32[] memory pa, bytes32[] memory pb) = _publishNative(1, 0.4 ether, 0.6 ether);
        vm.expectRevert(CashbackDistributor.InvalidProof.selector);
        d.claim(1, NATIVE, alice, 0.5 ether, pa); // inflated amount
        vm.expectRevert(CashbackDistributor.InvalidProof.selector);
        d.claim(1, NATIVE, alice, 0.4 ether, pb); // someone else's proof
        vm.expectRevert(CashbackDistributor.InvalidProof.selector);
        d.claim(1, NATIVE, carol, 0.4 ether, pa); // wrong wallet
        vm.expectRevert(CashbackDistributor.NoRound.selector);
        d.claim(2, NATIVE, alice, 0.4 ether, pa);
    }

    function test_publishOverFreeBalanceReverts() public {
        _fundNative(1 ether);
        (bytes32 root,,) = _two(1, NATIVE, 0.6 ether, 0.6 ether);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.ExceedsFreeBalance.selector, 1.2 ether, 1 ether));
        d.publishRoot(1, NATIVE, root, 1.2 ether);
        // allocation counts: a second round cannot reuse promised funds
        _publishNative(1, 0.5 ether, 0.4 ether);
        (bytes32 root2,,) = _two(2, NATIVE, 0.1 ether, 0.2 ether);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.ExceedsFreeBalance.selector, 0.3 ether, 0.1 ether));
        d.publishRoot(2, NATIVE, root2, 0.3 ether);
    }

    function test_secondRootSameEpochReverts() public {
        _fundNative(2 ether);
        _publishNative(1, 0.5 ether, 0.4 ether);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.EpochNotIncreasing.selector, 1, 1));
        d.publishRoot(1, NATIVE, bytes32(uint256(1)), 1);
    }

    function test_epochRegressionReverts() public {
        _fundNative(2 ether);
        _publishNative(5, 0.5 ether, 0.4 ether);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.EpochNotIncreasing.selector, 4, 5));
        d.publishRoot(4, NATIVE, bytes32(uint256(1)), 1);
        // epochs are tracked per asset
        tok.mint(address(d), 1e18);
        vm.prank(updater);
        d.publishRoot(4, address(tok), bytes32(uint256(1)), 1);
    }

    function test_onlyUpdaterPublishes() public {
        _fundNative(1 ether);
        vm.expectRevert(CashbackDistributor.NotUpdater.selector);
        d.publishRoot(1, NATIVE, bytes32(uint256(1)), 1);
        vm.prank(owner);
        vm.expectRevert(CashbackDistributor.NotUpdater.selector);
        d.publishRoot(1, NATIVE, bytes32(uint256(1)), 1);
    }

    // ── sweep ──
    function test_sweepBeforeWindowReverts() public {
        _fundNative(1 ether);
        _publishNative(1, 0.4 ether, 0.4 ether);
        vm.warp(block.timestamp + WINDOW - 1);
        vm.expectRevert();
        d.sweepExpired(1, NATIVE);
    }

    function test_sweepFreesFundsForLaterRoot() public {
        _fundNative(1 ether);
        (bytes32[] memory pa,) = _publishNative(1, 0.4 ether, 0.6 ether);
        d.claim(1, NATIVE, alice, 0.4 ether, pa);
        assertEq(d.freeBalance(NATIVE), 0);
        vm.warp(block.timestamp + WINDOW);
        d.sweepExpired(1, NATIVE);
        assertEq(d.allocated(NATIVE), 0);
        assertEq(d.freeBalance(NATIVE), 0.6 ether);
        vm.expectRevert(CashbackDistributor.AlreadySwept.selector);
        d.sweepExpired(1, NATIVE);
        // swept round cannot be claimed any more
        bytes32 lb = d.leafOf(1, alice, NATIVE, 0.4 ether);
        bytes32[] memory p = new bytes32[](1);
        p[0] = lb;
        vm.expectRevert(CashbackDistributor.RoundSwept.selector);
        d.claim(1, NATIVE, bob, 0.6 ether, p);
        // later root can use the freed balance
        (bytes32 root2,,) = _two(2, NATIVE, 0.3 ether, 0.3 ether);
        vm.prank(updater);
        d.publishRoot(2, NATIVE, root2, 0.6 ether);
        assertEq(d.allocated(NATIVE), 0.6 ether);
    }

    function test_noOwnerWithdrawal() public {
        _fundNative(1 ether);
        _publishNative(1, 0.4 ether, 0.6 ether);
        vm.prank(owner);
        d.setUpdater(alice);
        assertEq(address(d).balance, 1 ether);
        vm.prank(owner);
        vm.expectRevert(CashbackDistributor.RenounceDisabled.selector);
        d.renounceOwnership();
        vm.prank(owner);
        vm.expectRevert(CashbackDistributor.ZeroAddress.selector);
        d.setUpdater(address(0));
    }

    function test_constructorMinWindow() public {
        vm.expectRevert(CashbackDistributor.WindowTooShort.selector);
        new CashbackDistributor(owner, updater, 6 days);
    }

    // ── reentrancy ──
    function test_reentrancyViaReceiverFails() public {
        _fundNative(1 ether);
        ReentrantReceiver evil = new ReentrantReceiver();
        bytes32 le = d.leafOf(1, address(evil), NATIVE, 0.4 ether);
        bytes32 lb = d.leafOf(1, bob, NATIVE, 0.6 ether);
        vm.prank(updater);
        d.publishRoot(1, NATIVE, _pair(le, lb), 1 ether);
        bytes32[] memory pb = new bytes32[](1);
        pb[0] = le;
        bytes32[] memory pe = new bytes32[](1);
        pe[0] = lb;
        evil.arm(d, 1, bob, 0.6 ether, pb); // tries to also pull bob's leaf mid-claim
        vm.expectRevert(CashbackDistributor.NativeSendFailed.selector);
        d.claim(1, NATIVE, address(evil), 0.4 ether, pe);
        assertEq(d.allocated(NATIVE), 1 ether);
        assertEq(address(d).balance, 1 ether);
        assertFalse(d.hasClaimed(NATIVE, 1, address(evil)));
    }

    function test_zeroRootReverts() public {
        _fundNative(1 ether);
        vm.prank(updater);
        vm.expectRevert(CashbackDistributor.ZeroRoot.selector);
        d.publishRoot(1, NATIVE, bytes32(0), 1 ether);
    }

    function test_openOrFutureEpochReverts() public {
        _fundNative(1 ether);
        uint64 today = uint64(block.timestamp / 1 days);
        vm.startPrank(updater);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.EpochNotClosed.selector, today));
        d.publishRoot(today, NATIVE, bytes32(uint256(1)), 1);
        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.EpochNotClosed.selector, type(uint64).max));
        d.publishRoot(type(uint64).max, NATIVE, bytes32(uint256(1)), 1);
        d.publishRoot(today - 1, NATIVE, bytes32(uint256(1)), 1); // yesterday is closed
        vm.stopPrank();
    }
}
