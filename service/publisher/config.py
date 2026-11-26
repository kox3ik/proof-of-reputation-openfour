"""Service-level constants."""
from __future__ import annotations

# Rug detector threshold: a wallet is a dumper when it sells at least this share of the position it held at the window
# start. 0.5 is the verified rule "mf050" used for all history labels; rug_core.MIN_FRAC must equal it (tested).
RUG_MIN_FRAC = 0.5
RUG_EVENTS_FILE = "rug_events_hist_mf050.jsonl.gz"  # history events found with RUG_MIN_FRAC
