# AI audit report

Proof of Reputation (OpenFour trade module, registry, ledger, cashback pool, real-time publisher). All reviews were
done on 26 Nov 2026 during the hackathon; every review was followed by fixes in the same repository. This is an AI
review, not a human audit and not a formal verification: findings were produced by models, each status below was
re-checked against the current code and `git log`.

## Reviewers

| Reviewer | Scope | When |
|---|---|---|
| OpenAI Codex (GPT, high-reasoning mode), several rounds | mechanism design, then code: cashback distributor, ledger + pool, pre-migration transfer fee, real-time publisher, newness rule | 26 Nov, rounds from early morning to afternoon |
| Google Gemini (large-context, extended-reasoning mode), 3 rounds | consistency of code / docs / demo, attack scenarios, what judges would ask | 26 Nov, early morning, late morning, afternoon |
| Claude (Sonnet 5.5) | security review of the contracts at snapshot `dc14421` with 8 own exploit/prototype tests (69 tests green in the copy) | 26 Nov, morning |
| Claude (Sonnet 5.5) | read-only consistency audit of code vs docs vs demo vs deck | 26 Nov, afternoon |

Reviewers saw a snapshot, not the live repository, so some findings concern earlier states of the code. Findings
marked `code only` were derived by reading code, not by running it. Every reviewer was asked to separate "checked code
only", "recomputed independently" and "not confirmed"; unconfirmed items are not listed as findings.

## Findings

Severity is the reviewer's, normalised to High / Medium / Low. Status: **fixed** (commit), **mitigated** (reduced or
documented design choice), **known limitation** (open by design, listed for judges).

