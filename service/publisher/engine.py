"""Scoring engine: trades in, changed wallets (components) out. No network code here.

Flow per head block F: `add_block` for every new block, then `finalize(F)` (rug windows that ended), then `drain` the
wallets whose published components would change. `covered_until(F, ts)` is the time up to which flags are final.
"""
from __future__ import annotations

import time
from collections import deque
from typing import NamedTuple

import newness
from reference import Reference
from rug_live import RugLive
from wallets import WalletTable

WINDOW_BLOCKS = 3  # = rug_core.WINDOW_BLOCKS (asserted in tests)
TOKEN_DECIMALS = 1e18


class TradeIn(NamedTuple):
    token: str
    payer: str          # tx.from, lower case
    is_buy: bool
    quote_asset: str
    token_amount: int   # raw 18 decimals
    curve_quote: int    # raw quote units


class Change(NamedTuple):
    wallet: str
    comps: tuple[int, int, int, int, int]
    block: int          # block of the latest trade / rug decision behind the change
    since: int = 0      # start of the wallet's rug activity (published as flaggedFrom); 0 for an unflagged wallet


class Engine:
    def __init__(self, table: WalletTable, quote_rates: dict[str, float], refresh_s: float = 3600.0,
                 rule: newness.NewnessRule | None = None) -> None:
        self.t = table
        self.rule = rule or newness.DefaultRule()
        self.rates = {k.lower(): v for k, v in quote_rates.items()}
        self.ref = Reference()
        self.ref.rebuild(table)
        self.rugs = RugLive()
        self.dirty: dict[int, int] = {}       # wallet id -> block of the change
        self.published: dict[int, tuple] = {}  # last components handed to the chain
        self.refresh_s = refresh_s
        self._last_refresh = time.time()
        self.now_ts = 0.0
        self.last_trade_ts = 0.0
        self.trade_ts: deque = deque()  # times of trades not yet covered by a confirmed coveredUntil (ascending)
        self.flag_from: dict[int, float] = {}  # wallet id -> earliest start of a rug window it took part in
        self.default_since = 0  # registry creation time: the date of a flag that comes from the history snapshot
        self.pos_from: int | None = None  # block from which every position of the tokens created since is known

    def __getstate__(self) -> dict:
        st = dict(self.__dict__)
        st.pop("ref")  # rebuilt from the table on load
        return st

    def __setstate__(self, st: dict) -> None:
        self.__dict__.update(st)
        self._last_refresh = time.time()
        self.ref = Reference()
        self.ref.rebuild(self.t, self.now_ts)

    def on_create(self, token: str, ts: float, max_supply_raw: int) -> None:
        self.rugs.on_create(token, ts, max_supply_raw / TOKEN_DECIMALS)

    def add_trade(self, tr: TradeIn, block: int, ts: float) -> None:
        amount = tr.token_amount / TOKEN_DECIMALS
        quote = tr.curve_quote / TOKEN_DECIMALS * self.rates.get(tr.quote_asset, 0.0)
        price = tr.curve_quote / tr.token_amount if tr.token_amount else 0.0
        w, before = self.t.add_trade(tr.token, tr.payer, ts, tr.is_buy, amount, quote)
        self.rugs.add(tr.token, block, ts, w, tr.is_buy, amount, price, before)
        self.dirty[w] = block
        self.now_ts = max(self.now_ts, ts)
        self.last_trade_ts = max(self.last_trade_ts, ts)
        self.trade_ts.append(ts)

    def finalize(self, final_block: int) -> list[tuple[str, int, int]]:
        """Decide rug windows that ended; flagged wallets become dirty. Returns (token, block, n_wallets) per event."""
        found = []
        for token, b, wallets, _share, _drop in self.rugs.scan(final_block):
            ts = self.rugs.event_ts.pop((token, b), 0.0)
            for w in wallets:
                self.t.flag[w] = True
                self.flag_from[w] = min(self.flag_from.get(w, ts), ts)
                self.dirty[w] = max(self.dirty.get(w, 0), final_block)
            found.append((token, b, len(wallets)))
        return found

    def preload(self, addrs: list[str], block: int) -> int:
        """Queue wallets of the history snapshot for publication (their scores come from the snapshot, no live trade needed).
        Wallets unknown to the table or already published are skipped; returns how many were queued."""
        n = 0
        for a in addrs:
            w = self.t.idx.get(a.lower())
            if w is None or w in self.published or w in self.dirty:
                continue
            self.dirty[w] = block
            n += 1
        if n and not self.trade_ts:
            # flags of the snapshot wait for coverage to pass the registry's creation: give coverage something to cover
            self.trade_ts.append(float(self.default_since or 1))
        return n

    def maybe_refresh(self, now_wall: float) -> bool:
        if now_wall - self._last_refresh >= self.refresh_s:
            self.ref.rebuild(self.t, self.now_ts)
            self._last_refresh = now_wall
            return True
        return False

    def since_of(self, w: int) -> int:
        """flaggedFrom to publish for a flagged wallet: the dump's window start, never before the registry existed."""
        if not self.t.flag[w]:
            return 0
        return max(int(self.flag_from.get(w, 0)), self.default_since, 1)

    def _blocked(self, w: int, cov_cap: int | None) -> bool:
        """A flag may only be dated at or before the coveredUntil of its publication: wait until the coverage reaches it."""
        return cov_cap is not None and bool(self.t.flag[w]) and self.since_of(w) > cov_cap

    def ready_count(self, cov_cap: int | None) -> int:
        return sum(1 for w in self.dirty if not self._blocked(w, cov_cap))

    def drain(self, limit: int | None = None, cov_cap: int | None = None) -> list[Change]:
        """Components of the dirty wallets that differ from what the chain already holds (flags wait for `cov_cap`)."""
        out: list[Change] = []
        for w in sorted(self.dirty, key=self.dirty.get):
            if limit is not None and len(out) >= limit:
                break
            if self._blocked(w, cov_cap):
                continue
            held_fresh = self.rule.is_fresh(self.t, w, self.now_ts)  # fresh wallets are all zero on chain already
            if not self.t.known[w]:  # not in the population (e.g. only seen on an orphaned branch): zero on chain
                comps = newness.ZERO
            else:
                comps = newness.apply(self.rule, self.t, w, self.now_ts, self.ref.components(self.t, w, self.now_ts))
            if self.published.get(w, newness.ZERO if held_fresh else None) != comps:
                out.append(Change(self.t.addr[w], comps, self.dirty[w], self.since_of(w) if comps[4] > 0 else 0))
            del self.dirty[w]
        return out

    def flag_step(self, limit: int, cov: int, chain_cov: int) -> tuple[list[Change], int] | None:
        """More new flags than fit in one batch, all dated after the chain's coveredUntil: a flag can only be published in a tx whose
        coveredUntil is at or after its date, so coverage advances in steps. Returns (changes, coveredUntil of this tx): the earliest
        `limit` flags and the date of the last of them (never above `cov`); the rest become publishable at once (their date is then
        <= chain coverage) and the normal path finishes them and moves coverage to `cov`. None when no flag waits for coverage.
        Flags with exactly the date of the step that do not fit stay behind (a short window; `Publisher` logs an alert)."""
        waiting = sorted((self.since_of(w), w) for w in self.dirty if self.t.flag[w] and chain_cov < self.since_of(w) <= cov)
        if not waiting:
            return None
        step_cov = waiting[min(limit, len(waiting)) - 1][0]
        return self.drain(limit, step_cov), step_cov

    def needs_coverage(self, cov: int) -> bool:
        """True when a trade lies in (chain coveredUntil, cov]: moving coveredUntil to `cov` opens something."""
        return bool(self.trade_ts) and self.trade_ts[0] <= cov

    def covered(self, cov: int) -> None:
        while self.trade_ts and self.trade_ts[0] <= cov:
            self.trade_ts.popleft()

    def end_warmup(self) -> None:
        """History replayed only to rebuild positions: nothing from it is published, except flags it decided."""
        self.dirty = {w: b for w, b in self.dirty.items() if self.t.flag[w]}
        self.trade_ts.clear()

    def mark_published(self, changes: list[Change]) -> None:
        for c in changes:
            self.published[self.t.idx[c.wallet]] = c.comps

    def requeue(self, changes: list[Change]) -> None:
        for c in changes:
            w = self.t.idx[c.wallet]
            self.published.pop(w, None)
            self.dirty[w] = c.block


def covered_until(ts_final_minus2: int, ts_final_minus1: int) -> int:
    """Time up to which every flag decision is final when blocks <= F-2 are fully decided (F = last block read).

    A trade in block c can belong to a window starting at any anchor b <= c; windows starting at b are decided once block
    b + WINDOW_BLOCKS - 1 is read, so blocks <= F - (WINDOW_BLOCKS - 1) are covered. Several BSC blocks share one second,
    so the bound must stay below the first second of the first uncovered block.
    """
    return min(ts_final_minus2, ts_final_minus1 - 1)
