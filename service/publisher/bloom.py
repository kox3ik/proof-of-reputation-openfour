"""Ethereum logsBloom test: does the block header claim a log from `address` (or with `topic`)?

A header whose bloom contains the Core address but whose log list for that address is empty means the log query was incomplete.
"""
from __future__ import annotations

from txsign import keccak256


def _bits(data: bytes) -> list[int]:
    h = keccak256(data)
    return [((h[i] << 8) | h[i + 1]) & 2047 for i in (0, 2, 4)]


def contains(bloom_hex: str, data: bytes) -> bool:
    b = int(bloom_hex, 16)
    return all((b >> bit) & 1 for bit in _bits(data))


def add(bloom: int, data: bytes) -> int:
    for bit in _bits(data):
        bloom |= 1 << bit
    return bloom


def has_address(bloom_hex: str, address: str) -> bool:
    return contains(bloom_hex, bytes.fromhex(address[2:]))
