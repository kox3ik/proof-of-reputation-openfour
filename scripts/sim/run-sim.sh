#!/usr/bin/env bash
# Live rating simulation: deploy (deploy-testnet.sh SETUP_ONLY=1), load real mainnet ratings through the publisher, run the bots
# while the publisher recomputes scores and flags live, record the page with Playwright, write the run log.
#
#   DRY_RUN=1 VARIANT=b scripts/sim/run-sim.sh                          # local anvil fork of testnet, ~5 min, nothing real is sent
#   CONFIRM_TESTNET=yes VARIANT=b scripts/sim/run-sim.sh                # REAL BSC testnet (chain 97), ~25 min
# Rates: VARIANT=a|b or FRESH_DEPOSIT_BPS / PENALTY_BPS / ZERO_BPS (see deploy-testnet.sh). PRELOAD_N = real wallets to load (default 8000).
# SKIP_SETUP=1 reuses the deployment of the previous run in the same WORK dir. Keys: testnet-keys/{deployer.json,updater.key} and
# testnet-keys/sim/bots*.json (created here, mode 600); nothing is printed or passed on a command line.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; H="$(cd "$REPO/../.." && pwd)"
export PATH="$HOME/.foundry/bin:${NODE_BIN:+$NODE_BIN:}$PATH"  # set NODE_BIN to a node bin dir if node is not on PATH
cd "$REPO"
DRY_RUN="${DRY_RUN:-0}"; export DRY_RUN
[ "$DRY_RUN" = 1 ] || [ "${CONFIRM_TESTNET:-}" = yes ] || { echo "real testnet run needs CONFIRM_TESTNET=yes (or DRY_RUN=1)"; exit 2; }
KIND=testnet; [ "$DRY_RUN" = 1 ] && KIND=dry
export KEYS_DIR="${KEYS_DIR:-$H/testnet-keys}"
export WORK_DIR="${WORK_DIR:-$H/run/sim-$KIND}"; WORK="$WORK_DIR"
export UNIT_A=por-sim-anvil UNIT_P=por-sim-publisher PORT="${PORT:-8571}" UPDATER_FUND="${UPDATER_FUND:-0.03}"
UNIT_H=por-sim-http; UNIT_R=por-sim-rec; HTTP_PORT="${HTTP_PORT:-8600}"
export SIM_SECONDS="${SIM_SECONDS:-$([ "$DRY_RUN" = 1 ] && echo 270 || echo 1500)}"
PRELOAD_N="${PRELOAD_N:-8000}"
LIM=(-p MemoryMax=8G -p Nice=19 -p CPUWeight=10 -p IOSchedulingClass=idle)
VIDEO_DIR="${VIDEO_DIR:-$H/deck/video}"; STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
cleanup() { systemctl --user stop "$UNIT_P" "$UNIT_H" "$UNIT_R" 2>/dev/null || true; [ "$DRY_RUN" = 1 ] && [ "${KEEP_ANVIL:-0}" != 1 ] && systemctl --user stop "$UNIT_A" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$WORK" "$VIDEO_DIR"
export OPENFOUR_DEV="${OPENFOUR_DEV:-$H/work/contracts-v2/developer}"

# ---- 0. pre-flight (real run): balances and the tBNB estimate; abort above MAX_TBNB (default 0.2)
if [ "$DRY_RUN" != 1 ]; then
  PF_RPC="${RPC_URL:-https://bsc-testnet-rpc.publicnode.com}"
  PF_DEP="$(jq -r '.[0].address' "$KEYS_DIR/deployer.json")"; PF_UPD="$(tr -d ' \n' < "$KEYS_DIR/updater.address")"
  export BOTS_FILE="${BOTS_FILE:-$KEYS_DIR/sim/bots-$KIND.json}" RPC_URL="${RPC_URL:-$PF_RPC}" GAS_PRICE="${GAS_PRICE:-100000000}"
  PF_BOTS="$(node "$HERE/bots.js" need)"
  python3 - "$(cast balance --rpc-url "$PF_RPC" "$PF_DEP")" "$(cast balance --rpc-url "$PF_RPC" "$PF_UPD")" "$PF_BOTS" "$UPDATER_FUND" "${MAX_TBNB:-0.2}" "${SKIP_SETUP:-0}" <<'PY'
import sys
dep, upd = (int(x) / 1e18 for x in sys.argv[1:3]); bots, upd_fund, cap = map(float, sys.argv[3:6])
resume = sys.argv[6] == "1"                     # deployment and updater funding already paid in an earlier part of this run
deploy = 0.0105                                  # measured on the dry run (OpenFour set + our contracts + mocks + preset)
if resume: deploy = upd_fund = 0.0
peak = deploy + upd_fund + bots                  # everything the deployer has to pay up front (bot leftovers come back at the end)
net = deploy + 0.03 + 0.03 + 0.001               # deploy + rating load (~0.022-0.025) + bot fees/penalty/forfeits (~0.03) + live publishing
print(f"deployer balance {dep:.4f} tBNB, updater balance {upd:.4f} tBNB")
print(f"estimate: deploy {deploy} + updater {upd_fund} + bots {bots} = peak {peak:.4f} tBNB; expected net spend about {net:.3f} tBNB (cap {cap})")
if peak > cap or peak > dep + upd:
    sys.exit(f"ABORT: peak estimate {peak:.4f} exceeds the cap {cap} or the available balance")
PY
fi

# ---- 1. deployment
if [ "${SKIP_SETUP:-0}" != 1 ]; then
  rm -f "$WORK/sim-env.sh"
  SETUP_ONLY=1 KEEP_ANVIL=1 "$REPO/scripts/deploy-testnet.sh"
fi
# shellcheck disable=SC1091
source "$WORK/sim-env.sh"
export ABI_DIR="$WORK/forge-out" BOTS_FILE="$KEYS_DIR/sim/bots-$KIND.json"
[ "$(cast chain-id --rpc-url "$RPC_URL")" = 97 ] || { echo "expected chain id 97"; exit 1; }
[ "$DRY_RUN" = 1 ] && cast rpc --rpc-url "$RPC_URL" anvil_setIntervalMining 1 >/dev/null

# ---- 2. real wallets to load, bots
python3 -I "$HERE/pick_wallets.py" --n "$PRELOAD_N" --out-dir "$WORK/prep"
node "$HERE/bots.js" gen
if [ "$DRY_RUN" = 1 ]; then cast rpc --rpc-url "$RPC_URL" anvil_setBalance "$DEPLOYER_ADDR" 0x56BC75E2D63100000 >/dev/null; fi
B0="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER_ADDR")"
node "$HERE/bots.js" fund

