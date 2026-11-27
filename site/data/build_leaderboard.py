#!/usr/bin/env python3
"""Build site/data/leaderboard.json: the real mainnet wallets preloaded into the BSC testnet registry (prep/preload.txt),
components read from the live testnet registry (componentsOf/isFlagged, JSON-RPC batch eth_call), fees by the current-contracts
formula (build_mainnet_replay.quote_score).
Usage: build_leaderboard.py PRELOAD.txt [OUT.json]"""
import json, os, sys, time, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_mainnet_replay import quote_score, score_1000

RPC = "https://bsc-testnet-rpc.publicnode.com"
REG = "0x7231682cdfed6d9d401efb8a2002b026bcbbc105"
SEL_C, SEL_F = "0x45292166", None


def rpc(batch):
    for a in range(6):
        try:
            req = urllib.request.Request(RPC, json.dumps(batch).encode(), {"Content-Type": "application/json", "User-Agent": "por-leaderboard"})
            r = json.load(urllib.request.urlopen(req, timeout=30))
            if all("result" in x for x in r):
                return {x["id"]: x["result"] for x in r}
        except Exception:
            pass
        time.sleep(2 + 3 * a)
    raise SystemExit("rpc failed")


def main():
    addrs = [l.strip().lower() for l in open(sys.argv[1]) if l.strip()]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "leaderboard.json")
    import hashlib
    # isFlagged(address) selector
    sel_f = "0x" + os.popen("cast sig 'isFlagged(address)'").read().strip()[2:]
    cache = out + '.partial'
    rows = json.load(open(cache)) if os.path.exists(cache) else []
    done = len(rows)
    for i in range(done, len(addrs), 100):
        chunk = addrs[i:i + 100]
        batch = []
        for j, a in enumerate(chunk):
            data = a[2:].rjust(64, "0")
            batch.append({"jsonrpc": "2.0", "id": 2 * j, "method": "eth_call", "params": [{"to": REG, "data": SEL_C + data}, "latest"]})
            batch.append({"jsonrpc": "2.0", "id": 2 * j + 1, "method": "eth_call", "params": [{"to": REG, "data": sel_f + data}, "latest"]})
        res = rpc(batch)
        for j, a in enumerate(chunk):
            h = res[2 * j][2:]
            c = [int(h[k * 64:(k + 1) * 64], 16) for k in range(5)]
            fl = int(res[2 * j + 1], 16) == 1
            s = score_1000(tuple(c))
            if fl:
                s = 0
            b, se = quote_score(s, c[4], True), quote_score(s, c[4], False)
            rows.append({"a": a, "s": s, "c": c, "f": fl, "buy": b["total"], "sell": se["total"], "dep": b["deposit"], "pen": b["penalty"]})
        json.dump(rows, open(cache, 'w'))
        print(i, file=sys.stderr)
    if os.path.exists(cache):
        os.remove(cache)
    rows.sort(key=lambda r: (-r["s"], r["a"]))
    json.dump({"registry": REG, "source": "8000 real mainnet wallets preloaded into the BSC testnet registry; components from the live registry", "n": len(rows), "rows": rows}, open(out, "w"), separators=(",", ":"))
    print(len(rows), rows[0], rows[-1])


main()
