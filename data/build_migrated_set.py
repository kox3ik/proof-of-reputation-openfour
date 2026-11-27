#!/usr/bin/env python3
"""Build the terminal data set for the BSC testnet run with a migration (27 Nov 2026).

  build_migrated_set.py extract RAW.json SCORES.json OUT_CHAIN.json   trim NodeReal receipts to the numbers we use
  build_migrated_set.py build RUN.json CHAIN.json [OUT_DIR]           write testnet-<symbol>.json, merge into index.json

RUN.json is the run record (submission/migrate-run-testnet-20261127.json); CHAIN.json is the trimmed chain extract
(receipts of the 8 curve trades: Core Trade event and cashback-pool Inflow event, tx value, registry scores, two block
times). Fees come from the logs of each trade: module fee / curve quote, Inflow deposit / quote, Inflow fund / quote.
Nothing is estimated; times of blocks other than the two fetched ones are linear in the block number.
"""
import json
import os
import sys

CORE_TRADE = "0x8728ba77"  # topic0 prefix of the Core trade event
INFLOW = "0xd740b3bd"      # CashbackPool.Inflow(asset, wallet, budget, deposit, fund, bonus)
IDX = {"isBuy": 0, "tokens": 3, "quote": 5, "protocolFee": 9, "moduleFee": 10}
ROLE_CLASS = {"fresh": "new", "regular": "honest", "trusted": "honest"}
SET_ID = "testnet-migrated"
SET_TITLE = "Testnet · full path with migration (27 Nov)"
SET_NOTE = ("BSC testnet, 27 Nov 2026: create → buys → sells → migration to PancakeSwap → claims, "
            "all real transactions. Fees come from each trade's own logs; ratings are the registry values at the time of the run, "
            "not re-read.")


def _words(data):
    h = data[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h) // 64 * 64, 64)]


def extract(raw, scores, run):
    """Trim raw receipts/transactions to the numbers the set needs (pure: inputs are not modified)."""
    steps = [s for s in run["steps"] if s.get("step", "").startswith(("buy", "sell"))]
    trades = []
    for s in steps:
        h = s["tx"]
        rc, tx = raw["rc"][h], raw["tx"][h]
        if rc.get("status") != "0x1":
            raise ValueError("trade %s did not succeed" % h)
        core = [l for l in rc["logs"] if l["address"].lower() == tx["to"].lower() and l["topics"][0].startswith(CORE_TRADE)]
        inflow = [l for l in rc["logs"] if l["topics"][0].startswith(INFLOW)]
        if len(core) != 1 or len(inflow) != 1:
            raise ValueError("expected one Core trade and one Inflow event in %s" % h)
        w, iw = _words(core[0]["data"]), _words(inflow[0]["data"])
        side = "buy" if s["step"].startswith("buy") else "sell"
        if (w[IDX["isBuy"]] == 1) != (side == "buy"):
            raise ValueError("side of %s does not match the Core event" % h)
        trades.append({
            "tx": h, "block": int(rc["blockNumber"], 16), "side": side, "role": s["role"],
            "wallet": "0x" + core[0]["topics"][2][-40:], "valueWei": str(int(tx["value"], 16)),
            "core": {k: str(w[i]) for k, i in IDX.items()},
            "inflow": dict(zip(("budget", "deposit", "fund", "bonus"), (str(x) for x in iw[:4]))),
        })
    last = next(s["block"] for s in run["steps"] if s.get("step") == "migrate")
    return {
        "token": run["token"], "chainId": run["chainId"],
        "registry": "0x98bbf48635f680bdbecda0343896d8a7a2ca703e",
        "scores": {k: scores[k] for k in sorted(scores)},
        "blockTimes": {str(run["steps"][1]["block"]): raw["block0"], str(last): raw["block"]},
        "trades": trades,
    }


def _clock(chain):
    (b0, t0), (b1, t1) = sorted((int(b), t) for b, t in chain["blockTimes"].items())
    rate = (t1 - t0) / (b1 - b0)
    return lambda b: int(round(t0 + (b - b0) * rate))


def _bps(num, den):
    return int(round(int(num) * 10000 / int(den)))


def _trade(tr, ts):
    q, c = int(tr["core"]["quote"]), tr["core"]
    total, dep, pen = _bps(c["moduleFee"], q), _bps(tr["inflow"]["deposit"], q), _bps(tr["inflow"]["fund"], q)
    tokens = int(c["tokens"]) / 1e18
    bnb = q / 1e18
    return {"t": ts(tr["block"]), "block": tr["block"], "side": tr["side"], "wallet": tr["wallet"].lower(),
            "bnb": bnb, "tokens": tokens, "price": bnb / tokens, "tx": tr["tx"], "phase": "curve",
            "feeBps": {"regular": total - dep - pen, "deposit": dep, "penalty": pen, "total": total},
            "role": ROLE_CLASS[tr["role"]], "label": "%s %s" % (tr["role"], tr["side"])}


