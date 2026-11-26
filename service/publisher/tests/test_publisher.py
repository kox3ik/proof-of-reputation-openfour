import unittest

import helpers  # noqa: F401
import snapshot_io
import txsign
from engine import Engine, covered_until
from fakechain import FakeChain
from publisher import Publisher
from wallets import WalletTable

KEY = int("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", 16)
ME = txsign.address_of(KEY)
TOK = "0x" + "aa" * 20
WB = "0x" + "bb" * 20
BUYERS = ["0x" + f"{i:02x}" * 20 for i in range(0x31, 0x36)]


def make(conf=0, store=None, **kw):
    chain = FakeChain(ME)
    logs = []
    pub = Publisher(chain, Engine(WalletTable(snapshot_io.empty()), {WB: 1.0}), "0x" + "c0" * 20, "0x" + "e0" * 20, KEY,
                    chain_id=97, log=logs.append, confirmations=conf, store=store, **kw)
    pub.start(1, registry_block=1)
    return chain, pub, logs


def advance(chain, pub, n=1):
    for _ in range(n):
        chain.mine()
        pub.step()


class PublisherTest(unittest.TestCase):
    def test_covered_until_below_first_uncovered_second(self):
        self.assertEqual(covered_until(100, 100), 99)   # blocks F-2 and F-1 share a second
        self.assertEqual(covered_until(100, 103), 100)

    def test_trade_scores_within_two_blocks_and_dump_flags(self):
        chain, pub, logs = make()
        chain.create(TOK, 1e9)
        advance(chain, pub, 30)                      # 90 s: past the 60 s skip window
        for i, b in enumerate(BUYERS):
            chain.trade(TOK, b, True, 6e7, 0.1 * (i + 1))
        advance(chain, pub)                          # block of the buys is read at once
        advance(chain, pub, 2)
        self.assertTrue(all(b in chain.comps for b in BUYERS), "buyers scored on chain")
        self.assertTrue(all(chain.comps[b][4] == 0 for b in BUYERS))
        for b in BUYERS[:3]:                         # scripted bundle dump, one block
            chain.trade(TOK, b, False, 6e7, 0.02)
        dump_block = len(chain.blocks)
        advance(chain, pub)
        self.assertEqual(chain.comps[BUYERS[0]][4], 0, "not decided before the window is complete")
        advance(chain, pub, 3)
        for b in BUYERS[:3]:
            self.assertEqual(chain.comps[b][4], 1000, "bundle wallet flagged")
        self.assertEqual(chain.comps[BUYERS[4]][4], 0)
        pubs = [r for r in logs if r["event"] == "publish" and r["ok"]]
        flagged_pub = [r for r in pubs if r["flagged"] >= 3][0]
        self.assertLessEqual(flagged_pub["publish_block"] - dump_block, 4)
        dump_ts = chain.blocks[dump_block]["timestamp"]
        self.assertGreaterEqual(chain.cov, dump_ts, "coveredUntil passed the sale")
        self.assertTrue(all(r["ok"] for r in logs if r["event"] == "publish"))

    def test_no_publish_without_news(self):
        chain, pub, _ = make()
        advance(chain, pub, 5)
        self.assertEqual(chain.sent, [])

    def test_failed_publish_requeues(self):
        chain, pub, logs = make()
        chain.trade(TOK, BUYERS[0], True, 1e6, 0.1)
        chain.mine()
        orig = chain._apply
        chain._apply = lambda raw, ts: False
        pub.step()
        advance(chain, pub)
        self.assertTrue(any(r["event"] == "publish" and not r["ok"] for r in logs))
        self.assertTrue(any(r["event"] == "resync" for r in logs))
        chain._apply = orig
        advance(chain, pub, 3)
        self.assertIn(BUYERS[0], chain.comps, "re-queued wallet published after recovery")


if __name__ == "__main__":
    unittest.main()
