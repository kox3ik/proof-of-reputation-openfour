#!/usr/bin/env bash
# daemon.sh start|stop : the rehearsal daemon as a systemd --user unit (env from rehearse.sh)
set -euo pipefail
UNIT=por-rt-publisher
case "$1" in
  start)
    systemd-run --user --collect --unit=$UNIT -p MemoryMax=8G -p Nice=19 -E FAULT_FILE="$OUT/fault" -E FAULT_LOST="$OUT/lost" \
      python3 "$HERE/run_faulty.py" --rpc "$RPC_URL" --registry "$REGISTRY" --core "$OPENFOUR_CORE" --wbnb "$QUOTE_ASSET" \
      --key-file "$KEYFILE" --snapshot "$OUT/rehearsal-snapshot.npz" --log "$OUT/publisher.jsonl" --poll 0.2 \
      --state-dir "$OUT/state" --checkpoint-every 4 --bump-after 8 --history-from "$HIST_FROM" --registry-block "$HIST_FROM" >/dev/null ;;
  stop) systemctl --user stop $UNIT ;;
esac
