"""In-memory chain with the RPC surface the publisher uses; applies `publish` calls like the registry does."""
import abi
import bloom
import txsign

TOKEN_DECIMALS = 10**18


def word(i, d):
    return int(d[2 + 64 * i: 66 + 64 * i], 16)


class FakeChain:
    def __init__(self, updater_addr, chain_id=97, t0=1_000_000):
        self.updater, self.chain_id = updater_addr, chain_id
        self.blocks = [{"timestamp": t0, "txs": {}, "logs": [], "hash": self._h(0, t0, ""), "parent": "0x" + "00" * 32}]
        self.snaps = [({}, 0, 0, 0)]  # (comps, cov, epoch, applied txs) after each block
        self.salt, self.applied = "", 0
        self.core, self.gas_limit_value = "0x" + "c0" * 20, 140_000_000
        self.range_drop = self.range_dup = False  # faulty range answers: one log missing / every log twice
        self.landed = 0
        self.deployed_at, self.flagged_from = t0, {}
        self.hold_txs = self.fail_estimate = False
        self.fail_sends = 0
        self.pending, self.receipts = [], {}
        self.comps, self.cov, self.epoch, self.nonces = {}, 0, 0, {}
        self.queue_logs, self.queue_from, self.sent = [], {}, []
        self.n = 0

    # scripted activity for the next block
    @staticmethod
    def _h(num, ts, salt):
        return "0x" + txsign.keccak256(f"{num}:{ts}:{salt}".encode()).hex()

    def trade(self, token, payer, is_buy, tokens, quote, quote_asset="0x" + "bb" * 20, signer=None):
        """`payer` is the log's trader topic (a router for contract traders); `signer` = tx.from (default: payer)."""
        self.n += 1
        h = f"0x{self.n:064x}"
        words = [int(is_buy), int(quote_asset, 16), 0, 0, int(tokens * TOKEN_DECIMALS), int(quote * TOKEN_DECIMALS),
                 int(quote * TOKEN_DECIMALS), 3] + [0] * 7
        self.queue_logs.append({"topics": [abi.TRADE_TOPIC, "0x" + "00" * 12 + token[2:], "0x" + "00" * 12 + payer[2:], "0x" + "00" * 32],
                                "data": "0x" + "".join(f"{w:064x}" for w in words), "transactionHash": h,
                                "transactionIndex": hex(self.n), "logIndex": hex(self.n)})
        self.queue_from[h] = signer or payer

    def create(self, token, supply):
        self.n += 1
        words = [1, 0, 0, int(supply * TOKEN_DECIMALS)] + [0] * 8
        self.queue_logs.append({"topics": [abi.CREATED_TOPIC, "0x" + "00" * 32, "0x" + "00" * 32, "0x" + "00" * 12 + token[2:]],
                                "data": "0x" + "".join(f"{w:064x}" for w in words), "transactionHash": f"0x{self.n:064x}",
                                "transactionIndex": "0x0", "logIndex": hex(self.n)})
        self.queue_from[f"0x{self.n:064x}"] = "0x" + "00" * 20

    def mine(self, secs=3):
        num = len(self.blocks)
        ts = self.blocks[-1]["timestamp"] + secs
        logs = [dict(r, blockNumber=hex(num)) for r in self.queue_logs]
        txs = dict(self.queue_from)
        self.queue_logs, self.queue_from = [], {}
        mined = [] if self.hold_txs else self.pending
        self.pending = self.pending if self.hold_txs else []
        for raw in mined:
            h = "0x" + txsign.keccak256(raw).hex()
            ok = self._apply(raw, ts)
            self.applied += 1
            txs[h] = self.updater
            self.receipts[h] = {"status": "0x1" if ok else "0x0", "blockNumber": hex(num), "gasUsed": hex(60_000)}
        parent = self.blocks[-1]["hash"]
        bl = bloom.add(0, bytes.fromhex(self.core[2:])) if logs else 0
        self.blocks.append({"bloom": bl, "raws": list(mined), "timestamp": ts, "txs": txs, "logs": logs, "hash": self._h(num, ts, self.salt + parent),
                            "parent": parent})
        self.snaps.append((dict(self.comps), self.cov, self.epoch, self.applied))

    def reorg(self, depth):
        """Drop the last `depth` blocks (their txs vanish, logs are gone); the next blocks get different hashes."""
        for b in self.blocks[-depth:]:
            for h in b["txs"]:
                self.receipts.pop(h, None)
            self.pending += b.get("raws", [])  # like a node: txs of dropped blocks return to the mempool
        del self.blocks[-depth:], self.snaps[-depth:]
        self.comps, self.cov, self.epoch, self.applied = dict(self.snaps[-1][0]), *self.snaps[-1][1:]
        self.salt += "r"

    def _apply(self, raw, ts):
        items = txsign._decode(raw)[0]
        data = items[5].hex()
        epoch, cov = int(data[8:72], 16), int(data[8 + 192:8 + 256], 16)
        src, src_hash = int(data[8 + 256:8 + 320], 16), "0x" + data[8 + 320:8 + 384]
        n = int(data[8 + 7 * 64: 8 + 8 * 64], 16)
        wallets = ["0x" + data[8 + 8 * 64 + 64 * i + 24: 8 + 8 * 64 + 64 * (i + 1)] for i in range(n)]
        base = 8 + 8 * 64 + 64 * n + 64
        sbase = base + 64 * 5 * n + 64
        if src >= len(self.blocks) or self.blocks[src]["hash"] != src_hash or len(self.blocks) - src > 256:
            self.sent.append(data)
            return False  # BadSource: the publication was computed on another branch
        if epoch < self.epoch or cov >= ts or cov < self.cov:
            self.sent.append(data)
            return False
        new = {w: tuple(int(data[base + 64 * (5 * i + j): base + 64 * (5 * i + j + 1)], 16) for j in range(5)) for i, w in enumerate(wallets)}
        since = [int(data[sbase + 64 * i: sbase + 64 * (i + 1)], 16) for i in range(n)]
        for w, sn in zip(wallets, since):  # BadFlagTime: a flag needs a date in [deployedAt, coveredUntil]
            if new[w][4] >= 700 and not (self.deployed_at <= sn <= cov):
                self.sent.append(data)
                return False
        self.sent.append(data)
        for w, sn in zip(wallets, since):
            if new[w][4] >= 700 and (w not in self.flagged_from or sn < self.flagged_from[w]):
                self.flagged_from[w] = sn
        self.comps.update(new)
        self.epoch, self.cov = epoch, cov
        self.landed += 1
        return True

    # RPC surface
    def head(self): return len(self.blocks) - 1
    def chain_id_(self): return self.chain_id
    def block(self, n, full=False):
        if n >= len(self.blocks):
            from chain import RpcError
            raise RpcError(f"block {n} not available")
        b = self.blocks[n]
        return {"gasLimit": hex(self.gas_limit_value), "logsBloom": "0x" + f"{b['bloom']:0512x}", "number": hex(n), "hash": b["hash"], "parentHash": b["parent"], "timestamp": hex(b["timestamp"]), "transactions": [{"hash": h, "from": f} for h, f in b["txs"].items()]}
    def logs(self, lo, hi, address, topics):
        rows = [dict(r, blockHash=self.blocks[n]["hash"]) for n in range(lo, hi + 1) for r in self.blocks[n]["logs"]
                if r["topics"][0] in topics[0]]
        if self.range_drop and rows:
            rows = rows[:-1]
        if self.range_dup:
            rows = rows + rows
        return rows

    def logs_of_block(self, block_hash, address, topics):
        for n, b in enumerate(self.blocks):
            if b["hash"] == block_hash:
                return [dict(r, blockHash=block_hash) for r in b["logs"] if r["topics"][0] in topics[0]]
        return []

    def gas_limit(self):
        return self.gas_limit_value
    def eth_call(self, to, data):
        if data == abi.UPDATER:
            return "0x" + "00" * 12 + self.updater[2:]
        if data == abi.DEPLOYED_AT:
            return hex(self.deployed_at)
        return hex(self.epoch if data == abi.CURRENT_EPOCH else self.cov)
    def uint(self, to, data): return int(self.eth_call(to, data), 16)
    def nonce(self, a, tag="pending"): return self.applied + (len(self.pending) if tag == "pending" else 0)
    def gas_price(self): return 50_000_000
    def estimate_gas(self, f, t, d):
        if self.fail_estimate:
            raise RuntimeError("execution reverted")
        n = int(d[10 + 7 * 64: 10 + 8 * 64], 16)
        return 40_000 + 25_000 * n
    def send_raw(self, raw):
        if self.fail_sends:
            self.fail_sends -= 1
            raise RuntimeError("connection reset")
        nonce = int.from_bytes(txsign._decode(raw)[0][0], "big")
        self.pending = [r for r in self.pending if int.from_bytes(txsign._decode(r)[0][0], "big") != nonce]  # replacement
        self.pending.append(raw)
        if getattr(self, 'lose_answer', 0):
            self.lose_answer -= 1
            raise RuntimeError('answer lost')
        return "0x" + txsign.keccak256(raw).hex()
    def receipt(self, h): return self.receipts.get(h)
