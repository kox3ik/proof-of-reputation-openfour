"""Minimal legacy (EIP-155) transaction signing, no web3 dependency: keccak256 (pycryptodomex), secp256k1 (cryptography).

The key is read from a file by `load_key`; it is never logged or passed on a command line.
"""
from __future__ import annotations

import os

from Cryptodome.Hash import keccak
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import Prehashed, decode_dss_signature

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def keccak256(data: bytes) -> bytes:
    return keccak.new(digest_bits=256, data=data).digest()


def _rlp(x) -> bytes:
    if isinstance(x, int):
        x = x.to_bytes((x.bit_length() + 7) // 8, "big") if x else b""
    if isinstance(x, (bytes, bytearray)):
        b = bytes(x)
        if len(b) == 1 and b[0] < 0x80:
            return b
        return _len(len(b), 0x80) + b
    body = b"".join(_rlp(i) for i in x)
    return _len(len(body), 0xC0) + body


def _len(n: int, off: int) -> bytes:
    if n < 56:
        return bytes([off + n])
    nb = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([off + 55 + len(nb)]) + nb


def _add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0]:
        if (a[1] + b[1]) % P == 0:
            return None
        lam = 3 * a[0] * a[0] * pow(2 * a[1], -1, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], -1, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return x, (lam * (a[0] - x) - a[1]) % P


def _mul(k: int, pt):
    r = None
    while k:
        if k & 1:
            r = _add(r, pt)
        pt = _add(pt, pt)
        k >>= 1
    return r


def _pub(priv: int) -> tuple[int, int]:
    nums = ec.derive_private_key(priv, ec.SECP256K1()).public_key().public_numbers()
    return nums.x, nums.y


def address_of(priv: int) -> str:
    x, y = _pub(priv)
    return "0x" + keccak256(x.to_bytes(32, "big") + y.to_bytes(32, "big"))[-20:].hex()


def _recover(h: int, r: int, s: int, rec: int):
    y2 = (pow(r, 3, P) + 7) % P
    y = pow(y2, (P + 1) // 4, P)
    if y % 2 != rec:
        y = P - y
    rinv = pow(r, -1, N)
    return _mul(rinv, _add(_mul(s, (r, y)), _mul(N - h, G)))


def sign_hash(priv: int, digest: bytes) -> tuple[int, int, int]:
    """(r, s, recovery id 0/1) with low s."""
    key = ec.derive_private_key(priv, ec.SECP256K1())
    r, s = decode_dss_signature(key.sign(digest, ec.ECDSA(Prehashed(hashes.SHA256()))))
    if s > N // 2:
        s = N - s
    h = int.from_bytes(digest, "big")
    want = _pub(priv)
    for rec in (0, 1):
        if _recover(h, r, s, rec) == want:
            return r, s, rec
    raise RuntimeError("signature recovery failed")


def sign_legacy(priv: int, chain_id: int, nonce: int, gas_price: int, gas: int, to: str, data: bytes, value: int = 0) -> bytes:
    to_b = bytes.fromhex(to[2:])
    r, s, rec = sign_hash(priv, keccak256(_rlp([nonce, gas_price, gas, to_b, value, data, chain_id, 0, 0])))
    return _rlp([nonce, gas_price, gas, to_b, value, data, 35 + 2 * chain_id + rec, r, s])


def sender_of(raw: bytes, chain_id: int) -> str:
    """Recover the sender of a signed legacy tx (self-check and tests)."""
    items = _decode(raw)[0]
    nonce, gp, gas, to, value, data, v, r, s = items
    v = int.from_bytes(v, "big")
    pt = _recover(int.from_bytes(keccak256(_rlp([int.from_bytes(nonce, "big"), int.from_bytes(gp, "big"),
                  int.from_bytes(gas, "big"), to, int.from_bytes(value, "big"), data, chain_id, 0, 0])), "big"),
                  int.from_bytes(r, "big"), int.from_bytes(s, "big"), (v - 35 - 2 * chain_id) % 2)
    return "0x" + keccak256(pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big"))[-20:].hex()


def _decode(b: bytes, i: int = 0):
    p = b[i]
    if p < 0x80:
        return b[i:i + 1], i + 1
    if p < 0xB8:
        return b[i + 1:i + 1 + p - 0x80], i + 1 + p - 0x80
    if p < 0xC0:
        n = int.from_bytes(b[i + 1:i + 1 + p - 0xB7], "big")
        s = i + 1 + p - 0xB7
        return b[s:s + n], s + n
    if p < 0xF8:
        n, s = p - 0xC0, i + 1
    else:
        n = int.from_bytes(b[i + 1:i + 1 + p - 0xF7], "big")
        s = i + 1 + p - 0xF7
    out, j = [], s
    while j < s + n:
        it, j = _decode(b, j)
        out.append(it)
    return out, s + n


def load_key(path: str) -> int:
    st = os.stat(path)
    if st.st_mode & 0o077:
        raise PermissionError(f"key file {path} is accessible by group/others (mode {st.st_mode & 0o777:o}); chmod 600")
    if st.st_uid != os.geteuid():
        raise PermissionError(f"key file {path} is owned by another user")
    with open(path) as fh:
        k = int(fh.read().strip(), 16)
    if not 0 < k < N:
        raise ValueError("invalid private key file")
    return k
