import unittest

import helpers  # noqa: F401
import config
import newness
import rug_core
import rug_live  # noqa: F401
import snapshot_io
from engine import Engine, TradeIn
from wallets import WalletTable

WB = "0x" + "bb" * 20
TOK = "0x" + "aa" * 20


def engine(rule=None):
    return Engine(WalletTable(snapshot_io.empty()), {WB: 1.0}, rule=rule)


class NewnessTest(unittest.TestCase):
    def test_detector_threshold_is_the_mf050_constant(self):
        self.assertEqual(config.RUG_MIN_FRAC, 0.5)
        self.assertEqual(rug_core.MIN_FRAC, 0.5)

    def test_default_publishes_as_soon_as_there_is_history(self):
        e = engine()
        e.add_trade(TradeIn(TOK, "0x" + "11" * 20, True, WB, 10**18, 10**18), 1, 1000.0)
        e.ref.rebuild(e.t)
        ch = e.drain()
        self.assertEqual(len(ch), 1)
        self.assertGreater(sum(ch[0].comps[:4]), 0)

    def test_threshold_keeps_fresh_wallet_at_zero_but_flag_goes_out(self):
        rule = newness.ThresholdRule(min_tokens=3)
        e = engine(rule)
        e.add_trade(TradeIn(TOK, "0x" + "11" * 20, True, WB, 10**18, 10**18), 1, 1000.0)
        e.ref.rebuild(e.t)
        self.assertEqual(e.drain(), [])  # all zero = what the chain already holds for a fresh wallet
        w = e.t.idx["0x" + "11" * 20]
        e.t.flag[w] = True
        e.dirty[w] = 2
        self.assertEqual(e.drain()[0].comps, (0, 0, 0, 0, 1000))
        e.t.n_tok[w] = 3
        e.t.flag[w] = False
        e.dirty[w] = 3
        self.assertGreater(sum(e.drain()[0].comps[:4]), 0)

    def test_from_args(self):
        self.assertIsInstance(newness.from_args("default"), newness.DefaultRule)
        with self.assertRaises(ValueError):
            newness.from_args("x")


if __name__ == "__main__":
    unittest.main()
