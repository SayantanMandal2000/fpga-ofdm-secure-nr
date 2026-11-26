"""Plot the constellations and per-symbol EVM from an RTL simulation dump.

The system testbench (tb/tb_ofdm_top.v) writes constellation.csv with one line per decoded point:
    test,I,Q
for the first 1024 points after each BER-counter clear. Vivado writes it to
    <project>.sim/sim_1/behav/xsim/constellation.csv
and `make sim-top` writes it to build/constellation.csv.

Usage:
    python plot_rtl_constellation.py path/to/constellation.csv [--out rtl_constellations]
"""
import argparse

import numpy as np

from _common import plt, save

A = 2048
LEVELS = np.array([-3, -1, 1, 3]) * A
NAMES = {1: "Test 1: PC off", 2: "Test 2: PC on", 3: "Test 3: wrong key",
         4: "Test 4: chaos off", 5: "Test 5: |P|$^2$ metric", 6: "Test 6: CFO + multipath"}


def nearest(v):
    return LEVELS[np.argmin(np.abs(v[:, None] - LEVELS[None, :]), axis=1)]


def evm(i, q):
    ri, rq = nearest(i), nearest(q)
    return 100 * np.sqrt(np.sum((i - ri) ** 2 + (q - rq) ** 2) / np.sum(ri ** 2 + rq ** 2))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv")
    ap.add_argument("--out", default="rtl_constellations")
    args = ap.parse_args()
    d = np.loadtxt(args.csv, delimiter=",", ndmin=2)
    tests = sorted(set(d[:, 0].astype(int)))
    cols = 3
    rows = int(np.ceil(len(tests) / cols))
    fig, axs = plt.subplots(rows, cols, figsize=(6.6, 2.2 * rows), squeeze=False)
    print(f"{'test':>4} {'points':>6} {'EVM %':>7}   per-symbol EVM % (128 points each)")
    for ax, t in zip(axs.ravel(), tests):
        p = d[d[:, 0] == t]
        i, q = p[:, 1], p[:, 2]
        per_sym = [evm(i[k:k + 128], q[k:k + 128]) for k in range(0, len(i) - 127, 128)]
        print(f"{t:>4} {len(i):>6} {evm(i, q):>7.2f}   " + " ".join(f"{e:5.1f}" for e in per_sym))
        ax.plot(i, q, ".", ms=1.2, color="k")
        ax.set_title(NAMES.get(t, f"Test {t}"), fontsize=8)
        ax.set_xlim(-9000, 9000)
        ax.set_ylim(-9000, 9000)
        ax.set_aspect("equal")
        ax.set_xticks(LEVELS)
        ax.set_yticks(LEVELS)
        ax.tick_params(labelsize=6)
    for ax in axs.ravel()[len(tests):]:
        ax.axis("off")
    fig.tight_layout()
    save(fig, args.out)


if __name__ == "__main__":
    main()
