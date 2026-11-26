"""The publisher loop: read confirmed blocks, feed the engine, publish changed wallets (one tx in flight, see sender.py).

Safety rules (each has a test):
  * only blocks up to head - CONFIRMATIONS are read; each block range is fetched, de-duplicated, cross-checked and parsed
    completely before the engine is touched (blockreader.py);
  * parentHash continuity is checked against a ring of recent hashes, the tip is re-checked every step; a mismatch rolls the
    engine back to the newest checkpoint below the fork point, the sender re-reads nonce / epoch / coveredUntil from the
    canonical chain and the journaled wallets are evaluated again;
  * every publish carries (sourceBlock, sourceHash) of the last processed block: the contract rejects it on another branch;
  * `coveredUntil` is derived from the last block actually processed, only if all positions are known (history replayed from
    `history_from` <= the registry's deployment block), and is sent only in the last batch of a round, after every earlier tx
    is confirmed OK; a failed or lost batch is re-queued, never skipped; an empty batch advances it when nothing changed;
  * state is checkpointed (atomic); a restart resumes after the last checkpoint and re-reads the blocks produced meanwhile.
"""
from __future__ import annotations

import json
import sys
import time
from typing import Callable

import abi
from blockreader import BlockReader, Event, Hdr
from chain import Chain, RpcError
from engine import Engine, TradeIn, covered_until
from sender import Sender
from store import Store, State
from txsign import address_of

SPAN = 200            # blocks applied per step while catching up
RING = 128
RETRY_S = 2.0
GAP_TOLERANCE_S = 60
MAX_LAG = 64          # no publication while further behind than this: the source block must stay within 256 blocks
MAX_SPLITS = 10


