// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FeeQuote} from "./ReputationTypes.sol";

/// @notice Split of what one priced trade paid into the cashback pool, shared by the token's post-migration pricing.
///         Same arithmetic as `ReputationLedger` (each tier rounded down; a collapsed tier goes wholly to the pool).
library ReputationSplit {
    uint256 internal constant BPS = 10_000;

    /// @dev `cq` is the traded amount in the fee asset; `shareBps` = registry `treasuryShareBps`. Returns what the pool
    ///      receives (`poolAmt`), the refundable deposit, the honest cashback right (`fee`), the part that joins the scam
    ///      fund and the bonus right. A flagged wallet's whole pool share goes to the fund. An unflagged wallet with a
    ///      (partial) penalty gets no cashback or bonus right on the penalty: its pool part goes to the fund.
    function amounts(bool flagged, FeeQuote memory q, uint256 cq, uint256 shareBps)
        internal
        pure
        returns (uint256 poolAmt, uint256 deposit, uint256 fee, uint256 fundIn, uint256 bonus)
    {
        bool collapsed = q.treasury == q.pool;
        poolAmt = collapsed ? cq * (q.treasuryBps + q.poolBps) / BPS : cq * q.poolBps / BPS;
        if (flagged) return (poolAmt, 0, 0, poolAmt, 0);
        uint256 poolTier = cq * q.poolBps / BPS;
        deposit = cq * q.depositBps / BPS;
        if (deposit > poolAmt) deposit = poolAmt;
        uint256 avail = poolTier > deposit ? poolTier - deposit : 0;
        uint256 penTreasuryBps = q.penaltyBps * shareBps / BPS;
        uint256 penPool = cq * (q.penaltyBps - penTreasuryBps) / BPS;
        if (penPool > avail) penPool = avail;
        fee = avail - penPool;
        fundIn = penPool;
        if (collapsed) fundIn += poolAmt - poolTier;
        else {
            uint256 tier = cq * q.treasuryBps / BPS;
            uint256 penT = cq * penTreasuryBps / BPS;
            bonus = tier > penT ? tier - penT : 0;
        }
    }
}
