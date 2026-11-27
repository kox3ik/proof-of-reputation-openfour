# OpenFour submission: Reputation Bonding V1

Preset `Reputation Bonding V1`, id `1795717041641`, on our own OpenFour fork on BSC testnet (chain 97). The final run of 27 Nov 2026 (~02:19-02:32 BKK) is the deployment that counts. Site: https://kox3ik.github.io/proof-of-reputation-openfour/ . Repository: https://github.com/kox3ik/proof-of-reputation-openfour .

## OpenFour requirement -> where it is (Phase 7)

| Requirement | Where |
| --- | --- |
| Module / Preset / token source and commit | `src/ReputationTradeModule.sol`, `src/ReputationLedger.sol`, `src/ReputationLockedToken.sol` (+ `ReputationRegistry.sol`, `CashbackPool.sol`, `ReputationMath.sol`, `ReputationTypes.sol`). Preset definition and module keys: `submission/reputation-bonding-registration.json`; source list and git revision (`gitRev` in the pack, taken at pack time, not the final head): `submission/reputation-bonding-submit-pack.json`. |
| Gameplay, composition, risk notes | Sections below; risks in more detail in `README.md` ("Risks and limitations"). |
| `descriptor()` tag, version, schema, moduleKey | Section "Descriptors" below. |
| Validator rules and tests | We reuse the standard Bonding V1 validator unchanged (`validator.reuse: "fork"` in the submit pack). We wrote no validator of our own, so there are no validator tests of ours; module behaviour is covered by `test/` (283 forge tests, passing). |
| Create / buy / sell / migrate records | `submission/tokens.json` (three tokens created in the final run) and the run log `keyTxs` listed in `README.md`. **Migrate: recorded on BSC testnet on 27 Nov 2026** with the current contracts: token `0x3122dA3f46E2941fA098Add55caF5345d5d83F69`, migrate tx `0xa7810639fd495261c403a5ed24495e644dd0dfc76ac61bce3b4a0169c04bd08b`, full step list in `submission/migrate-run-testnet-20261127.json` and README. |
| Fork development Registry address | `0x74463FA010193012601912d961a445899164BeeF` (Core `0x210edA86A5343b37a06573b6a4C9d49D0F86B2b3`), BSC testnet. |
| Phase 6 AI audit report | `docs/AI-AUDIT.md` (AI review only, not a human audit). |
| Temporary UI (OpenFour frontend-style) | `app/` (styled with the OpenFour style pack; `frontendStyle` in the submit pack). Screenshots: `submission/screenshots/cashback-panel.png`, `submission/screenshots/lookup-result.png`. Demo link: the site above. Video: `site/media/demo.webm` (1:56). |

## Gameplay

A wallet's on-chain history gives it a score from 0 to 1. The trade fee of every buy and sell follows the score: trusted wallets pay less than the regular 50 bps extra, below score 0.4 a refundable deposit on buys grows smoothly up to 640 bps at score 0, and rug history adds a penalty proportional to the rug component, up to 640 bps, in the wallet's own rate. No cliffs. Nobody is blocked; sells are never blocked. Deposits and cashback unlock only on a real sale, on the curve or into the migrated pair; migration itself releases nothing, and the same pricing applies against the pair. A flagged wallet's deposit and cashback go to a scam fund, which pays honest wallets a bonus. Measured on chain: the same bundle wallet paid 50 bps before the flag and 690 bps after, on buy and on sell (the testnet deployment predates smooth pricing and post-migration pricing; both are in the repository contracts and covered by tests).

## Composition

| Slot | Contract | Origin |
| --- | --- | --- |
| Trade | `ReputationTradeModule` (key `module.trade.reputation`) | ours |
| CustomData | `ReputationLedger` (key `module.data.reputation_ledger`) | ours |
| Token impl | `ReputationLockedToken` (`TOKEN_IMPL_REPUTATION_LOCKED`) | ours |
| Token module, Vault, Curve, Migrate | `module.token.standard`, `module.vault.standard`, `module.curve.bonding`, `module.migrate.bonding` | reused standard (Bonding V1) |
| Validator | Bonding V1 validator of the fork | reused, unchanged |

Supporting contracts (not slots): `ReputationRegistry` (scores, flags, fee curve) and `CashbackPool`. Scores are published by a signed off-chain service (`service/publisher`).

## Risk notes

- One publisher key writes scores and flags; a wrong publication can flag a wallet unfairly. Plan: multisig, later ZK proofs.
- For a contract trader the payer is `tx.origin` (relayers and ERC-4337 bundlers become the payer).
- The rug detector sees sells inside a 3-block window; dumps through a collector contract or stretched over more blocks are not detected, and neither are rugs that collect tokens by plain transfers.
- Positions on tokens that never migrate stay locked.
- `ReputationLockedToken` uses OpenZeppelin v5 while OpenFour's own token bases use v4; it needs OpenFour's review.
- Testnet only. Nothing was run on an official, audited Registry. BABT and Agent ID are stand-ins on testnet.

## Descriptors

| Module | tag / moduleKey source | version | schema |
| --- | --- | --- | --- |
| `ReputationTradeModule` | `module.trade.reputation`, key `0xafaec57895b1a9196fa49cb83c71650fa18041b07c2f25ff62b97399516b04a8` | `1.0.0` (registered with the module; the contract takes it at initialisation) | `ModuleEncodeSchema("trade", 1, [])` |
| `ReputationLedger` | `module.data.reputation_ledger`, key `0x5382845c70c77c6d29086020e4844324ac8a39be01597d2ef567f9e6f5b5ae83` | `1.0.0` | `ModuleEncodeSchema("customData", 1, [])` |

`descriptor()` returns `tagId = bytes8(keccak256(tag))`, the tag and the version. Sources: `src/ReputationTradeModule.sol` lines 52-55 and 85-87, `src/ReputationLedger.sol` lines 69-72 and 158-160, `scripts/demo/demo.js`.

## Hackathon deliverables

- GitHub: https://github.com/kox3ik/proof-of-reputation-openfour
- Demo video (1:56; the brief asks for 2-3 min, so it is slightly shorter): `site/media/demo.webm`; live page: https://kox3ik.github.io/proof-of-reputation-openfour/

**Problem.** Every wallet looks the same to a launchpad, so rug wallets and honest traders pay the same. Wallets with earlier rugs account for about three quarters of rug turnover (75.5 %, see `site/SOURCES.md`). Fresh one-time wallets are free to dump again.

**Audience.** OpenFour / Four.meme launch creators and traders who want fairer terms; the OpenFour team as a default trade rule for launches.

**Differentiation.** We do not ban, we price: no blocked buys or sells, the flag penalty sits in the wallet's own rate. Honest wallets get the forfeited deposits and cashback back. The module sits in the Trade slot and leaves OpenFour's protocol fee untouched.
