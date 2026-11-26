"""IEEE-style Matplotlib settings shared by all experiment scripts."""
import os
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

FIGDIR = Path(os.environ.get("OFDM_FIGDIR", Path(__file__).resolve().parents[2] / "docs" / "figures"))
plt.rcParams.update({
    "font.family": "serif", "font.serif": ["Liberation Serif", "Times New Roman", "DejaVu Serif"],
    "mathtext.fontset": "stix", "font.size": 9, "axes.labelsize": 9, "axes.titlesize": 9, "legend.fontsize": 7.5,
    "xtick.labelsize": 8, "ytick.labelsize": 8, "axes.linewidth": 0.6, "lines.linewidth": 1.0,
    "xtick.direction": "in", "ytick.direction": "in", "xtick.top": True, "ytick.right": True,
    "axes.grid": True, "grid.linewidth": 0.3, "grid.color": "0.8", "grid.linestyle": ":", "lines.markersize": 4,
})


def save(fig, name):
    """Write docs/figures/<name>.png at 300 dpi."""
    FIGDIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGDIR / f"{name}.png", dpi=300, bbox_inches="tight", pad_inches=0.03)
    plt.close(fig)
