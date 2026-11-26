"""Unit tests of the bit-accurate arithmetic against floating point and the RTL formats."""
import numpy as np
import pytest

from ofdm_model import fx


def test_convergent_rounding_ties_to_even():
    v = np.array([2, 6, 10, -2, -6, 3, -3])          # x / 4: 0.5, 1.5, 2.5, -0.5, -1.5, 0.75, -0.75
    assert fx.conv_rnd(v, 2).tolist() == [0, 2, 2, 0, -2, 1, -1]


def test_twiddles_are_q2_14():
    assert fx.TWC[0] == 16384 and fx.TWS[0] == 0
    assert fx.TWC[32] == 0 and fx.TWS[32] == 16384


def test_forward_fft_matches_numpy():
    rng = np.random.default_rng(0)
    x = rng.integers(-200, 200, (8, 128)) + 1j * rng.integers(-200, 200, (8, 128))
    r, i = fx.fft_fx(x.real.astype(int), x.imag.astype(int))
    # 7 stages of Q2.14 twiddle rounding on an unscaled transform: a few LSB on outputs of ~10^4
    assert np.max(np.abs(r + 1j * i - np.fft.fft(x, axis=1))) <= 8


def test_scaled_ifft_matches_numpy():
    rng = np.random.default_rng(1)
    x = (rng.integers(-6000, 6000, (8, 128)) + 1j * rng.integers(-6000, 6000, (8, 128)))
    r, i = fx.fft_fx(x.real.astype(int), x.imag.astype(int), inverse=True, scale=True)
    assert np.max(np.abs(r + 1j * i - np.fft.ifft(x, axis=1))) <= 2


@pytest.mark.parametrize("level,code", [(-3, 0), (-1, 1), (1, 3), (3, 2)])
def test_gray_demapper(level, code):
    assert fx.demap(np.array([level * fx.A]))[0] == code


def test_training_symbol_is_real_16qam():
    assert set(np.abs(fx.XTR).tolist()) <= {fx.A, 3 * fx.A}
    assert len(fx.XTR) == fx.N


def test_slot_length():
    assert fx.SLOT == 2244
    assert fx.STARTS[0] == 36 and fx.STARTS[1] == 36 + 128 + 32


def test_ber_theory_at_16p5_db():
    assert fx.ber16_theory(16.54) == pytest.approx(1e-3, rel=0.05)
