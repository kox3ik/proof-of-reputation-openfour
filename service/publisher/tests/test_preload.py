import unittest

import helpers  # noqa: F401
import numpy as np
import snapshot_io
from engine import Engine
from wallets import WalletTable

A, B, C = "0x" + "01" * 20, "0x" + "02" * 20, "0x" + "03" * 20


def snap():
    addr = np.frombuffer(b"".join(bytes.fromhex(a[2:]) for a in (A, B)), np.uint8).reshape(-1, 20)
    return snapshot_io.Snapshot(addr, np.array([5.0, 0.1], np.float32), np.array([9, 1], np.uint16), np.array([8, 1], np.uint32),
                                np.array([3.0, 0.0], np.float32), np.array([0, 1], np.uint8), {})


class PreloadTest(unittest.TestCase):
    def test_preload_queues_known_wallets_and_publishes_snapshot_scores(self):
        e = Engine(WalletTable(snap()), {}, 3600.0)
        self.assertEqual(e.preload([A, B, C, A.upper()], 7), 2)  # C unknown; upper-case form is the same wallet
        out = {c.wallet: c for c in e.drain(cov_cap=None)}
        self.assertEqual(set(out), {A, B})
        self.assertEqual(out[B].comps[4], 1000)  # flagged in history
        self.assertGreater(out[A].comps[0], out[B].comps[0])

    def test_published_wallets_are_not_queued_again(self):
        e = Engine(WalletTable(snap()), {}, 3600.0)
        e.preload([A], 1)
        e.mark_published(e.drain())
        self.assertEqual(e.preload([A], 2), 0)


if __name__ == "__main__":
    unittest.main()
