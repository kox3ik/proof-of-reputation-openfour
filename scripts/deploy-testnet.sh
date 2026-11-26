#!/usr/bin/env bash
# One-command redeploy of Proof of Reputation on BSC testnet (chain 97): own OpenFour Registry/Core (their fork-deploy),
# our contracts, preset, the demo path create -> buy -> sell -> migrate -> claim, the publisher with the updater key,
# then the OpenFour submit pack and the app config.
#
#   VARIANT=a CONFIRM_TESTNET=yes scripts/deploy-testnet.sh        # option A: 0.5 % base fee, deposit = penalty = 900 bps
#   VARIANT=b CONFIRM_TESTNET=yes scripts/deploy-testnet.sh        # option B: 0.5 % base fee, deposit = penalty = 640 bps
#   VARIANT=a DRY_RUN=1 scripts/deploy-testnet.sh                  # whole path on a local anvil fork of testnet, nothing real is sent
# Rates can be set directly (they win over VARIANT): ZERO_BPS, FRESH_DEPOSIT_BPS, PENALTY_BPS.
#
# Keys are read from files and never printed or passed on a command line:
#   $KEYS_DIR/deployer.json  ([{address, private_key}])   $KEYS_DIR/updater.key + updater.address
# SETUP_ONLY=1 (used by scripts/sim/run-sim.sh): stop after step 4 + the updater hand-over, write $WORK/sim-env.sh for the simulation
# (no demo wallets, no demo trades, no publisher, no submit pack).
# Needs: foundry (~/.foundry/bin), node, python3, jq; OPENFOUR_SRC = openfour-docs `developer/` dir with node_modules.
# Real run (no DRY_RUN) refuses to start without CONFIRM_TESTNET=yes and only talks to chain id 97.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"; H="$(cd "$REPO/../.." && pwd)"
export PATH="$HOME/.foundry/bin:${NODE_BIN:+$NODE_BIN:}$PATH"  # set NODE_BIN to a node bin dir if node is not on PATH
cd "$REPO"

VARIANT="${VARIANT:-}"
case "$VARIANT" in
  a) : "${FRESH_DEPOSIT_BPS:=900}" "${PENALTY_BPS:=900}" ;;
  b) : "${FRESH_DEPOSIT_BPS:=640}" "${PENALTY_BPS:=640}" ;;
  "") [ -n "${FRESH_DEPOSIT_BPS:-}" ] && [ -n "${PENALTY_BPS:-}" ] || { echo "set VARIANT=a|b (or FRESH_DEPOSIT_BPS and PENALTY_BPS)"; exit 2; } ;;
  *) echo "VARIANT must be a or b"; exit 2 ;;
esac
: "${ZERO_BPS:=50}"; export ZERO_BPS FRESH_DEPOSIT_BPS PENALTY_BPS
echo "rates: base fee at score 0 = $ZERO_BPS bps, fresh deposit = $FRESH_DEPOSIT_BPS bps, flag penalty = $PENALTY_BPS bps"

DRY_RUN="${DRY_RUN:-0}"
KEYS_DIR="${KEYS_DIR:-$H/testnet-keys}"
GAS_PRICE="${GAS_PRICE:-100000000}"; export GAS_PRICE            # wei, 0.1 gwei (the demo uses the same)
WALLET_FUND="${WALLET_FUND:-0.02}"                               # base tBNB per demo wallet, x2 for trusted, x0.6 for three others (leftovers are returned at the end)
UPDATER_FUND="${UPDATER_FUND:-0.02}"
RUN_PUBLISHER="${RUN_PUBLISHER:-1}"; PUBLISHER_SECONDS="${PUBLISHER_SECONDS:-60}"
DRYTAG=""; [ "$DRY_RUN" = 1 ] && DRYTAG="-dry"
WORK="${WORK_DIR:-$H/run/testnet-deploy-${VARIANT:-custom}$DRYTAG}"; mkdir -p "$WORK"; chmod 700 "$WORK"
SUFFIX=testnet; [ "$DRY_RUN" = 1 ] && SUFFIX=dry
UNIT_A="${UNIT_A:-por-dry-anvil}"; UNIT_P="${UNIT_P:-por-testnet-publisher}"; SETUP_ONLY="${SETUP_ONLY:-0}"
cleanup() { systemctl --user stop "$UNIT_P" 2>/dev/null || true; [ "$DRY_RUN" = 1 ] && [ "${KEEP_ANVIL:-0}" != 1 ] && systemctl --user stop "$UNIT_A" 2>/dev/null || true; }
trap cleanup EXIT

# ---------- network ----------
if [ "$DRY_RUN" = 1 ]; then
  PORT="${PORT:-8563}"; export RPC_URL="http://127.0.0.1:$PORT"
  systemctl --user stop "$UNIT_A" 2>/dev/null || true
  systemd-run --user --collect --unit=$UNIT_A -p MemoryMax=8G -p Nice=19 \
    anvil --fork-url "${FORK_URL:-https://bsc-testnet-rpc.publicnode.com}" --chain-id 97 --port "$PORT" --gas-price 50000000 --host 127.0.0.1 >/dev/null
  for _ in $(seq 60); do cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1 && break; sleep 1; done
