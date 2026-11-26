"""Per-wallet raw stats, updated incrementally per trade with the semantics of `por_pit.epoch_components` inputs.

Base values come from the mainnet-history snapshot; live trades add to them (days and tokens of the target network are
new, so they add rather than merge). Positions and holding follow `positions.compute_positions` exactly.
"""
from __future__ import annotations

import numpy as np

from snapshot_io import Snapshot, bytes_to_addr

DAY = 86400
DUST = 1e-6  # = positions.DUST


class WalletTable:
    """Stats arrays indexed by wallet id; `idx` maps lower-case address -> id (grows with new wallets)."""

    def __init__(self, snap: Snapshot) -> None:
        n = len(snap.vol)
        self.n = n
        cap = max(1024, 2 * n)
        self.vol = np.zeros(cap)
        self.n_days = np.zeros(cap, np.int64)
        self.n_tok = np.zeros(cap, np.int64)
        self.hold = np.zeros(cap)
        self.flag = np.zeros(cap, bool)
        self.known = np.zeros(cap, bool)  # has any trade (history or live): part of the reference population
        self.vol[:n], self.n_days[:n], self.n_tok[:n] = snap.vol, snap.n_days, snap.n_tok
        self.hold[:n], self.flag[:n] = snap.hold, snap.flag.astype(bool)
        self.known[:n] = (snap.vol > 0) | (snap.n_days > 0)
        self.addr: list[str] = [bytes_to_addr(r.tobytes()) for r in snap.addr]
        self.idx: dict[str, int] = {a: i for i, a in enumerate(self.addr)}
        self.live_days: dict[int, set[int]] = {}
        self.pos: dict[tuple[str, int], list[float]] = {}  # (token, wallet) -> [pos, basis, last_t]
        self.open_of: dict[int, set[str]] = {}  # wallet -> tokens with an open live position

    _ARR = ("vol", "n_days", "n_tok", "hold", "flag", "known")

    def __getstate__(self) -> dict:
        """Checkpoint form: arrays cut to the used length (the spare capacity is not stored)."""
        st = dict(self.__dict__)
        for k in self._ARR:
            st[k] = st[k][: self.n].copy()
        return st

    def __setstate__(self, st: dict) -> None:
        self.__dict__.update(st)
        cap = max(1024, 2 * self.n)
        for k in self._ARR:
            a = getattr(self, k)
            b = np.zeros(cap, a.dtype)
            b[: len(a)] = a
            setattr(self, k, b)

    def _grow(self) -> None:
        cap = 2 * len(self.vol)
        for name in ("vol", "n_days", "n_tok", "hold", "flag", "known"):
            a = getattr(self, name)
            b = np.zeros(cap, a.dtype)
            b[: len(a)] = a
            setattr(self, name, b)

    def get(self, addr: str) -> int:
        i = self.idx.get(addr)
        if i is None:
            if self.n == len(self.vol):
                self._grow()
            i = self.n
            self.n += 1
            self.idx[addr] = i
            self.addr.append(addr)
        return i

    def add_trade(self, token: str, addr: str, ts: float, is_buy: bool, amount: float, quote_bnb: float) -> tuple[int, float]:
        """Apply one trade; returns (wallet id, wallet's visible position before the trade)."""
        w = self.get(addr)
        self.known[w] = True
        days = self.live_days.setdefault(w, set())
        d = int(ts) // DAY
        if d not in days:
            days.add(d)
            self.n_days[w] += 1
        self.vol[w] += quote_bnb
        rec = self.pos.get((token, w))
        if rec is None:
            rec = [0.0, 0.0, ts]
            self.pos[(token, w)] = rec
            self.n_tok[w] += 1
        pos, basis, last_t = rec
        self.hold[w] += basis * (ts - last_t) / 3600.0
        before = pos
        if is_buy:
            pos += amount
            basis += quote_bnb
        else:
            if pos > 0:
                basis *= max(0.0, 1.0 - amount / pos)
            pos = max(0.0, pos - amount)
            if pos <= DUST:
                pos = basis = 0.0
        rec[0], rec[1], rec[2] = pos, basis, ts
        open_set = self.open_of.setdefault(w, set())
        (open_set.add if basis > 0 else open_set.discard)(token)
        return w, before

    def hold_now(self, w: int, now: float) -> float:
        """Closed holding plus open live positions accrued to `now` (as `compute_positions` does with t_end)."""
        h = float(self.hold[w])
        for tok in self.open_of.get(w, ()):
            _, basis, last_t = self.pos[(tok, w)]
            h += basis * max(0.0, now - last_t) / 3600.0
        return h
