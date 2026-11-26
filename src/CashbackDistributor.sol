// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title CashbackDistributor
/// @notice Receives the `rewardsPool` share of module fees (native or ERC-20) and pays it back to wallets via
///         per-epoch Merkle roots published by the updater. The pool pays out what it received, no promised rate.
/// @dev Leaf = keccak256(bytes.concat(keccak256(abi.encode(epoch, wallet, asset, amount)))) (OpenZeppelin
///      StandardMerkleTree). `asset == address(0)` is native. Funds always go to the leaf's wallet. Nobody (owner
///      included) can withdraw user cashback: unclaimed amounts only return to the free balance via `sweepExpired`.
contract CashbackDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Round {
        bytes32 root;
        uint256 total;
        uint256 claimed;
        uint64 publishedAt;
        bool swept;
    }

    /// @notice Minimum allowed claim window.
    uint64 public constant MIN_CLAIM_WINDOW = 7 days;

    /// @notice Seconds after publication before a round's unclaimed remainder can be swept.
    uint64 public immutable CLAIM_WINDOW;
    /// @notice Root publisher (off-chain epoch service).
    address public updater;

    /// @notice asset => sum of published amounts not yet claimed or swept.
    mapping(address => uint256) public allocated;
    /// @notice asset => last published epoch.
    mapping(address => uint64) public lastEpoch;

    mapping(address => mapping(uint64 => Round)) private _rounds;
    mapping(address => mapping(uint64 => mapping(address => bool))) public hasClaimed;

    event RootPublished(uint64 indexed epoch, address indexed asset, bytes32 root, uint256 total);
    event Claimed(uint64 indexed epoch, address indexed asset, address indexed wallet, uint256 amount, address caller);
    event Swept(uint64 indexed epoch, address indexed asset, uint256 amount);
    event UpdaterChanged(address indexed updater);
    event Received(address indexed from, uint256 amount);

    error NotUpdater();
    error ZeroRoot();
    error EpochNotClosed(uint64 epoch);
    error ZeroAddress();
    error WindowTooShort();
    error EpochNotIncreasing(uint64 epoch, uint64 last);
    error RoundExists();
    error ExceedsFreeBalance(uint256 total, uint256 free);
    error NoRound();
    error AlreadyClaimed();
    error InvalidProof();
    error RoundSwept();
    error WindowOpen(uint64 until);
    error AlreadySwept();
    error NativeSendFailed();
    error LengthMismatch();
    error RenounceDisabled();

    modifier onlyUpdater() {
        if (msg.sender != updater) revert NotUpdater();
        _;
    }

    constructor(address initialOwner, address updater_, uint64 claimWindow_) Ownable(initialOwner) {
        if (claimWindow_ < MIN_CLAIM_WINDOW) revert WindowTooShort();
        CLAIM_WINDOW = claimWindow_;
        _setUpdater(updater_);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Disabled: renouncing would freeze the updater forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Owner can only change the updater; nothing here touches funds.
    function setUpdater(address updater_) external onlyOwner {
        _setUpdater(updater_);
    }

    // ───────────────────────── updater ─────────────────────────

    /// @notice Publish the root for (epoch, asset). `epoch` is a closed UTC day number (< timestamp / 1 days), never
    ///         overwritten, strictly increasing per asset. A zero root is rejected.
    function publishRoot(uint64 epoch, address asset, bytes32 root, uint256 total) external onlyUpdater {
        if (root == bytes32(0)) revert ZeroRoot();
        if (epoch >= block.timestamp / 1 days) revert EpochNotClosed(epoch);
        if (epoch <= lastEpoch[asset] && lastEpoch[asset] != 0) revert EpochNotIncreasing(epoch, lastEpoch[asset]);
        if (_rounds[asset][epoch].root != bytes32(0)) revert RoundExists();
        uint256 free = freeBalance(asset);
        if (total > free) revert ExceedsFreeBalance(total, free);
        lastEpoch[asset] = epoch;
        allocated[asset] += total;
        _rounds[asset][epoch] = Round(root, total, 0, uint64(block.timestamp), false);
        emit RootPublished(epoch, asset, root, total);
    }

    // ───────────────────────── claims ─────────────────────────

    /// @notice Pay `wallet` its cashback for (epoch, asset). Anyone may call; funds always go to `wallet`.
    function claim(uint64 epoch, address asset, address wallet, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        _claim(epoch, asset, wallet, amount, proof);
    }

    /// @notice Batch of claims (e.g. a terminal claiming for many users). Any failing item reverts the whole batch.
    function claimMany(
        uint64[] calldata epochs,
        address[] calldata assets,
        address[] calldata wallets,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        uint256 n = epochs.length;
        if (assets.length != n || wallets.length != n || amounts.length != n || proofs.length != n) {
            revert LengthMismatch();
        }
        for (uint256 i; i < n; ++i) {
            _claim(epochs[i], assets[i], wallets[i], amounts[i], proofs[i]);
        }
    }

    /// @notice After the claim window, return a round's unclaimed remainder to the free balance. Callable by anyone.
    function sweepExpired(uint64 epoch, address asset) external {
        Round storage r = _rounds[asset][epoch];
        if (r.root == bytes32(0)) revert NoRound();
        if (r.swept) revert AlreadySwept();
        uint64 until = r.publishedAt + CLAIM_WINDOW;
        if (block.timestamp < until) revert WindowOpen(until);
        r.swept = true;
        uint256 rest = r.total - r.claimed;
        allocated[asset] -= rest;
        emit Swept(epoch, asset, rest);
    }

    // ───────────────────────── views ─────────────────────────

    /// @notice Balance of `asset` not promised to any open round.
    function freeBalance(address asset) public view returns (uint256) {
        uint256 bal = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        uint256 a = allocated[asset];
        return bal > a ? bal - a : 0;
    }

    function roundOf(uint64 epoch, address asset) external view returns (Round memory) {
        return _rounds[asset][epoch];
    }

    /// @notice Leaf hash of (epoch, wallet, asset, amount), StandardMerkleTree format.
    function leafOf(uint64 epoch, address wallet, address asset, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, wallet, asset, amount))));
    }

    // ───────────────────────── internal ─────────────────────────

    function _claim(uint64 epoch, address asset, address wallet, uint256 amount, bytes32[] calldata proof) private {
        Round storage r = _rounds[asset][epoch];
        if (r.root == bytes32(0)) revert NoRound();
        if (r.swept) revert RoundSwept();
        if (hasClaimed[asset][epoch][wallet]) revert AlreadyClaimed();
        if (!MerkleProof.verifyCalldata(proof, r.root, leafOf(epoch, wallet, asset, amount))) revert InvalidProof();

        hasClaimed[asset][epoch][wallet] = true;
        uint256 newClaimed = r.claimed + amount;
        if (newClaimed > r.total) revert InvalidProof(); // root promised more than its declared total
        r.claimed = newClaimed;
        allocated[asset] -= amount;

        if (asset == address(0)) {
            (bool ok,) = wallet.call{value: amount}("");
            if (!ok) revert NativeSendFailed();
        } else {
            IERC20(asset).safeTransfer(wallet, amount);
        }
        emit Claimed(epoch, asset, wallet, amount, msg.sender);
    }

    function _setUpdater(address updater_) private {
        if (updater_ == address(0)) revert ZeroAddress();
        updater = updater_;
        emit UpdaterChanged(updater_);
    }
}
