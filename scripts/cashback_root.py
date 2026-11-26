#!/usr/bin/env python3
"""Build Merkle roots + per-wallet proofs for CashbackDistributor (OpenZeppelin StandardMerkleTree format).

Input  (JSON list or CSV with header epoch,wallet,asset,amount): one row per wallet per (epoch, asset).
         asset 0x0 or the zero address = native (normalized).
         epoch = closed UTC day number (unix time // 86400). amount in wei (integer > 0).
Output (JSON): {"rounds": [{"epoch", "asset", "root", "total", "claims": [{"wallet","amount","proof":[...]}]}]}
         One round per (epoch, asset); call publishRoot(epoch, asset, root, total) for each.
Leaf = keccak256(keccak256(abi.encode(uint64 epoch, address wallet, address asset, uint256 amount))).
Pure Python (no dependencies); keccak is self-tested on startup.
Usage: cashback_root.py INPUT [-o OUTPUT]
"""
import argparse, csv, json, re, sys
from collections import defaultdict

# ───────── Keccak-256 (original padding 0x01, as in Ethereum) ─────────
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
       0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
       0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
       0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += b"\x00" * ((-len(msg)) % rate)
    msg[-1] |= 0x80
    st = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            st[i % 5][i // 5] ^= int.from_bytes(msg[off + 8 * i: off + 8 * i + 8], "little")
        st = _f(st)
    out = b"".join(st[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak self-test"

# ───────── StandardMerkleTree ─────────
ZERO = "0x" + "0" * 40
ADDR = re.compile(r"^0x[0-9a-fA-F]{40}$")


def word_uint(v: int) -> bytes:
    return v.to_bytes(32, "big")


def word_addr(a: str) -> bytes:
    return bytes(12) + bytes.fromhex(a[2:])


def leaf(epoch: int, wallet: str, asset: str, amount: int) -> bytes:
    inner = keccak256(word_uint(epoch) + word_addr(wallet) + word_addr(asset) + word_uint(amount))
    return keccak256(inner)


def hash_pair(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b if a < b else b + a)


def build_tree(leaves):
    """OZ layout: sorted leaves fill the array from the end; returns (tree, index-by-leaf)."""
    n = len(leaves)
    order = sorted(range(n), key=lambda i: leaves[i])
    tree = [b""] * (2 * n - 1)
    pos = {}
    for k, i in enumerate(order):
        tree[len(tree) - 1 - k] = leaves[i]
        pos[i] = len(tree) - 1 - k
    for i in range(len(tree) - 1 - n, -1, -1):
        tree[i] = hash_pair(tree[2 * i + 1], tree[2 * i + 2])
    return tree, pos


def proof(tree, i):
    out = []
    while i > 0:
        out.append(tree[i - 1 if i % 2 == 0 else i + 1])
        i = (i - 1) // 2
    return out


def _int(v, name):
    """Strict integer: ints, or strings of decimal digits. Floats and fractions are rejected, never truncated."""
    if isinstance(v, bool) or isinstance(v, float):
        raise ValueError(f"{name} must be an integer, got {v!r}")
    if isinstance(v, int):
        return v
    t = str(v).strip()
    if not re.fullmatch(r"[0-9]+", t):
        raise ValueError(f"{name} must be a non-negative integer, got {v!r}")
    return int(t)


def _asset(v):
    a = str(v).strip().lower()
    return ZERO if a == "0x0" else a


def parse_rows(path):
    if path.endswith(".csv"):
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
    else:
        with open(path) as f:
            rows = json.load(f)
    return parse_rows_from(rows)


def parse_rows_from(rows):
    out = []
    for r in rows:
        epoch, amount = _int(r["epoch"], "epoch"), _int(r["amount"], "amount")
        wallet, asset = str(r["wallet"]).strip().lower(), _asset(r["asset"])
        if not (0 <= epoch < 2**64):
            raise ValueError(f"bad epoch {epoch}")
        if amount <= 0 or amount >= 2**256:
            raise ValueError(f"bad amount for {wallet}: {amount}")
        for a in (wallet, asset):
            if not ADDR.match(a):
                raise ValueError(f"bad address {a}")
        out.append((epoch, wallet, asset, amount))
    return out


def build(rows):
    groups = defaultdict(list)
    for epoch, wallet, asset, amount in rows:
        groups[(epoch, asset)].append((wallet, amount))
    rounds = []
    for (epoch, asset) in sorted(groups):
        items = groups[(epoch, asset)]
        wallets = [w for w, _ in items]
        if len(set(wallets)) != len(wallets):
            raise ValueError(f"duplicate wallet in round epoch={epoch} asset={asset}")
        leaves = [leaf(epoch, w, asset, a) for w, a in items]
        tree, pos = build_tree(leaves)
        total = sum(a for _, a in items)
        if total >= 2**256:
            raise ValueError(f"round total overflows uint256: epoch={epoch} asset={asset}")
        rounds.append({
            "epoch": epoch, "asset": asset, "root": "0x" + tree[0].hex(),
            "total": str(total),
            "claims": [{"wallet": w, "amount": str(a), "proof": ["0x" + p.hex() for p in proof(tree, pos[i])]}
                       for i, (w, a) in enumerate(items)],
        })
    return {"rounds": rounds}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    res = build(parse_rows(args.input))
    text = json.dumps(res, indent=2) + "\n"
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