def _wallets(chain, trades):
    out = {}
    for tr, x in zip(chain["trades"], trades):
        w, role = x["wallet"], tr["role"]
        sc = int(chain["scores"][role + ".score"], 16) / 1000
        flagged = int(chain["scores"][role + ".flag"], 16) != 0
        f = x["feeBps"]
        cur = out.get(w, {"score": sc, "flagged": flagged, "fresh": f["deposit"] > 0 and not flagged, "buyBps": None,
                          "sellBps": None, "depositBps": 0, "label": role, "live": False})
        if x["side"] == "buy" and cur["buyBps"] is None:
            cur = dict(cur, buyBps=f["total"], depositBps=f["deposit"], fresh=f["deposit"] > 0 and not flagged)
        if x["side"] == "sell" and cur["sellBps"] is None:
            cur = dict(cur, sellBps=f["total"])
        out[w] = cur
    # a wallet that never sold pays the same rate on a sale minus the (buy-only) deposit
    return {w: dict(v, sellBps=v["sellBps"] if v["sellBps"] is not None else v["buyBps"] - v["depositBps"]) for w, v in out.items()}


def _events(run, ts, trades):
    st = {s.get("step", ""): s for s in run["steps"]}
    mig = st["migrate"]
    ev = [{"t": ts(mig["block"]), "kind": "migrate", "block": mig["block"], "tx": mig["tx"],
           "text": "Migrated to PancakeSwap (block %d): the raise target was reached, %.4f BNB raised" % (mig["block"], int(mig["totalRaised"]) / 1e18)}]
    fin = st["finalizeEpoch (coveredUntil passes the migration)"]
    ev.append({"t": ts(fin["block"]), "kind": "finalize", "block": fin["block"], "tx": fin["tx"],
               "text": "Epoch finalized after the migration (block %d): unlocks cashback and deposits" % fin["block"]})
    for s in run["steps"]:
        if s.get("step", "").startswith("claim") and "paid" in s:
            ev.append({"t": ts(s["block"]), "kind": "claim", "block": s["block"], "tx": s["tx"],
                       "text": "Cashback and deposit claimed (%s): %.6f BNB" % (s["role"], int(s["paid"]["total"]) / 1e18)})
    return sorted(ev, key=lambda e: (e["block"], e["kind"]))


def build_set(run, chain):
    """Return the token document; trades after the migration are listed with phase 'pool' (none in this run)."""
    ts = _clock(chain)
    trades = sorted((_trade(t, ts) for t in chain["trades"]), key=lambda x: x["block"])
    ordered = sorted(chain["trades"], key=lambda t: t["block"])
    mig_block = next(s["block"] for s in run["steps"] if s.get("step") == "migrate")
    trades = [dict(x, phase="pool" if x["block"] > mig_block else "curve") for x in trades]
    sym = run["steps"][1]["tokenRecord"]["symbol"]
    after = sum(1 for x in trades if x["phase"] == "pool")
    return {"id": SET_ID + "-" + sym.lower(), "name": sym, "symbol": sym, "network": "bsc-testnet", "address": run["token"],
            "note": "Full path on BSC testnet: %d trades on the curve, %s after the migration (finalizeEpoch and the claims follow). Time per trade is derived from its block." % (
                len(trades) - after, "none" if not after else str(after)),
            "registry": chain["registry"], "migrated": {"block": mig_block, "tx": next(s["tx"] for s in run["steps"] if s.get("step") == "migrate")},
            "trades": trades, "wallets": _wallets(dict(chain, trades=ordered), trades), "events": _events(run, ts, trades)}


def merge_index(idx, file_name):
    """Return a new index with the migrated set right after the 26 Nov simulation set."""
    sets = [s for s in idx["sets"] if s.get("id") != SET_ID]
    pos = next((i + 1 for i, s in enumerate(sets) if s.get("id") == "testnet"), 0)
    entry = {"id": SET_ID, "title": SET_TITLE, "note": SET_NOTE, "static": True, "tokens": [file_name]}
    return dict(idx, sets=sets[:pos] + [entry] + sets[pos:])


def main(argv):
    if len(argv) >= 5 and argv[1] == "extract":
        raw, scores = json.load(open(argv[2])), json.load(open(argv[3]))
        run = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "submission", "migrate-run-testnet-20261127.json")))
        json.dump(extract(raw, scores, run), open(argv[4], "w"), indent=1)
        return 0
    if len(argv) >= 4 and argv[1] == "build":
        run, chain = json.load(open(argv[2])), json.load(open(argv[3]))
        out = argv[4] if len(argv) > 4 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "terminal")
        doc = build_set(run, chain)
        fn = "testnet-%s.json" % doc["symbol"].lower()
        json.dump(doc, open(os.path.join(out, fn), "w"), indent=1)
        ip = os.path.join(out, "index.json")
        idx = json.load(open(ip)) if os.path.exists(ip) else {"sets": []}
        json.dump(merge_index(idx, fn), open(ip, "w"), indent=1)
        print("wrote", fn, len(doc["trades"]), "trades")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
