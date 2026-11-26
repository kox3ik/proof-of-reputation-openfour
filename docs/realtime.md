# Real-time publication

> Scores and flags reach the registry within a few blocks of the trade or the dump, not once per epoch. One trusted key
> (the updater) writes them through `publish()`; flags carry a date (`flaggedFrom`) so that they act as of the sale.

## What "real time" means here
- `service/publisher/` is a daemon. On every new block it reads OpenFour Core `Trade` / `TokenCreated` logs on the target RPC,
  updates per-wallet stats incrementally, runs the rug detector incrementally, recomputes components **only for wallets whose
  inputs changed** and sends **one `ReputationRegistry.publish(epoch, wallets, components, coveredUntil, sourceBlock, sourceHash, since)` tx per block with
  changes** (`--interval S` batches to at most one tx per S seconds, `--max-batch N` splits large batches).
- The payer is the tx signer (`tx.from`), as the trade module prices it. First-seen wallets start from a mainnet-history
  snapshot (Four.meme + OpenFour history, labels by the same detector). The snapshot is built by an internal tool that is
  not part of this repository; without it the service starts from an empty state (`--snapshot none`) and rebuilds positions
  by replaying blocks from `--history-from`.
- **Rug rule:** a dumper sells at least 0.5 of the position it held at the window start (rule "mf050 / RUG2 v5", used for all
  history labels; constant `RUG_MIN_FRAC` in `service/publisher/config.py`). Window = 3 blocks from a sell, at least 2 wallets,
  at least 5 % of supply, price drop at least 30 %, ignored in the first 60 s of a token. The history labels and the service use the same detector with this threshold
  (default 0.8 overridden to 0.5). The shipped snapshot is rebuilt with it (Four.meme events from the mf050 run).
- **`coveredUntil`** = the latest time whose flag decisions are final: the second before the first block whose window is still
  open (block time of head-2, never above head-1 minus one second). It moves in the same `publish` tx, so cashback claims open
  as soon as the decision for the sale is final, not at an epoch end.

## Safety rules of the daemon
- **Confirmations:** only blocks up to `head - N` are read (`--confirmations`, default 2) and a tx counts as done only when its
  receipt is that deep. Every block header is checked against the stored parent hash; a replaced or shorter tip rolls the engine
  back to the newest checkpoint below the fork point and the wallets sent since then are evaluated again (a wallet that only
  existed on the dropped branch is written back to zero).
- **One tx in flight.** A failed estimate, a price above `--max-gas-price-gwei` (default 3) or a refused send sends nothing and the
  batch is re-queued (retry after 2 s). A stuck tx is replaced with +25 % gas (same nonce) after `--bump-after` seconds; a dropped
  nonce triggers a resync of epoch, nonce and `coveredUntil` from the chain. Receipt errors never stop the loop.
- **`coveredUntil`** comes from the last block actually processed and is sent only in the last batch of a round, after every
  earlier tx is confirmed OK. A lost or reverted batch is re-queued, so coverage cannot pass a lost flag.
- **State:** checkpoints (`--state-dir`, atomic, three generations, only when no tx is in flight) + a journal of sent wallets.
  After a restart the daemon re-reads the blocks produced meanwhile; on a first start it replays from the block of the
  chain's `coveredUntil` (and refuses to start after a gap unless `--allow-gap`). Positions opened before the first processed
  block of a first start are unknown (the same limit as the history snapshot).
- Batches are limited to `--max-batch` wallets (150 new wallets = about 3.7M gas) and a tx never asks for more than 12M gas.

## Measured latencies (local anvil fork, 1 block per second, daemon polling every 0.2 s, 2 confirmations)
Source: `service/publisher/rehearse/rehearse.sh` (`rehearsal-result.json`).

| Event | Blocks | Seconds on the fork |
|---|---|---|
| Newcomer buys, fee 450 -> 133 bps (score 0.169) | 3 | 3 |
| Wallet with mainnet history buys right after, fee 450 -> 25 bps (score 0.702) | 5 | 5 (waits for the previous tx to confirm) |
| 3 bundle wallets dump in one block, flagged on chain | 6 | 6 |
| `coveredUntil` passes an honest sale, then the claim pays (before: claim reverts) | 6 | 6 |

Latency = (window of 3 blocks for flags) + confirmations + the mining block + confirmation of the previous tx. With
`--confirmations 0` the figures were 1 / 1 / 3 / 3 blocks (earlier measurement); every confirmation adds one block. Seconds scale
with the real block time (the fork used 1 s).

### Failure rehearsal (`MODE=safety rehearse.sh`, `rehearse/out/safety-result.json`)
A sampler read `coveredUntil` and the flags at one block every 250 ms and counted a violation whenever `coveredUntil` passed a
dump's time while one of its wallets was not flagged at that block.
- **Send failure:** the publish of a bundle dump was refused twice (injected): flagged 6 blocks after the dump, coverage did not move first.
- **Restart:** the daemon was stopped, a second bundle dumped while it was down, `coveredUntil` did not change while down; after the
  restart (77 blocks behind, restored from the checkpoint) the bundle was flagged 1.9 s later.
- **Reorg:** `evm_snapshot` / `evm_revert` dropped 4 blocks that the daemon had processed and published from; it logged `reorg`, rolled
  back to its checkpoint, the orphan wallet is zero again and a trade on the new branch was scored.
- **Violations: 0.**

## Gas
Measured by the rehearsal (tx gas, steady state) and `forge test --match-contract PublishGas -vv` (execution part):

