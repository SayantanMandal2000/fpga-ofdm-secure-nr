"""Key-stream generator: determinism, boundedness, key sensitivity and basic randomness."""
import numpy as np

from ofdm_model import chaos

KEY = 0x0123456789ABCDEF_0BADF00D_CAFEF00D


def test_deterministic():
    a = chaos.streams([KEY], chaos.DP, 256)
    b = chaos.streams([KEY], chaos.DP, 256)
    assert np.array_equal(a, b)


def test_domains_differ():
    assert not np.array_equal(chaos.streams([KEY], chaos.DP, 64), chaos.streams([KEY], chaos.DQ, 64))


def test_state_stays_bounded():
    x, y, z = (np.array([v]) for v in chaos.seed(KEY, chaos.DP))
    peak = 0
    for _ in range(5000):
        x, y, z = chaos.step(x, y, z)
        peak = max(peak, int(np.max(np.abs(np.concatenate([x, y, z])))))
    assert peak < 60 * 2**20          # |state| < 60, far inside the Q12.20 range of 2048


def test_one_key_bit_changes_half_the_stream():
    a = chaos.streams([KEY], chaos.DP, 1664)[0]
    b = chaos.streams([KEY ^ (1 << 77)], chaos.DP, 1664)[0]
    frac = np.mean(chaos.bits_of(a & 0xF, 4) != chaos.bits_of(b & 0xF, 4))
    assert 0.45 < frac < 0.55 and a[0] != b[0]


def test_monobit_and_runs_pass():
    s = chaos.streams([KEY], chaos.DQ, 16384)[0]
    bits = chaos.bits_of(s & 0x7F, 7)
    assert chaos.t_monobit(bits) >= 0.01
    assert chaos.t_runs(bits) >= 0.01
