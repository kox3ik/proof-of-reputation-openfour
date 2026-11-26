"""One publish tx in flight at a time: estimate, sign, persist, send, wait for a confirmed receipt, bump when stuck, resync on loss.

`coveredUntil` is only ever sent in the tx that follows a confirmed success of every earlier tx (the caller submits the next
one only after `poll` returned "ok"), so it cannot pass a lost batch. Any failure returns control to the caller, which
re-queues the wallets of the batch. The tx (hash, nonce, payload) is written to the store BEFORE it is sent: if the answer
is lost or the daemon dies, the nonce is resolved (receipt / dropped / re-broadcast) before any new batch is built.
"""
from __future__ import annotations

from typing import Callable

import abi
from chain import Chain, RpcRejected
from store import Store
from txsign import address_of, keccak256, sign_legacy

GAS_MARGIN = 1.3
BUMP = 1.25
KNOWN = ("already known", "known transaction", "replacement transaction underpriced")


class Sender:
    def __init__(self, chain: Chain, priv: int, chain_id: int, registry: str, log: Callable[[dict], None],
                 clock: Callable[[], float], *, max_gas_price: int, bump_after_s: float, gas_share: float = 0.25,
                 max_bumps: int = 6, store: Store | None = None) -> None:
        self.c, self.priv, self.chain_id, self.registry = chain, priv, chain_id, registry
        self.me = address_of(priv)
        self.log, self.clock, self.store = log, clock, store
        self.max_gas_price, self.bump_after_s, self.max_bumps, self.gas_share = max_gas_price, bump_after_s, max_bumps, gas_share
        self.epoch = self.nonce = self.cov = 0
        self.inflight: dict | None = None

    @property
    def busy(self) -> bool:
        return self.inflight is not None

    def resync(self) -> None:
        """Re-read epoch, coveredUntil and the next nonce from the chain's current (canonical) state."""
        self.epoch = self.c.uint(self.registry, abi.CURRENT_EPOCH)
        self.cov = self.c.uint(self.registry, abi.COVERED_UNTIL)
        self.nonce = self.c.nonce(self.me)
        self.log({"event": "resync", "epoch": self.epoch, "nonce": self.nonce, "covered_until": self.cov})

    def _safe_resync(self) -> None:
        try:
            self.resync()
        except Exception as e:  # noqa: BLE001
            self.log({"event": "resync_failed", "error": str(e)[:200]})

    def adopt_pending(self) -> None:
        """After a restart: take over the tx that was written before the last send; its fate is resolved by `poll`."""
        rec = self.store.load_pending() if self.store else None
        if rec:
            self.inflight = dict(rec, payload=bytes.fromhex(rec["payload"]), batch=[], sent_at=self.clock(), bumps=0)
            self.log({"event": "pending_adopted", "nonce": rec["nonce"], "hashes": rec["hashes"]})

    def _persist(self, it: dict) -> None:
        if self.store:
            self.store.save_pending({k: (v.hex() if k == "payload" else v) for k, v in it.items()
                                     if k in ("nonce", "price", "gas", "payload", "epoch", "cov", "head_at_send", "hashes")})

    def _broadcast(self, it: dict) -> None:
        raw = sign_legacy(self.priv, self.chain_id, it["nonce"], it["price"], it["gas"], self.registry, it["payload"])
        h = "0x" + keccak256(raw).hex()
        if h not in it["hashes"]:
            it["hashes"].append(h)
        self._persist(it)  # before the send: a lost answer must not make the tx untracked
        try:
            self.c.send_raw(raw)
        except RpcRejected as e:
            if not any(k in str(e).lower() for k in KNOWN):
                raise
        except Exception:  # noqa: BLE001 - transport error: the node may or may not have the tx
            it["ambiguous"] = True
            self.log({"event": "send_unknown", "nonce": it["nonce"], "tx": h})

    def submit(self, changes: list, cov: int, head: int, src_block: int, src_hash: str) -> tuple[str, int]:
        """("sent", 0) | ("retry", 0): nothing was sent, re-queue | ("split", n): send only the first n wallets."""
        data = abi.encode_publish(self.epoch + 1, [c.wallet for c in changes], [c.comps for c in changes], cov, src_block, src_hash,
                                  [c.since for c in changes])
        try:
            est = self.c.estimate_gas(self.me, self.registry, data)
            budget = int(self.c.gas_limit() * self.gas_share)
            price = self.c.gas_price()
        except Exception as e:  # noqa: BLE001 - estimation fails on a state the contract rejects: do not send blind
            self.log({"event": "estimate_failed", "error": str(e)[:200]})
            return "retry", 0
        gas = int(est * GAS_MARGIN)
        if gas > budget:  # never clip the estimate: make the batch smaller before signing
            if len(changes) <= 1:
                self.log({"event": "gas_over_budget", "estimate": est, "budget": budget})
                return "retry", 0
            return "split", max(1, min(len(changes) - 1, int(len(changes) * budget / gas * 0.9)))
        if price > self.max_gas_price:
            self.log({"event": "gas_price_above_cap", "price": price, "cap": self.max_gas_price})
            return "retry", 0
        it = {"nonce": self.nonce, "price": price, "gas": gas, "payload": bytes.fromhex(data[2:]), "epoch": self.epoch + 1,
              "batch": changes, "cov": cov, "head_at_send": head, "sent_at": self.clock(), "bumps": 0, "hashes": []}
        try:
            self._broadcast(it)
        except Exception as e:  # noqa: BLE001 - the node refused the tx: it is not on its way
            self.log({"event": "send_failed", "error": str(e)[:200]})
            if self.store:
                self.store.clear_pending()
            self._safe_resync()
            return "retry", 0
        self.inflight = it
        return "sent", 0

    def _done(self) -> None:
        self.inflight = None
        if self.store:
            self.store.clear_pending()

    def poll(self, safe_head: int) -> tuple[str, dict | None]:
        """("idle"|"pending", None-or-item) or ("ok"|"failed", item). Never raises."""
        it = self.inflight
        if it is None:
            return "idle", None
        try:
            r = next((x for x in (self.c.receipt(h) for h in it["hashes"]) if x), None)
            if r is not None:
                if int(r["blockNumber"], 16) > safe_head:
                    return "pending", it  # mined but not yet confirmed
                self._done()
                ok = int(r["status"], 16) == 1
                if ok:
                    self.epoch, self.nonce, self.cov = it["epoch"], it["nonce"] + 1, max(self.cov, it["cov"])
                else:
                    self._safe_resync()
                return ("ok" if ok else "failed"), dict(it, receipt=r)
            return self._stuck(it)
        except Exception as e:  # noqa: BLE001 - RPC hiccup: look again next step
            self.log({"event": "poll_error", "error": f"{type(e).__name__}: {str(e)[:200]}"})
            return "pending", it

    def reconcile(self) -> None:
        """After a rollback: nonce, epoch and coveredUntil come from the canonical chain again; the tx in flight stays tracked."""
        self._safe_resync()

    def _stuck(self, it: dict) -> tuple[str, dict]:
        if self.clock() - it["sent_at"] < self.bump_after_s:
            return "pending", it
        if self.c.nonce(self.me, "latest") > it["nonce"]:  # the nonce was used by another tx: ours is gone
            self._done()
            self.log({"event": "tx_dropped", "nonce": it["nonce"]})
            self._safe_resync()
            return "failed", it
        price = min(int(it["price"] * BUMP) + 1, self.max_gas_price)
        if price <= it["price"] or it["bumps"] >= self.max_bumps:
            # at the cap: alert and re-broadcast the same tx (a tx that fell out of the mempool is re-admitted)
            self.log({"event": "ALERT_tx_stuck_at_gas_cap", "price": it["price"], "cap": self.max_gas_price, "nonce": it["nonce"]})
            it["sent_at"] = self.clock()
            self._broadcast(it)
            return "pending", it
        it.update(price=price, bumps=it["bumps"] + 1, sent_at=self.clock())
        self._broadcast(it)
        self.log({"event": "tx_bumped", "price": price, "nonce": it["nonce"], "bumps": it["bumps"]})
        return "pending", it
