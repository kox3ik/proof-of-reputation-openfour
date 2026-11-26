#!/usr/bin/env bash
# Repeatable local demo against an ALREADY RUNNING anvil fork of BSC Testnet (chain-id 97, 127.0.0.1:8545):
#   anvil --fork-url https://bsc-testnet-rpc.publicnode.com --chain-id 97 --port 8545 --gas-price 50000000
# Needs: OPENFOUR_DEV=<openfour-docs>/developer (npm install done), forge/cast in PATH (~/.foundry/bin).
# Only Anvil's public default dev keys are used. Nothing is ever sent to mainnet or the real testnet.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
: "${OPENFOUR_DEV:?set OPENFOUR_DEV to <openfour-docs>/developer}"
export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
[ "$(cast chain-id --rpc-url "$RPC_URL")" = "97" ] || { echo "expected chain-id 97 fork"; exit 1; }
# anvil default accounts (public): #0 deployer/owner/updater/Core.signer, #1..#4 + #5, #6 demo wallets (trusted, regular, fresh, flagged, babholder, agentholder), #8 treasury, #9 rewards
# public Anvil default dev key, not a secret
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# public Anvil default dev keys, not secrets
export WALLET_KEYS=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d,0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a,0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6,0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a,0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba,0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
export TREASURY=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955

# local anvil only: make sure every demo wallet has plenty of test funds (fork balances are the real testnet ones)
for k in ${WALLET_KEYS//,/ } "$DEPLOYER_PRIVATE_KEY"; do
  cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$(cast wallet address "$k")" 0x56BC75E2D63100000 >/dev/null
done

# 1. OpenFour developer-owned proxy set on the fork (you become Registry owner and Core.signer)
FORK_DIR="$OPENFOUR_DEV/fork-deploy-local"
if [ "${SKIP_FORK_DEPLOY:-0}" != 1 ]; then
  scripts/demo/prepare-fork-deploy.sh
  (cd "$FORK_DIR" && RPC_URL="$RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" node fork-from-chain.js | tail -3)
fi
export FORK_JSON="$FORK_DIR/out/fork-deployment.json"
export OPENFOUR_CORE=$(jq -r .addresses.core "$FORK_JSON") QUOTE_ASSET=$(jq -r .addresses.wbnb "$FORK_JSON")

# 2. our contracts. The real BABT / Agent ID live on BSC mainnet only, so the demo deploys stand-in mocks on the fork
#    and points the registry's identity checks at them.
forge build >/dev/null
forge script script/DeployDemoMocks.s.sol --rpc-url "$RPC_URL" --broadcast --legacy --gas-price 50000000 | tail -3
export BAB_TOKEN=$(jq -r .babToken deployments/demo-mocks.json) AGENT_ID_TOKEN=$(jq -r .agentIdToken deployments/demo-mocks.json)
forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --legacy --gas-price 50000000 | tail -4

# 3. register module + preset (+ fee override), 4. create token, trade, write log
node scripts/demo/demo.js register
export OUT_JSON="${OUT_JSON:-$PWD/demo-out/demo-run-local.json}"
node scripts/demo/demo.js trade

# 5. full lifecycle on a small curve: create -> buy -> sell -> migrate -> settle -> claim
export MIGRATE_OUT_JSON="${MIGRATE_OUT_JSON:-$PWD/demo-out/demo-migrate-local.json}"
OUT_JSON="$MIGRATE_OUT_JSON" node scripts/demo/demo.js migrate

# 6. OpenFour submission files (tokens.json, registration, submit pack) from the logs above
node scripts/demo/make_submit_pack.js --run "$OUT_JSON" --migrate "${MIGRATE_OUT_JSON:-$PWD/demo-out/demo-migrate-local.json}" --out "${PACK_OUT:-$PWD/demo-out/submit-pack}"
