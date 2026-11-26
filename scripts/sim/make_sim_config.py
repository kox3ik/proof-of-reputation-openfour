#!/usr/bin/env python3
"""Build the page for the simulation: a copy of app/ with config.json (registry, pool, real-wallet chips) and a sim-live.json stub.

  python3 make_sim_config.py --out-dir DIR --por deployments/por-deployment.json --state deployments/demo-state.json \
      --fork FORK_JSON --bots BOTS_FILE --preload PRELOAD_JSON --rpc URL [--explorer-chain]
Only public addresses are written (the bots file is read for its `address` / `role` fields only).
"""
import argparse, json, shutil
from pathlib import Path

APP = Path(__file__).resolve().parents[2] / "app"


def main():
    ap = argparse.ArgumentParser()
    for k in ("out-dir", "por", "state", "fork", "bots", "preload", "rpc"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--fresh-deposit-bps", default="640")
    ap.add_argument("--penalty-bps", default="640")
    ap.add_argument("--public-chain", action="store_true")
    ap.add_argument("--logs-rpc", default=None, help="node that allows eth_getLogs (page event feed)")
    a = ap.parse_args()
    out = Path(a.out_dir)
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(APP, out, ignore=shutil.ignore_patterns("sim-live.json", "screenshot.png"))
    por, state, fork = (json.loads(Path(p).read_text()) for p in (a.por, a.state, a.fork))
    roster = {b["role"]: b["address"] for b in json.loads(Path(a.bots).read_text())}
    samples = json.loads(Path(a.preload).read_text())["samples"]
    chips = {k: v["address"] for k, v in samples.items()}
    net = {"key": "testnet", "label": "BSC testnet (97)" if a.public_chain else "Local fork of BSC testnet (97)", "chainId": 97, "rpc": a.rpc,
           "explorer": "https://testnet.bscscan.com" if a.public_chain else None, "registry": por["registry"], "tradeModule": por["tradeModule"],
           "pool": por["pool"], "ledger": por["ledger"], "lockedToken": por.get("lockedToken"), "mockBabt": None, "mockAgentId": None,
           "quoteAsset": fork["addresses"]["wbnb"], "token": None, "tokens": [], "router": None, "presetId": state.get("presetId"), "wallets": chips,
           "treasury": None, "fromBlock": None, "pollMs": 3000 if a.public_chain else 1500, "logsRpc": a.logs_rpc}
    (out / "config.json").write_text(json.dumps({"default": "testnet", "networks": {"testnet": net}, "runSource": "simulation", "runOnTestnet": a.public_chain}, indent=2))
    (out / "run.json").write_text(json.dumps({"trades": [], "token": ""}))
    (out / "sim-live.json").write_text(json.dumps({"roster": roster, "tokens": {}, "trades": [], "onPublicChain": a.public_chain,
                                                    "rates": {"freshDepositBps": a.fresh_deposit_bps, "penaltyBps": a.penalty_bps}}))
    html = (out / "index.html").read_text().replace('<section id="table">', '<section id="table" hidden>', 1)
    (out / "index.html").write_text(html)
    print(f"page written to {out} ({len(chips)} real-wallet chips, {len(roster)} bots)")


if __name__ == "__main__":
    main()
