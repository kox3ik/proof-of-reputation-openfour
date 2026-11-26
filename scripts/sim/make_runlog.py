#!/usr/bin/env python3
"""Merge everything of one simulation run into one JSON: deployment txs, preload (rating load) txs, bot trades, claims, flags, costs.

  python3 make_runlog.py --scenario RUN_LOG --publisher publisher.jsonl --state demo-state.json --broadcast-dir broadcast --out OUT [--video PATH ...]
"""
import argparse, json
from pathlib import Path

EXPL = "https://testnet.bscscan.com/tx/"


def load_jsonl(p):
    out = []
    for line in Path(p).read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def deploy_txs(bdir, state):
    rows = []
    for script in ("DeployDemoMocks.s.sol", "Deploy.s.sol"):
        f = Path(bdir) / script / "97" / "run-latest.json"
        if f.exists():
            for t in json.loads(f.read_text()).get("transactions", []):
                rows.append({"what": f"{script}: {t.get('transactionType')} {t.get('contractName') or ''}".strip(), "hash": t["hash"], "link": EXPL + t["hash"],
                             "address": t.get("contractAddress")})
    for k, label in (("upsertModuleTx", "register trade module"), ("upsertDataModuleTx", "register ledger module"), ("upsertTokenImplTx", "register token implementation"),
                     ("upsertPresetTx", "register preset")):
        if state.get(k):
            rows.append({"what": label, "hash": state[k], "link": EXPL + state[k]})
    return rows


def scanned(a):
    names = {}
    for f in ("por-deployment.json", "demo-mocks.json"):
        for k, v in json.loads((Path(a.por) / f).read_text()).items():
            names[v.lower()] = k
    rows = [{"what": "deploy " + names.get((r["contractAddress"] or "").lower(), "contract"), "hash": r["hash"], "link": EXPL + r["hash"], "address": r["contractAddress"]}
            for r in json.loads(Path(a.deployment_scan).read_text()) if r["contractAddress"] and r["contractAddress"].lower() in names]
    st = json.loads(Path(a.state).read_text())
    for k, label in (("upsertModuleTx", "register trade module"), ("upsertDataModuleTx", "register ledger module"), ("upsertTokenImplTx", "register token implementation"),
                     ("upsertPresetTx", "register preset")):
        if st.get(k):
            rows.append({"what": label, "hash": st[k], "link": EXPL + st[k]})
    return rows


def main():
    ap = argparse.ArgumentParser()
    for k in ("scenario", "publisher", "state", "broadcast-dir", "out"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--preload-json", default=None)
    ap.add_argument("--deployment-scan", default=None, help="json of the deployer's txs around the registry block (replaces the forge broadcast files)")
    ap.add_argument("--por", default=None, help="por-deployment.json + demo-mocks.json dir, to name scanned contracts")
    ap.add_argument("--video", action="append", default=[])
    ap.add_argument("--gas-price-wei", type=int, default=100_000_000)
    a = ap.parse_args()
    sc = json.loads(Path(a.scenario).read_text())
    pub = load_jsonl(a.publisher)
    pubs = [e for e in pub if e.get("event") == "publish" and e.get("ok")]
    pre_n = next((e.get("queued") for e in pub if e.get("event") == "preload"), 0)
    # the first publishes carry the preload; those before the scenario started are the "rating load"
    started = json.loads(Path(a.scenario).read_text())["startedAt"]
    from datetime import datetime
    t_start = datetime.fromisoformat(started.replace("Z", "+00:00")).timestamp()
    load_tx = [e for e in pubs if e["t"] < t_start and e["wallets"] >= 20]  # load batches are big; live publications carry a few wallets
    live_tx = [e for e in pubs if e["t"] >= t_start]
    gas_load = sum(e.get("gas_used", 0) for e in load_tx)
    gas_live = sum(e.get("gas_used", 0) for e in live_tx)
    price = a.gas_price_wei
    out = {"network": {"chainId": sc["chainId"], "onPublicChain": sc["onPublicChain"], "explorer": sc["explorer"], "registry": sc["registry"], "pool": sc["pool"] if isinstance(sc["pool"], str) else None, "core": sc["core"]},
           "rates": sc["rates"], "startedAt": sc["startedAt"], "finishedAt": sc.get("finishedAt"),
           "deployment": scanned(a) if a.deployment_scan else deploy_txs(a.broadcast_dir, json.loads(Path(a.state).read_text())),
           "ratingLoad": {"walletsQueued": pre_n, "walletsPublished": sum(e["wallets"] for e in load_tx), "flaggedHistory": sum(e["flagged"] for e in load_tx), "txs": len(load_tx),
                          "gasUsed": gas_load, "costTbnbAtGasPrice": gas_load * price / 1e18, "gasPriceWei": price,
                          "txList": [{"hash": e["tx"], "link": EXPL + e["tx"], "wallets": e["wallets"], "gasUsed": e.get("gas_used")} for e in load_tx]},
           "livePublishing": {"txs": len(live_tx), "gasUsed": gas_live, "costTbnbAtGasPrice": gas_live * price / 1e18,
                              "txList": [{"hash": e["tx"], "link": EXPL + e["tx"], "wallets": e["wallets"], "flagged": e["flagged"], "latencyBlocks": e.get("latency_blocks"),
                                          "coveredUntil": e.get("covered_until")} for e in live_tx]},
           "wallets": sc["wallets"], "tokens": sc["tokens"], "steps": sc["steps"], "flag": sc.get("flag"), "feeBeforeAfter": sc.get("feeBeforeAfter"),
           "trades": sc["trades"], "claims": sc["claims"], "otherTxs": sc["txs"], "poolAtEnd": sc.get("poolState", sc["pool"] if isinstance(sc["pool"], dict) else None), "final": sc["final"], "timeline": sc["timeline"], "videos": a.video}
    if a.preload_json:
        out["preload"] = {k: v for k, v in json.loads(Path(a.preload_json).read_text()).items() if k != "snapshot"}
    Path(a.out).write_text(json.dumps(out, indent=2))
    print(f"run log written: {a.out} (rating load {out['ratingLoad']['walletsPublished']} wallets, {gas_load} gas, "
          f"{out['ratingLoad']['costTbnbAtGasPrice']:.4f} tBNB at {price} wei)")


if __name__ == "__main__":
    main()
