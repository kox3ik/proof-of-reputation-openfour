"""Command line: python3 run.py --rpc URL --registry 0x.. --core 0x.. --key-file PATH [--snapshot PATH] ..."""
from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time

import newness
import paths
import snapshot_io
from chain import Chain
from engine import Engine
from publisher import Publisher
from store import Store
from txsign import load_key
from wallets import WalletTable


def parse(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Proof of Reputation real-time score / flag publisher")
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--registry", required=True)
    ap.add_argument("--core", required=True, help="OpenFour Core address of the target network")
    ap.add_argument("--key-file", default=os.environ.get("POR_UPDATER_KEY_FILE"), help="updater key file (or env POR_UPDATER_KEY_FILE)")
    ap.add_argument("--snapshot", default=paths.DEFAULT_SNAPSHOT, help="mainnet-history snapshot (npz); 'none' = empty")
    ap.add_argument("--wbnb", required=True, help="quote asset priced 1:1 in BNB (WBNB of the target network)")
    ap.add_argument("--quote-rate", action="append", default=[], metavar="ADDR=RATE", help="BNB per unit of another quote asset")
    ap.add_argument("--start-block", type=int, default=None, help="first block to read (default: head)")
    ap.add_argument("--interval", type=float, default=0.0, help="min seconds between publishes (0 = every block with changes)")
    ap.add_argument("--poll", type=float, default=0.25, help="seconds between head polls")
    ap.add_argument("--max-batch", type=int, default=150, help="wallets per tx (150 new wallets = about 3.7M gas)")
    ap.add_argument("--confirmations", type=int, default=2, help="read only blocks up to head - N (reorg protection)")
    ap.add_argument("--state-dir", default=None, help="checkpoints + journal (restart / reorg recovery); strongly recommended")
    ap.add_argument("--checkpoint-every", type=float, default=300.0, help="seconds between checkpoints")
    ap.add_argument("--max-gas-price-gwei", type=float, default=3.0, help="never send above this gas price")
    ap.add_argument("--bump-after", type=float, default=30.0, help="seconds before a stuck tx is replaced with +25%% gas")
    ap.add_argument("--history-from", type=int, default=None, help="replay history from this block to rebuild open positions (first start)")
    ap.add_argument("--registry-block", type=int, default=None, help="block the registry was deployed at; coveredUntil advances only if --history-from <= it")
    ap.add_argument("--gas-share", type=float, default=0.25, help="largest share of the block gas limit one publish tx may use")
    ap.add_argument("--allow-gap", action="store_true", help="start after blocks that were never read (not recommended)")
    ap.add_argument("--max-replay", type=int, default=400_000, help="blocks replayed from coveredUntil on a first start")
    ap.add_argument("--reference-refresh", type=float, default=3600.0, help="seconds between reference rebuilds")
    ap.add_argument("--newness", default="default", choices=["default", "threshold"], help="when a wallet stops being fresh (default = registry behaviour)")
    ap.add_argument("--newness-min-tokens", type=int, default=0)
    ap.add_argument("--newness-min-days", type=int, default=0)
    ap.add_argument("--newness-min-volume", type=float, default=0.0, help="BNB")
    ap.add_argument("--preload", default=None, help="file with one wallet address per line: publish their snapshot scores at start")
    ap.add_argument("--log", default=None, help="append JSON lines to this file (also stdout)")
    return ap.parse_args(argv)


def main(argv=None) -> None:
    a = parse(argv)
    if not a.key_file:
        raise SystemExit("--key-file or POR_UPDATER_KEY_FILE required")
    snap = snapshot_io.empty() if a.snapshot == "none" else snapshot_io.load(a.snapshot)
    rates = {a.wbnb: 1.0, **{k: float(v) for k, v in (p.split("=") for p in a.quote_rate)}}
    engine = Engine(WalletTable(snap), rates, a.reference_refresh,
                    newness.from_args(a.newness, a.newness_min_tokens, a.newness_min_days, a.newness_min_volume))
    chain = Chain(a.rpc)
    logf = open(a.log, "a") if a.log else None

    def log(rec: dict) -> None:
        line = json.dumps({"t": round(time.time(), 3), **rec})
        print(line, flush=True)
        if logf:
            logf.write(line + "\n")
            logf.flush()

    cid = chain.chain_id()
    store = Store(a.state_dir, f"{cid}:{a.registry.lower()}:{a.core.lower()}") if a.state_dir else None
    pub = Publisher(chain, engine, a.core, a.registry, load_key(a.key_file), chain_id=cid, max_batch=a.max_batch,
                    interval_s=a.interval, confirmations=a.confirmations, store=store, checkpoint_s=a.checkpoint_every,
                    max_gas_price=int(a.max_gas_price_gwei * 1e9), bump_after_s=a.bump_after, gas_share=a.gas_share, log=log)
    stop = {"v": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(v=True))
    signal.signal(signal.SIGINT, lambda *_: stop.update(v=True))
    pub.start(a.start_block, allow_gap=a.allow_gap, max_replay=a.max_replay, history_from=a.history_from,
              registry_block=a.registry_block)
    if a.preload:
        with open(a.preload) as fh:
            addrs = [x.strip() for x in fh if x.strip()]
        log({"event": "preload", "queued": pub.e.preload(addrs, pub.last_block), "listed": len(addrs)})
    while not stop["v"]:
        try:
            if not pub.step():
                time.sleep(a.poll)
        except Exception as e:  # noqa: BLE001 - keep the daemon alive across RPC hiccups, log the cause
            log({"event": "error", "error": f"{type(e).__name__}: {str(e)[:300]}"})
            time.sleep(1.0)
    pub.checkpoint(force=True)
    log({"event": "stop"})
    sys.exit(0)


if __name__ == "__main__":
    main()