else
  [ "${CONFIRM_TESTNET:-}" = yes ] || { echo "this sends real transactions to BSC testnet: set CONFIRM_TESTNET=yes"; exit 2; }
  export RPC_URL="${RPC_URL:-https://bsc-testnet-rpc.publicnode.com}"
fi
[ "$(cast chain-id --rpc-url "$RPC_URL")" = 97 ] || { echo "expected chain id 97"; exit 1; }

# ---------- keys (read, never printed) ----------
DEPLOYER_ADDR="$(jq -r '.[0].address' "$KEYS_DIR/deployer.json")"
UPDATER_ADDR="$(tr -d ' \n' < "$KEYS_DIR/updater.address")"
UPDATER_KEYFILE="$KEYS_DIR/updater.key"
DEPLOYER_PRIVATE_KEY="$(jq -r '.[0].private_key' "$KEYS_DIR/deployer.json")"; export DEPLOYER_PRIVATE_KEY
case "$DEPLOYER_PRIVATE_KEY" in 0x*) ;; *) export DEPLOYER_PRIVATE_KEY="0x$DEPLOYER_PRIVATE_KEY" ;; esac
if [ "$DRY_RUN" = 1 ]; then
  for a in "$DEPLOYER_ADDR" "$UPDATER_ADDR"; do cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$a" 0x56BC75E2D63100000 >/dev/null; done
fi
bal() { cast balance --rpc-url "$RPC_URL" "$1"; }

# ---------- OpenFour developer dir (scratch copy: their fork-deploy is patched against stale nonces) ----------
OPENFOUR_SRC="${OPENFOUR_SRC:-$H/work/contracts-v2/developer}"
[ -d "$OPENFOUR_SRC/node_modules/ethers" ] || { echo "OPENFOUR_SRC needs npm install"; exit 1; }
export OPENFOUR_DEV="$WORK/developer"; mkdir -p "$OPENFOUR_DEV"
[ -d "$OPENFOUR_DEV/fork-deploy" ] || cp -r "$OPENFOUR_SRC/fork-deploy" "$OPENFOUR_DEV/"
ln -sfn "$OPENFOUR_SRC/node_modules" "$OPENFOUR_DEV/node_modules"; cp -f "$OPENFOUR_SRC/package.json" "$OPENFOUR_DEV/"

B0="$(bal "$DEPLOYER_ADDR")"
python3 - "$B0" <<'PY'
import sys; print("deployer balance: %.4f tBNB" % (int(sys.argv[1]) / 1e18))
PY

# ---------- 1. demo wallets ----------
export TREASURY="${TREASURY:-$DEPLOYER_ADDR}"
if [ "$SETUP_ONLY" != 1 ]; then
  node scripts/demo/wallets.js gen "$WORK/demo-wallets.json"
  WALLET_KEYS="$(node scripts/demo/wallets.js keys "$WORK/demo-wallets.json")"; export WALLET_KEYS
  node scripts/demo/wallets.js fund "$WORK/demo-wallets.json" "$WALLET_FUND"
fi

