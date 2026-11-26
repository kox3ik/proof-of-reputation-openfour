"""Reference distribution and components: percentile ranks of a wallet's raw stats among all known wallets.

Same arithmetic as `por_wallets.pct_rank` (mid-rank, integer 0..1000, ties share the mean rank) and
`por_pit.epoch_components` (activity = mean of the day and token ranks, penalty = 1000 for rug participants).
The reference is a set of sorted arrays; it is rebuilt from the live table every `refresh_s` seconds (and at start), so
it follows the growing population. Wallets that did not trade keep their last published components until their next
trade (documented limitation: their rank can drift slowly with the population).
"""
from __future__ import annotations

import numpy as np

from wallets import WalletTable


def rank(sorted_ref: np.ndarray, x: float) -> int:
    n = len(sorted_ref)
    if n == 0:
        return 0
    lo = int(np.searchsorted(sorted_ref, x, side="left"))
    hi = int(np.searchsorted(sorted_ref, x, side="right"))
    return min(1000, (lo + hi) * 500 // n)


class Reference:
    def __init__(self) -> None:
        self.vol = self.days = self.tok = self.hold = np.zeros(0)
        self.size = 0

    def rebuild(self, t: WalletTable, now: float = 0.0) -> None:
        """Population = every known wallet; holding includes the open live positions accrued to `now`."""
        m = t.known[: t.n]
        holds = t.hold[: t.n].copy()
        for w in t.open_of:
            if t.open_of[w]:
                holds[w] = t.hold_now(w, now)
        self.vol = np.sort(t.vol[: t.n][m])
        self.days = np.sort(t.n_days[: t.n][m].astype(np.float64))
        self.tok = np.sort(t.n_tok[: t.n][m].astype(np.float64))
        self.hold = np.sort(holds[m])
        self.size = int(m.sum())

    def components(self, t: WalletTable, w: int, now: float) -> tuple[int, int, int, int, int]:
        """(volume, activity, holding, identity, penalty) as published on chain."""
        vol = rank(self.vol, float(t.vol[w]))
        act = (rank(self.days, float(t.n_days[w])) + rank(self.tok, float(t.n_tok[w]))) // 2
        hold = rank(self.hold, t.hold_now(w, now))
        return vol, act, hold, 0, 1000 if t.flag[w] else 0
