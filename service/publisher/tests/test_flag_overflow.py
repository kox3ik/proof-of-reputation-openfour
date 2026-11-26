import unittest

import helpers  # noqa: F401
from test_publisher import ME, TOK, advance, make  # noqa: F401

DUMPERS = ["0x" + f"{i:02x}" * 20 for i in range(0x40, 0x4A)]  # 10 wallets dump in one block


class FlagOverflowTest(unittest.TestCase):
    def test_more_new_flags_than_the_batch_size_still_flag_everyone_and_advance_coverage(self):
        chain, pub, logs = make(max_batch=3)
        chain.create(TOK, 1e9)
        advance(chain, pub, 30)
        for b in DUMPERS:
            chain.trade(TOK, b, True, 6e7, 0.1)
        advance(chain, pub, 12)  # the buys are published first, 3 wallets per batch
        for b in DUMPERS:
            chain.trade(TOK, b, False, 6e7, 0.02)
        dump_block = len(chain.blocks)
        advance(chain, pub, 40)
        self.assertTrue(all(chain.comps[b][4] == 1000 for b in DUMPERS), "every dumper flagged (10 flags > batch of 3)")
        self.assertGreaterEqual(chain.cov, chain.blocks[dump_block]["timestamp"], "coveredUntil passed the dump")
        self.assertTrue(all(r["ok"] for r in logs if r["event"] == "publish"))


if __name__ == "__main__":
    unittest.main()
