#!/usr/bin/env python3
"""Adapter: turn the simulation's run log + deployment files into the run json that scripts/demo/make_submit_pack.js reads.

  python3 make_submit_input.py --runlog RUNLOG --state demo-state.json --por por-deployment.json --fork fork-deployment.json --deployer 0x.. --out run.json
"""
import argparse, json
from datetime import datetime, timezone
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    for k in ("runlog", "state", "por", "fork", "deployer", "out"):
        ap.add_argument("--" + k, required=True)
    a = ap.parse_args()
    log, state, por, fork = (json.loads(Path(p).read_text()) for p in (a.runlog, a.state, a.por, a.fork))
    wbnb = fork["addresses"]["wbnb"]
    rows = [{"tokenAddress": t["token"], "name": t["name"], "symbol": t["name"], "presetId": state["presetId"], "presetName": "Reputation Bonding V1",
             "creator": a.deployer, "txHash": t["tx"], "chainId": log["network"]["chainId"], "quoteAsset": wbnb,
             "createdAt": datetime.fromtimestamp(t["ts"], timezone.utc).isoformat().replace("+00:00", "Z")} for t in log["tokens"].values()]
    run = {"chainId": log["network"]["chainId"], "generatedAt": log["startedAt"], "onPublicChain": log["network"]["onPublicChain"],
           "openfour": fork["addresses"], "por": por, "presetId": state["presetId"], "registration": state, "tokenRecord": rows[0], "extraTokens": rows[1:]}
    Path(a.out).write_text(json.dumps(run, indent=2))
    print(f"submit input written: {a.out} ({len(rows)} tokens)")


if __name__ == "__main__":
    main()
