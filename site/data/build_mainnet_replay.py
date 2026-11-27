#!/usr/bin/env python3
"""Build the "mainnet replay" JSON files of the trading-terminal page.

Real Four.meme curve trades (public on-chain history) + the reputation score our open rule would have given every
trader BEFORE the token's first trade (point in time, no look-ahead) + the fee our module would charge per trade.

  python3 build_mainnet_replay.py --trades trades_hist.npz --rugs rug_events.jsonl.gz --quote-meta quote_meta.json \
      --out-dir site/data/terminal --token 0x..:rug --token 0x..:organic [--token ...]

Inputs are plain files given on the command line (no network access, no chain calls):
  trades   npz with columns block ts tx_index log_index side(+1 buy/-1 sell) amount quote price token wallet token_names wallet_names
  rugs     jsonl.gz of rug events {"token","block","wallets":[..],"supply_pct","price_drop_pct","ts"} (rug rule: sells >= 50% of a
           position inside a 3-block window, >= 5% of supply, >= 30% price drop)
  quote-meta json {"mig_quote": {token: quote asset}} (only BNB-quoted curves are priced; zero address = BNB)

Scoring rule = the repository's open rule (service/publisher/reference.py + wallets.py): components volume / activity / holding are
integer percentile ranks 0..1000 of a wallet's raw stats among all wallets known at that time, penalty 1000 for rug participants,
identity 0 (no BAB / Agent ID data in the history). Fee = ReputationMath.score / feeBps + ReputationRegistry.quoteDetailed, ported 1:1.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import sys

import numpy as np

DAY = 86400
DUST = 1e-6
BNB = "0x0000000000000000000000000000000000000000"

# --- deployed config (script/Deploy.s.sol defaults, same values as the testnet registry; verified by test_mainnet_replay_port.py) ---
CFG = dict(wVolume=30, wActivity=25, wHolding=25, wIdentity=20, penaltyWeight=1000, flagThreshold=700, neutralScore=400,
           zeroBps=50, neutralBps=50, minBps=0, sellCapBps=100, treasuryShareBps=5000, freshDepositBps=640, penaltyBps=640)
MAX_SCORE, MAX_TOTAL_BPS = 1000, 950


def score_1000(c: tuple[int, int, int, int, int], cfg: dict = CFG) -> int:
    """ReputationMath.score: weighted average of the 4 positive components minus penalty * penaltyWeight / 1000 (integer, floor)."""
    v, a, h, i, p = c
    sum_w = cfg["wVolume"] + cfg["wActivity"] + cfg["wHolding"] + cfg["wIdentity"]
    pos = (v * cfg["wVolume"] + a * cfg["wActivity"] + h * cfg["wHolding"] + i * cfg["wIdentity"]) // sum_w
    pen = p * cfg["penaltyWeight"] // MAX_SCORE
    return pos - pen if pos > pen else 0


def fee_curve(s: int, cfg: dict = CFG) -> int:
    """ReputationMath.feeBps: quadratic below neutralScore, linear above (integer division like Solidity)."""
    s = min(s, MAX_SCORE)
    n = cfg["neutralScore"]
    if s < n:
        d = n - s
        return cfg["neutralBps"] + (cfg["zeroBps"] - cfg["neutralBps"]) * d * d // (n * n)
    return cfg["neutralBps"] - (cfg["neutralBps"] - cfg["minBps"]) * (s - n) // (MAX_SCORE - n)


def quote_detailed(c: tuple[int, int, int, int, int], is_buy: bool, cfg: dict = CFG) -> dict:
    """ReputationRegistry.quoteDetailed for stored components c (no BAB / Agent ID held)."""
    flagged = c[4] >= cfg["flagThreshold"]
    regular = fee_curve(score_1000(c, cfg), cfg)
    if not is_buy and not flagged and regular > cfg["sellCapBps"]:
        regular = cfg["sellCapBps"]
    regular = min(regular, MAX_TOTAL_BPS)
    fresh = not any(c)
    deposit = cfg["freshDepositBps"] if fresh and is_buy else 0
    penalty = cfg["penaltyBps"] if flagged else 0
    return {"regular": regular, "deposit": deposit, "penalty": penalty, "total": regular + deposit + penalty}


def rank(sorted_ref: np.ndarray, x: float) -> int:
    """reference.rank: mid-rank percentile 0..1000, ties share the mean rank."""
    n = len(sorted_ref)
    if n == 0:
        return 0
    lo = int(np.searchsorted(sorted_ref, x, side="left"))
    hi = int(np.searchsorted(sorted_ref, x, side="right"))
    return min(1000, (lo + hi) * 500 // n)


class History:
    """Raw per-wallet stats from all trades strictly before `cut` (BNB-quoted curves priced, other quotes count days/tokens only)."""

    def __init__(self, z: dict, bnb_tok: np.ndarray, cut: int, sample: int = 40000, seed: int = 7) -> None:
        m = z["ts"] < cut
        w, t, ts, q = z["wallet"][m], z["token"][m], z["ts"][m].astype(np.int64), z["quote"][m]
        priced = np.where(bnb_tok[t], q, 0.0)
        nw = len(z["wallet_names"])
        self.vol = np.bincount(w, weights=priced, minlength=nw)
        pairs = np.unique(w.astype(np.int64) * 100000 + ts // DAY)
        self.days = np.bincount(pairs // 100000, minlength=nw)
        pairs = np.unique(w.astype(np.int64) * 10_000_000 + t)
        self.ntok = np.bincount(pairs // 10_000_000, minlength=nw)
        self.known = (self.days > 0)
        self.cut = cut
        self.rows = (m, w, t)
        self.z, self.bnb_tok = z, bnb_tok
        rng = np.random.default_rng(seed)
        known_ids = np.nonzero(self.known)[0]
        samp = rng.choice(known_ids, size=min(sample, len(known_ids)), replace=False)
        self.ref_hold = np.sort(self.holding(samp))
        self.ref_vol = np.sort(self.vol[known_ids])
        self.ref_days = np.sort(self.days[known_ids].astype(np.float64))
        self.ref_tok = np.sort(self.ntok[known_ids].astype(np.float64))
        self.n_known = len(known_ids)

    def holding(self, wallets: np.ndarray) -> np.ndarray:
        """BNB-hours of cost basis held (positions.compute_positions semantics, open positions accrued to the cut)."""
        z = self.z
        sel = np.nonzero(np.isin(z["wallet"], wallets) & (z["ts"] < self.cut))[0]
        order = sel[np.lexsort((z["log_index"][sel], z["tx_index"][sel], z["block"][sel], z["wallet"][sel], z["token"][sel]))]
        tk, wl = z["token"][order].tolist(), z["wallet"][order].tolist()
        tt, sd = z["ts"][order].astype(np.float64).tolist(), z["side"][order].tolist()
        am = z["amount"][order].tolist()
        qt = np.where(self.bnb_tok[z["token"][order]], z["quote"][order], 0.0).tolist()
        hold: dict[int, float] = {}
        cur = (-1, -1)
        pos = basis = last = 0.0
        for i in range(len(tk)):
            key = (tk[i], wl[i])
            if key != cur:
                if cur[0] >= 0 and basis > 0:
                    hold[cur[1]] = hold.get(cur[1], 0.0) + basis * (self.cut - last) / 3600.0
                cur, pos, basis, last = key, 0.0, 0.0, tt[i]
            hold[key[1]] = hold.get(key[1], 0.0) + basis * (tt[i] - last) / 3600.0
            last = tt[i]
            if sd[i] > 0:
                pos += am[i]
                basis += qt[i]
            else:
                if pos > 0:
                    basis *= max(0.0, 1.0 - am[i] / pos)
                pos = max(0.0, pos - am[i])
                if pos <= DUST:
                    pos = basis = 0.0
        if cur[0] >= 0 and basis > 0:
            hold[cur[1]] = hold.get(cur[1], 0.0) + basis * (self.cut - last) / 3600.0
        return np.array([hold.get(int(w), 0.0) for w in wallets])

    def components(self, wallets: np.ndarray, flagged: set[int]) -> dict[int, tuple[int, int, int, int, int]]:
        """(volume, activity, holding, identity, penalty); a wallet without any earlier trade is fresh: all zero."""
        hold = self.holding(wallets)
        out = {}
        for w, h in zip(wallets.tolist(), hold.tolist()):
            if not self.known[w]:
                out[w] = (0, 0, 0, 0, 0)
                continue
            v = rank(self.ref_vol, float(self.vol[w]))
            a = (rank(self.ref_days, float(self.days[w])) + rank(self.ref_tok, float(self.ntok[w]))) // 2
            out[w] = (v, a, rank(self.ref_hold, h), 0, 1000 if w in flagged else 0)
        return out


def load_rugs(path: str) -> list[dict]:
    with gzip.open(path, "rt") as fh:
        return [json.loads(line) for line in fh]


def short(a: str) -> str:
    return a[:6] + "…" + a[-4:]


def build_token(z, bnb_tok, rugs, token: str, kind: str, hist_cache: dict, max_rows: int) -> dict:
    tidx = int(np.nonzero(z["token_names"] == token)[0][0])
    rows = np.nonzero(z["token"] == tidx)[0]
    rows = rows[np.lexsort((z["log_index"][rows], z["tx_index"][rows], z["block"][rows], z["ts"][rows]))]
    t0 = int(z["ts"][rows[0]])
    if t0 not in hist_cache:
        hist_cache[t0] = History(z, bnb_tok, t0)
    hist = hist_cache[t0]
    wl = np.unique(z["wallet"][rows])
    names = z["wallet_names"]
    ev_here = [e for e in rugs if e["token"] == token]
    bundle_addr = {a for e in ev_here for a in e["wallets"]}
    # wallets flagged by rug events that finished before this token's first trade (no look-ahead)
    prior = {}
    for e in rugs:
        if e["ts"] < t0:
            for a in e["wallets"]:
                prior[a] = True
    prior_ids = set(np.nonzero(np.isin(names, list(prior.keys())))[0].tolist()) if prior else set()
    comp = hist.components(wl, prior_ids)
    wallets, roles = {}, {}
    for w in wl.tolist():
        a = str(names[w])
        c = comp[w]
        s = score_1000(c) / 1000
        flagged = c[4] >= CFG["flagThreshold"]
        fresh = not any(c)
        qb, qs = quote_detailed(c, True), quote_detailed(c, False)
        wallets[a] = {"score": round(s, 3), "flagged": bool(flagged), "fresh": bool(fresh), "buyBps": qb["total"],
                      "sellBps": qs["total"], "depositBps": qb["deposit"], "label": None, "live": False}
        roles[a] = "bundle" if a in bundle_addr else "flagged" if flagged else "new" if fresh else "honest" if s >= 0.4 else "other"
    trades = []
    for r in rows.tolist():
        a = str(names[z["wallet"][r]])
        c = comp[int(z["wallet"][r])]
        buy = int(z["side"][r]) > 0
        f = quote_detailed(c, buy)
        trades.append({"t": int(z["ts"][r]), "block": int(z["block"][r]), "side": "buy" if buy else "sell", "wallet": a,
                       "bnb": round(float(z["quote"][r]), 6), "tokens": float(z["amount"][r]), "price": float(z["price"][r]),
                       "tx": None, "feeBps": f, "role": roles[a]})
    if len(trades) > max_rows:  # keep every bundle trade, thin out the rest evenly
        keep_b = [i for i, x in enumerate(trades) if x["role"] == "bundle"]
        rest = [i for i, x in enumerate(trades) if x["role"] != "bundle"]
        k = max(0, max_rows - len(keep_b))
        pick = set(keep_b) | {rest[int(j)] for j in np.linspace(0, len(rest) - 1, k)} if k else set(keep_b)
        trades = [x for i, x in enumerate(trades) if i in pick]
    events = []
    for e in ev_here:
        sells = [x for x in trades if x["role"] == "bundle" and x["side"] == "sell" and abs(x["block"] - e["block"]) <= 3]
        first = min(sells, key=lambda x: (x["block"], x["t"])) if sells else None
        n_b = len({x["wallet"] for x in sells}) or len(e["wallets"])
        sold = sum(x["bnb"] for x in sells)
        events.append({"t": first["t"] if first else int(e["ts"]), "kind": "dump",
                       "text": f"Bundle dump: {n_b} wallets sold {e['supply_pct']:.0f}% of the supply within 3 blocks "
                               f"(about {sold:.2f} BNB out), price fell {e['price_drop_pct']:.0f}%", "tx": None})
        pre = sum(1 for x in e["wallets"] if wallets.get(x, {}).get("flagged"))
        events.append({"t": int(e["ts"]) + 1, "kind": "flag",
                       "text": f"Rug rule fires: {len(e['wallets'])} wallets get the rug flag (penalty component 1000) "
                               f"and pay +{CFG['penaltyBps']} bps from now on"
                               + (f"; {pre} of them were already flagged by earlier rugs" if pre else ""), "tx": None})
    sym = "FM" + token[2:6].upper()
    return {"id": f"mainnet-{sym.lower()}", "name": f"Four.meme {short(token)}", "symbol": sym, "network": "bsc-mainnet-replay",
            "address": token,
            "note": ("Real Four.meme trades; a coordinated bundle dumps on buyers. " if bundle_addr else "Real Four.meme trades; organic flow, no rug event. ")
                    + f"Scores = our open rule on history before the first trade ({hist.n_known} wallets known); fees = what the module would charge.",
            "trades": trades, "wallets": wallets, "events": events,
            "_stats": {"kind": kind, "wallets": len(wallets), "fresh": sum(w["fresh"] for w in wallets.values()),
                       "flagged": sum(w["flagged"] for w in wallets.values()), "bundle": len(bundle_addr), "n_known": hist.n_known}}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trades", required=True)
    ap.add_argument("--rugs", required=True)
    ap.add_argument("--quote-meta", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--token", action="append", required=True, help="0xTOKEN[:kind]")
    ap.add_argument("--max-rows", type=int, default=400)
    a = ap.parse_args()
    z = dict(np.load(a.trades))
    names = z["token_names"]
    mig = json.load(open(a.quote_meta))["mig_quote"]
    bnb_tok = np.array([mig.get(t, BNB) == BNB for t in names.tolist()])
    rugs = load_rugs(a.rugs)
    os.makedirs(a.out_dir, exist_ok=True)
    cache: dict = {}
    entries = []
    for spec in a.token:
        token, _, kind = spec.partition(":")
        out = build_token(z, bnb_tok, rugs, token.lower(), kind or "token", cache, a.max_rows)
        st = out.pop("_stats")
        path = os.path.join(a.out_dir, f"mainnet-{out['symbol'].lower()}.json")
        with open(path, "w") as fh:
            json.dump(out, fh, separators=(",", ":"))
        entries.append(f"mainnet-{out['symbol'].lower()}.json")
        print(path, len(out["trades"]), "trades", st, flush=True)
    idx_path = os.path.join(a.out_dir, "index.json")
    idx = json.load(open(idx_path)) if os.path.exists(idx_path) else {}
    sets = idx["sets"] if isinstance(idx, dict) and "sets" in idx else (idx if isinstance(idx, list) else [])
    mine = {"id": "mainnet", "title": "Mainnet replay",
            "note": "Real Four.meme trades; scores by our open rule from history before each token; fees = what the module would charge",
            "tokens": entries}
    sets = [s for s in sets if s.get("id") != "mainnet"] + [mine]
    with open(idx_path, "w") as fh:
        json.dump({**(idx if isinstance(idx, dict) else {}), "sets": sets}, fh, indent=1)


if __name__ == "__main__":
    main()
