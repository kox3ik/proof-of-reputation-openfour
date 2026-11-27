// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Components, Config, PendingConfig, FeeQuote} from "./ReputationTypes.sol";
import {ReputationMath} from "./ReputationMath.sol";

/// @title ReputationRegistry
/// @notice Protocol-owned store of per-wallet reputation components plus the (timelocked) scoring/fee config.
/// @dev Token creators have no write access anywhere in this contract. The `updater` (epoch publisher) can only
///      write wallet components; the `owner` (protocol admin) controls weights, curve, recipients and the updater.
contract ReputationRegistry is Ownable2Step {
    /// @notice Address allowed to publish components (the off-chain scoring service).
    address public updater;
    /// @notice Latest epoch number published by the updater.
    uint64 public currentEpoch;
    /// @notice All trades up to this timestamp are covered by a COMPLETE publication (set by `finalizeEpoch`; score
    ///         batches alone never move it). The cashback pool opens a claim only when `coveredUntil >= sale time`.
    uint64 public coveredUntil;
    /// @notice Gas forwarded to each identity-contract `balanceOf` probe (bounds grief via a hostile contract).
    uint256 public constant IDENTITY_CHECK_GAS = 30_000;

    Config private _config;
    PendingConfig private _pending;
    mapping(address => Components) private _components;
    /// @notice Routers (OpenFour terminal contracts) whose pulls from the signer are exempt from the token transfer fee.
    mapping(address => bool) public isRouter;
    /// @notice Registry creation time: no rug activity can be dated before it (lower bound of `flaggedFrom`).
    uint64 public immutable deployedAt = uint64(block.timestamp);
    /// @notice Effective start of a wallet's rug activity, append-only: the first publication of a flag (penalty >= flagThreshold)
    ///         sets it, later publications can only move it EARLIER, never later or to zero, and removing the penalty never
    ///         clears it. The cashback pool treats a sale at or after this time as part of the rug (forfeit); a sale before
    ///         it stays claimable even if the wallet is flagged later. 0 = never flagged.
    mapping(address => uint64) public flaggedFrom;
    /// @notice Owner-proposed correction of a wrongful flag (later date, or 0 = clear): wallet => (newFrom, activateAt, exists).
    struct FlagCorrection {
        uint64 newFrom;
        uint64 activateAt;
        bool exists;
    }
    mapping(address => FlagCorrection) public pendingFlagCorrection;
    /// @notice Pending router additions: router => activation time (0 = none). Delay = current `configDelay`.
    mapping(address => uint64) public routerActivateAt;

    event ScoresUpdated(uint64 indexed epoch, uint256 count);
    event EpochFinalized(uint64 indexed epoch, uint64 coveredUntil);
    event UpdaterChanged(address indexed updater);
    event ConfigProposed(uint64 activateAt, Config config);
    event ConfigActivated(Config config);
    event ConfigCancelled();
    event RouterProposed(address indexed router, uint64 activateAt);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
    event FlaggedFrom(address indexed wallet, uint64 from);
    event FlagCorrectionProposed(address indexed wallet, uint64 newFrom, uint64 activateAt);
    event FlagCorrected(address indexed wallet, uint64 oldFrom, uint64 newFrom);
    event FlagCorrectionCancelled(address indexed wallet);

    error NotUpdater();
    error LengthMismatch();
    error ComponentOutOfRange(address wallet);
    error EpochRegression(uint64 epoch, uint64 current);
    error BadFinalization();
    error BadSource();
    error BadFlagTime(address wallet);
    error NothingPending();
    error TooEarly(uint64 activateAt);
    error ZeroAddress();
    error RenounceDisabled();

    modifier onlyUpdater() {
        if (msg.sender != updater) revert NotUpdater();
        _;
    }

    /// @param initialOwner protocol admin
    /// @param updater_ epoch publisher
    /// @param initialConfig applied immediately (no delay at deployment)
    constructor(address initialOwner, address updater_, Config memory initialConfig) Ownable(initialOwner) {
        _setUpdater(updater_);
        _checkConfig(initialConfig);
        _config = initialConfig;
        emit ConfigActivated(initialConfig);
    }

    // ───────────────────────── admin ─────────────────────────

    /// @notice Disabled: renouncing would freeze config and updater forever.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setUpdater(address updater_) external onlyOwner {
        _setUpdater(updater_);
    }

    /// @notice Announce a new config; it can be activated after the CURRENT config's `configDelay`.
    function proposeConfig(Config calldata newConfig) external onlyOwner {
        _checkConfig(newConfig);
        uint64 at = uint64(block.timestamp + _config.configDelay);
        _pending = PendingConfig({config: newConfig, activateAt: at});
        emit ConfigProposed(at, newConfig);
    }

    /// @notice Apply the pending config once its delay elapsed. Callable by anyone.
    function activateConfig() external {
        PendingConfig memory p = _pending;
        if (p.activateAt == 0) revert NothingPending();
        if (block.timestamp < p.activateAt) revert TooEarly(p.activateAt);
        _config = p.config;
        delete _pending;
        emit ConfigActivated(p.config);
    }

    function cancelPendingConfig() external onlyOwner {
        if (_pending.activateAt == 0) revert NothingPending();
        delete _pending;
        emit ConfigCancelled();
    }

    /// @notice Announce a router for the transfer-fee exemption; activatable after the current `configDelay`
    ///         (an addition loosens fees, so it is timelocked like config; removal is immediate).
    function proposeRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        uint64 at = uint64(block.timestamp + _config.configDelay);
        routerActivateAt[router] = at;
        emit RouterProposed(router, at);
    }

    /// @notice Add the router once its delay elapsed. Callable by anyone.
    function activateRouter(address router) external {
        uint64 at = routerActivateAt[router];
        if (at == 0) revert NothingPending();
        if (block.timestamp < at) revert TooEarly(at);
        delete routerActivateAt[router];
        isRouter[router] = true;
        emit RouterAdded(router);
    }

    /// @notice Remove a router (or cancel its pending addition) immediately.
    function removeRouter(address router) external onlyOwner {
        delete isRouter[router];
        delete routerActivateAt[router];
        emit RouterRemoved(router);
    }

    // ───────────────────────── updater ─────────────────────────

    /// @notice Publish components for a batch of wallets. Several batches may share one epoch.
    ///         A flag published here is dated with the publication time (use `publish` to date it at the rug).
    function setScores(uint64 epoch, address[] calldata wallets, Components[] calldata comps) external onlyUpdater {
        _writeBatch(epoch, wallets, comps);
        uint16 threshold = _config.flagThreshold;
        for (uint256 i; i < wallets.length; ++i) {
            if (comps[i].penalty >= threshold) _noteFlag(wallets[i], uint64(block.timestamp));
        }
    }

    /// @notice Declare the publication of `epoch` complete: flags now reflect everything up to `coveredUntil`, which must
    ///         lie in the past (so every trade at or before it is covered) and never moves back.
    function finalizeEpoch(uint64 epoch, uint64 coveredUntil_) external onlyUpdater {
        _finalize(epoch, coveredUntil_);
    }

    /// @notice Real-time publication: write a batch AND advance `coveredUntil` in one transaction (the checks of
    ///         `setScores` followed by `finalizeEpoch`). `epoch` is then a batch counter that only grows; an empty batch
    ///         just moves `coveredUntil` forward. The batch is bound to the branch it was computed on: `sourceHash` must be the
    ///         hash of block `sourceBlock` (one of the last 256 blocks), so a publication from an orphaned branch, even when
    ///         it is mined again on the new one, reverts.
    function publish(
        uint64 epoch,
        address[] calldata wallets,
        Components[] calldata comps,
        uint64 coveredUntil_,
        uint64 sourceBlock,
        bytes32 sourceHash,
        uint64[] calldata since
    ) external onlyUpdater {
        if (since.length != wallets.length) revert LengthMismatch();
        if (sourceBlock >= block.number || block.number - sourceBlock > 256 || sourceHash == 0 || blockhash(sourceBlock) != sourceHash) {
            revert BadSource();
        }
        _writeBatch(epoch, wallets, comps);
        _finalize(epoch, coveredUntil_);
        uint16 threshold = _config.flagThreshold;
        for (uint256 i; i < wallets.length; ++i) {
            if (comps[i].penalty < threshold) continue;
            uint64 f = since[i]; // start of the wallet's rug activity (detector window start)
            if (f == 0 || f < deployedAt || f > coveredUntil_) revert BadFlagTime(wallets[i]);
            _noteFlag(wallets[i], f);
        }
    }

    function _noteFlag(address wallet, uint64 from) private {
        uint64 cur = flaggedFrom[wallet];
        if (cur == 0 || from < cur) {
            flaggedFrom[wallet] = from;
            emit FlaggedFrom(wallet, from);
        }
    }

    // ───────────── wrongful-flag correction (owner, timelocked like config) ─────────────

    /// @notice Propose moving a wallet's `flaggedFrom` later, or clearing it (newFrom = 0). Effective after `configDelay`.
    function proposeFlagCorrection(address wallet, uint64 newFrom) external onlyOwner {
        uint64 at = uint64(block.timestamp + _config.configDelay);
        pendingFlagCorrection[wallet] = FlagCorrection(newFrom, at, true);
        emit FlagCorrectionProposed(wallet, newFrom, at);
    }

    /// @notice Apply a proposed correction once its delay elapsed. Callable by anyone.
    function activateFlagCorrection(address wallet) external {
        FlagCorrection memory p = pendingFlagCorrection[wallet];
        if (!p.exists) revert NothingPending();
        if (block.timestamp < p.activateAt) revert TooEarly(p.activateAt);
        delete pendingFlagCorrection[wallet];
        emit FlagCorrected(wallet, flaggedFrom[wallet], p.newFrom);
        flaggedFrom[wallet] = p.newFrom;
    }

    function cancelFlagCorrection(address wallet) external onlyOwner {
        if (!pendingFlagCorrection[wallet].exists) revert NothingPending();
        delete pendingFlagCorrection[wallet];
        emit FlagCorrectionCancelled(wallet);
    }

    function _writeBatch(uint64 epoch, address[] calldata wallets, Components[] calldata comps) private {
        if (wallets.length != comps.length) revert LengthMismatch();
        if (epoch < currentEpoch) revert EpochRegression(epoch, currentEpoch);
        currentEpoch = epoch;
        for (uint256 i; i < wallets.length; ++i) {
            Components calldata c = comps[i];
            if (c.volume > 1000 || c.activity > 1000 || c.holding > 1000 || c.identity > 1000 || c.penalty > 1000) {
                revert ComponentOutOfRange(wallets[i]);
            }
            _components[wallets[i]] = c;
        }
        emit ScoresUpdated(epoch, wallets.length);
    }

    function _finalize(uint64 epoch, uint64 coveredUntil_) private {
        if (epoch != currentEpoch || coveredUntil_ >= block.timestamp || coveredUntil_ < coveredUntil) {
            revert BadFinalization();
        }
        coveredUntil = coveredUntil_;
        emit EpochFinalized(epoch, coveredUntil_);
    }

    // ───────────────────────── views ─────────────────────────

    function config() external view returns (Config memory) {
        return _config;
    }

    function pendingConfig() external view returns (PendingConfig memory) {
        return _pending;
    }

    function componentsOf(address wallet) external view returns (Components memory) {
        return _components[wallet];
    }

    /// @notice Reputation score 0..1000 (0 for unknown wallets).
    function scoreOf(address wallet) public view returns (uint256) {
        Config memory c = _config;
        return ReputationMath.score(_withIdentity(wallet, c), c);
    }

    /// @notice Identity component used for scoring: max(stored, babIdentity if BAB held, agentIdentity if agent held).
    function effectiveIdentity(address wallet) public view returns (uint16) {
        return _withIdentity(wallet, _config).identity;
    }

    /// @notice True if the wallet's penalty component reached `flagThreshold`. A flagged wallet has no sell cap
    ///         (sells are priced, never blocked) and forfeits its refundable deposit and cashback on a rug sale; the penalty
    ///         itself is continuous in the penalty component (`quoteDetailed`).
    function isFlagged(address wallet) public view returns (bool) {
        return _components[wallet].penalty >= _config.flagThreshold;
    }

    /// @notice Informational (UI): fresh wallet. NOT used for pricing any more: the deposit falls smoothly with the score
    ///         (`quoteDetailed`). Every stored component is zero and no BAB (non-transferable SBT) is held. The Agent ID
    ///         is soulbound but minted by any wallet for ~gas with a SPACE ID server signature, so it never ends
    ///         freshness (a ring of cheap wallets would waive every deposit); newness is decided by our stored
    ///         components + BAB only. Agent ID only raises the identity component of the regular fee.
    function isFresh(address wallet) public view returns (bool) {
        return _isFresh(wallet, _config);
    }

    /// @notice Total extra fee in bps for `wallet` (regular fee + fresh deposit + flag penalty).
    function quoteFeeBps(address wallet, bool isBuy) public view returns (uint256) {
        FeeQuote memory q = quoteDetailed(wallet, isBuy);
        return q.regularBps + q.depositBps + q.penaltyBps;
    }

    /// @notice Fee split and recipients (legacy shape): `rewardsBps` is the whole pool tier.
    function quote(address wallet, bool isBuy)
        external
        view
        returns (uint256 totalBps, uint256 treasuryBps, uint256 rewardsBps, address treasury, address rewardsPool)
    {
        FeeQuote memory q = quoteDetailed(wallet, isBuy);
        return (q.treasuryBps + q.poolBps, q.treasuryBps, q.poolBps, q.treasury, q.pool);
    }

    /// @notice Full breakdown for the trade module and the cashback ledger. Smooth in the wallet's reputation (no cliffs).
    /// @dev With `s` = score (0..1000, as in the fee curve) and `N` = `neutralScore` (the knee where the regular fee starts
    ///      to fall):
    ///        regular fee      = `feeBps(s)` (sell cap applies to wallets without any penalty component),
    ///        deposit (BUYS)   = `freshDepositBps * (N - s) / N` for s < N, else 0 (refundable, 100% pool),
    ///        penalty          = `penaltyBps * penaltyComponent / 1000` (continuous in the publisher's component, buys and
    ///                           sells; a wallet with a penalty component has no sell cap).
    ///      Integer math, rounded down. If regular + penalty + deposit would exceed `MAX_TOTAL_BPS`, the penalty is cut
    ///      first, then the deposit. Regular fee and penalty split treasury / pool by `treasuryShareBps`.
    function quoteDetailed(address wallet, bool isBuy) public view returns (FeeQuote memory q) {
        Config memory c = _config;
        Components memory comp = _withIdentity(wallet, c);
        uint256 s = ReputationMath.score(comp, c);
        uint256 regular = ReputationMath.feeBps(s, c);
        if (!isBuy && comp.penalty == 0 && regular > c.sellCapBps) regular = c.sellCapBps;
        if (regular > ReputationMath.MAX_TOTAL_BPS) regular = ReputationMath.MAX_TOTAL_BPS;
        uint256 room = ReputationMath.MAX_TOTAL_BPS - regular;
        uint256 penalty = uint256(c.penaltyBps) * comp.penalty / ReputationMath.MAX_SCORE;
        if (penalty > room) penalty = room;
        uint256 deposit = isBuy ? ReputationMath.depositBps(s, c) : 0;
        if (deposit > room - penalty) deposit = room - penalty;
        q.regularBps = regular;
        q.depositBps = deposit;
        q.penaltyBps = penalty;
        // the penalty is split like any other fee: treasury / pool by `treasuryShareBps`; only the deposit is all pool
        uint256 base = regular + penalty;
        q.treasuryBps = base * c.treasuryShareBps / ReputationMath.BPS;
        q.poolBps = base - q.treasuryBps + deposit;
        q.treasury = c.treasury;
        q.pool = c.rewardsPool;
    }

    // ───────────────────────── internal ─────────────────────────

    /// @dev Definition of "fresh" for `isFresh`: all stored components zero and no BAB held.
    function _isFresh(address wallet, Config memory c) private view returns (bool) {
        Components memory s = _components[wallet];
        if (s.volume != 0 || s.activity != 0 || s.holding != 0 || s.identity != 0 || s.penalty != 0) return false;
        return !_holds(c.babToken, wallet);
    }

    /// @dev Stored components with `identity` raised by the on-chain BAB / agent checks.
    function _withIdentity(address wallet, Config memory c) private view returns (Components memory comp) {
        comp = _components[wallet];
        if (c.babIdentity > comp.identity && _holds(c.babToken, wallet)) comp.identity = c.babIdentity;
        if (c.agentIdentity > comp.identity && _holds(c.agentIdToken, wallet)) comp.identity = c.agentIdentity;
    }

    /// @dev balanceOf(wallet) != 0 on `token` via a gas-capped staticcall. Never reverts: a zero address, a failing,
    ///      gas-guzzling, short-returning (<32 bytes) or return-bombing token all count as "no". Only 32 bytes are copied
///      back. A token answering a nonzero word counts as "yes": tokens are chosen by the timelocked owner, not by users.
    function _holds(address token, address wallet) private view returns (bool held) {
        if (token == address(0)) return false;
        uint256 gasCap = IDENTITY_CHECK_GAS;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, shl(224, 0x70a08231)) // balanceOf(address)
            mstore(add(m, 4), wallet)
            let ok := staticcall(gasCap, token, m, 36, m, 32)
            if and(ok, iszero(lt(returndatasize(), 32))) { held := iszero(iszero(mload(m))) }
        }
    }

    function _checkConfig(Config memory c) private view {
        ReputationMath.validate(c);
        if (c.babToken != address(0) && c.babToken.code.length == 0) revert ReputationMath.InvalidConfig("babToken not a contract");
        if (c.agentIdToken != address(0) && c.agentIdToken.code.length == 0) {
            revert ReputationMath.InvalidConfig("agentIdToken not a contract");
        }
    }

    function _setUpdater(address updater_) private {
        if (updater_ == address(0)) revert ZeroAddress();
        updater = updater_;
        emit UpdaterChanged(updater_);
    }
}