| # | Finding | Sev. | Status | Where |
|---|---|---|---|---|
| 1 | Contract trader prices by `tx.origin`; a clean relayer "rents" its reputation to a flagged wallet; a constructor call has `code.length == 0` (Claude) | High | **mitigated** `99fa913`: flagged wallets are no longer banned from buying, they pay their own penalty rate, so renting only changes price, never authorisation. `tx.origin` is used only for pricing/accounting (view), documented in NatSpec | `ReputationTradeModule.sol` `resolveWallet`, `ReputationLedger.sol` |
| 2 | Relayers / ERC-4337: payer is the bundler, positions of different users mix (Claude, Codex) | Medium | **known limitation** (needs payer identity confirmed by Core) | `docs/cashback.md`, `docs/transfers.md`, NatSpec |
| 3 | Registry timelock covers only the config; scores and `updater` change instantly (Claude, Codex) | Medium | **known limitation**: the updater is the single trusted input and can delay publication or change flags; owner/updater powers are stated in the judge note | `docs/cashback.md` |
| 4 | `CONFIG_DELAY` default 0 in deploy script (Claude) | Medium | **fixed** `99fa913`: default 86400 s on non-test chains, 0 only on local/test chain ids | `script/Deploy.s.sol` |
| 5 | `renounceOwnership` freezes config forever (Claude) | Low | **fixed** `99fa913` (disabled in registry; also in pool and distributor) | `ReputationRegistry.sol`, `CashbackPool.sol` |
| 6 | Treasury and rewards pool being the same address creates two tiers to one recipient (Claude) | Low | **fixed** `99fa913` (single tier for equal recipients) | `ReputationMath.sol` / registry fee quote |
| 7 | Transfer lock lets a contract collect tokens; lock stops EOA-to-EOA only (Claude, Codex, Gemini) | High | **fixed** `687bff3`, `02171c5`, `990f868`: the lock was replaced by a pre-migration transfer fee at the sender's sell rate; credit only for same-transaction vault/Core hand-off, otherwise listed routers only; owner-managed allowlist with delay for adding | `ReputationLockedToken.sol`, `docs/transfers.md` |
| 8 | Transient credit could outlive spending; listed router may keep tokens without a sale (Codex) | Medium | **mitigated** `02171c5`: credit capped at the amount received and spent by any exit, router allowlist delayed on add; a listed router that keeps tokens is a documented trust assumption | `ReputationLockedToken.sol` |
| 9 | Transferable Agent ID could end "fresh" status and waive the deposit (Gemini, "critical") | n/a | **false as stated, hardened anyway** `8a1c944`. Agent ID is soulbound (a transfer reverts with `Soulbound()`; checked on mainnet), so it cannot be passed between wallets. Commit `8a1c944` is kept: it is still cheap to mint (SPACE ID server signature, about gas), so newness is decided only by stored components + BAB, one shared `isFresh` | `ReputationRegistry.sol` `isFresh` |
| 10 | Agent ID is borrowable identity score (Claude) | Low | **mitigated**: Agent ID can only lower the identity part of the regular fee, never the flag or the deposit | `ReputationRegistry.sol` |
| 11 | Zero Merkle root with positive total locks funds (Codex) | Medium | **fixed** `a21498f` (zero root and out-of-range epoch rejected). The Merkle distributor was later replaced by the on-chain pool and is no longer deployed | `CashbackDistributor.sol` |
| 12 | Wrong-token / forged ledger accepted; fee above rounded tiers; positions locked after a pool change (Codex) | High | **fixed** `0f77c22` (`ctx.token` check, fee never exceeds rounded tiers, positions unlock after `rewardsPool` change) | `ReputationLedger.sol` |
| 13 | Cashback cap basis and rounding could pay above own deposit plus fee (Codex, Gemini: pool drain by wash trades) | High | **fixed** `4d43620`, `82049c6`, `199e421`, `2904b2c`: cap basis is the pool part of the regular fee, never the treasury part | `ReputationLedger.sol`, `CashbackPool.sol` |
| 14 | Pool trusted reported inflows without holding them (Codex, Gemini) | High | **fixed** `3060611`: `report` reverts `Underfunded` unless the balance covers deposits + budget + fund | `CashbackPool.sol` |
| 15 | Bonus-only buckets stuck; `sweepSurplus` to the pool itself loses accounting; collapsed-tier treasury share (Codex follow-up) | Medium | **fixed** `d6020c5`, `5cc73ce` | `CashbackPool.sol`, `ReputationLedger.sol` |
| 16 | Rounding in partial unlock (Codex) | Low | **fixed** `465205d` (`Math.mulDiv`) | `ReputationLedger.sol` |
| 17 | Claim abuse: partial payout, third-party claim, forfeit of unflagged wallets (Codex) | Medium | **fixed** `5c14744`, `d735f33`: flag-gated forfeit, remainder kept on partial payout, anyone may trigger a claim but funds go only to the wallet | `CashbackPool.sol` |
| 18 | A late flag does not reverse a claim already paid; `coveredUntil` could pass a sale without its flag (Codex) | High | **fixed** `cfab139`, `c2e278b`, `0c76ba3`: append-only `flaggedFrom`, flags wait for coverage that reaches their date, coverage only from processed and confirmed blocks, claim waits for `coveredUntil`. Wrongful flags are corrected only by the owner through the config timelock | `ReputationRegistry.sol`, `service/publisher` |
| 19 | Publication from an orphaned branch could land on the new one; reorg left stale nonce / coverage (Codex, Gemini) | High | **fixed** `1fba179` (`publish` bound to a source block hash), `40dd1a0`, `4122925`, `dfbdc43`, `5b59fcd` (reorg rollback, one tx in flight, tx written down before sending, lost-answer resolution, gas-price cap) | `ReputationRegistry.sol` `publish`, `service/publisher` |
| 20 | Incomplete or duplicate RPC logs accepted; positions before start unknown (Codex) | Medium | **fixed** `8e832ff`, `dfbdc43` (bloom + by-hash cross-check, de-dup, history replay; coverage only when positions are known) | `service/publisher` |
| 21 | Publisher key file readable by others (Codex) | Low | **fixed** `d00237a` | `service/publisher` |
| 22 | Service `publish` call (4 args) does not match contract (6 args) (Gemini) | n/a | **false on current code**: observed on an old snapshot; the current ABI, service and contract agree (`2ea54ee`, `1fba179`, tests in `service/publisher`) | `service/publisher`, `ReputationRegistry.sol` |
| 23 | Demo ABI for `config()` out of date; demo did not exercise cashback (Gemini, Claude) | Medium | **fixed** `b8628c9`, `79d56e2`, `b10a1a2`, `d36d25a` (21-field ABI, scam-fund circle, claim / forfeit / sweep in the demo and rehearsal) | `scripts/demo`, `test/` |
| 24 | Trusted updater can set or clear any flag, delay or open claims (Codex, Gemini) | Medium | **known limitation** (single trusted input; wrongful-flag recovery path exists through the owner, see 18) | `docs/cashback.md` |
| 25 | A position never sold on the curve and never migrated has no unlock time (Codex, Gemini) | Medium | **known limitation** | `docs/cashback.md` |
| 26 | Cheap history warm-up of a wallet can buy a better score (Gemini, Codex) | Medium | **known limitation**; newness is a pluggable rule in the publisher and the deposit is refundable | `service/publisher`, `docs/realtime.md` |
| 27 | Gas of full trades through a real Core not measured (Codex) | Low | **known limitation** | `docs/cashback.md` |
| 28 | Public testnet deployment predates the ledger / pool (Gemini, Claude) | Medium | **known limitation**: `deployments/testnet.json` was last written before the ledger and pool were added; the current flow is shown on a local fork (`scripts/demo-local.sh`) | `deployments/testnet.json`, `README.md` |
| 29 | `init` has no access control (Claude) | Low | **mitigated**: as in OpenFour's own modules; `initializer` blocks a second call, the implementation is locked in the constructor | `ReputationTradeModule.sol` |
| 30 | A fee recipient that reverts on receive would break all trades of the preset (Claude) | Low | **known limitation** (recipients are owner-set; pull payment not implemented) | registry config |
| 31 | A claim triggered by a third party while the fund was short wrote off the wallet's unpaid bonus (Gemini) | Medium | **fixed** `8b4e666`, reworked in the next commit: with a short fund `claim` pays no bonus and leaves the right whole (no write-off, no drain by repeated claims); only the wallet itself may take a pro rata share via `claimBonusPartial` | `CashbackPool.sol` |
| 32 | One bucket per wallet and asset: a late rug sale on token B stripped the refund of an honest closed position on token A; sales glued into one bucket (Codex, Gemini) | High | **fixed** `255512d`: buckets keyed per (asset, token, wallet); `claim` / `forfeit` / `unlocked` take the token. Sales of the same token still share one bucket stamped with the latest sale | `CashbackPool.sol` |
| 33 | Fresh-wallet deposit was also charged on sells; the economics model charges it on buys only (Codex, Gemini) | Medium | **fixed** `cabbb0f`: `quoteDetailed` charges the deposit on buys only; sells and sell-priced transfers pay the regular fee | `ReputationRegistry.sol`, `ReputationLedger.sol` |
| 34 | Deposit refunded at migration, then dump into the PancakeSwap pool unpriced; holding instead of selling farmed rating (found by the team) | High | **fixed**: positions unlock only on a real sale; after migration trades against the migrated pair are priced like the curve (fee, deposit, penalty in tokens), `onPoolSale` unlocks the curve position | `ReputationLockedToken.sol`, `ReputationLedger.sol`, `CashbackPool.sol` |
| 35 | Pricing cliff: regular fee 50 bps at score 0-0.4 but fresh / flagged wallets paid +640 bps, so improving reputation gave no gradual benefit (found by the team) | Medium | **fixed**: smooth deposit (`freshDepositBps * (N - s) / N` on buys) and penalty (`penaltyBps * component / 1000`), total capped at 950 bps; flag history `flaggedFrom` unchanged | `ReputationRegistry.sol`, `ReputationMath.sol`, `ReputationSplit.sol` |

Totals: 35 items. Fixed 21 (rows 4-7, 11-21, 23, 31-35), mitigated 4 (1, 8, 10, 29), known limitation 8 (2, 3, 24-28, 30),
false positives 2 (9 and 22; row 9 additionally hardened).

## What was verified independently

- Fee curve: monotone, continuous, capped at 1000 bps, treasury + pool shares always sum to the total (tests over all 1001 scores).
- No division by zero or overflow in score math; config delay cannot be shortened by replacing a pending config.
- Claim is reentrancy-guarded, marks payment before transfer, and only pays the wallet.
- Merkle root builder matched the OpenZeppelin StandardMerkleTree format on trees of 1, 2, 3 and 5 leaves.
- Hostile BABT / Agent ID tokens cannot revert `evaluate` (gas-capped static calls, any failure means "no").

## Limits of this report

AI reviewers read code and ran tests on snapshots; none ran against the real OpenFour Core or a production
FeeRouter. Real-Core gas, relayer behaviour and migration with leftover tokens are unverified. A human audit is
recommended before any mainnet deployment.