# ---------- 2. OpenFour: own Registry / Core ----------
scripts/demo/prepare-fork-deploy.sh >/dev/null
FORK_DIR="$OPENFOUR_DEV/fork-deploy-local"
(cd "$FORK_DIR" && env -u DRY_RUN RPC_URL="$RPC_URL" DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" node fork-from-chain.js | tail -3)
export FORK_JSON="$FORK_DIR/out/fork-deployment.json"
export OPENFOUR_CORE="$(jq -r .addresses.core "$FORK_JSON")" QUOTE_ASSET="$(jq -r .addresses.wbnb "$FORK_JSON")"

# ---------- 3. our contracts ----------
FO=(--out "$WORK/forge-out" --cache-path "$WORK/forge-cache")
forge build "${FO[@]}" >/dev/null
forge script "${FO[@]}" script/DeployDemoMocks.s.sol --rpc-url "$RPC_URL" --broadcast --legacy --gas-price "$GAS_PRICE" | tail -3
export BAB_TOKEN="$(jq -r .babToken deployments/demo-mocks.json)" AGENT_ID_TOKEN="$(jq -r .agentIdToken deployments/demo-mocks.json)"
REG_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
export UPDATER="$DEPLOYER_ADDR"     # the demo path publishes as the deployer; the updater key takes over below
forge script "${FO[@]}" script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --legacy --gas-price "$GAS_PRICE" | tail -6
REGISTRY="$(jq -r .registry deployments/por-deployment.json)"

# ---------- 4. preset, 5. demo path ----------
node scripts/demo/demo.js register
if [ "$SETUP_ONLY" = 1 ]; then
  node scripts/demo/wallets.js fund-address "$UPDATER_ADDR" "$UPDATER_FUND"
  node scripts/demo/wallets.js set-updater "$REGISTRY" "$UPDATER_ADDR"
  mkdir -p "$WORK/deployments"; cp -f deployments/por-deployment.json deployments/demo-state.json deployments/demo-mocks.json "$WORK/deployments/"   # a later run in this repo must not change them
  { for v in RPC_URL OPENFOUR_DEV FORK_JSON OPENFOUR_CORE QUOTE_ASSET REG_BLOCK REGISTRY WORK UPDATER_KEYFILE UPDATER_ADDR DEPLOYER_ADDR; do
      printf 'export %s=%q\n' "$v" "${!v}"; done
    printf 'export POR_JSON=%q STATE_JSON=%q MOCKS_JSON=%q\n' "$WORK/deployments/por-deployment.json" "$WORK/deployments/demo-state.json" "$WORK/deployments/demo-mocks.json"
    printf 'export FRESH_DEPOSIT_BPS=%q PENALTY_BPS=%q ZERO_BPS=%q GAS_PRICE=%q\n' "$FRESH_DEPOSIT_BPS" "$PENALTY_BPS" "$ZERO_BPS" "$GAS_PRICE"; } > "$WORK/sim-env.sh"
  chmod 600 "$WORK/sim-env.sh"
  python3 - "$B0" "$(bal "$DEPLOYER_ADDR")" <<'PY'
import sys; print("setup done; deployer spent %.5f tBNB (incl. updater funding)" % ((int(sys.argv[1]) - int(sys.argv[2])) / 1e18))
PY
  trap - EXIT; [ "$DRY_RUN" = 1 ] || true
  exit 0
fi
mkdir -p demo-out
RUN_JSON="$PWD/demo-out/demo-run-$SUFFIX.json"; MIG_JSON="$PWD/demo-out/demo-migrate-$SUFFIX.json"
OUT_JSON="$RUN_JSON" node scripts/demo/demo.js trade                 # create, buy, sell, transfers, scam-fund circle
OUT_JSON="$MIG_JSON" node scripts/demo/demo.js migrate               # create, buy, sell, migrate, settle, claim

# ---------- 6. publisher with the updater key ----------
if [ "$RUN_PUBLISHER" = 1 ]; then
  node scripts/demo/wallets.js fund-address "$UPDATER_ADDR" "$UPDATER_FUND"
  node scripts/demo/wallets.js set-updater "$REGISTRY" "$UPDATER_ADDR"
  [ "$DRY_RUN" = 1 ] && cast rpc --rpc-url "$RPC_URL" anvil_setIntervalMining 1 >/dev/null
  COV0="$(cast call --rpc-url "$RPC_URL" "$REGISTRY" 'coveredUntil()(uint64)' | awk '{print $1}')"
  : > "$WORK/publisher.jsonl"; rm -rf "$WORK/publisher-state"
  systemd-run --user --collect --unit=$UNIT_P -p MemoryMax=8G -p Nice=19 \
    python3 "$REPO/service/publisher/run.py" --rpc "$RPC_URL" --registry "$REGISTRY" --core "$OPENFOUR_CORE" --wbnb "$QUOTE_ASSET" \
    --key-file "$UPDATER_KEYFILE" --log "$WORK/publisher.jsonl" --poll 1 --state-dir "$WORK/publisher-state" \
    --history-from "$REG_BLOCK" --registry-block "$REG_BLOCK" >/dev/null
  COV1="$COV0"
  for _ in $(seq "$PUBLISHER_SECONDS"); do
    sleep 1; COV1="$(cast call --rpc-url "$RPC_URL" "$REGISTRY" 'coveredUntil()(uint64)' | awk '{print $1}')"
    [ "$COV1" != "$COV0" ] && break
  done
  systemctl --user stop "$UNIT_P" 2>/dev/null || true
  echo "publisher: coveredUntil $COV0 -> $COV1 (log: $WORK/publisher.jsonl)"
  [ "$COV1" != "$COV0" ] || { echo "WARNING: coveredUntil did not move within ${PUBLISHER_SECONDS}s"; PUB_WARN=1; }
fi

# ---------- 7. submission files and app config ----------
node scripts/demo/make_submit_pack.js --run "$RUN_JSON" --migrate "$MIG_JSON" --out "$PWD/demo-out/submit-pack"
python3 app/make_config.py --run "$RUN_JSON" --testnet-por
node scripts/demo/wallets.js refund "$WORK/demo-wallets.json"

B1="$(bal "$DEPLOYER_ADDR")"; U1="$(bal "$UPDATER_ADDR")"
python3 - "$B0" "$B1" "$U1" <<'PY'
import sys; b0,b1,u1=map(int,sys.argv[1:])
print("deployer spent (net of returned leftovers, minus updater funding): %.4f tBNB; updater balance now %.4f tBNB" % ((b0-b1)/1e18, u1/1e18))
PY
echo "done. submit pack: demo-out/submit-pack/  run logs: $RUN_JSON $MIG_JSON"
[ "${PUB_WARN:-0}" = 0 ] || exit 3
