"""Shared setup for the experiment scripts.

Results go to results/<name>.json and figures to docs/figures/.
Set OFDM_QUICK=1 for a fast smoke run (about 1/10 of the trials; used in CI).
"""
import json  # noqa: F401  (re-exported for the scripts)
import os
import sys
from pathlib import Path

import numpy as np  # noqa: F401

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from ofdm_model import chaos, fx, sync  # noqa: E402,F401
from ofdm_model.plotstyle import plt, save  # noqa: E402,F401

QUICK = os.environ.get("OFDM_QUICK", "0") == "1"
RES = ROOT / ("results/quick" if QUICK else "results")
RES.mkdir(parents=True, exist_ok=True)


def n(trials, floor=3):
    """Number of Monte-Carlo trials: full value, or about a tenth in quick mode."""
    return max(floor, trials // 10) if QUICK else trials
