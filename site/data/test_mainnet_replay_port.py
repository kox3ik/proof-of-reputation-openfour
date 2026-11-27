#!/usr/bin/env python3
"""Check the fee port of build_mainnet_replay.py against the BSC testnet registry (read-only eth_call, no keys).

  python3 test_mainnet_replay_port.py --preload preload.txt [--rpc URL] [--registry 0x..] [--n 10]

For wallets loaded into the testnet registry: read componentsOf(w) and quoteDetailed(w, isBuy) on chain and compare with
the port (score_1000 / fee_curve / quote_detailed) applied to the same components. Also compares the deployed config() values.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "service", "publisher"))
from txsign import keccak256  # noqa: E402
import build_mainnet_replay as m  # noqa: E402

RPC = "https://bsc-testnet-rpc.publicnode.com"
REGISTRY = "0x7231682cdfed6d9d401efb8a2002b026bcbbc105"


def call(rpc: str, to: str, sig: str, args: str = "") -> list[int]:
    data = "0x" + keccak256(sig.encode())[:4].hex() + args
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}).encode()
    req = urllib.request.Request(rpc, body, {"content-type": "application/json", "user-agent": "por-port-test"})
    out = json.load(urllib.request.urlopen(req, timeout=30))["result"][2:]
    return [int(out[i:i + 64], 16) for i in range(0, len(out), 64)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preload", required=True)
    ap.add_argument("--rpc", default=RPC)
    ap.add_argument("--registry", default=REGISTRY)
    ap.add_argument("--n", type=int, default=10)
    ap.add_argument("--flagged", help="a preloaded wallet with a rug flag (penalty component)")
    a = ap.parse_args()
    cfg = call(a.rpc, a.registry, "config()")
    names = ["wVolume", "wActivity", "wHolding", "wIdentity", "penaltyWeight", "flagThreshold", "neutralScore", "zeroBps", "neutralBps",
             "minBps", "sellCapBps", "treasuryShareBps"]
    ok = True
    for i, k in enumerate(names):
        ok &= cfg[i] == m.CFG[k]
    ok &= cfg[19] == m.CFG["freshDepositBps"] and cfg[20] == m.CFG["penaltyBps"]
    print("config match:", ok, {k: cfg[i] for i, k in enumerate(names)}, "deposit", cfg[19], "penalty", cfg[20])
    wallets = [l.strip() for l in open(a.preload) if l.strip()]
    step = max(1, len(wallets) // (a.n - 2))
    pick = wallets[::step][: a.n - 2]
    # one flagged wallet (penalty 1000) and one never-seen wallet (fresh)
    flagged = a.flagged or next((w for w in wallets[:400] if call(a.rpc, a.registry, "componentsOf(address)", w[2:].rjust(64, "0"))[4] >= 700), None)
    pick += [flagged] if flagged else []
    pick += ["0x" + "ab" * 20]
    bad = 0
    for w in pick:
        arg = w[2:].rjust(64, "0")
        comp = tuple(call(a.rpc, a.registry, "componentsOf(address)", arg))
        for is_buy in (True, False):
            q = call(a.rpc, a.registry, "quoteDetailed(address,bool)", arg + ("%064x" % int(is_buy)))
            mine = m.quote_detailed(comp, is_buy)
            good = (q[0], q[1], q[2]) == (mine["regular"], mine["deposit"], mine["penalty"])
            bad += not good
            print("OK " if good else "BAD", w[:10], comp, "buy" if is_buy else "sell", "chain", q[:3], "port", (mine["regular"], mine["deposit"], mine["penalty"]))
    print("mismatches:", bad, "config ok:", ok)
    return 0 if ok and bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
