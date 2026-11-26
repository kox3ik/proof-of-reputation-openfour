"""End-to-end cases from an external review: positions before start, incomplete / duplicate logs, equal-second blocks, a batch at
the gas limit, a lost send response with a restart, coverage without new components, a tx stuck at the gas cap, an old publish
mined again after a reorg."""
import tempfile
import unittest

import helpers  # noqa: F401
from engine import Engine
from fakechain import FakeChain
from chain import RpcError
from store import Store
from test_publisher import BUYERS, ME, TOK, WB
from test_safety import Clock, build, cov_of, dump_bundle, run


def history(chain, clock, pub=None):
    """Token with five buyers, built BEFORE any daemon watches it; returns nothing (the chain holds the history)."""
    chain.create(TOK, 1e9)
    for _ in range(30):
        chain.mine()
    for i, b in enumerate(BUYERS):
        chain.trade(TOK, b, True, 6e7, 0.1 * (i + 1))
    for _ in range(4):
        chain.mine()


def dump(chain):
    for b in BUYERS[:3]:
        chain.trade(TOK, b, False, 6e7, 0.02)
    chain.mine()
    return chain.blocks[-1]["timestamp"]


class PositionsBeforeStart(unittest.TestCase):
    def test_without_history_coverage_is_held_back_and_with_history_the_dump_is_flagged(self):
        chain, clock = FakeChain(ME), Clock()
        history(chain, clock)
        blind, logs = build(chain, clock)
        blind.start(None, registry_block=1)          # positions known only from now on
        self.assertFalse(blind.cov_enabled())
        good, _ = build(chain, clock)
        good.start(None, history_from=1, registry_block=1)
        self.assertTrue(good.cov_enabled())
        dump_ts = dump(chain)
        for _ in range(10):
            chain.mine()
            blind.step()
        self.assertEqual(chain.cov, 0, "no coveredUntil from a daemon that does not know the positions")
        self.assertTrue(any(r["event"] == "coverage_disabled" for r in logs))
        self.assertEqual(sum(1 for b in BUYERS if blind.e.t.pos.get((TOK, blind.e.t.idx.get(b, -1)), [0])[0] > 0), 0)
        for _ in range(12):
            chain.mine()
            clock.t += 1
            good.step()
        self.assertTrue(all(chain.comps[b][4] == 1000 for b in BUYERS[:3]), "dump of pre-start positions flagged")
        self.assertGreaterEqual(chain.cov, dump_ts)


class LogCompleteness(unittest.TestCase):
    def test_partial_answer_is_rejected_and_nothing_is_applied(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.1)
        chain.mine()
        chain.range_drop = True
        before = pub.last_block
        with self.assertRaises(RpcError):
            pub.step()
        self.assertEqual(pub.last_block, before)
        self.assertEqual(pub.e.t.n, 0, "no trade of the half-read block was applied")
        chain.range_drop = False
        run(chain, pub, clock, 3)
        self.assertIn(BUYERS[0], chain.comps)

    def test_duplicate_logs_are_counted_once(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.range_dup = True
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.1)
        run(chain, pub, clock, 2)
        w = pub.e.t.idx[BUYERS[0]]
        self.assertAlmostEqual(pub.e.t.pos[(TOK, w)][0], 6e7)

    def test_malformed_log_fails_the_whole_range(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.1)
        chain.trade(TOK, BUYERS[1], True, 6e7, 0.1)
        chain.queue_logs[-1]["data"] = "0x12"       # second trade of the block cannot be parsed
        chain.mine()
        with self.assertRaises(Exception):
            pub.step()
        self.assertEqual(pub.e.t.n, 0, "the first trade of the block was not applied alone")


class TimingAndSize(unittest.TestCase):
    def test_equal_second_blocks_never_let_coverage_pass_the_dump(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 30)
        for i, b in enumerate(BUYERS):
            chain.trade(TOK, b, True, 6e7, 0.1 * (i + 1))
        run(chain, pub, clock, 3)
        for b in BUYERS[:3]:
            chain.trade(TOK, b, False, 6e7, 0.02)
        chain.mine(0)
        dump_ts = chain.blocks[-1]["timestamp"]
        for _ in range(10):
            chain.mine(0)                            # many blocks share the dump's second
            clock.t += 1
            pub.step()
            if chain.cov >= dump_ts:
                self.assertTrue(all(chain.comps.get(b, (0,) * 5)[4] == 1000 for b in BUYERS[:3]))
        self.assertLess(chain.cov, dump_ts, "blocks of the dump's own second are never covered")
        run(chain, pub, clock, 8)
        self.assertGreaterEqual(chain.cov, dump_ts)
        self.assertTrue(all(chain.comps[b][4] == 1000 for b in BUYERS[:3]))

    def test_batch_is_split_to_the_gas_share_of_the_block_limit(self):
        chain, clock = FakeChain(ME), Clock()
        chain.gas_limit_value = 4_000_000            # share 0.25 -> 1M per tx -> about 29 new wallets
        pub, _ = build(chain, clock, max_batch=250)
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 25)
        for i in range(250):
            chain.trade(TOK, f"0x{0x2000 + i:040x}", True, 1e6, 0.01)
        run(chain, pub, clock, 60)
        sizes = [int(d[8 + 7 * 64: 8 + 8 * 64], 16) for d in chain.sent]
        self.assertEqual(len(chain.comps), 250)
        self.assertTrue(all(40_000 + 25_000 * n <= 1_000_000 for n in sizes), sizes)
        covs = [cov_of(d) for d in chain.sent]
        self.assertEqual(covs[:-1], [0] * (len(covs) - 1))
        self.assertGreater(covs[-1], 0)