| Publish tx | 0 wallets | 1 | 10 | 100 |
|---|---|---|---|---|
| New wallets (zero -> nonzero slot) | 36.7k | 61.2k | 282k | 2.49M |
| Rewrite of known wallets | 36.7k | 44.1k | 111k | 777k |

Model: 36.7k base (intrinsic, epoch, coveredUntil) + 24.5k per new wallet + 7.4k per rewritten wallet (the very first publish
also pays about 17k to initialise epoch and coveredUntil). Checked on the fork: 3 new wallets 110.2k, 3 rewrites 58.9k.

Per day at current OpenFour activity (343 active wallets/day median, about 4,700 trades/day average since June), counting every
trade as one wallet rewrite and all 343 wallets as new:

| Mode | Txs/day | Gas/day | BNB/day at 0.05 gwei | at 0.1 gwei |
|---|---|---|---|---|
| Per block, upper bound (each trade alone in its block, plus one coverage-only tx after it) | 9,400 | 386M | 0.019 | 0.039 |
| `--interval 60` (at most one tx per minute, coverage in the same tx) | 1,440 | 94M | 0.0047 | 0.0094 |

Same-block trades share a tx, wallets whose components did not change are skipped, so real use is below the bound.

## What is trusted: the updater key
Whoever holds the updater key can, within the contract's checks:
- **set or remove any flag** (a penalty component up to 1000 for any wallet) and date it (`flaggedFrom` can be set to any time between the registry's creation and the coverage of that publication, and only moves earlier);
- **delay claims** by not publishing, or **open them early** by moving `coveredUntil` forward (it never moves back) before the flags of that period are in;
- change fees through components (scores), within 0..1 (integers 0..1000 on chain).
It cannot touch funds directly. **Anyone** may call `forfeit` on a wallet whose rug started at or before a covered sale, which moves the unlocked deposit into the cashback budget. The registry owner can replace the updater at once (`setUpdater`) and can correct a wrongful `flaggedFrom` only through the config timelock (`proposeFlagCorrection`, then `activateFlagCorrection` after `configDelay`, with events). Flags are an append-only history: unflagging later lowers future fees but does not release a deposit of a sale made during the rug.

The daemon refuses to start if its key is not the registry's `updater`, never writes components above 1000, and re-queues failed batches. The key is read from a file by path (`--key-file` / `POR_UPDATER_KEY_FILE`, mode 0600, owned by the daemon's user) and is never logged. Stopping the daemon stops new flags and coverage; claims then wait.

## Source binding, coverage and positions (review round 9)
- **Source binding:** `publish(epoch, wallets, comps, coveredUntil, sourceBlock, sourceHash, since)` reverts unless `blockhash(sourceBlock) == sourceHash` (one of the last 256 blocks). The daemon passes the last block it processed, so a publication computed on an orphaned branch cannot land on the new one even when the node mines it again. After a rollback the sender re-reads nonce, epoch and `coveredUntil` from the canonical chain.
- **Flag dates:** `since[i]` is the dump window start of a flagged wallet (the registry creation time for flags from the history snapshot). A flag whose date is later than the `coveredUntil` it would be published with waits until the coverage reaches it.
- **Positions:** a first start replays history from `--history-from` (buys before the first processed block would otherwise be unknown, and a dump of such positions would be missed). `coveredUntil` is advanced only when `--history-from <= --registry-block`; otherwise the daemon logs `coverage_disabled` and publishes scores only (flags need a coverage that reaches their date, so they wait too).
- **Logs:** every block range is parsed completely before it is applied; repeated logs count once; a block whose header bloom contains the Core address, or that returned any log, is cross-checked with a second query by block hash; any mismatch fails the range and it is read again.
- **Coverage stall:** when the safe boundary moves and no component changed, an empty batch advances `coveredUntil` as long as an uncovered trade lies below it (batch order kept: coverage only in the last batch).
- **Lost answer:** the tx (hash, nonce, payload) is written to the state directory before the send; after a lost answer or a restart that nonce is resolved (receipt, drop, re-broadcast) before any new batch. At the gas-price cap a stuck tx raises `ALERT_tx_stuck_at_gas_cap` and is re-broadcast, so a dropped tx cannot block the queue.
- **Gas:** the block gas limit is read from the chain; a batch that would use more than `--gas-share` (default 0.25) of it is split before signing, the estimate is never clipped. A flagged wallet costs one more new storage slot (`flaggedFrom`), so 100 new flagged wallets use about 4.9M gas.

## Newness: when a wallet stops being fresh
The registry treats a wallet as fresh while all its published components are zero. The service decides what to publish, so the
rule is pluggable (`service/publisher/newness.py`, one hook in `Engine.drain`):
- **default (active)**: no override, a wallet gets its components as soon as it has any history. This is the current registry behaviour.
- **`ThresholdRule`** (off): a wallet stays at zero until it has at least N tokens, N days and a minimum volume
  (`run.py --newness threshold --newness-min-tokens N --newness-min-days N --newness-min-volume BNB`). Flags are never held back.
- Other measures (closed honest rounds, age, trade count) need one more per-wallet counter in `WalletTable` and one field in the rule.

## Run
`python3 service/publisher/run.py --rpc URL --registry 0x.. --core 0x.. --wbnb 0x.. --key-file PATH [--snapshot PATH] [--interval S]`.
Deploy with `UPDATER=<address>` so the registry accepts the key. Tests: `cd service/publisher && python3 -m unittest discover -s tests`.
Rehearsal: `service/publisher/rehearse/rehearse.sh` (local anvil fork only; anvil and the daemon run as `systemd --user` units
and are stopped by unit name).
