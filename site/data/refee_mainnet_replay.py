"""Re-price an existing mainnet replay (terminal/mainnet-*.json) with the current contract formula, keeping trades,
tx hashes and events. Fees in the replay are per wallet (score and rug flag fixed before the token's first trade), so
the score (3 decimals = exact integer 0..1000) and the flag are enough: flagged = penalty component 1000."""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_mainnet_replay import fee_curve, quote_score  # noqa: E402


def reprice(d: dict) -> dict:
    wallets = {}
    for a, w in d["wallets"].items():
        s, pen = round(w["score"] * 1000), (1000 if w["flagged"] else 0)
        qb, qs = quote_score(s, pen, True), quote_score(s, pen, False)
        wallets[a] = {**w, "buyBps": qb["total"], "sellBps": qs["total"], "depositBps": qb["deposit"]}
    trades = []
    for t in d["trades"]:
        w = d["wallets"][t["wallet"]]
        s, pen = round(w["score"] * 1000), (1000 if w["flagged"] else 0)
        old = t["feeBps"]
        if old["regular"] != min(fee_curve(s), 100 if (t["side"] == "sell" and pen == 0) else 10**9):
            raise SystemExit(f"regular mismatch {t['wallet']} {old} s={s}")
        trades.append({**t, "feeBps": quote_score(s, pen, t["side"] == "buy")})
    return {**d, "wallets": wallets, "trades": trades}


def main() -> None:
    for p in sorted(glob.glob(os.path.join(sys.argv[1], "mainnet-*.json"))):
        d = json.load(open(p))
        out = reprice(d)
        with open(p, "w") as fh:
            json.dump(out, fh, separators=(",", ":"))
        print(p, len(out["trades"]), "trades re-priced")


if __name__ == "__main__":
    main()