class FlagDating(unittest.TestCase):
    def test_flag_is_dated_at_the_dump_window_start_not_publication_time(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        dump_ts = dump_bundle(chain, pub, clock)
        run(chain, pub, clock, 10)
        for b in BUYERS[:3]:
            self.assertEqual(chain.flagged_from[b], dump_ts, "flaggedFrom = start of the dump window")
        self.assertNotIn(BUYERS[4], chain.flagged_from)
        self.assertLessEqual(chain.flagged_from[BUYERS[0]], chain.cov)

    def test_flag_waits_until_coverage_reaches_its_date(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 30)
        for i, b in enumerate(BUYERS):
            chain.trade(TOK, b, True, 6e7, 0.1 * (i + 1))
        run(chain, pub, clock, 3)
        for b in BUYERS[:3]:
            chain.trade(TOK, b, False, 6e7, 0.02)
        chain.mine(0)                                # the dump's block shares its second with the next ones
        for _ in range(6):
            chain.mine(0)
            clock.t += 1
            pub.step()
        self.assertEqual(chain.flagged_from, {}, "no flag is sent with a date after the coverage of its publication")
        run(chain, pub, clock, 8)
        self.assertEqual(len(chain.flagged_from), 3)


class SenderCases(unittest.TestCase):
    def test_lost_response_then_restart_resolves_the_nonce_first(self):
        d = tempfile.mkdtemp()
        chain, clock = FakeChain(ME), Clock()
        store = Store(d, "t")
        pub, _ = build(chain, clock, store)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.1)
        chain.lose_answer = 1                        # the node takes the tx but the answer is lost
        chain.hold_txs = True                        # and it stays in the mempool while the daemon dies
        run(chain, pub, clock, 2)
        self.assertTrue(pub.sender.busy and store.load_pending(), "the tx was written down before it was sent")
        del pub                                      # and the daemon dies
        pub2, logs = build(chain, clock, store)
        pub2.start(None, registry_block=1)
        self.assertTrue(any(r["event"] == "pending_adopted" for r in logs))
        self.assertTrue(pub2.sender.busy, "no new batch before the old nonce is resolved")
        chain.hold_txs = False
        run(chain, pub2, clock, 6)
        epochs = [int(d[8:72], 16) for d in chain.sent]
        self.assertEqual(epochs, sorted(set(epochs)), "the adopted tx was mined once; any later batch has a new epoch")
        self.assertEqual(epochs[0], 1)
        self.assertIn(BUYERS[0], chain.comps)
        self.assertIsNone(store.load_pending())

    def test_tx_stuck_at_the_gas_cap_raises_an_alert_and_is_rebroadcast(self):
        chain, clock = FakeChain(ME), Clock()
        pub, logs = build(chain, clock, bump_after_s=5.0, max_gas_price=chain.gas_price())
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.1)
        chain.hold_txs = True
        run(chain, pub, clock, 2)
        clock.t += 6
        run(chain, pub, clock, 1)
        self.assertTrue(any(r["event"] == "ALERT_tx_stuck_at_gas_cap" for r in logs))
        chain.hold_txs = False
        run(chain, pub, clock, 4)
        self.assertIn(BUYERS[0], chain.comps)


class CoverageWithoutNews(unittest.TestCase):
    def test_empty_batch_moves_coverage_when_components_did_not_change(self):
        chain, clock = FakeChain(ME), Clock()
        pub, _ = build(chain, clock)
        pub.start(1, registry_block=1)
        chain.trade(TOK, BUYERS[0], True, 6e7, 0.1)
        run(chain, pub, clock, 6)
        first_cov = chain.cov
        chain.trade(TOK, BUYERS[0], True, 1e3, 0.0001)    # same wallet, components stay the same
        chain.mine()
        t2 = chain.blocks[-1]["timestamp"]
        run(chain, pub, clock, 6)
        self.assertGreater(chain.cov, first_cov)
        self.assertGreaterEqual(chain.cov, t2)
        self.assertEqual(int(chain.sent[-1][8 + 7 * 64: 8 + 8 * 64], 16), 0, "last tx is an empty batch")


class OldPublishAfterReorg(unittest.TestCase):
    def test_publication_of_the_orphaned_branch_does_not_land_on_the_new_one(self):
        from test_safety import populated
        chain, clock = FakeChain(ME), Clock()
        store = Store(tempfile.mkdtemp(), "t")
        pub, _ = build(chain, clock, store, conf=1, snap=populated())
        pub.start(1, registry_block=1)
        chain.create(TOK, 1e9)
        run(chain, pub, clock, 30)
        orphan = "0x" + "77" * 20
        chain.trade(TOK, orphan, True, 6e7, 3.5)
        run(chain, pub, clock, 3)
        self.assertGreater(sum(chain.comps[orphan]), 0)
        landed = chain.landed
        chain.reorg(3)                               # its publish tx returns to the mempool, as on a real node
        self.assertTrue(chain.pending, "the old publication is waiting to be mined again")
        for _ in range(12):
            run(chain, pub, clock)
            self.assertEqual(sum(chain.comps.get(orphan, (0,))), 0, "the old publication must never land")
        self.assertGreaterEqual(chain.landed, landed)


if __name__ == "__main__":
    unittest.main()