# ---- 3. publisher with the history snapshot: it publishes the preload list, then runs live
PRELOAD_ARG=(--preload "$WORK/prep/preload.txt")
if [ "${SKIP_PRELOAD:-0}" = 1 ]; then   # ratings are already on chain (resume of an aborted run): keep the checkpoint, load nothing
  PRELOAD_ARG=(); cp -f "$WORK/publisher.jsonl" "$WORK/publisher-before-resume-$STAMP.jsonl" 2>/dev/null || true   # the log keeps growing: it holds the rating load
else rm -rf "$WORK/publisher-state"; : > "$WORK/publisher.jsonl"; fi
PUB_RPC="${PUB_RPC:-$RPC_URL}"   # publicnode: the only free testnet node that serves eth_getLogs
systemd-run --user --collect --unit=$UNIT_P "${LIM[@]}" \
  python3 "$REPO/service/publisher/run.py" --rpc "$PUB_RPC" --registry "$REGISTRY" --core "$OPENFOUR_CORE" --wbnb "$QUOTE_ASSET" \
  --key-file "$UPDATER_KEYFILE" --log "$WORK/publisher.jsonl" --poll "${PUB_POLL:-$([ "$DRY_RUN" = 1 ] && echo 0.3 || echo 0.5)}" --state-dir "$WORK/publisher-state" --max-batch 250 \
  --history-from "$REG_BLOCK" --registry-block "$REG_BLOCK" "${PRELOAD_ARG[@]}" >/dev/null
echo "publisher started, loading real ratings ..."
LOADED=0
[ "${SKIP_PRELOAD:-0}" = 1 ] && { LOADED=1; sleep 20; }
for _ in $(seq 1800); do
  [ "$LOADED" = 1 ] && break
  sleep 1
  if grep -q '"event": "preload"' "$WORK/publisher.jsonl" 2>/dev/null; then
    LOADED="$(python3 -I - "$WORK/publisher.jsonl" <<'PY'
import json, sys
q = tot = 0
for l in open(sys.argv[1]):
    try: e = json.loads(l)
    except ValueError: continue
    if e.get("event") == "preload": q = e["queued"]
    if e.get("event") == "publish" and e.get("ok"): tot += e["wallets"]
print(1 if q and tot >= q else 0)
PY
)"
    [ "$LOADED" = 1 ] && break
  fi
done
[ "$LOADED" = 1 ] || { echo "rating load did not finish"; exit 3; }
echo "ratings loaded"; sleep 4

# ---- 4. page (served from a copy of app/), recorder, scenario
APPDIR="$WORK/app-sim"; PUBLIC=""; RPC_PAGE="$RPC_URL"
[ "$DRY_RUN" = 1 ] || { PUBLIC="--public-chain"; RPC_PAGE="${PAGE_RPC:-https://data-seed-prebsc-2-s1.bnbchain.org:8545}"; export SAMPLE_MS="${SAMPLE_MS:-8000}" WAIT_MS="${WAIT_MS:-1500}" POLL_MS="${POLL_MS:-1000}"; LOGS_RPC_ARG="--logs-rpc ${LOGS_RPC:-https://bsc-testnet-rpc.publicnode.com}"; }
python3 "$HERE/make_sim_config.py" --out-dir "$APPDIR" --por "$POR_JSON" --state "$STATE_JSON" --fork "$FORK_JSON" --bots "$BOTS_FILE" \
  --preload "$WORK/prep/preload.json" --rpc "$RPC_PAGE" ${LOGS_RPC_ARG:-} --fresh-deposit-bps "$FRESH_DEPOSIT_BPS" --penalty-bps "$PENALTY_BPS" $PUBLIC
