# Repeat the demo on the real BSC Testnet (chain 97)

Same scripts as `scripts/demo-local.sh`, pointed at a real RPC with a funded deployer. Nothing here touches mainnet
(the script refuses chain ids 56 and 4663).

## What you need

| Item | Detail |
| --- | --- |
| Deployer wallet | one fresh testnet key (NOT reused anywhere else). It becomes OpenFour Registry owner, `Core.signer`, our Registry owner/updater and token creator. |
| tBNB for the deployer | about 0.05 tBNB. The whole local run (OpenFour proxy set + modules, our 2 contracts, preset, ~12 txs) burned about 0.005 tBNB of gas at 0.05 gwei; the rest is margin for 0.1 gwei and retries. |
| 6 demo wallets | fresh keys: `trusted`, `regular`, `fresh`, `flagged`, `babholder`, `agentholder`. Fund each with 0.015 tBNB (buy budget 0.004 + gas). Fund them from the deployer: `cast send <addr> --value 0.015ether ...`. Total tBNB: about 0.05 + 6 x 0.015 = 0.14, round up to 0.2. |
| Identity tokens | Real BABT / SPACE ID Agent ID exist on BSC **mainnet** only (BABT `0x2B09d47D550061f995A3b5C6F0Fd58005215D7c8`, Agent ID `0x60b9262456de011f7d15a54cdd8c48baaa8b022f`; the Agent ID is an ERC-721, not ERC-8004). On testnet deploy the stand-in mocks with `forge script script/DeployDemoMocks.s.sol --broadcast --legacy` (they have an open `mint`). |
| Treasury | any address (can be the deployer). Set `TREASURY`. The rewards pool is the CashbackDistributor, deployed by `Deploy`. |
| Node.js 18+ and Foundry | `OPENFOUR_DEV` = the cloned `four-meme-community/openfour-docs` repo's `developer/` dir. |
| RPC | `RPC_URL=https://bsc-testnet-rpc.publicnode.com` (public). Do NOT use a private/keyed URL (OpenFour tooling rejects them). |

Keys are passed only as environment variables on the command line. Do not create `.env` files and do not commit keys.

## Commands

```bash
export RPC_URL=https://bsc-testnet-rpc.publicnode.com
export OPENFOUR_DEV=/path/to/openfour-docs/developer
export DEPLOYER_PRIVATE_KEY=0x...            # funded deployer
export WALLET_KEYS=0xKEY_TRUSTED,0xKEY_REGULAR,0xKEY_FRESH,0xKEY_FLAGGED,0xKEY_BAB,0xKEY_AGENT   # each funded
export TREASURY=0x...

# 1. OpenFour: your own proxy set (you become Registry owner and Core.signer)
scripts/demo/prepare-fork-deploy.sh                       # patched scratch copy (see header comment); needed for instant-mining nodes only,
cd $OPENFOUR_DEV/fork-deploy-local && npm run fork        # on the real testnet `cd $OPENFOUR_DEV/fork-deploy && npm run fork` works as is
cd -
export FORK_JSON=$OPENFOUR_DEV/fork-deploy-local/out/fork-deployment.json   # or fork-deploy/out/...

# 2a. mocks for BABT / Agent ID (testnet only), then export their addresses
forge script script/DeployDemoMocks.s.sol --rpc-url $RPC_URL --broadcast --legacy --gas-price 100000000
export BAB_TOKEN=$(jq -r .babToken deployments/demo-mocks.json) AGENT_ID_TOKEN=$(jq -r .agentIdToken deployments/demo-mocks.json)
# 2. our contracts: registry, trade module and ReputationLockedToken (optionally: CONFIG_DELAY=86400 for a realistic timelock; default 0 for the demo)
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --legacy --gas-price 100000000

# 3. register module + token implementation (ReputationLockedToken) + preset on YOUR fork Registry, developerFeePoolBps=0
node scripts/demo/demo.js register

# 4. create token, publish scores, trade from the 6 wallets, write the log
OUT_JSON=$PWD/demo-out/demo-run-testnet.json node scripts/demo/demo.js trade
```

Add `--verify` to step 2 with a BscScan testnet API key (`--etherscan-api-key`) to publish source; the key is a secret,
pass it via the command line only.

Expected result (same as the local fork): buy extra fee trusted 9 bps < regular 50 bps < fresh 300 bps; babholder 300 -> 155 bps after receiving a BABT; agentholder 190 bps; flagged (penalised) wallet buys at its curve fee (score 100 -> 190 bps; no buy ban)
flagged sell succeeds at the 100 bps cap,
router buy priced by `tx.origin` (the router hands tokens to the signer for free); a wallet-to-wallet token transfer before migration pays the sender's sell rate (`quoteFeeBps(sender,false)`) in tokens to the treasury. Protocol fee 50 bps and developer fee 0.

## Caveats on the real testnet

* The state is not instant-mined: txs take about 3 s each; the script awaits receipts, so a full run is a few minutes.
* Anvil's demo keys are public; never fund them on a real network.
