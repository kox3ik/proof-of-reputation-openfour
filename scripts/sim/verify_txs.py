#!/usr/bin/env python3
"""Check the key transactions of a simulation run on chain (eth_getTransactionReceipt, status == 1) and write them into the run log.

  python3 verify_txs.py --runlog RUNLOG --rpc URL      (exit 1 if any key tx is missing or failed)
"""
import argparse, json, sys
from pathlib import Path
import urllib.request

EXPL = "https://testnet.bscscan.com/tx/"


def receipt(rpc, h):
    req = urllib.request.Request(rpc, json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionReceipt", "params": [h]}).encode(), {"content-type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=20)).get("result")


def pick(log):
    t = log["trades"]
    by = lambda s: [x for x in t if x["label"].startswith(s)]  # noqa: E731
    rows = []
    for x in by("honestA first buy T1")[:1]:
        rows.append(("first honest buy (fresh wallet, deposit)", x["hash"]))
    for x in by("bundle")[:4]:
        if "buys T1" in x["label"]:
            rows.append((f"{x['role']} buys T1 with the bundle", x["hash"]))
    for x in [y for y in t if "dumps T1" in y["label"]]:
        rows.append((f"{x['role']} dumps T1 (bundle dump)", x["hash"]))
    flag = next((e for e in log["livePublishing"]["txList"] if e.get("flagged")), None)
    if flag:
        rows.append(("publisher: flag publication (bundle flagged)", flag["hash"]))
    for x in [y for y in t if y["role"] == "bundle1" and ("BEFORE the flag" in y["label"] or "AFTER the flag" in y["label"])]:
        rows.append((x["label"], x["hash"]))
    for c in log["claims"]:
        if c["event"] == "Forfeited":
            rows.append((f"{c['forWallet']} deposit and cashback forfeited", c["hash"]))
    for c in log["claims"]:
        if c["event"] == "Claimed":
            rows.append((f"{c['forWallet']} claims deposit refund + cashback + bonus", c["hash"]))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runlog", required=True)
    ap.add_argument("--rpc", required=True)
    a = ap.parse_args()
    p = Path(a.runlog)
    log = json.loads(p.read_text())
    out, bad = [], 0
    for what, h in pick(log):
        r = receipt(a.rpc, h)
        ok = bool(r) and int(r["status"], 16) == 1
        bad += not ok
        out.append({"what": what, "hash": h, "link": EXPL + h, "block": int(r["blockNumber"], 16) if r else None, "status": 1 if ok else 0})
        print(("OK  " if ok else "FAIL"), what, EXPL + h)
    log["keyTxs"] = out
    p.write_text(json.dumps(log, indent=2))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
