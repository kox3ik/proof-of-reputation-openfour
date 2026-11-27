#!/usr/bin/env python3
"""Tests for build_migrated_set.py. Run from this directory: python3 -m unittest test_migrated_set"""
import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_migrated_set as b  # noqa: E402

SUB = os.path.join(HERE, "..", "..", "submission")
RUN = json.load(open(os.path.join(SUB, "migrate-run-testnet-20261127.json")))
CHAIN = json.load(open(os.path.join(SUB, "migrate-run-testnet-20261127-chain.json")))


class MigratedSet(unittest.TestCase):
    def setUp(self):
        self.doc = b.build_set(RUN, CHAIN)

    def test_counts_and_phases(self):
        self.assertEqual(len(self.doc["trades"]), 8)
        self.assertEqual({t["phase"] for t in self.doc["trades"]}, {"curve"})
        self.assertEqual(sum(t["side"] == "sell" for t in self.doc["trades"]), 2)

    def test_fees_come_from_logs(self):
        f = {t["tx"][:10]: t["feeBps"] for t in self.doc["trades"]}
        self.assertEqual(f["0xaa79ae9d"], {"regular": 50, "deposit": 640, "penalty": 0, "total": 690})
        self.assertEqual(f["0xff12e1b2"]["total"], 50)
        self.assertEqual(f["0xf6b87b85"]["total"], 9)
        for x in self.doc["trades"]:
            self.assertEqual(x["feeBps"]["regular"] + x["feeBps"]["deposit"] + x["feeBps"]["penalty"], x["feeBps"]["total"])

    def test_fee_rounding_is_tight(self):
        for t in CHAIN["trades"]:
            exact = int(t["core"]["moduleFee"]) * 10000 / int(t["core"]["quote"])
            self.assertAlmostEqual(exact, round(exact), delta=0.01)

    def test_migration_event_and_after(self):
        kinds = [e["kind"] for e in self.doc["events"]]
        self.assertEqual(kinds, ["migrate", "finalize", "claim", "claim"])
        mig = self.doc["events"][0]
        self.assertEqual(mig["block"], 145084403)
        self.assertEqual(mig["tx"], self.doc["trades"][-1]["tx"])
        self.assertEqual(self.doc["migrated"]["block"], 145084403)

    def test_wallets(self):
        w = self.doc["wallets"]
        self.assertEqual(sorted(v["score"] for v in w.values()), [0.0, 0.4, 0.9])
        fresh = w["0xcf75edac67eafee9f334bdcfa70a1f6fdf11ab33"]
        self.assertEqual((fresh["buyBps"], fresh["sellBps"], fresh["depositBps"], fresh["fresh"]), (690, 50, 640, True))
        self.assertTrue(all(t["wallet"] in w for t in self.doc["trades"]))

    def test_times_follow_blocks(self):
        t = [x["t"] for x in self.doc["trades"]]
        self.assertEqual(t, sorted(t))
        self.assertEqual(self.doc["trades"][-1]["t"], CHAIN["blockTimes"]["145084403"])

    def test_pool_trade_after_migration_is_marked(self):
        chain = copy.deepcopy(CHAIN)
        extra = copy.deepcopy(chain["trades"][-1])
        extra.update(block=145084420, tx="0x" + "ab" * 32, side="sell")
        extra["core"]["isBuy"] = "0"
        chain["trades"].append(extra)
        doc = b.build_set(RUN, chain)
        self.assertEqual(doc["trades"][-1]["phase"], "pool")

    def test_inputs_not_mutated(self):
        run, chain = copy.deepcopy(RUN), copy.deepcopy(CHAIN)
        b.build_set(run, chain)
        self.assertEqual(run, RUN)
        self.assertEqual(chain, CHAIN)

    def test_extract_rejects_failed_trade(self):
        raw = {"rc": {s["tx"]: {"status": "0x0"} for s in RUN["steps"] if "tx" in s}, "tx": {s["tx"]: {} for s in RUN["steps"] if "tx" in s}, "block": 1, "block0": 0}
        with self.assertRaises(ValueError):
            b.extract(raw, {}, RUN)

    def test_index_merge_places_set_after_simulation(self):
        idx = {"sets": [{"id": "testnet"}, {"id": "mainnet"}]}
        out = b.merge_index(idx, "x.json")
        self.assertEqual([s["id"] for s in out["sets"]], ["testnet", b.SET_ID, "mainnet"])
        self.assertEqual([s["id"] for s in idx["sets"]], ["testnet", "mainnet"])
        again = b.merge_index(out, "x.json")
        self.assertEqual(len(again["sets"]), 3)


if __name__ == "__main__":
    unittest.main()
