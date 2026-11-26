"""Locations shared by the daemon and its tools."""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DATA_DIR = os.path.join(HERE, "data")
DEFAULT_SNAPSHOT = os.path.join(DATA_DIR, "snapshot.npz")

