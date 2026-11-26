"""Mainnet-history snapshot: per-wallet raw stats at the time of the build (compact npz, addresses as 20 bytes).

Raw stats are the inputs of the open scoring rule (`por_pit.epoch_components`): volume in BNB, distinct active days,
distinct tokens, holding in BNB-hours, and the prior rug flag (`por_rug`, owner definition B).
"""
from __future__ import annotations

import json
from typing import NamedTuple

import numpy as np


class Snapshot(NamedTuple):
    addr: np.ndarray    # (n, 20) uint8, sorted lexicographically
    vol: np.ndarray     # float32 BNB
    n_days: np.ndarray  # uint16
    n_tok: np.ndarray   # uint32
    hold: np.ndarray    # float32 BNB-hours
    flag: np.ndarray    # uint8, 1 = rug participant in history
    meta: dict


def addr_to_bytes(a: str) -> bytes:
    return bytes.fromhex(a[2:] if a.startswith("0x") else a)


def bytes_to_addr(b: bytes) -> str:
    return "0x" + bytes(b).hex()


def save(path: str, addr_hex: list[str], vol, n_days, n_tok, hold, flag, meta: dict) -> None:
    raw = np.frombuffer(b"".join(addr_to_bytes(a) for a in addr_hex), dtype=np.uint8).reshape(-1, 20)
    order = np.lexsort(raw.T[::-1])
    np.savez_compressed(path, addr=raw[order], vol=np.asarray(vol, np.float32)[order],
                        n_days=np.minimum(np.asarray(n_days), 65535).astype(np.uint16)[order],
                        n_tok=np.asarray(n_tok, np.uint32)[order], hold=np.asarray(hold, np.float32)[order],
                        flag=np.asarray(flag, np.uint8)[order], meta=np.frombuffer(json.dumps(meta).encode(), np.uint8))


def load(path: str) -> Snapshot:
    z = np.load(path)
    return Snapshot(z["addr"], z["vol"], z["n_days"], z["n_tok"], z["hold"], z["flag"],
                    json.loads(bytes(z["meta"]).decode()))


def empty() -> Snapshot:
    return Snapshot(np.zeros((0, 20), np.uint8), np.zeros(0, np.float32), np.zeros(0, np.uint16),
                    np.zeros(0, np.uint32), np.zeros(0, np.float32), np.zeros(0, np.uint8), {"empty": True})
