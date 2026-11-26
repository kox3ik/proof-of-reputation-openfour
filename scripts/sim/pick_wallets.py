#!/usr/bin/env python3
"""Pick the real mainnet (Four.meme / OpenFour) wallets to preload into a testnet Registry.

Reads a prepared history snapshot (service/publisher/data/snapshot.npz, built offline) with the publisher's own modules; the
scores are computed later by the publisher itself (`run.py --preload FILE`), nothing is scored here.

  python3 pick_wallets.py --n 8000 --out-dir DIR     -> DIR/preload.txt (one address per line), DIR/preload.json (summary + samples)
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "service", "publisher"))
import snapshot_io  # noqa: E402
from reference import Reference  # noqa: E402
from wallets import WalletTable  # noqa: E402


MAX_FLAGGED = 10**9  # no cap: the publisher advances coverage in steps when flags exceed a batch (see Engine.flag_step)


def pick(t: WalletTable, n: int, seed: int) -> list[int]:
    rng = np.random.default_rng(seed)
    known = np.nonzero(t.known[: t.n] & (t.vol[: t.n] > 0))[0]
    flagged = known[t.flag[known]]
    clean = known[~t.flag[known]]
    top = clean[np.argsort(-t.vol[clean])[: n * 15 // 100]]
    rest = np.setdiff1d(clean, top)
    active = rest[t.n_tok[rest] >= 10]
    plain = np.setdiff1d(rest, active)
    take = lambda a, k: rng.choice(a, size=min(k, len(a)), replace=False)  # noqa: E731
    chosen = np.concatenate([top, take(flagged, min(n * 10 // 100, MAX_FLAGGED)), take(active, n * 35 // 100)])
    chosen = np.concatenate([chosen, take(plain, n - len(chosen))])
    return [int(i) for i in chosen[:n]]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", default=snapshot_io and os.path.join(HERE, "..", "..", "service", "publisher", "data", "snapshot.npz"))
    ap.add_argument("--n", type=int, default=8000)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out-dir", required=True)
    a = ap.parse_args()
    snap = snapshot_io.load(a.snapshot)
    t = WalletTable(snap)
    ref = Reference()
    ref.rebuild(t, float(snap.meta.get("as_of_ts", 0)))
    ids = pick(t, a.n, a.seed)
    now = float(snap.meta.get("as_of_ts", 0))
    rows = []
    for w in ids:
        v, ac, h, _, p = ref.components(t, w, now)
        rows.append({"address": t.addr[w], "volume_bnb": round(float(t.vol[w]), 4), "tokens": int(t.n_tok[w]), "components": [v, ac, h, 0, p],
                     "approx_score": 0.0 if p else round((30 * v + 25 * ac + 25 * h) / 100 / 1000, 3), "flagged": bool(p)})
    os.makedirs(a.out_dir, exist_ok=True)
    with open(os.path.join(a.out_dir, "preload.txt"), "w") as fh:
        fh.write("\n".join(r["address"] for r in rows) + "\n")
    clean = sorted((r for r in rows if not r["flagged"]), key=lambda r: r["approx_score"])
    pick_at = lambda q: clean[int(q * (len(clean) - 1))]  # noqa: E731
    samples = {"real: top": pick_at(1.0), "real: high": pick_at(0.9), "real: median": pick_at(0.5), "real: low": pick_at(0.1),
               "real: flagged (rug history)": next(r for r in rows if r["flagged"])}
    summary = {"wallets": len(rows), "flagged": sum(r["flagged"] for r in rows), "snapshot": snap.meta,
               "score_deciles": [pick_at(q / 10)["approx_score"] for q in range(11)], "samples": samples}
    with open(os.path.join(a.out_dir, "preload.json"), "w") as fh:
        json.dump(summary, fh, indent=2)
    print(f"picked {len(rows)} wallets ({summary['flagged']} flagged); score deciles {summary['score_deciles']}")


if __name__ == "__main__":
    main()
