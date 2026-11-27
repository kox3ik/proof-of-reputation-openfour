#!/usr/bin/env python3
"""Build the BSC testnet data set for terminal.html from the simulation run log.
Usage: build_testnet_set.py RUNLOG.json [OUT_DIR]   (OUT_DIR default: ./terminal next to this script)
Merges into OUT_DIR/index.json without touching other sets."""
import json, os, sys

BASE_BLOCK_TS = 0.4463  # seconds per block, from token-create ts vs flaggedFrom in the log

def main():
    log = json.load(open(sys.argv[1]))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "terminal")
    os.makedirs(out, exist_ok=True)
    tokens = log["tokens"]
    t0b, t0t = tokens["T1"]["block"], tokens["T1"]["ts"]
    ts = lambda b: int(round(t0t + (b - t0b) * BASE_BLOCK_TS))
    flag = log["flag"]
    names = {v["token"].lower(): (k, v) for k, v in tokens.items()}
    who = {a.lower(): k for k, a in log["wallets"].items()}
    final = log["final"]
    files = []
    for key, tk in tokens.items():
        addr = tk["token"].lower()
        trades, wallets = [], {}
        for tr in log["trades"]:
            if tr["token"].lower() != addr:
                continue
            q = tr["fees"]["quoted"]
            role = tr["role"]
            if role.startswith("honest"): r = "honest"
            elif role.startswith("newbie"): r = "new"
            else: r = "flagged" if tr["before"]["flagged"] else "bundle"
            bnb = tr["fees"]["curveQuoteBnb"]
            tok = int(tr["fees"]["tokens"]) / 1e18
            trades.append({"t": ts(tr["block"]), "block": tr["block"], "side": tr["side"], "wallet": tr["wallet"].lower(),
                           "bnb": bnb, "tokens": tok, "price": bnb / tok, "tx": tr["hash"],
                           "feeBps": {"regular": q["regular"], "deposit": q["deposit"], "penalty": q["penalty"], "total": q["total"]},
                           "role": r, "label": tr["label"]})
            w = tr["wallet"].lower()
            f = final[tr["role"]]
            wallets[w] = {"score": f["score"], "flagged": f["flagged"], "fresh": f["fresh"],
                          "buyBps": f["bps"]["total"], "sellBps": f["bps"]["total"], "depositBps": f["bps"]["deposit"],
                          "label": tr["role"], "live": False}
        trades.sort(key=lambda x: x["block"])
        events = []
        if any(t["role"] == "bundle" for t in trades) and any(t["side"] == "sell" for t in trades if t["role"] == "bundle"):
            events.append({"t": ts(flag["dumpBlock"]), "kind": "dump", "text": "Bundle dumps together (4 wallets, one block)",
                           "tx": next(t["tx"] for t in trades if t["side"] == "sell" and t["role"] == "bundle")})
        events.append({"t": ts(flag["flaggedBlock"]), "kind": "flag",
                       "text": "Bundle flagged by the rule, %d blocks (%d s) after the dump" % (flag["blocksAfterDump"], flag["secondsAfterDump"]), "tx": ""})
        for c in log["claims"]:
            if c["wallet"].lower() in wallets:
                a = c["args"]
                ev = "Deposit forfeited by flagged wallet" if c["event"] == "Forfeited" else "Cashback and deposit claimed"
                events.append({"t": ts(c["block"]), "kind": "claim", "text": "%s (%s)" % (ev, c["forWallet"]), "tx": c["hash"]})
        fn = "testnet-%s.json" % tk["name"].lower()
        doc = {"id": "testnet-" + key.lower(), "name": tk["name"], "symbol": tk["name"][:5], "network": "bsc-testnet",
               "address": tk["token"], "note": "BSC testnet: real transactions of our simulation run (token on the OpenFour curve). Time per trade is derived from its block.",
               "trades": trades, "wallets": wallets, "events": events}
        json.dump(doc, open(os.path.join(out, fn), "w"), indent=1)
        files.append(fn)
    ip = os.path.join(out, "index.json")
    idx = json.load(open(ip)) if os.path.exists(ip) else {"sets": []}
    idx["sets"] = [s for s in idx["sets"] if s.get("id") != "testnet"]
    idx["sets"].insert(0, {"id": "testnet", "title": "BSC testnet · live",
                           "note": "BSC testnet: real transactions of our simulation; trader ratings and fees are re-read live from the registry.", "tokens": files})
    json.dump(idx, open(ip, "w"), indent=1)
    print("wrote", files)

main()
