"""Rug (group dump) detector, owner's definition B. Positions from curve trades only (transfers invisible).

Window = 3 consecutive blocks starting at a block with a sell. A wallet is a dumper when it holds a visible position
at the window start (> DUST) and sells >= MIN_FRAC (50%) of that position inside the window (sells counted up to the position,
so tokens that arrived by transfer do not inflate the share). Needs >= 2 distinct dumpers, together >= 5% of supply,
price after the window's last trade <= 70% of the price before the window, and the first trade of the window at least
60 s after creation.
"""
from __future__ import annotations

from typing import NamedTuple

import numpy as np

from positions import DUST

WINDOW_BLOCKS = 3
MIN_WALLETS = 2
MIN_FRAC = 0.5  # verified rule "mf050" (the batch analytics keep 0.8 and are overridden to 0.5 in the equivalence tests)
MIN_SUPPLY_SHARE = 0.05
MIN_DROP = 0.30
SKIP_SECONDS = 60


class RugEvent(NamedTuple):
    token: int
    block: int
    wallets: tuple[int, ...]
    supply_share: float
    price_drop: float
    seconds_after_creation: float  # -1 if creation not in window


def _window(wallet, side, amount, pos_before, sl: slice):
    """Dumpers of one window: (wallet ids, group sold amount capped at each visible position)."""
    w = wallet[sl]
    uw, first, inv = np.unique(w, return_index=True, return_inverse=True)
    start = pos_before[sl][first]
    sell = side[sl] < 0
    sold = np.bincount(inv[sell], weights=amount[sl][sell], minlength=len(uw))
    ok = (start > DUST) & (sold >= MIN_FRAC * start)
    return uw[ok], np.minimum(sold, start)[ok]


def find_rugs(token: np.ndarray, wallet: np.ndarray, block: np.ndarray, ts: np.ndarray, side: np.ndarray,
              amount: np.ndarray, price: np.ndarray, pos_before: np.ndarray, create_ts: np.ndarray,
              supply: np.ndarray) -> list[RugEvent]:
    """Arrays are per trade, sorted by (token, block, tx, log). create_ts/supply are per token (nan ts = unknown)."""
    after = np.where(np.isnan(create_ts[token]), np.inf, ts - create_ts[token])
    anchor = (side < 0) & (after >= SKIP_SECONDS)
    bounds = np.r_[0, np.nonzero(np.diff(token))[0] + 1, len(token)]
    events: list[RugEvent] = []
    for k in range(len(bounds) - 1):
        lo, hi = int(bounds[k]), int(bounds[k + 1])
        sells = (side[lo:hi] < 0)
        if sells.sum() < MIN_WALLETS or len(np.unique(wallet[lo:hi][sells])) < MIN_WALLETS:
            continue
        t = int(token[lo])
        blocks = block[lo:hi]
        done_until = -1
        for b in np.unique(blocks[anchor[lo:hi]]):
            b = int(b)
            if b <= done_until:
                continue
            i0 = lo + int(np.searchsorted(blocks, b, side="left"))
            i1 = lo + int(np.searchsorted(blocks, b + WINDOW_BLOCKS, side="left"))
            if after[i0] < SKIP_SECONDS:
                continue
            wl, sold = _window(wallet, side, amount, pos_before, slice(i0, i1))
            if len(wl) < MIN_WALLETS:
                continue
            share = float(sold.sum() / supply[t])
            if share < MIN_SUPPLY_SHARE:
                continue
            p0 = price[i0 - 1] if i0 > lo else price[i0]
            drop = 1.0 - price[i1 - 1] / p0 if p0 > 0 else 0.0
            if drop < MIN_DROP:
                continue
            ct = create_ts[t]
            secs = float(ts[i0] - ct) if not np.isnan(ct) else -1.0
            events.append(RugEvent(t, b, tuple(int(w) for w in wl), share, float(drop), secs))
            done_until = b + WINDOW_BLOCKS - 1
    return events
