"""Checkpoints of the engine state (atomic, a few generations) and a journal of published wallets.

A checkpoint = engine (wallet stats, positions, rug logs, what was published) + last processed block + recent block hashes.
On restart the daemon resumes after `last_block` and re-reads the blocks produced since; after a reorg it falls back to the
newest checkpoint below the fork point. The journal lists every wallet sent after a given block, so that wallets whose
on-chain value may no longer match the restored state are re-evaluated (see `Publisher._taint`).
"""
from __future__ import annotations

import json
import os
import pickle
from typing import NamedTuple

VERSION = 2


class State(NamedTuple):
    engine: object
    last_block: int
    ring: dict


class Store:
    def __init__(self, directory: str, ident: str, keep: int = 3) -> None:
        self.dir, self.ident, self.keep = directory, ident, keep
        os.makedirs(directory, mode=0o700, exist_ok=True)
        self.journal_path = os.path.join(directory, "journal.jsonl")

    def _files(self) -> list[tuple[int, str]]:
        out = []
        for f in os.listdir(self.dir):
            if f.startswith("ck-") and f.endswith(".pkl"):
                out.append((int(f[3:-4]), os.path.join(self.dir, f)))
        return sorted(out, reverse=True)

    def save(self, engine, last_block: int, ring: dict) -> str:
        path = os.path.join(self.dir, f"ck-{last_block}.pkl")
        tmp = path + ".tmp"
        with open(tmp, "wb") as fh:
            pickle.dump({"v": VERSION, "ident": self.ident, "engine": engine, "last_block": last_block, "ring": ring}, fh,
                        protocol=pickle.HIGHEST_PROTOCOL)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        files = self._files()
        for _, f in files[self.keep:]:
            os.remove(f)
        self._trim_journal(files[: self.keep][-1][0])
        return path

    def _load(self, path: str) -> State | None:
        try:
            with open(path, "rb") as fh:
                d = pickle.load(fh)
        except Exception:  # noqa: BLE001 - a torn or foreign file is skipped, an older generation is used
            return None
        if d.get("v") != VERSION or d.get("ident") != self.ident:
            return None
        return State(d["engine"], d["last_block"], d["ring"])

    def newest_at_or_below(self, block: int | None = None) -> State | None:
        for n, path in self._files():
            if block is None or n <= block:
                st = self._load(path)
                if st is not None:
                    return st
        return None

    # ── the tx that may be on its way: written BEFORE it is sent, removed when its fate is known ──
    @property
    def pending_path(self) -> str:
        return os.path.join(self.dir, "pending-tx.json")

    def save_pending(self, rec: dict) -> None:
        tmp = self.pending_path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(rec, fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.pending_path)

    def load_pending(self) -> dict | None:
        try:
            with open(self.pending_path) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    def clear_pending(self) -> None:
        try:
            os.remove(self.pending_path)
        except FileNotFoundError:
            pass

    # ── journal: {"head": last processed block when sent, "wallets": [...]} ──
    def journal_add(self, head: int, wallets: list[str]) -> None:
        with open(self.journal_path, "a") as fh:
            fh.write(json.dumps({"head": head, "wallets": wallets}) + "\n")
            fh.flush()
            os.fsync(fh.fileno())

    def journal_after(self, block: int) -> set[str]:
        out: set[str] = set()
        if not os.path.exists(self.journal_path):
            return out
        with open(self.journal_path) as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue  # torn last line
                if r["head"] >= block:
                    out.update(r["wallets"])
        return out

    def _trim_journal(self, oldest_kept: int) -> None:
        if not os.path.exists(self.journal_path):
            return
        with open(self.journal_path) as fh:
            keep = [ln for ln in fh if ln.strip() and _head(ln) >= oldest_kept]
        tmp = self.journal_path + ".tmp"
        with open(tmp, "w") as fh:
            fh.writelines(keep)
        os.replace(tmp, self.journal_path)


def _head(line: str) -> int:
    try:
        return json.loads(line)["head"]
    except ValueError:
        return -1
