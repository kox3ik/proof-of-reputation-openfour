# Numbers on the page and where they come from

Base dir: our private working directory, not part of this repo.
PITCH = `deck/mentor-pitch-20261127.md`, DECK = `deck/presentation-v2.html`,
RUNLOG = `deck/video/por-simulation-testnet-20261126T191952Z-runlog.json`.

| Number on the page | Source |
|---|---|
| 75.5 % of rug turnover from wallets with earlier rugs | PITCH, "The problem" |
| 35.0 % of curve volume from rug participants, 6.5 % of wallets | DECK, "The problem" slide |
| 5,358 wallets, 919 coordinated rug events, 844 tokens | DECK, "The problem" slide |
| 35.6M Four.meme trades, 1.47M tokens | PITCH, "Why trust it" |
| 820k OpenFour trades since launch | PITCH ("820k"); DECK has 819,797 |
| 50 bps before, 690 bps after the flag (buy and sell) | RUNLOG `steps` (post-flag trades: buyBefore/AfterBps, sellBefore/AfterBps) |
| 640 bps deposit, 640 bps penalty, 50 bps regular | RUNLOG `rates` (freshDepositBps, penaltyBps, zeroBps) |
| 690 bps for a new wallet (50 + 640) | RUNLOG `trades[0].before.bps` |
| 8,000 wallets scored, 800 flagged | RUNLOG `ratingLoad` (walletsPublished, flaggedHistory), `preload` |
| Card scores 0.799 / 0.570 / 0.000 (static fallback) | RUNLOG `preload.samples` (approx_score) |
| Live scores, fees, deposit in cards and lookup | not stored: read live from the registry `0x7231682c...c105` on BSC testnet (chain 97); they change if the registry changes |
| Wallet addresses in cards and quick buttons | RUNLOG `preload.samples` (real), `wallets` (sim honestA, bundle1) |
| Transaction hashes in Receipts | RUNLOG `keyTxs` |
| 1:56 demo length | `deck/video/por-simulation-testnet-cut.webm` (duration) |
| 235 contract tests, 51 publisher tests | Measured 27.11.2026 ~03:00 BKK on commit c69b4bd+: `forge test` → 235 passed, 0 failed (13 suites); `cd service/publisher/tests && python3 -m unittest discover -p "test_*.py"` → Ran 51 tests, OK. (The mentor pitch still says 227 — older count.) |
| "Trusted wallets pay below 50 bps" | no number from files: qualitative, consistent with the live registry reading |
