import unittest

import numpy as np

import helpers  # noqa: F401
import abi
import snapshot_io
import txsign
from reference import Reference, rank
from wallets import WalletTable

KEY = int("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", 16)


class TxSignTest(unittest.TestCase):
    def test_keccak_empty(self):
        self.assertEqual(txsign.keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    def test_address_of_anvil_key0(self):
        self.assertEqual(txsign.address_of(KEY), "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")

    def test_sign_recovers_sender_for_both_parities(self):
        for nonce in range(6):
            raw = txsign.sign_legacy(KEY, 97, nonce, 50_000_000, 100_000, "0x" + "14" * 20, bytes.fromhex("1234"))
            self.assertEqual(txsign.sender_of(raw, 97), txsign.address_of(KEY))


class AbiTest(unittest.TestCase):
    def test_publish_calldata_matches_cast(self):
        # `cast calldata "publish(uint64,address[],(uint16,uint16,uint16,uint16,uint16)[],uint64,uint64,bytes32,uint64[])" 3
        #  "[0x11..,0x22..]" "[(1,2,3,4,5),(6,7,8,9,10)]" 1234 77 0xabab..ab "[0,900]"` (byte for byte)
        got = abi.encode_publish(3, ["0x" + "11" * 20, "0x" + "22" * 20], [(1, 2, 3, 4, 5), (6, 7, 8, 9, 10)], 1234, 77,
                                 "0x" + "ab" * 32, [0, 900])
        self.assertEqual(got, "0x8445312f000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000004d2000000000000000000000000000000000000000000000000000000000000004dabababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000111111111111111111111111111111111111111100000000000000000000000022222222222222222222222222222222222222220000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000700000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000384")

    def test_trade_topic(self):
        self.assertEqual(abi.TRADE_TOPIC, "0x8728ba77a8dc0cbf185f23fe65b61fc658a37975e027062c3114394222a10f3f")

    def test_parse_trade(self):
        words = [1, int("bb" * 20, 16), 0, 0, 5 * 10**18, 7 * 10**17, 7 * 10**17, 3] + [0] * 7
        log = {"topics": [abi.TRADE_TOPIC, "0x" + "00" * 12 + "aa" * 20, "0x" + "00" * 12 + "cc" * 20, "0x" + "00" * 32],
               "data": "0x" + "".join(f"{w:064x}" for w in words), "blockNumber": "0x10", "transactionHash": "0xab",
               "transactionIndex": "0x1", "logIndex": "0x2"}
        t = abi.parse_trade(log)
        self.assertEqual((t.token, t.trader, t.is_buy, t.quote_asset), ("0x" + "aa" * 20, "0x" + "cc" * 20, True, "0x" + "bb" * 20))
        self.assertEqual((t.token_amount, t.curve_quote, t.block), (5 * 10**18, 7 * 10**17, 16))


class ReferenceTest(unittest.TestCase):
    def test_rank_equals_pct_rank(self):
        try:
            import analytics_path  # noqa: F401  (full repo only)
            import por_wallets
        except ImportError:
            self.skipTest("batch analytics not available")
        x = np.array([1.0, 5.0, 5.0, 9.0, 20.0, 0.5])
        want = por_wallets.pct_rank(x)
        s = np.sort(x)
        self.assertEqual([rank(s, v) for v in x], want.tolist())

    def test_components_from_table(self):
        snap = snapshot_io.empty()
        t = WalletTable(snap)
        for i in range(5):
            t.add_trade("0xt", f"0x{i:040x}", 1000.0, True, 1.0, float(i + 1))
        r = Reference()
        r.rebuild(t)
        w = t.idx[f"0x{4:040x}"]
        v, a, h, ident, pen = r.components(t, w, 1000.0)
        self.assertEqual((ident, pen), (0, 0))
        self.assertGreater(v, 800)  # largest volume of 5 -> mid-rank 900
        t.flag[w] = True
        self.assertEqual(r.components(t, w, 1000.0)[4], 1000)


class SnapshotTest(unittest.TestCase):
    def test_roundtrip_and_table(self):
        import tempfile
        a = ["0x" + "02" * 20, "0x" + "01" * 20]
        with tempfile.TemporaryDirectory() as d:
            snapshot_io.save(f"{d}/s.npz", a, [1.5, 2.5], [3, 4], [5, 6], [7.0, 8.0], [0, 1], {"x": 1})
            s = snapshot_io.load(f"{d}/s.npz")
        t = WalletTable(s)
        self.assertEqual(t.addr, sorted(a))
        self.assertEqual((t.n_days[t.idx[a[1]]], bool(t.flag[t.idx[a[1]]])), (4, True))


if __name__ == "__main__":
    unittest.main()
