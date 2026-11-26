# Proof of Reputation

Reputation-priced trading for OpenFour launches (Four.meme), built for **BNB Bangkok 2026 — Four.meme / OpenFour track**.

A wallet's on-chain track record sets its trading terms on every launch:
trusted traders pay less, fresh one-time wallets pay a surcharge plus a configurable, refundable deposit (on buys only), and wallets with a rug history pay a penalty in their own rate. Nobody is blocked: flagged wallets can buy and sell, sells are never blocked, and the sell-fee cap does not apply to flagged wallets.
OpenFour's protocol fee is untouched by construction.

Status: work in progress.

## Contracts

| Contract | Role |
| --- | --- |
| `ReputationRegistry` | Per-wallet score from 5 components (shown as 0..1; on chain the integers 0..1000) (volume, activity, holding, identity, penalty). Protocol-only weights and a smooth fee curve; config changes go through a delay. |
| `ReputationTradeModule` | OpenFour `TradeModule` (`evaluate(TradeContext)`): fee by score for every wallet (no buy ban; the flag penalty is part of the wallet's own rate; the sell cap does not apply to flagged wallets; sells are never blocked). Uses `tx.origin` when the trader is a contract. |
| `ReputationLockedToken` | OpenFour token implementation with a pre-migration transfer fee: wallet-to-wallet moves cost the sender's sell rate (to the treasury); trade flows are free, and so are router hand-offs of tokens bought in the same tx (see `docs/transfers.md`). |

### On-chain identity (BABT and Agent ID)

The `identity` component is `max(stored, babIdentity if BABT held, agentIdentity if Agent ID held)`. The checks are a
gas-capped (30k) `staticcall` to `balanceOf` that never reverts: a reverting, gas-burning, short-returning or
return-bombing token simply counts as "not held". Addresses live in the timelocked config and must be contracts.

The Agent ID is **not ERC-8004**. It is the ERC-721 "SPACE ID Agent ID" (OpenFour resolves it through its
AddressManager for the "Binance Agent ID Exclusive" preset 1778027615735).

| Token | BSC **mainnet** address | Testnet |
| --- | --- | --- |
| BABT (Binance Account Bound Token, SBT) | `0x2B09d47D550061f995A3b5C6F0Fd58005215D7c8` | not available; the local demo deploys mocks |
| SPACE ID Agent ID (ERC-721) | `0x60b9262456de011f7d15a54cdd8c48baaa8b022f` | not available; the local demo deploys mocks |

Deploy env vars: `BAB_TOKEN`, `AGENT_ID_TOKEN` (0 = check disabled), `BAB_IDENTITY` / `AGENT_IDENTITY` (default 700 / 500).

### Transfer fee before migration

A rug, as we define it, is "collect tokens by plain transfers onto one wallet, then sell in one trade". With
`ReputationLockedToken` bound to the preset (Registry `upsertTokenImpl` + the preset's `tokenImplId`), moving tokens
wallet-to-wallet before migration costs what selling from the sender would cost: `amount * quoteFeeBps(sender, false) / 10000`
in tokens, paid to the registry treasury, so a clean or warmed wallet gets no discount. Buys and sells through Core are free. A router handing
over tokens it bought in the same transaction is free, and a router pulling tokens from the signer for a sale is free only if it
is on the registry router allowlist (owner proposes, activates after `configDelay`); after migration the token is a normal token with no fee. Details and the
remaining hole: `docs/transfers.md`. OpenFour's own token bases target OpenZeppelin v4 hooks, so the fee is
expressed on OZ v5 `_update`; the interface/storage surface matches `OpenFourToken` (interfaces vendored in
`src/vendor/openfour`, MIT).

### Cashback

The on-chain path: OpenFour's post-trade hook calls `ReputationLedger`, which tracks positions and funds `CashbackPool`;
the deposit and cashback unlock on a curve sale or at migration (`docs/cashback.md`). The Merkle distributor is kept in the
repo but is not deployed.

**Scam fund.** A flagged wallet pays its usual fee plus a penalty, and its whole share of the pool goes into a separate fund, as do the deposit and cashback right confiscated from a rug sale. Honest wallets get their deposit back, their own cashback, and a bonus (the rest of the module fee they paid) from that fund; if the fund is short, bonuses are shared pro rata, and only what exceeds all bonus rights can be swept to the treasury. Details: `docs/cashback.md`.

### Tests and demo

`forge test` (solc 0.8.24, via-IR). Local end-to-end demo on a local fork of BSC testnet: `scripts/demo-local.sh`
(logs are written to `demo-out/`: `demo-run-local.json` for the trades, `demo-migrate-local.json` for the full create, buy, sell, migrate, settle, claim path, and `demo-out/submit-pack/` with OpenFour's `tokens.json`, registration and submit pack, built by `scripts/demo/make_submit_pack.js`). Real testnet: `scripts/demo-testnet.md`.

## Live on BSC Testnet (chain 97)

Own OpenFour fork + our contracts, full demo run on chain. All addresses and tx hashes: `deployments/testnet.json`,
the trade log is produced by `scripts/demo-testnet.md` into `demo-out/`. Explorer: https://testnet.bscscan.com.

| Item | Address |
| --- | --- |
| ReputationRegistry | [`0x496a355E7B84C967Db4bcBBd5F67B2Bf81dd8046`](https://testnet.bscscan.com/address/0x496a355E7B84C967Db4bcBBd5F67B2Bf81dd8046) |
| ReputationTradeModule | [`0xA7c0285f8b8e679f9ffd475ba722EAd5CF1bF5CA`](https://testnet.bscscan.com/address/0xA7c0285f8b8e679f9ffd475ba722EAd5CF1bF5CA) |
| ReputationLockedToken (impl) | [`0x030A3a49b01cB9Fb0EB53368439d5109eE5b03A9`](https://testnet.bscscan.com/address/0x030A3a49b01cB9Fb0EB53368439d5109eE5b03A9) |
| Mock BABT / Mock Agent ID (testnet stand-ins) | [`0x7cF564B1B92668c732b844A9c15070FcFa8b2502`](https://testnet.bscscan.com/address/0x7cF564B1B92668c732b844A9c15070FcFa8b2502) / [`0x6981243bb9F32B2857c973811b352cA885e16512`](https://testnet.bscscan.com/address/0x6981243bb9F32B2857c973811b352cA885e16512) |
| OpenFour fork Registry / Core | [`0xD3FD416B937f252d8C9fdDAdba9BafCF407F1214`](https://testnet.bscscan.com/address/0xD3FD416B937f252d8C9fdDAdba9BafCF407F1214) / [`0xf7aeCDf4411baA046Cdf978da94ddc8BAf890f98`](https://testnet.bscscan.com/address/0xf7aeCDf4411baA046Cdf978da94ddc8BAf890f98) |
| Demo token | [`0x5cA9072d99dE8e92dFe28816D2142764b33Cb4A0`](https://testnet.bscscan.com/address/0x5cA9072d99dE8e92dFe28816D2142764b33Cb4A0) |

Measured extra fee (on top of OpenFour's 50 bps): trusted buy 9 bps ([0xa9c3fa5c...](https://testnet.bscscan.com/tx/0xa9c3fa5c9c55997346329552f6d5c8e0aa40ab8d1afb93e7b337f0004db0cd6f)), regular 50,
fresh 300 ([0x4442a346...](https://testnet.bscscan.com/tx/0x4442a34693f6d347f9b684217e4e630fcde0752d7b2ba37283c67a2e9e48dd4a)), flagged wallet (penalised, score 0.100) 190 and it can buy
([0xa1a5cc63...](https://testnet.bscscan.com/tx/0xa1a5cc635a5db39eb2d37d28d2c35ce37ba6ec4656f2dbd5a97a6f85478d9952)), flagged sell 100 (old deployment; flagged sells are now uncapped), BABT holder 300 -> 155, Agent ID holder 190.
Wallet-to-wallet transfer before migration pays the sender's sell rate in tokens to the treasury (see `docs/transfers.md`;
the live-testnet run above predates this and still shows the old transfer lock, the local demo log `demo-out/demo-run-local.json` shows the fee).

## Risks and limitations

- **Trusted keys.** One publisher key writes scores, flags and `coveredUntil`; the registry owner changes config (behind a timelock) and corrects flags. A wrong or malicious publication can unfairly flag a wallet or delay claims. Plan: multisig for the owner and the publisher, later a ZK proof of the publication.
- **Payer is `tx.origin`.** For a contract trader the module and ledger charge `tx.origin`. A relayer or ERC-4337 bundler is then the payer, not the user: positions mix and payouts go to the relayer.
- **Detector evasion.** The rug detector looks at wallets selling inside a 3-block window. Dumping through a collector contract, or stretching a dump over more than the window, is not detected. Sells in the first 60 s of a token are ignored.
- **Newness.** A wallet stops being fresh (stops paying the deposit) after its first published trade. A stricter threshold rule exists in the publisher (`service/publisher/newness.py`) but is off; its values are to be chosen by measurement. The Agent ID does not end newness; the BAB does.
- **Positions that never close.** Deposits and cashback unlock only on a curve sale or at migration. A token that never migrates (for example one that ends in the Terminal phase) leaves open positions locked; the transfer fee still applies in that phase (`docs/transfers.md`). We have not tested Terminal behaviour against a real Core.
- **Token implementation.** `ReputationLockedToken` is built on OpenZeppelin v5; OpenFour's own `OpenFourToken` uses v4. It needs OpenFour's review before it can replace the official implementation.
- **Mock Core in unit tests.** The unit tests use a stand-in for OpenFour Core that pays the fee tiers before calling the ledger hook. The pool checks its balance on every report, so a different order would revert the trade instead of corrupting accounts. The demos and the publisher rehearsal run the same flow through OpenFour's Core deployed on a local fork of BSC testnet, which passes that check; nothing was run on an official, audited Registry.
- **Rehearsal needs a history snapshot.** `service/publisher/rehearse/rehearse.sh` (local anvil fork of BSC testnet, needs network and OpenFour's developer kit) uses a mainnet-history snapshot that is not in this repository; the publisher itself also starts without one (`--snapshot none`).
