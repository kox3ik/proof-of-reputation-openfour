// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Components, Config} from "./ReputationTypes.sol";

/// @title ReputationMath
/// @notice Pure integer math: component weighting, fee curve and config validation.
library ReputationMath {
    uint256 internal constant MAX_SCORE = 1000;
    uint256 internal constant BPS = 10_000;
    /// @dev FeeRouter maxTaxBps is 1000 and (assumed) includes the 50 bps protocol fee; the module never charges more
    ///      than 950 bps in total (regular fee + fresh deposit + flag penalty).
    uint256 internal constant MAX_TOTAL_BPS = 950;
    uint256 internal constant MAX_CONFIG_DELAY = 7 days;

    error InvalidConfig(string reason);

    /// @notice score = (weighted average of 4 positive components) - penalty * penaltyWeight / 1000, clamped 0..1000.
    function score(Components memory c, Config memory cfg) internal pure returns (uint256) {
        uint256 sumW = uint256(cfg.wVolume) + cfg.wActivity + cfg.wHolding + cfg.wIdentity;
        uint256 positive = (
            uint256(c.volume) * cfg.wVolume + uint256(c.activity) * cfg.wActivity + uint256(c.holding) * cfg.wHolding
                + uint256(c.identity) * cfg.wIdentity
        ) / sumW;
        uint256 pen = (uint256(c.penalty) * cfg.penaltyWeight) / MAX_SCORE;
        return positive > pen ? positive - pen : 0;
    }

    /// @notice Smooth, monotonically non-increasing fee curve (bps) in the score.
    /// @dev s < N : fee = neutral + (zero - neutral) * (N - s)^2 / N^2           (quadratic, convex)
    ///      s >= N: fee = neutral - (neutral - min) * (s - N) / (1000 - N)       (linear)
    ///      Continuous at s = N (both give `neutralBps`); rounding is toward the lower fee.
    function feeBps(uint256 s, Config memory cfg) internal pure returns (uint256) {
        if (s > MAX_SCORE) s = MAX_SCORE;
        uint256 n = cfg.neutralScore;
        if (s < n) {
            uint256 d = n - s;
            return uint256(cfg.neutralBps) + (uint256(cfg.zeroBps) - cfg.neutralBps) * d * d / (n * n);
        }
        return uint256(cfg.neutralBps) - (uint256(cfg.neutralBps) - cfg.minBps) * (s - n) / (MAX_SCORE - n);
    }

    /// @notice Refundable deposit on a buy (bps), falling linearly with the score: full `freshDepositBps` at score 0, zero at
    ///         `neutralScore` and above. Rounded down.
    function depositBps(uint256 s, Config memory cfg) internal pure returns (uint256) {
        uint256 n = cfg.neutralScore;
        if (s >= n) return 0;
        return uint256(cfg.freshDepositBps) * (n - s) / n;
    }

    /// @notice Reverts with InvalidConfig if the config breaks any protocol invariant.
    function validate(Config memory c) internal pure {
        if (uint256(c.wVolume) + c.wActivity + c.wHolding + c.wIdentity == 0) revert InvalidConfig("weights sum zero");
        if (c.penaltyWeight > MAX_SCORE) revert InvalidConfig("penaltyWeight");
        if (c.flagThreshold == 0 || c.flagThreshold > MAX_SCORE) revert InvalidConfig("flagThreshold");
        if (c.neutralScore == 0 || c.neutralScore >= MAX_SCORE) revert InvalidConfig("neutralScore");
        if (c.zeroBps < c.neutralBps || c.neutralBps < c.minBps) revert InvalidConfig("curve order");
        if (c.zeroBps > MAX_TOTAL_BPS) revert InvalidConfig("zeroBps > cap");
        uint256 extra = c.freshDepositBps > c.penaltyBps ? c.freshDepositBps : c.penaltyBps;
        if (uint256(c.zeroBps) + extra > MAX_TOTAL_BPS) revert InvalidConfig("fee + deposit/penalty > cap");
        if (c.sellCapBps > MAX_TOTAL_BPS) revert InvalidConfig("sellCap > cap");
        if (c.treasuryShareBps > BPS) revert InvalidConfig("treasuryShare");
        if (c.treasury == address(0) || c.rewardsPool == address(0)) revert InvalidConfig("zero recipient");
        if (c.babIdentity > MAX_SCORE || c.agentIdentity > MAX_SCORE) revert InvalidConfig("identity value");
        if (c.configDelay > MAX_CONFIG_DELAY) revert InvalidConfig("configDelay");
    }
}