export LIVE_JSON="$APPDIR/sim-live.json" RUN_LOG="$WORK/sim-run-log-$STAMP.json"
systemd-run --user --collect --unit=$UNIT_H "${LIM[@]}" python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$APPDIR" >/dev/null
sleep 1
REAL=$(python3 -I -c "import json,sys; s=json.load(open('$WORK/prep/preload.json'))['samples']; print(' '.join('--real-addr '+v['address'] for k,v in s.items() if k in ('real: top','real: median','real: flagged (rug history)')))")
VIDEO_NAME="por-simulation-$KIND-$STAMP"
# shellcheck disable=SC2086
systemd-run --user --collect --unit=$UNIT_R "${LIM[@]}" python3 "$HERE/record_video.py" --url "http://127.0.0.1:$HTTP_PORT/index.html" --live "$LIVE_JSON" \
  --out-dir "$VIDEO_DIR" --name "$VIDEO_NAME" $REAL >/dev/null
sleep 3
SIM_ENV=(-E RPC_URL -E OPENFOUR_DEV -E FORK_JSON -E POR_JSON -E STATE_JSON -E WORK -E KEYS_DIR -E BOTS_FILE -E ABI_DIR -E GAS_PRICE -E LIVE_JSON -E RUN_LOG -E SAMPLE_MS -E WAIT_MS -E POLL_MS -E SIM_SECONDS
         -E FRESH_DEPOSIT_BPS -E PENALTY_BPS -E ZERO_BPS -E SIM_RAISE -E BUNDLE_BUDGET -E HONEST_BUDGET -E NEWBIE_BUDGET)
export SIM_RAISE="${SIM_RAISE:-0.2}" BUNDLE_BUDGET="${BUNDLE_BUDGET:-0.01}" HONEST_BUDGET="${HONEST_BUDGET:-0.006}" NEWBIE_BUDGET="${NEWBIE_BUDGET:-0.004}"
# the bots / sampler use their own RPC (the public node rate-limits one IP; the publisher needs it for eth_getLogs)
SIM_RPC="${SIM_RPC:-$([ "$DRY_RUN" = 1 ] && echo "$RPC_URL" || echo https://data-seed-prebsc-1-s1.bnbchain.org:8545)}"
RPC_URL="$SIM_RPC" systemd-run --user --collect --wait --pipe --unit=por-sim-scenario "${LIM[@]}" "${SIM_ENV[@]}" node "$HERE/scenario.js"
for _ in $(seq 120); do systemctl --user is-active --quiet $UNIT_R || break; sleep 1; done

# ---- 5. wrap up
systemctl --user stop "$UNIT_P" 2>/dev/null || true
node "$HERE/bots.js" refund || true
B1="$(cast balance --rpc-url "$RPC_URL" "$DEPLOYER_ADDR")"
python3 "$HERE/make_runlog.py" --scenario "$RUN_LOG" --publisher "$WORK/publisher.jsonl" --state "$STATE_JSON" --broadcast-dir "$REPO/broadcast" ${DEPLOY_SCAN:+--deployment-scan "$DEPLOY_SCAN" --por "$(dirname "$POR_JSON")"} \
  --preload-json "$WORK/prep/preload.json" --gas-price-wei "$GAS_PRICE" --video "$VIDEO_DIR/$VIDEO_NAME.webm" --out "$VIDEO_DIR/$VIDEO_NAME-runlog.json"
python3 "$HERE/verify_txs.py" --runlog "$VIDEO_DIR/$VIDEO_NAME-runlog.json" --rpc "$RPC_URL" || echo "WARNING: some key tx did not verify"
SUBDIR="$REPO/submission"; [ "$DRY_RUN" = 1 ] && SUBDIR="$WORK/submission-dry"
python3 "$HERE/make_submit_input.py" --runlog "$VIDEO_DIR/$VIDEO_NAME-runlog.json" --state "$STATE_JSON" --por "$POR_JSON" --fork "$FORK_JSON" \
  --deployer "$DEPLOYER_ADDR" --out "$WORK/submit-input.json"
node "$REPO/scripts/demo/make_submit_pack.js" --run "$WORK/submit-input.json" --migrate none --out "$SUBDIR"
echo "balances: deployer $(cast balance --rpc-url "$RPC_URL" "$DEPLOYER_ADDR" --ether), updater $(cast balance --rpc-url "$RPC_URL" "$UPDATER_ADDR" --ether) tBNB"
python3 - "$B0" "$B1" <<'PY'
import sys; print("deployer balance change over bot funding + refund: %.5f tBNB" % ((int(sys.argv[2]) - int(sys.argv[1])) / 1e18))
PY
echo "video: $VIDEO_DIR/$VIDEO_NAME.webm   run log: $VIDEO_DIR/$VIDEO_NAME-runlog.json"
