"""End-to-end link checks of the model, including the analytical LS-equaliser prediction."""
import numpy as np
import pytest

from ofdm_model import fx


def _run(snr, eq, nslot=6, seed=3, **kw):
    rng = np.random.default_rng(seed)
    E = B = 0
    S = 0.0
    for _ in range(nslot):
        tx, info = fx.tx_slot(rng)
        yr, yi = fx.channel(tx, snr, rng, **kw)
        cfo = fx.cfo_est(yr, yi) if kw.get("eps") else None
        Dr, Di = fx.rx_slot(yr, yi, info, eq=eq, cfo=cfo)
        e, b, ev = fx.score(Dr, Di, info)
        E += e
        B += b
        S += ev
    return E / B, 100 * np.sqrt(S / nslot)


def test_noise_free_chain_is_error_free_with_low_floor():
    ber, evm = _run(None, eq=False)
    assert ber == 0 and evm < 0.3


def test_phase_compensation_and_decryption_at_test_snr():
    ber, evm = _run(38.2, eq=False)
    assert ber == 0 and evm == pytest.approx(100 / np.sqrt(10 ** 3.82), rel=0.15)


def test_ls_equaliser_noise_enhancement_matches_theory():
    _, e0 = _run(38.2, eq=False)
    _, e1 = _run(38.2, eq=True)
    assert e1 / e0 == pytest.approx(np.sqrt(1 + 10 * 0.5556), rel=0.15)   # 2.56


def test_cfo_correction_with_multipath():
    ber, _ = _run(30, eq=True, eps=0.05, mp=True, n0=1234)
    assert ber < 1e-3


def test_cfo_estimator_accuracy():
    rng = np.random.default_rng(9)
    errs = []
    for _ in range(10):
        tx, _ = fx.tx_slot(rng)
        yr, yi = fx.channel(tx, 30, rng, eps=0.05, n0=int(rng.integers(0, 10**6)))
        errs.append(fx.cfo_est(yr, yi) - 0.05)
    assert np.sqrt(np.mean(np.square(errs))) < 1e-3
