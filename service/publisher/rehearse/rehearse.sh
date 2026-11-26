#!/usr/bin/env bash
# Local rehearsal of the real-time publisher on an anvil fork of BSC testnet (chain 97). Local only: nothing is sent to
# mainnet or to the real testnet; only anvil's public dev keys and the testnet-only updater key (read from a file).
# Needs: OPENFOUR_DEV (<openfour-docs>/developer, npm installed), forge/cast/anvil in ~/.foundry/bin, node.
# Anvil and the daemon run as systemd --user units and are stopped by unit name at the end.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
H="$(cd "$REPO/../.." && pwd)"
export PATH="$HOME/.foundry/bin:${NODE_BIN:+$NODE_BIN:}$PATH"
POR_TMP="${POR_TMP:-${TMPDIR:-/tmp}/por-rt}"
: "${OPENFOUR_DEV:=$H/work/contracts-v2/developer}"; export OPENFOUR_DEV
PORT="${PORT:-8549}"; export RPC_URL="http://127.0.0.1:$PORT"
KEYFILE="${UPDATER_KEY_FILE:-$H/testnet-keys/updater.key}"
OUT="${OUT_DIR:-$HERE/out}"; mkdir -p "$OUT"
UNIT_A=por-rt-anvil; UNIT_P=por-rt-publisher
FORK_URL="${FORK_URL:-https://bsc-testnet-rpc.publicnode.com}"
cleanup() { systemctl --user stop "$UNIT_P" "$UNIT_A" 2>/dev/null || true; }
trap cleanup EXIT
cleanup
systemd-run --user --collect --unit=$UNIT_A -p MemoryMax=8G -p Nice=19 \
  anvil --fork-url "$FORK_URL" --chain-id 97 --port "$PORT" --gas-price 50000000 --host 127.0.0.1 >/dev/null
for _ in $(seq 60); do cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$RPC_URL")" = 97 ]

# public Anvil default dev key, not a secret
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# honest, newcomer, bundle x3, veteran (anvil public dev keys #1..#6)
# public Anvil default dev keys, not secrets
export WALLET_KEYS=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d,0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a,0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6,0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a,0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba,0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
export TREASURY=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955
UPDATER_ADDR="$(python3 -c "import sys; sys.path.insert(0, '$HERE/..'); import txsign; print(txsign.address_of(txsign.load_key('$KEYFILE')))")"
for a in "$UPDATER_ADDR" $(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY"); do
  cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$a" 0x56BC75E2D63100000 >/dev/null
done

cd "$REPO"
FORK_DIR="$OPENFOUR_DEV/fork-deploy-local"
scripts/demo/prepare-fork-deploy.sh >/dev/null
(cd "$FORK_DIR" && RPC_URL="$RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" node fork-from-chain.js | tail -2)
export FORK_JSON="$FORK_DIR/out/fork-deployment.json"
export OPENFOUR_CORE=$(jq -r .addresses.core "$FORK_JSON") QUOTE_ASSET=$(jq -r .addresses.wbnb "$FORK_JSON")
FO=(--out "$POR_TMP-out" --cache-path "$POR_TMP-cache")
forge build "${FO[@]}" >/dev/null
# forge may write only below deployments/ (foundry.toml); these files are git-ignored and never touch the real testnet records
export MOCKS_OUT_JSON=deployments/rt-demo-mocks.json POR_OUT_JSON=deployments/rt-por-deployment.json
export STATE_JSON="$REPO/deployments/rt-demo-state.json" POR_JSON="$REPO/deployments/rt-por-deployment.json"
forge script "${FO[@]}" script/DeployDemoMocks.s.sol --rpc-url "$RPC_URL" --broadcast --legacy --gas-price 50000000 >/dev/null
export BAB_TOKEN=$(jq -r .babToken "$REPO/$MOCKS_OUT_JSON") AGENT_ID_TOKEN=$(jq -r .agentIdToken "$REPO/$MOCKS_OUT_JSON") UPDATER="$UPDATER_ADDR"
REG_BLOCK=$(cast block-number --rpc-url "$RPC_URL"); export REG_BLOCK  # registry is deployed at or after this block
forge script "${FO[@]}" script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --legacy --gas-price 50000000 | tail -6
node scripts/demo/demo.js register | tail -3
REGISTRY=$(jq -r .registry "$POR_JSON")
echo "registry $REGISTRY updater $(cast call "$REGISTRY" 'updater()(address)' --rpc-url "$RPC_URL")"

VET=$(cast wallet address --private-key "$(echo "$WALLET_KEYS" | cut -d, -f6)")
python3 "$HERE/make_rehearsal_snapshot.py" "$VET" "$OUT/rehearsal-snapshot.npz"
# live phase: one block per second (setup above ran with instant mining)
cast rpc --rpc-url "$RPC_URL" anvil_setIntervalMining 1 >/dev/null
export HERE OUT KEYFILE REGISTRY; export HIST_FROM="$REG_BLOCK"
rm -rf "$OUT/state" "$OUT/state-main"; : > "$OUT/publisher.jsonl"; rm -f "$OUT/fault"
if [ "${MODE:-main}" = safety ]; then
  # forced send failures, a restart with trades during the downtime, a reorg (anvil evm_snapshot / evm_revert)
  "$HERE/daemon.sh" start
  sleep 4
  OUT_JSON="$OUT/safety-result.json" FAULT_FILE="$OUT/fault" node "$HERE/rehearse_safety.js"
  "$HERE/daemon.sh" stop
else
  systemd-run --user --collect --unit=$UNIT_P -p MemoryMax=8G -p Nice=19 \
    python3 "$HERE/../run.py" --rpc "$RPC_URL" --registry "$REGISTRY" --core "$OPENFOUR_CORE" --wbnb "$QUOTE_ASSET" \
    --key-file "$KEYFILE" --snapshot "$OUT/rehearsal-snapshot.npz" --log "$OUT/publisher.jsonl" --poll 0.2 \
    --state-dir "$OUT/state-main" --history-from "$REG_BLOCK" --registry-block "$REG_BLOCK" >/dev/null
  sleep 4
  OUT_JSON="$OUT/rehearsal-result.json" node "$HERE/rehearse.js"
  sleep 4
  systemctl --user stop "$UNIT_P"
fi
echo "publisher log: $OUT/publisher.jsonl"
