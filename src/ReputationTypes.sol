// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Per-wallet reputation components, each in 0..1000, published off-chain once per epoch.
struct Components {
    uint16 volume; // trading volume quality
    uint16 activity; // breadth / consistency of on-chain activity
    uint16 holding; // holding behaviour (diamond hands vs. instant dumps)
    uint16 identity; // stored (off-chain) identity value; the registry raises it from on-chain BAB / Agent ID checks
    uint16 penalty; // participation in rugs / coordinated dumps
}

/// @notice Protocol-wide scoring and fee configuration. Only the protocol admin can change it.
struct Config {
    // weights of the four positive components (relative, must not all be zero)
    uint16 wVolume;
    uint16 wActivity;
    uint16 wHolding;
    uint16 wIdentity;
    uint16 penaltyWeight; // 0..1000: score -= penalty * penaltyWeight / 1000
    uint16 flagThreshold; // 1..1000: penalty >= threshold => flagged: extra `penaltyBps`, no sell cap, deposit and cashback forfeited
    // fee curve (bps)
    uint16 neutralScore; // 1..999
    uint16 zeroBps; // fee at score 0 (fresh wallet)
    uint16 neutralBps; // fee at neutralScore
    uint16 minBps; // fee at score 1000 (may be 0)
    uint16 sellCapBps; // sell fee never exceeds this
    // surcharge destinations (never the token creator)
    uint16 treasuryShareBps; // 0..10000 of the computed fee that goes to treasury
    address treasury;
    address rewardsPool;
    // delay between proposeConfig and activateConfig
    uint32 configDelay;
    // on-chain identity checks (zero address = check disabled); identity component = max(stored, granted values)
    address babToken; // Binance Account Bound token (SBT); BSC mainnet: 0x2B09d47D550061f995A3b5C6F0Fd58005215D7c8
    address agentIdToken; // SPACE ID "Agent ID" ERC-721 (NOT ERC-8004); BSC mainnet: 0x60b9262456de011f7d15a54cdd8c48baaa8b022f
    uint16 babIdentity; // 0..1000 identity value granted when balanceOf(wallet) > 0 on babToken (non-transferable SBT)
    uint16 agentIdentity; // 0..1000 identity value granted when balanceOf(wallet) > 0 on agentIdToken
    // refundable surcharge of fresh wallets (all-zero components, no BAB; the soulbound Agent ID, minted for gas with a SPACE ID server signature, does not count); 100% to the cashback pool, refunded when honest
    uint16 freshDepositBps;
    // extra fee of rug-flagged wallets (penalty >= flagThreshold); 100% to the pool, never refunded; lifts the sell cap
    uint16 penaltyBps;
}

/// @notice Fee breakdown of one trade. `poolBps` already includes `depositBps` and `penaltyBps`.
struct FeeQuote {
    uint256 regularBps; // curve fee (treasury part + regular pool part)
    uint256 depositBps; // fresh-wallet deposit
    uint256 penaltyBps; // flagged-wallet penalty
    uint256 treasuryBps; // treasury tier
    uint256 poolBps; // rewards pool tier = regular pool part + deposit + penalty
    address treasury;
    address pool;
}

/// @notice Config waiting for its activation time.
struct PendingConfig {
    Config config;
    uint64 activateAt; // 0 = nothing pending
}
