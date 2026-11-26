"""Per (token, wallet) curve positions (service copy; equality with the batch analytics is checked by tests/test_equivalence.py in the full repo)."""
from __future__ import annotations

from typing import NamedTuple

import numpy as np

DUST = 1e-6  # tokens; positions below this count as closed


class Positions(NamedTuple):
    pos_before: np.ndarray   # per trade (input order): wallet's visible curve position before the trade
    sell_frac: np.ndarray    # per trade: amount / pos_before for sells with pos_before > 0, else 0 (buys 0)
    hold_bnb_h: np.ndarray   # per wallet: sum(cost basis in BNB * hours held), open positions to window end
    n_tokens: np.ndarray     # per wallet: distinct tokens traded
    # holding intervals (position open with cost basis > 0): wallet, start ts, end ts, cost basis in BNB
    iv_wallet: np.ndarray = np.zeros(0, np.int64)
    iv_t0: np.ndarray = np.zeros(0)
    iv_t1: np.ndarray = np.zeros(0)
    iv_basis: np.ndarray = np.zeros(0)
    # first trade of every (wallet, token) pair: wallet, ts
    pair_wallet: np.ndarray = np.zeros(0, np.int64)
    pair_ts: np.ndarray = np.zeros(0)


def compute_positions(token: np.ndarray, wallet: np.ndarray, block: np.ndarray, tx: np.ndarray, log: np.ndarray,
                      ts: np.ndarray, side: np.ndarray, amount: np.ndarray, quote: np.ndarray,
                      n_wallets: int, t_end: float) -> Positions:
    order = np.lexsort((log, tx, block, wallet, token))
    tk, wl, tt = token[order].tolist(), wallet[order].tolist(), ts[order].astype(np.float64).tolist()
    sd, am, qt = side[order].tolist(), amount[order].tolist(), quote[order].tolist()
    n = len(tk)
    pb = [0.0] * n
    sf = [0.0] * n
    hold = [0.0] * n_wallets
    ntok = [0] * n_wallets
    ivw: list[int] = []
    iv0: list[float] = []
    iv1: list[float] = []
    ivb: list[float] = []
    pw: list[int] = []
    pt: list[float] = []
    pos = basis = last_t = 0.0
    cur = (-1, -1)
    for i in range(n):
        key = (tk[i], wl[i])
        if key != cur:
            if cur[0] >= 0 and basis > 0:
                hold[cur[1]] += basis * (t_end - last_t) / 3600.0
                ivw.append(cur[1]), iv0.append(last_t), iv1.append(t_end), ivb.append(basis)
            cur, pos, basis, last_t = key, 0.0, 0.0, tt[i]
            ntok[key[1]] += 1
            pw.append(key[1]), pt.append(tt[i])
        hold[key[1]] += basis * (tt[i] - last_t) / 3600.0
        if basis > 0 and tt[i] > last_t:
            ivw.append(key[1]), iv0.append(last_t), iv1.append(tt[i]), ivb.append(basis)
        last_t = tt[i]
        pb[i] = pos
        if sd[i] > 0:
            pos += am[i]
            basis += qt[i]
        else:
            if pos > 0:
                sf[i] = am[i] / pos
                basis = basis * max(0.0, 1.0 - am[i] / pos)
            pos = max(0.0, pos - am[i])
            if pos <= DUST:
                pos, basis = 0.0, 0.0
    if cur[0] >= 0 and basis > 0:
        hold[cur[1]] += basis * (t_end - last_t) / 3600.0
        ivw.append(cur[1]), iv0.append(last_t), iv1.append(t_end), ivb.append(basis)
    out_pb = np.empty(n)
    out_sf = np.empty(n)
    out_pb[order] = pb
    out_sf[order] = sf
    return Positions(out_pb, out_sf, np.array(hold), np.array(ntok, dtype=np.int64), np.array(ivw, dtype=np.int64),
                     np.array(iv0), np.array(iv1), np.array(ivb), np.array(pw, dtype=np.int64), np.array(pt))
