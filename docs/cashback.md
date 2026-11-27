# Cashback

> Every cashback amount is computed on-chain from OpenFour's own post-trade hook; the only trusted input is the rating
> registry's flags. Cashback is paid from the fee pool and no rate is promised.

## Flow
1. The trade module returns two tiers: treasury and the pool. The pool tier is `CashbackPool`, the registry's
   `rewardsPool`. It carries the pool part of the regular fee, the **fresh deposit** (`freshDepositBps`, deploy default 640, scaled by the score: `freshDepositBps * (N - s) / N` for score `s` below the knee `N` = `neutralScore`, zero at or above it; buys only:
   wallets with no history and no BAB pay it on top of the regular rate, on **buys only** (a sell, and a transfer priced as a sell, pays the regular fee without a deposit); the soulbound Agent ID is minted for ~gas with a
   SPACE ID server signature, so it does not end newness) and the **flag penalty** (`penaltyBps`, deploy default 640, scaled by the
   publisher's penalty component: `penaltyBps * component / 1000`, no cliff at `flagThreshold`; flagged wallets also lose the 1 % sell cap, sells are priced, never blocked). The penalty is split
   like any other fee (treasury / pool by `treasuryShareBps`); only the deposit is 100 % pool.
2. After every successful buy or sell OpenFour Core calls `afterHook` on the token's `ReputationLedger` (an OpenFour
   *customData* module, one BeaconProxy per token, enabled by the preset's `customDataId`). The ledger resolves the payer
   exactly like the trade module (`trader.code.length > 0 ? tx.origin : trader`), re-reads the fee quote from the
   registry (same transaction, same rate), mirrors Core's tier arithmetic (`curveQuote * bps / 10000`, rounded down per
   tier) and reports to the pool what arrived there. Quote assets: WBNB / plain ERC-20 without transfer tax.
3. The ledger tracks each payer's curve position per token from curve buys and sells only (`executedAmount`). Token
   transfers are invisible, so moving tokens elsewhere unlocks nothing.
4. A **sell of x** with position p releases fraction `min(x, p) / p` of the deposit and of the module fees paid while the
   position was open (the sale's own deposit and fee are added to the open amounts first, so a full sale releases
   everything; a sell with no tracked position releases only what that sale paid). No fixed shares: the fraction is
   whatever was sold. **Migration releases nothing**: a position unlocks only on a real sale, on the curve or, after migration, into the DEX pair (same pricing there, fee and deposit in tokens, bucket under asset = token; the curve position unlocks through `ledger.onPoolSale`). See `docs/transfers.md`.
5. Released amounts wait in a per-(asset, token, wallet) bucket (one per position) stamped with the latest sale time of that token. A sale of another token never touches it, so a closed honest position keeps its refund even if the wallet later rugs on a different token; `claim` / `forfeit` / `unlocked` take the token address.

## Claim (`CashbackPool.claim(asset, token, wallet)`: anyone may trigger it, the caller pays the gas, funds go only to `wallet`)
- Requires `registry.coveredUntil >= bucket timestamp`. `coveredUntil` is set by the updater through
  `finalizeEpoch(epoch, coveredUntil)` once an epoch's publication is complete (must lie in the past, never moves back);
  score batches alone, including empty ones, never open claims. So a sale that was part of a group dump is already flagged.
- Order: (1) the sale is part of a rug (the wallet's `flaggedFrom` is set and is at or before the bucket's sale time) -> nothing; its deposit and its cashback right move to the scam fund and its bonus right is written off. See *Flag history* below. (2) otherwise the **deposit is refunded
  in full** (held separately, always reserved), then **cashback = min(released own fees, budgetPool)**, then the **bonus** (see *Scam fund*), first come first
  served. If the budget is short, the unpaid remainder of the fee entitlement stays claimable later. A wallet never gets
  back more than the fees it paid. The cap basis is only the POOL PART of the wallet's regular module fee (never the
  treasury part, not the deposit, not the penalty); cashback is still paid only from `budgetPool`, never from the treasury.
- `forfeit(asset, wallet)` is permissionless but only works when the same rule holds (rug start at or before the sale, covered by a publication).

