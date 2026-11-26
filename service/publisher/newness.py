"""Pluggable "newness" rule: when does a wallet stop being fresh?

The registry treats a wallet as fresh while all its published components are zero (it then pays the fresh deposit).
The service decides what to publish, so the rule lives here. DEFAULT = current behaviour: no override, a wallet gets its
components as soon as it has any history. A threshold rule keeps the components at zero until the wallet has earned its
way out; it is NOT switched on anywhere. Flags are never held back (the penalty component is always published).
Switch on by config: `run.py --newness threshold --newness-min-tokens 3 --newness-min-days 2 --newness-min-volume 1.0`.
Other measures (closed honest rounds, age, trade count) need extra per-wallet counters: add them to WalletTable and a
field here; the hook below is the only place that changes.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from wallets import WalletTable

ZERO = (0, 0, 0, 0, 0)


class NewnessRule(Protocol):
    def is_fresh(self, t: WalletTable, w: int, now: float) -> bool: ...


@dataclass(frozen=True)
class DefaultRule:
    """Current registry behaviour: never override the computed components."""

    def is_fresh(self, t: WalletTable, w: int, now: float) -> bool:
        return False


@dataclass(frozen=True)
class ThresholdRule:
    """Fresh until the wallet has traded min_tokens tokens, on min_days days, with min_volume_bnb in total (all must hold)."""
    min_tokens: int = 0
    min_days: int = 0
    min_volume_bnb: float = 0.0

    def is_fresh(self, t: WalletTable, w: int, now: float) -> bool:
        return not (t.n_tok[w] >= self.min_tokens and t.n_days[w] >= self.min_days and t.vol[w] >= self.min_volume_bnb)


def apply(rule: NewnessRule, t: WalletTable, w: int, now: float, comps: tuple) -> tuple:
    """Components to publish: a fresh wallet keeps only the penalty (flags always go out)."""
    if rule.is_fresh(t, w, now):
        return (0, 0, 0, 0, comps[4])
    return comps


def from_args(kind: str, min_tokens: int = 0, min_days: int = 0, min_volume: float = 0.0) -> NewnessRule:
    if kind == "default":
        return DefaultRule()
    if kind == "threshold":
        return ThresholdRule(min_tokens, min_days, min_volume)
    raise ValueError(f"unknown newness rule: {kind}")
