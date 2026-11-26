"""Failure, restart, reorg and cap behaviour: `coveredUntil` never passes a block that was not processed or a batch that was lost."""
import os
import tempfile
import unittest

import helpers  # noqa: F401
import txsign
from engine import Engine
from fakechain import FakeChain
from publisher import Publisher
from store import Store
from test_publisher import BUYERS, KEY, ME, TOK, WB, advance
import snapshot_io
from wallets import WalletTable

CORE, REG = "0x" + "c0" * 20, "0x" + "e0" * 20


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def populated():
    """A small history so that percentile ranks are not all zero."""
    import numpy as np
    n = 6
    addr = np.array([[i + 1] * 20 for i in range(n)], np.uint8)
    return snapshot_io.Snapshot(addr, np.arange(1, n + 1, dtype=np.float32), np.full(n, 3, np.uint16),
                                np.full(n, 2, np.uint32), np.arange(1, n + 1, dtype=np.float32), np.zeros(n, np.uint8), {})


def build(chain, clock, store=None, conf=0, snap=None, **kw):
    logs = []
    pub = Publisher(chain, Engine(WalletTable(snap or snapshot_io.empty()), {WB: 1.0}), CORE, REG, KEY, chain_id=97, log=logs.append,
                    confirmations=conf, store=store, clock=clock, **kw)
    return pub, logs


def run(chain, pub, clock, n=1):
    for _ in range(n):
        chain.mine()
        clock.t += 1.0
        pub.step()


def dump_bundle(chain, pub, clock):
    """Create a token, five buyers, a three-wallet dump in one block; returns the dump block's timestamp."""
    chain.create(TOK, 1e9)
    run(chain, pub, clock, 30)
    for i, b in enumerate(BUYERS):
        chain.trade(TOK, b, True, 6e7, 0.1 * (i + 1))
    run(chain, pub, clock, 3)
    for b in BUYERS[:3]:
        chain.trade(TOK, b, False, 6e7, 0.02)
    chain.mine()
    return chain.blocks[-1]["timestamp"]


def cov_of(data):
    return int(data[8 + 192:8 + 256], 16)