## Flag history: a flag acts as of the sale, not as of now
`ReputationRegistry.flaggedFrom(wallet)` is an append-only date: the first publication of a flag (penalty at or above `flagThreshold`) sets it to the start of the rug activity (the detector window start of the dump, never before the registry existed, never after the `coveredUntil` of that publication); later publications can only move it EARLIER. Removing the penalty later lowers fees again but never clears `flaggedFrom`. The pool decides every bucket by it: a sale at or after `flaggedFrom` is forfeited (also if the updater unflags the wallet afterwards), a sale before it stays claimable even when the wallet is flagged later for another rug. A bucket carries the time of its latest sale, so a wallet that sells again after its rug started loses the whole bucket. A wrongful flag is corrected only by the registry owner: `proposeFlagCorrection(wallet, newFrom)` (later date, or 0 to clear), effective after `configDelay` through `activateFlagCorrection` (anyone), with events `FlagCorrectionProposed` / `FlagCorrected`; `cancelFlagCorrection` withdraws it. A flag published through `setScores` (no rug date) is dated with the publication time.
- `budgetPool` = the honest wallets' own pool shares; `depositPool` = refundable deposits; `fund` = the scam fund. Together
  they never exceed the pool's real balance (`report` reverts otherwise). All are exact quote-asset balances. Only quote assets whitelisted at deploy are accepted (WBNB for the demo), so a token that reports
  success without transferring cannot be used. The recorded regular fee never exceeds the rounded pool tier minus deposit and
  penalty; both hooks check `ctx.token`.

## Scam fund, in plain words
Scammers pay for the honest. The rules:
- A wallet that is flagged **at the time of its trade** pays the usual fee plus the penalty. Its whole pool share goes into the **scam fund** (`fund`): it earns no cashback and no bonus on it.
- When a rug sale is confiscated (`forfeit`, or `claim` of a rug sale), the wallet's deposit and its unpaid cashback right move into the fund too, and its bonus right is written off.
- An honest wallet is paid, on top of its deposit and its own cashback, a **bonus**: the treasury part of the regular fee it paid, so with the fund behind it the wallet gets back the module's whole fee. The right is released by sales in the same proportion as the cashback right. With one collapsed tier (treasury = pool) there is no bonus right, because that part already sits in the pool.
- The bonus comes only from the fund. If the fund is short, every bonus is paid `fund / bonusLiability` of its size (`bonusLiability` = all rights not yet paid or written off). While `fund < bonusLiability`, a normal `claim` (anyone may trigger it) pays deposit and cashback but **no bonus**, and leaves the bonus right whole, so neither a third party nor repeated claims can write it off or drain the fund ahead of others; after a refill a claim pays it in full. Only the wallet itself may take the pro rata share now through `claimBonusPartial(asset, token)`: it gets `fund * right / bonusLiability` and the rest of that right is written off (the ratio fund / liability does not change, so the order of such claims never changes anyone's share).
- `sweepSurplus(asset)` (anyone) sends only `fund - bonusLiability` to the treasury. Deposits, the cashback budget and unpaid bonus rights are never touched.

## Authenticity
`report` is accepted only from the `customData` instance that OpenFour Core itself bound to the reported token
(`Core.tokens(token)`: exists, preset == the bound preset, customData == caller). The preset id is bound once by the owner
(`bindPreset`); nothing else is configurable and nobody can withdraw user funds. A self-made ledger or a token of another
preset is rejected.

## Notes
- `CashbackDistributor` (Merkle roots, `scripts/cashback_root.py`) is kept in the repository as the earlier design but is
  **no longer deployed**; `Deploy.s.sol` deploys `CashbackPool` + `ReputationLedger` instead.
- Registering the ledger needs the OpenFour Registry owner: `upsertModule(..., kind 5)` and `upsertPreset` with
  `customDataId`. On our own testnet fork the deployer is the Registry owner, so no OpenFour admin rights are needed
  (`scripts/demo/demo.js register`). On the official Registry the module goes through OpenFour's audit and submission.

## For judges
Prototype on OpenFour's official hooks. Cashback depends on the budget and on flags by a trusted publisher. The deposit
unlocks on a real sale (curve or DEX pair). 640 / 640 bps are the deploy defaults (950 bps is the module cap). The official
preset needs OpenFour approval.

## Known limitations
- Relayers and ERC-4337: the payer is `tx.origin`, which for a relayer or bundler is not the user; positions of different
  users then mix and the payout goes to the relayer. Such routes need a payer identity confirmed by Core.
- A position that is never sold has no unlock time.
- The updater can delay publication (and so claims) or change flags; this is the single trusted input.
- `executedAmount` / `curveQuote` semantics and gas of full trades through Core were not measured against a real Core.
