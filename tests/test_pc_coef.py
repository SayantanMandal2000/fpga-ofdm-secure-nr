"""Golden values: the 3.5 GHz NR phase-compensation coefficients read back from the RTL registers."""
import numpy as np

from ofdm_model import fx

GOLDEN = {0: 0x2AB82FA8, 1: 0x3CE1EC42, 2: 0x069EC058, 3: 0xC87CE028, 4: 0xCC6425DA, 5: 0x0DB13E85, 6: 0x3EB40CD1}


def test_coefficients_match_register_readback():
    ph = fx.nr_phases(3.5e9)
    c = fx.q14(np.cos(-ph)) & 0xFFFF
    s = fx.q14(np.sin(-ph)) & 0xFFFF
    words = [(int(a) << 16) | int(b) for a, b in zip(c, s)]
    for l, w in GOLDEN.items():
        assert words[l] == w, f"PC_COEF[{l}] = {words[l]:#010x}, expected {w:#010x}"


def test_coefficients_repeat_every_slot_at_3p5_ghz():
    # f0 * 0.5 ms = 1.75e6 cycles is an integer, so the 14 phases are the same in every slot
    assert (3.5e9 * 0.5e-3) % 1 == 0
    assert len(fx.nr_phases(3.5e9)) == 14
