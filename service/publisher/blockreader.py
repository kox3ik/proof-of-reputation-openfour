"""Fetch and validate a block range completely before anything is applied.

For every block: header (hash, parent, time, bloom), the Core logs from the range query, de-duplicated by (txHash, logIndex)
and cross-checked by a second query by block hash; the payer of each trade (tx.from). Everything is parsed here, so a
malformed log fails the whole range and the engine never sees a half block.
"""
from __future__ import annotations

from typing import NamedTuple

import abi
import bloom
from chain import Chain, RpcError

LOG_CHUNK = 2000


class Hdr(NamedTuple):
    number: int
    hash: str
    parent: str
    ts: int


class Event(NamedTuple):
    kind: str          # "create" | "trade"
    created: abi.Created | None
    trade: abi.Trade | None
    payer: str | None


def hdr(b: dict) -> Hdr:
    return Hdr(int(b["number"], 16), b["hash"], b["parentHash"], int(b["timestamp"], 16))


def _key(r: dict) -> tuple[str, int]:
    return r["transactionHash"], int(r["logIndex"], 16)


class BlockReader:
    def __init__(self, chain: Chain, core: str) -> None:
        self.c, self.core = chain, core
        self.topics = [[abi.TRADE_TOPIC, abi.CREATED_TOPIC]]

    def fetch(self, lo: int, hi: int) -> list[tuple[Hdr, list[Event]]]:
        raw = [self.c.block(n) for n in range(lo, hi + 1)]
        hdrs = [hdr(b) for b in raw]
        by_num = {h.number: h for h in hdrs}
        rows: dict[int, dict[tuple[str, int], dict]] = {}
        for a in range(lo, hi + 1, LOG_CHUNK):
            for r in self.c.logs(a, min(hi, a + LOG_CHUNK - 1), self.core, self.topics):
                n = int(r["blockNumber"], 16)
                if n not in by_num or r.get("blockHash", by_num[n].hash) != by_num[n].hash:
                    raise RpcError("logs and headers disagree (chain moved while reading)")
                rows.setdefault(n, {})[_key(r)] = r  # a repeated log is counted once
        out = []
        for b, h in zip(raw, hdrs):
            got = rows.get(h.number, {})
            has_bloom = bloom.has_address(b["logsBloom"], self.core)
            if got and not has_bloom:
                raise RpcError(f"block {h.number}: logs returned but the header bloom has no Core log")
            if got or has_bloom:  # second, independent query (a bloom can also be a false positive: then both are empty)
                second = {_key(r): r for r in self.c.logs_of_block(h.hash, self.core, self.topics)}
                if set(second) != set(got):
                    raise RpcError(f"block {h.number}: incomplete log answer ({len(got)} vs {len(second)} logs)")
            out.append((h, self._events(h, got)))
        return out

    def _events(self, h: Hdr, got: dict) -> list[Event]:
        if not got:
            return []
        bd = self.c.block(h.number, True)
        if bd["hash"] != h.hash:
            raise RpcError("block changed while reading")
        frm = {t["hash"]: t["from"].lower() for t in bd["transactions"]}
        events = []
        for r in sorted(got.values(), key=lambda r: int(r["logIndex"], 16)):
            if r["topics"][0] == abi.CREATED_TOPIC:
                events.append(Event("create", abi.parse_created(r), None, None))
            else:
                t = abi.parse_trade(r)
                events.append(Event("trade", None, t, frm.get(t.tx_hash, t.trader)))  # payer = tx signer
        return events
