import os, sys, unittest
sys.path.insert(0, os.path.dirname(__file__))
import cashback_root as c

W = "0x" + "0" * 39 + "1"


def rows(*rs):
    return c.build(c.parse_rows_from(list(rs)))


class T(unittest.TestCase):
    def test_native_alias(self):
        r = rows({"epoch": 1, "wallet": W, "asset": "0x0", "amount": "5"})
        self.assertEqual(r["rounds"][0]["asset"], "0x" + "0" * 40)

    def test_float_rejected(self):
        with self.assertRaises(ValueError):
            rows({"epoch": 1, "wallet": W, "asset": "0x0", "amount": 1.5})
        with self.assertRaises(ValueError):
            rows({"epoch": 1, "wallet": W, "asset": "0x0", "amount": "1.5"})

    def test_overflow_rejected(self):
        w2 = "0x" + "0" * 39 + "2"
        big = 2**255
        with self.assertRaises(ValueError):
            rows({"epoch": 1, "wallet": W, "asset": "0x0", "amount": big},
                 {"epoch": 1, "wallet": w2, "asset": "0x0", "amount": big})

    def test_fixture_matches(self):
        import json
        here = os.path.dirname(__file__)
        out = c.build(c.parse_rows(os.path.join(here, "..", "test/fixtures/cashback-input.json")))
        self.assertEqual(out, json.load(open(os.path.join(here, "..", "test/fixtures/cashback-output.json"))))


if __name__ == "__main__":
    unittest.main()
