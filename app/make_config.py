#!/usr/bin/env python3
"""Generate app/config.json and app/run.json from ../deployments and a demo run JSON (stdlib only).

  python3 make_config.py                              # local run json, testnet = deployments/testnet.json
  python3 make_config.py --run ../demo-out/demo-run-testnet.json
  python3 make_config.py --testnet-por                # testnet = por-deployment.json (+ demo-mocks.json) after a redeploy

Only public addresses and tx hashes are written. No keys, no RPC secrets.
"""
import argparse, json, shutil, sys
from pathlib import Path

APP = Path(__file__).resolve().parent
DEP = APP.parent / "deployments"
ROLES = ["trusted", "regular", "fresh", "flagged", "babholder", "agentholder"]


def load(p):
    p = Path(p)
    return json.loads(p.read_text()) if p.exists() else {}


def broadcast_block():
    """Earliest block of our latest local Deploy.s.sol broadcast (receipts), or None."""
    b = load(APP.parent / "broadcast" / "Deploy.s.sol" / "97" / "run-latest.json")
    blocks = [int(r["blockNumber"], 16) for r in b.get("receipts", []) if r.get("blockNumber")]
    return min(blocks) if blocks else None


def testnet_net(por_overlay):
    t = load(DEP / "testnet.json")
    por = dict(t.get("proofOfReputation", {}))
    of = t.get("openfour", {})
    wallets = dict(t.get("demoWallets", {}))
    state = {}
    if por_overlay:
        por.update({k: v for k, v in load(DEP / "por-deployment.json").items()})
        mocks = load(DEP / "demo-mocks.json")
        por["mockBABT"] = mocks.get("babToken", por.get("mockBABT"))
        por["mockAgentId"] = mocks.get("agentIdToken", por.get("mockAgentId"))
        state = load(DEP / "demo-state.json")
    return {
        "key": "testnet", "label": "BSC testnet (97)", "chainId": 97,
        "rpc": "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
        "explorer": t.get("explorer", "https://testnet.bscscan.com"),
        "registry": por.get("registry"), "tradeModule": por.get("tradeModule"),
        "pool": por.get("pool"), "ledger": por.get("ledger"),
        "lockedToken": por.get("lockedToken") or por.get("lockedTokenImpl"),
        "mockBabt": por.get("mockBABT"), "mockAgentId": por.get("mockAgentId"),
        "quoteAsset": of.get("wbnb"), "token": t.get("demoToken"), "router": t.get("demoRouter"),
        "presetId": state.get("presetId") or (t.get("preset") or {}).get("id"),
        "wallets": {k: wallets[k] for k in ROLES if k in wallets},
        "treasury": wallets.get("treasury"),
        "fromBlock": por.get("deployBlock"),  # event queries start here (null = not recorded: from genesis)
    }


def local_net(run):
    por = dict(load(DEP / "por-deployment.json"))
    por.update(run.get("por", {}))
    mocks = load(DEP / "demo-mocks.json")
    cfg = run.get("config", {})
    return {
        "key": "local", "label": "Local fork (127.0.0.1:8545)", "chainId": 97,
        "rpc": "http://127.0.0.1:8545", "explorer": None,
        "registry": por.get("registry"), "tradeModule": por.get("tradeModule"),
        "pool": por.get("pool"), "ledger": por.get("ledger"),
        "lockedToken": por.get("lockedToken"),
        "mockBabt": mocks.get("babToken") or cfg.get("babToken"),
        "mockAgentId": mocks.get("agentIdToken") or cfg.get("agentIdToken"),
        "quoteAsset": run.get("openfour", {}).get("wbnb"), "token": run.get("token"),
        "router": run.get("router"), "presetId": run.get("presetId"),
        "wallets": {k: v for k, v in run.get("wallets", {}).items() if k in ROLES},
        "treasury": cfg.get("treasury"),
        "fromBlock": por.get("deployBlock") or broadcast_block(),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", default=str(APP.parent / "demo-out" / "demo-run-local.json"))
    ap.add_argument("--testnet-por", action="store_true", help="take testnet addresses from por-deployment.json")
    a = ap.parse_args()
    run_path = Path(a.run)
    if not run_path.exists():
        sys.exit(f"run json not found: {run_path}")
    run = json.loads(run_path.read_text())
    shutil.copyfile(run_path, APP / "run.json")
    cfg = {"default": "testnet", "networks": {"testnet": testnet_net(a.testnet_por), "local": local_net(run)},
           "runSource": run_path.name,
           "runOnTestnet": not any(h in str(run.get("rpc", "")) for h in ("127.0.0.1", "localhost"))}
    (APP / "config.json").write_text(json.dumps(cfg, indent=2) + "\n")
    print(f"wrote config.json and run.json ({len(run.get('trades', []))} trades) from {run_path.name}")


if __name__ == "__main__":
    main()