class Publisher:
    def __init__(self, chain: Chain, engine: Engine, core: str, registry: str, priv: int, *, chain_id: int,
                 max_batch: int = 150, interval_s: float = 0.0, confirmations: int = 2, store: Store | None = None,
                 checkpoint_s: float = 300.0, max_gas_price: int = 3_000_000_000, bump_after_s: float = 30.0,
                 gas_share: float = 0.25, log: Callable[[dict], None] | None = None,
                 clock: Callable[[], float] = time.time) -> None:
        self.c, self.e = chain, engine
        self.core, self.registry = core.lower(), registry.lower()
        self.me = address_of(priv)
        self.max_batch, self.interval_s, self.conf = max_batch, interval_s, confirmations
        self.store, self.checkpoint_s = store, checkpoint_s
        self._log = log or (lambda r: print(json.dumps(r), file=sys.stdout, flush=True))
        self.clock = clock
        self.sender = Sender(chain, priv, chain_id, self.registry, self._log, clock, max_gas_price=max_gas_price,
                             bump_after_s=bump_after_s, gas_share=gas_share, store=store)
        self.reader = BlockReader(chain, self.core)
        self.last_block = -1
        self.safe = -1
        self.registry_block: int | None = None
        self.ring: dict[int, Hdr] = {}
        self.seen_wall: dict[int, float] = {}
        self.last_send = self.last_ck = self.retry_at = 0.0
        self.rolled_back = False

    # ───────── startup / state ─────────
    def start(self, start_block: int | None, *, allow_gap: bool = False, max_replay: int = 400_000,
              history_from: int | None = None, registry_block: int | None = None) -> None:
        upd = "0x" + self.c.eth_call(self.registry, abi.UPDATER)[-40:]
        if upd.lower() != self.me.lower():
            raise SystemExit(f"registry updater is {upd}, this key is {self.me}: refusing to start")
        self.registry_block = registry_block
        self.sender.resync()
        self.e.default_since = self.c.uint(self.registry, abi.DEPLOYED_AT)
        self.sender.adopt_pending()  # a tx that may be on its way is resolved before any new batch
        head = self.c.head()
        st = self.store.newest_at_or_below() if self.store else None
        if st is not None:
            self._adopt(st)
            self._log({"event": "restored", "last_block": self.last_block, "blocks_behind": head - self.last_block})
        else:
            first = start_block if start_block is not None else self._default_start(head, max_replay)
            cov = self.sender.cov
            if cov and not allow_gap and int(self.c.block(first)["timestamp"], 16) > cov + GAP_TOLERANCE_S:
                raise SystemExit(f"blocks between coveredUntil {cov} and block {first} were never read: start earlier or --allow-gap")
            hf = first if history_from is None else min(history_from, first)
            self.last_block = hf - 1
            self.safe = head - self.conf
            self._warmup(first - 1)
            self.e.pos_from = hf
            self.checkpoint(force=True)  # a rollback needs a state to return to
        self.last_ck = self.clock()
        if not self.cov_enabled():
            self._log({"event": "coverage_disabled", "reason": "positions are only known from block "
                       f"{self.e.pos_from}; give --registry-block B with --history-from <= B", "registry_block": registry_block})
        self._log({"event": "start", "updater": self.me, "registry": self.registry, "head": head, "first_block": self.last_block + 1,
                   "epoch": self.sender.epoch, "covered_until": self.sender.cov, "reference_wallets": self.e.ref.size,
                   "confirmations": self.conf, "positions_from": self.e.pos_from})

    def cov_enabled(self) -> bool:
        """coveredUntil may pass a sale only when every position of the tokens that have a ledger is known."""
        return self.registry_block is not None and self.e.pos_from is not None and self.e.pos_from <= self.registry_block

    def _warmup(self, until: int) -> None:
        """Replay history only to rebuild open positions and unclosed detector windows; nothing from it is published."""
        n0 = self.last_block
        while self.last_block < until:
            self._advance_to(min(until, self.last_block + SPAN))
        if self.last_block > n0:
            self.e.end_warmup()
            self._log({"event": "warmup_done", "from": n0 + 1, "to": self.last_block, "wallets": self.e.t.n})

    def _default_start(self, head: int, max_replay: int) -> int:
        """Block of the chain's coveredUntil (replay from there), or the head for a registry that never published."""
        cov = self.sender.cov
        if not cov:
            return head
        lo, hi = 0, head
        while lo < hi:
            mid = (lo + hi) // 2
            if int(self.c.block(mid)["timestamp"], 16) >= cov:
                hi = mid
            else:
                lo = mid + 1
        if head - lo > max_replay:
            raise SystemExit(f"coveredUntil is {head - lo} blocks behind (> {max_replay}): give --start-block / --allow-gap")
        return lo

    def _adopt(self, st: State) -> None:
        self.e, self.last_block, self.ring = st.engine, st.last_block, dict(st.ring)
        self._taint(st.last_block)

    def _taint(self, from_block: int) -> None:
        """Wallets sent since the checkpoint may hold values the restored state does not know: evaluate them again."""
        if not self.store:
            return
        for a in self.store.journal_after(from_block):
            w = self.e.t.get(a)  # unknown to the restored state: its right value is zero, and it will be written
            self.e.published.pop(w, None)
            self.e.dirty[w] = max(self.e.dirty.get(w, 0), from_block + 1)

    def checkpoint(self, force: bool = False) -> None:
        if not self.store or self.last_block < 0 or self.sender.busy:
            return  # an unconfirmed tx would leave `published` ahead of the chain in the file
        if force or self.clock() - self.last_ck >= self.checkpoint_s:
            self.store.save(self.e, self.last_block, self.ring)
            self.last_ck = self.clock()

    # ───────── reading ─────────
    def _apply(self, h: Hdr, events: list[Event]) -> None:
        self.seen_wall.setdefault(h.number, self.clock())
        for ev in events:
            if ev.kind == "create":
                self.e.on_create(ev.created.token, h.ts, ev.created.max_supply)
            else:
                t = ev.trade
                self.e.add_trade(TradeIn(t.token, ev.payer, t.is_buy, t.quote_asset, t.token_amount, t.curve_quote), h.number, h.ts)
        self.last_block = h.number
        self.ring[h.number] = h
        self.ring.pop(h.number - RING, None)

    def _continuous(self, hdrs: list[Hdr]) -> bool:
        prev = self.ring.get(hdrs[0].number - 1)
        for h in hdrs:
            if prev is not None and h.parent != prev.hash:
                return False
            prev = h
        return True

    def _advance_to(self, hi: int) -> bool:
        """Read and apply blocks last_block+1..hi. False = the chain no longer continues our ring (rolled back)."""
        blocks = self.reader.fetch(self.last_block + 1, hi)
        if not self._continuous([h for h, _ in blocks]):
            self.rollback()
            return False
        for h, events in blocks:
            self._apply(h, events)
        for token, b, n in self.e.finalize(self.last_block):
            self._log({"event": "rug_detected", "token": token, "block": b, "wallets": n, "decided_at_block": self.last_block})
        return True

    def _canonical(self, n: int) -> str | None:
        try:
            return self.c.block(n)["hash"]
        except (RpcError, IndexError):
            return None  # the chain is shorter than what was processed

    def tip_changed(self) -> bool:
        t = self.ring.get(self.last_block)
        return t is not None and self._canonical(self.last_block) != t.hash

    def advance(self, safe: int) -> bool:
        if self.tip_changed():
            self.rollback()
            return True
        if safe <= self.last_block:
            return False
        if self._advance_to(min(safe, self.last_block + SPAN)):
            for blk in [k for k in self.seen_wall if k < self.last_block - 256]:
                del self.seen_wall[blk]
            if self.e.maybe_refresh(self.clock()):
                self._log({"event": "reference_refresh", "wallets": self.e.ref.size})
        return True

    def rollback(self) -> None:
        n = self.last_block
        while n in self.ring and self._canonical(n) != self.ring[n].hash:
            n -= 1
        st = self.store.newest_at_or_below(n) if self.store else None
        if st is None:
            raise SystemExit(f"reorg below block {n + 1} and no checkpoint at or below it: rebuild the state")
        self._log({"event": "reorg", "fork_after": n, "was_at": self.last_block, "restored_to": st.last_block})
        self._adopt(st)
        self.e.default_since = self.c.uint(self.registry, abi.DEPLOYED_AT)
        self.sender.reconcile()  # nonce, epoch, coveredUntil from the canonical chain; no send in this step
        self.rolled_back = True

    # ───────── one iteration ─────────
    def step(self) -> bool:
        head = self.c.head()
        self.safe = head - self.conf
        self._poll(self.safe)
        self.rolled_back = False
        moved = self.advance(self.safe)
        if not self.rolled_back:  # right after a rollback the state is re-derived first
            self._publish_due()
        self.checkpoint()
        return moved

    def cov_candidate(self) -> int:
        a, b = self.ring.get(self.last_block - 2), self.ring.get(self.last_block - 1)
        return covered_until(a.ts, b.ts) if a and b else 0

    def _publish_due(self) -> None:
        if self.sender.busy or self.clock() < self.retry_at or self.safe - self.last_block > MAX_LAG:
            return
        chain_cov = self.sender.cov
        self.e.covered(chain_cov)
        cov = max(self.cov_candidate(), chain_cov) if self.cov_enabled() else chain_cov
        need_cov = cov > chain_cov and self.e.needs_coverage(cov)
        if not self.e.dirty and not need_cov:
            return
        if self.interval_s and self.clock() - self.last_send < self.interval_s:
            return
        last = self.e.ready_count(cov) <= self.max_batch  # everything that can go now fits in this batch
        batch = self.e.drain(self.max_batch, cov if last else chain_cov)
        if not batch and not (last and need_cov):
            step = self.e.flag_step(self.max_batch, cov, chain_cov) if cov > chain_cov else None
            if step and step[0]:
                left = sum(1 for w in self.e.dirty if self.e.t.flag[w] and self.e.since_of(w) <= step[1])
                if left:
                    self._log({"event": "ALERT_flag_group_split", "left": left, "step_cov": step[1]})
                self._send(step[0], step[1], chain_cov)
            return
        self._send(batch, cov if last else chain_cov, chain_cov)

    def _send(self, batch: list, cov: int, chain_cov: int) -> None:
        src = self.ring.get(self.last_block)
        src_hash = src.hash if src else self._canonical(self.last_block)
        if src_hash is None:
            self.e.requeue(batch)
            return
        for _ in range(MAX_SPLITS):
            if self.store and batch:  # before the send: a restart can then re-evaluate these wallets
                self.store.journal_add(self.last_block, [c.wallet for c in batch])
            status, n = self.sender.submit(batch, cov, self.last_block, self.last_block, src_hash)
            if status != "split":
                break
            self.e.requeue(batch[n:])  # too big for the gas share of a block: send the first n, coverage waits
            batch, cov = batch[:n], chain_cov
        if status == "sent":
            self.e.mark_published(batch)
            self.last_send = self.clock()
        else:
            self.e.requeue(batch)
            self.retry_at = self.clock() + RETRY_S

    def _poll(self, safe: int) -> None:
        state, it = self.sender.poll(safe)
        if state not in ("ok", "failed"):
            return
        ok = state == "ok"
        batch = it["batch"]
        rec = {"event": "publish", "ok": ok, "tx": it["hashes"][-1], "epoch": it["epoch"], "wallets": len(batch),
               "flagged": sum(1 for c in batch if c.comps[4] >= 700), "covered_until": it["cov"],
               "head_at_send": it["head_at_send"], "bumps": it["bumps"]}
        blocks = [c.block for c in batch]
        if "receipt" in it:
            rec["gas_used"] = int(it["receipt"]["gasUsed"], 16)
            rec["publish_block"] = int(it["receipt"]["blockNumber"], 16)
        if blocks and "publish_block" in rec:
            rec["trade_block_first"], rec["trade_block_last"] = min(blocks), max(blocks)
            rec["latency_blocks"] = rec["publish_block"] - min(blocks)
            seen = self.seen_wall.get(min(blocks))
            if seen:
                rec["latency_seen_to_sent_s"] = round(it["sent_at"] - seen, 3)
        self._log(rec)
        if ok:
            self.e.covered(self.sender.cov)
        else:
            self.e.requeue(batch)
