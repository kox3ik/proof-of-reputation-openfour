"""Incremental rug detector: the same rule as `rug_core.find_rugs`, evaluated per token as blocks become final.

An anchor is a sell at least SKIP_SECONDS after creation; its window is the WINDOW_BLOCKS blocks starting at the
anchor's block. The decision for a window is final once its last block has been read, so the dump of block b is known
when block b + WINDOW_BLOCKS - 1 has been read (`scan(final_block)`). The window test itself is `rug_core._window` plus
the same supply share and price-drop checks, so the result equals the batch detector (tested).
"""
from __future__ import annotations

import numpy as np

import rug_core


class TokenLog:
    __slots__ = ("block", "ts", "wallet", "side", "amount", "price", "posb", "create_ts", "supply", "pointer", "done_until")

    def __init__(self, create_ts: float, supply: float) -> None:
        self.block: list[int] = []
        self.ts: list[float] = []
        self.wallet: list[int] = []
        self.side: list[int] = []
        self.amount: list[float] = []
        self.price: list[float] = []
        self.posb: list[float] = []
        self.create_ts = create_ts
        self.supply = supply
        self.pointer = -1      # anchors below this block are decided
        self.done_until = -1   # blocks up to here belong to an already reported event


class RugLive:
    def __init__(self) -> None:
        self.tokens: dict[str, TokenLog] = {}
        self.pending: set[str] = set()
        self.event_ts: dict[tuple[str, int], float] = {}  # (token, anchor block) -> time of the dump's first block

    def on_create(self, token: str, ts: float, supply: float) -> None:
        tl = self.tokens.get(token)
        if tl is None:
            self.tokens[token] = TokenLog(ts, supply if supply > 0 else 1e9)
        else:
            tl.create_ts, tl.supply = ts, supply if supply > 0 else 1e9

    def add(self, token: str, block: int, ts: float, wallet: int, is_buy: bool, amount: float, price: float,
            pos_before: float) -> None:
        tl = self.tokens.get(token)
        if tl is None:
            tl = self.tokens[token] = TokenLog(float("nan"), 1e9)
        if tl.block and block < tl.block[-1]:
            raise ValueError(f"trade of block {block} after block {tl.block[-1]}: blocks must be fed in order")
        tl.block.append(block)
        tl.ts.append(ts)
        tl.wallet.append(wallet)
        tl.side.append(1 if is_buy else -1)
        tl.amount.append(amount)
        tl.price.append(price)
        tl.posb.append(pos_before)
        if not is_buy:
            self.pending.add(token)

    def scan(self, final_block: int) -> list[tuple[str, int, tuple[int, ...], float, float]]:
        """Decide every window whose last block <= final_block; returns (token, block, wallet ids, share, drop)."""
        out = []
        for token in list(self.pending):
            tl = self.tokens[token]
            out.extend(self._scan_token(token, tl, final_block))
            if not tl.block or tl.block[-1] < tl.pointer:
                self.pending.discard(token)
        return out

    def _scan_token(self, token: str, tl: TokenLog, final_block: int):
        last_anchor = final_block - (rug_core.WINDOW_BLOCKS - 1)
        if last_anchor < tl.pointer or not tl.block:
            return []
        block = np.array(tl.block)
        ts, wallet = np.array(tl.ts), np.array(tl.wallet)
        side, amount = np.array(tl.side), np.array(tl.amount)
        price, posb = np.array(tl.price), np.array(tl.posb)
        after = np.where(np.isnan(tl.create_ts), np.inf, ts - tl.create_ts)
        anchor = (side < 0) & (after >= rug_core.SKIP_SECONDS) & (block >= tl.pointer) & (block <= last_anchor)
        events = []
        for b in np.unique(block[anchor]):
            b = int(b)
            if b <= tl.done_until:
                continue
            i0 = int(np.searchsorted(block, b, side="left"))
            i1 = int(np.searchsorted(block, b + rug_core.WINDOW_BLOCKS, side="left"))
            wl, sold = rug_core._window(wallet, side, amount, posb, slice(i0, i1))
            if len(wl) < rug_core.MIN_WALLETS:
                continue
            share = float(sold.sum() / tl.supply)
            if share < rug_core.MIN_SUPPLY_SHARE:
                continue
            p0 = price[i0 - 1] if i0 > 0 else price[i0]
            drop = 1.0 - price[i1 - 1] / p0 if p0 > 0 else 0.0
            if drop < rug_core.MIN_DROP:
                continue
            events.append((token, b, tuple(int(w) for w in wl), share, float(drop)))
            self.event_ts[(token, b)] = float(ts[i0])
            tl.done_until = b + rug_core.WINDOW_BLOCKS - 1
        tl.pointer = max(tl.pointer, last_anchor + 1)
        keep = int(np.searchsorted(block, tl.pointer, side="left")) - 1  # one sentinel trade before the pointer
        if keep > 0:
            for name in ("block", "ts", "wallet", "side", "amount", "price", "posb"):
                del getattr(tl, name)[:keep]
        return events