class SafetyTest(unittest.TestCase):
    def assert_cov_safe(self, chain, dump_ts):
        if chain.cov >= dump_ts:
            for b in BUYERS[:3]:
                self.assertEqual(chain.comps.get(b, (0,) * 5)[4], 1000, f"coveredUntil passed the dump but {b[:8]} is not flagged")

    def test_send_failure_requeues_and_cov_does_not_pass_lost_flag(self):
        chain, clock = FakeChain(ME), Clock()
        pub, logs = build(chain, clock, bump_after_s=5.0)
        pub.start(1, registry_block=1)
        dump_ts = dump_bundle(chain, pub, clock)
        chain.fail_sends = 2                      # the flag batch is lost twice (answer lost / node down)
        for _ in range(30):
            run(chain, pub, clock)
            self.assert_cov_safe(chain, dump_ts)
            clock.t += 3.0                         # past the retry / re-broadcast back-off
        run(chain, pub, clock, 6)
        self.assertTrue(all(chain.comps[b][4] == 1000 for b in BUYERS[:3]))
        self.assertGreaterEqual(chain.cov, dump_ts)
        self.assertTrue(any(r["event"] == "send_unknown" for r in logs))

    def test_estimate_failure_sends_nothing(self):
        chain, clock = FakeChain(ME), Clock()
        pub, logs = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 1e6, 0.1)
        chain.fail_estimate = True
        run(chain, pub, clock, 3)
        self.assertEqual(chain.sent, [])
        self.assertTrue(any(r["event"] == "estimate_failed" for r in logs))
        chain.fail_estimate = False
        clock.t += 3
        run(chain, pub, clock, 3)
        self.assertIn(BUYERS[0], chain.comps)

    def test_failed_receipt_does_not_let_cov_advance(self):
        chain, clock = FakeChain(ME), Clock()
        pub, logs = build(chain, clock)
        pub.start(1, registry_block=1)
        dump_ts = dump_bundle(chain, pub, clock)
        real = chain._apply
        chain._apply = lambda raw, ts: False      # every tx reverts for a while
        for _ in range(6):
            run(chain, pub, clock)
            self.assertLess(chain.cov, dump_ts)
            clock.t += 3
        chain._apply = real
        run(chain, pub, clock, 10)
        self.assertGreaterEqual(chain.cov, dump_ts)
        self.assertTrue(all(chain.comps[b][4] == 1000 for b in BUYERS[:3]))

    def test_one_tx_in_flight_cov_only_in_last_batch(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock, max_batch=100)
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 25)
        for i in range(250):
            chain.trade(TOK, f"0x{0x1000 + i:040x}", True, 1e6, 0.01)
        run(chain, pub, clock, 30)
        sizes = [int(d[8 + 7 * 64: 8 + 8 * 64], 16) for d in chain.sent]
        self.assertEqual(sorted(sizes, reverse=True)[:3], [100, 100, 50])
        covs = [cov_of(d) for d in chain.sent]
        self.assertEqual(covs[:-1], [0] * (len(covs) - 1), "earlier batches carry the old coveredUntil")
        self.assertGreater(covs[-1], 0)
        self.assertEqual(len(chain.comps), 250)

    def test_stuck_tx_is_bumped_and_mined(self):
        chain, clock = FakeChain(ME), Clock()
        pub, logs = build(chain, clock, bump_after_s=10.0)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 1e6, 0.1)
        chain.hold_txs = True
        run(chain, pub, clock, 3)
        clock.t += 11
        run(chain, pub, clock, 1)
        self.assertTrue(any(r["event"] == "tx_bumped" for r in logs))
        self.assertEqual(len(chain.pending), 1, "the replacement took the same nonce")
        chain.hold_txs = False
        run(chain, pub, clock, 4)
        self.assertIn(BUYERS[0], chain.comps)

    def test_gas_price_cap(self):
        chain, clock = FakeChain(ME), Clock()
        chain.gas_price = lambda: 9_000_000_000
        pub, logs = build(chain, clock, max_gas_price=1_000_000_000)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 1e6, 0.1)
        run(chain, pub, clock, 4)
        self.assertEqual(chain.sent, [])
        self.assertTrue(any(r["event"] == "gas_price_above_cap" for r in logs))

    def test_receipt_errors_are_not_fatal(self):
        chain, clock = FakeChain(ME), Clock()
        pub, logs = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 1e6, 0.1)
        run(chain, pub, clock, 1)
        chain.receipt = lambda h: (_ for _ in ()).throw(RuntimeError("node down"))
        run(chain, pub, clock, 2)
        self.assertTrue(any(r["event"] == "poll_error" for r in logs))
        del chain.receipt
        run(chain, pub, clock, 3)
        self.assertIn(BUYERS[0], chain.comps)

    def test_cov_candidate_never_beyond_processed_block(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        for _ in range(450):
            chain.mine()
        pub.step()                                  # first catch-up span only
        self.assertLess(pub.last_block, 450)
        self.assertLess(pub.cov_candidate(), chain.blocks[pub.last_block]["timestamp"])
        self.assertLessEqual(pub.cov_candidate(), chain.blocks[pub.last_block - 1]["timestamp"] - 1)

    def test_payer_is_tx_signer_for_contract_traders(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        router = "0x" + "99" * 20
        chain.trade(TOK, router, True, 1e6, 0.1, signer=BUYERS[0])
        run(chain, pub, clock, 4)
        self.assertIn(BUYERS[0], chain.comps)
        self.assertNotIn(router, chain.comps)

    def test_key_file_permissions(self):
        d = tempfile.mkdtemp()
        p = os.path.join(d, "k")
        with open(p, "w") as f:
            f.write("0x" + "11" * 32)
        os.chmod(p, 0o644)
        with self.assertRaises(PermissionError):
            txsign.load_key(p)
        os.chmod(p, 0o600)
        self.assertGreater(txsign.load_key(p), 0)


class RestartReorgTest(unittest.TestCase):
    def test_restart_reads_blocks_produced_during_downtime(self):
        d = tempfile.mkdtemp()
        chain, clock = FakeChain(ME), Clock()
        store = Store(d, "t")
        pub, _ = build(chain, clock, store)
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 30)
        for i, b in enumerate(BUYERS):
            chain.trade(TOK, b, True, 6e7, 0.1 * (i + 1))
        run(chain, pub, clock, 4)
        pub.checkpoint(force=True)
        ck = pub.last_block
        del pub                                     # the daemon dies
        for b in BUYERS[:3]:                        # dump while it is down
            chain.trade(TOK, b, False, 6e7, 0.02)
        dump_ts = None
        for _ in range(8):
            chain.mine()
        dump_ts = chain.blocks[ck + 1]["timestamp"]
        pub2, logs = build(chain, clock, store)    # fresh Engine object: state must come from the checkpoint
        pub2.start(None, registry_block=1)
        self.assertEqual(pub2.last_block, ck)
        self.assertEqual(chain.cov, chain.cov, "start() sends nothing")
        for _ in range(12):
            run(chain, pub2, clock)
            if chain.cov >= dump_ts:
                self.assertTrue(all(chain.comps[b][4] == 1000 for b in BUYERS[:3]))
        self.assertTrue(all(chain.comps[b][4] == 1000 for b in BUYERS[:3]), "dump during downtime flagged after restart")
        self.assertGreaterEqual(chain.cov, dump_ts)
        self.assertTrue(any(r["event"] == "restored" for r in logs))

    def test_first_start_replays_from_chain_cov_and_refuses_gap(self):
        chain, clock = FakeChain(ME), Clock()
        chain.cov = chain.blocks[0]["timestamp"] + 6
        for _ in range(500):
            chain.mine()
        pub, _ = build(chain, clock)
        with self.assertRaises(SystemExit):         # more than max_replay blocks behind
            pub.start(None, max_replay=100)
        pub2, _ = build(chain, clock)
        pub2.start(None, registry_block=1)
        self.assertEqual(pub2.last_block + 1, 2, "replay starts at the block of coveredUntil")
        pub3, _ = build(chain, clock)
        with self.assertRaises(SystemExit):         # explicit start far after coveredUntil
            pub3.start(400)
        pub4, _ = build(chain, clock)
        pub4.start(400, allow_gap=True)

    def test_reorg_rolls_back_and_republishes(self):
        chain, clock = FakeChain(ME), Clock()
        store = Store(tempfile.mkdtemp(), "t")
        pub, logs = build(chain, clock, store, conf=1, snap=populated())
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 30)
        pub.checkpoint(force=True)
        orphan = "0x" + "77" * 20
        chain.trade(TOK, orphan, True, 6e7, 3.5)    # lives only on the branch that is dropped
        run(chain, pub, clock, 3)                   # processed (head - 1) and published
        self.assertGreater(sum(chain.comps[orphan]), 0)
        chain.reorg(3)
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.2)  # the canonical branch has another trade
        run(chain, pub, clock, 12)
        self.assertTrue(any(r["event"] == "reorg" for r in logs))
        self.assertIn(BUYERS[0], chain.comps, "canonical trade published")
        self.assertEqual(chain.comps.get(orphan), (0, 0, 0, 0, 0), "value written from the orphaned branch is reset")
        self.assertEqual(pub.last_block, len(chain.blocks) - 1 - 1)

    def test_shorter_chain_is_detected_without_new_blocks(self):
        chain, clock = FakeChain(ME), Clock()
        store = Store(tempfile.mkdtemp(), "t")
        pub, logs = build(chain, clock, store, conf=0)
        pub.start(1, registry_block=1)
        run(chain, pub, clock, 8)
        chain.reorg(3)                              # nothing mined afterwards: the chain is shorter than the processed range
        pub.step()
        self.assertTrue(any(r["event"] == "reorg" for r in logs))
        self.assertLessEqual(pub.last_block, len(chain.blocks) - 1)
        self.assertLessEqual(pub.cov_candidate(), chain.blocks[-1]["timestamp"])

    def test_reorg_without_checkpoint_stops(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock, None, conf=0)
        pub.start(1, registry_block=1)
        run(chain, pub, clock, 6)
        chain.reorg(2)
        for _ in range(4):
            chain.mine()
        with self.assertRaises(SystemExit):
            pub.step()


if __name__ == "__main__":
    unittest.main()
