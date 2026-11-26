# Bit-accurate (to the RTL arithmetic) vectorised model of the OFDM link
import numpy as np
N = 128; LOGN = 7; CP = 32; CP0 = 36; A = 2048; NSYM = 14
SLOT = CP0 + N + 13 * (N + CP)
GRAY = np.array([-3, -1, 3, 1])          # 2-bit index b1b0 -> level: 00->-3, 01->-1, 10->3, 11->1
_k = np.arange(64)
TWC = np.round(np.cos(2 * np.pi * _k / N) * 16384).astype(np.int64)
TWS = np.round(np.sin(2 * np.pi * _k / N) * 16384).astype(np.int64)
BR = np.array([int(f'{i:07b}'[::-1], 2) for i in range(N)])
LUT = np.round(16384 * np.sin(2 * np.pi * np.arange(1024) / 1024)).astype(np.int64)

def conv_rnd(v, s):        # (v + 2^(s-1) - 1 + v[s]) >> s
    return (v + (1 << (s - 1)) - 1 + ((v >> s) & 1)) >> s

def sat16(v): return np.clip(v, -32768, 32767)

_plan = []
for s in range(LOGN):
    h = 1 << s; b = np.arange(64); k = b % h
    top = (b // h) * 2 * h + k
    _plan.append((top, top + h, k << (LOGN - 1 - s)))

def fft_fx(xr, xi, inverse=False, scale=False):
    """fft_core: DIT radix-2, Q2.14 twiddles, convergent rounding, optional /2 per stage."""
    re = np.asarray(xr, np.int64)[:, BR].copy(); im = np.asarray(xi, np.int64)[:, BR].copy()
    for top, bot, ti in _plan:
        wc = TWC[ti]; ws = TWS[ti] if inverse else -TWS[ti]
        ar, ai, br, bi = re[:, top], im[:, top], re[:, bot], im[:, bot]
        tre = conv_rnd(br * wc - bi * ws, 14); tim = conv_rnd(br * ws + bi * wc, 14)
        out = []
        for v in (ar + tre, ai + tim, ar - tre, ai - tim):
            if scale: v = (v + ((v >> 1) & 1)) >> 1
            out.append(sat16(v))
        re[:, top], im[:, top], re[:, bot], im[:, bot] = out
    return re, im

def rot_fx(xr, xi, c, s):  # cplx_rot, Q2.14, convergent rounding, saturation
    return sat16(conv_rnd(xr * c - xi * s, 14)), sat16(conv_rnd(xr * s + xi * c, 14))

def cmult_fx(xr, xi, c, s):  # cmult: round by 2^13 then >>14
    return sat16((xr * c - xi * s + 8192) >> 14), sat16((xr * s + xi * c + 8192) >> 14)

def nr_phases(f0=3.5e9, Ts=0.5e-3 / SLOT):
    st = 0; ph = []
    for l in range(NSYM):
        cpl = CP0 if l == 0 else CP
        ph.append(2 * np.pi * ((f0 * Ts * (st + cpl)) % 1.0)); st += N + cpl
    return np.array(ph)

def q14(v): return np.where(v >= 0, np.floor(v * 16384 + 0.5), -np.floor(-v * 16384 + 0.5)).astype(np.int64)

def training_levels():
    m = 0x1FF; X = []
    for k in range(N):
        b1 = ((m >> 8) ^ (m >> 4)) & 1; m1 = ((m << 1) | b1) & 0x1FF
        b0 = ((m1 >> 8) ^ (m1 >> 4)) & 1; m = ((m1 << 1) | b0) & 0x1FF
        X.append({0: -3, 1: -1, 3: 1, 2: 3}[(b1 << 1) | b0] * A)
    return np.array(X, np.int64)
XTR = training_levels()

def ber16_theory(esn0_db):
    from scipy.stats import norm
    a = np.sqrt(10 ** (np.asarray(esn0_db) / 10) / 5); Q = norm.sf
    return (3 * Q(a) + 2 * Q(3 * a) - Q(5 * a)) / 4

def demap(v):      # nearest Gray level index (2 bits) per dimension
    lv = np.clip(np.floor(v / (2 * A) + 2), 0, 3).astype(int)    # 0:-3 1:-1 2:1 3:3
    return np.array([0, 1, 3, 2])[lv]                              # level order -> Gray index

LVL2IDX = {-3: 0, -1: 1, 3: 2, 1: 3}

def tx_slot(rng, chaos=True, pc=True, phases=None):
    """One slot of transmitted samples (complex float of ints) plus the data needed to check it."""
    bI = rng.integers(0, 4, (13, N)); bQ = rng.integers(0, 4, (13, N))
    Xr = GRAY[bI] * A; Xi = GRAY[bQ] * A
    kq = rng.integers(0, 128, (13, N)) if chaos else np.zeros((13, N), int)
    c = LUT[(8 * kq + 256) % 1024]; s = LUT[(8 * kq) % 1024]
    Er, Ei = rot_fx(Xr, Xi, c, s)
    Fr = np.vstack([XTR[None, :], Er]); Fi = np.vstack([np.zeros((1, N), np.int64), Ei])
    tr, ti = fft_fx(Fr, Fi, inverse=True, scale=True)
    if phases is None: phases = nr_phases()
    if pc:
        cc = q14(np.cos(-phases)); ss = q14(np.sin(-phases))
        tr, ti = cmult_fx(tr, ti, cc[:, None], ss[:, None])
    out = []
    for l in range(NSYM):
        cpl = CP0 if l == 0 else CP
        x = tr[l] + 1j * ti[l]; out.append(np.concatenate([x[-cpl:], x]))
    return np.concatenate(out), dict(bI=bI, bQ=bQ, kq=kq, Xr=Xr, Xi=Xi)

def sym_starts():
    st = []; p = 0
    for l in range(NSYM):
        cpl = CP0 if l == 0 else CP; st.append(p + cpl); p += N + cpl
    return np.array(st)
STARTS = sym_starts()

def channel(x, snr_db, rng, phases=None, apply_nr=True, eps=0.0, mp=False, n0=0):
    y = x.astype(complex).copy()
    if apply_nr:
        if phases is None: phases = nr_phases()
        ph = np.zeros(len(y)); p = 0
        for l in range(NSYM):
            L = (CP0 if l == 0 else CP) + N; ph[p:p + L] = phases[l]; p += L
        y = y * np.exp(1j * ph)
    if mp:
        y2 = y.copy(); y2[3:] += 0.3 * np.exp(1j * np.pi / 4) * y[:-3]; y = y2
    if eps: y = y * np.exp(1j * 2 * np.pi * eps * (np.arange(len(y)) + n0) / N)
    ps = np.mean(np.abs(x) ** 2)
    if snr_db is not None:
        sig = np.sqrt(ps / 10 ** (snr_db / 10) / 2)
        y = y + sig * (rng.standard_normal(len(y)) + 1j * rng.standard_normal(len(y)))
    return np.round(y.real).astype(np.int64), np.round(y.imag).astype(np.int64)

def cfo_est(yr, yi, ncp=14, L=28):
    """CP correlation, 8-bit samples (sat8(r>>4)), last L samples of each CP."""
    q = lambda v: np.clip(v >> 4, -128, 127)
    S = 0
    for l in range(ncp):
        s0 = STARTS[l]
        n = np.arange(s0 - L, s0)
        a = q(yr[n]) - 1j * q(yi[n]); b = q(yr[n + N]) + 1j * q(yi[n + N])
        S += np.sum(a * b)
    return np.angle(S) / (2 * np.pi)

def rx_slot(yr, yi, info, chaos=True, eq=True, cfo=None, backoff=4, known_H=None):
    n = np.arange(len(yr))
    if cfo:
        ph = np.round(-cfo * n / N * 1024) % 1024                # 10-bit table phase
        c = LUT[((ph + 256) % 1024).astype(int)]; s = LUT[ph.astype(int)]
        yr, yi = rot_fx(yr, yi, c, s)
    bo = backoff if eq else 0
    idx = (STARTS - bo)[:, None] + np.arange(N)[None, :]
    Yr, Yi = fft_fx(yr[idx], yi[idx])
    Dr, Di = Yr[1:], Yi[1:]
    if eq:
        Ytr, Ytr_i = Yr[0], Yi[0]
        den = Ytr * Ytr + Ytr_i * Ytr_i
        def qdiv(num):
            mag = np.where(den > 0, (np.abs(num) << 14) // np.maximum(den, 1), 0)
            mag = np.minimum(mag, (1 << 17) - 1)
            return np.where(num < 0, -mag, mag)
        wr = qdiv(XTR * Ytr); wi = qdiv(-(XTR * Ytr_i))
        Dr, Di = rot_fx(Dr, Di, wr[None, :], wi[None, :])
    if known_H is not None:
        Z = (Dr + 1j * Di) / known_H[None, :]; Dr, Di = np.round(Z.real).astype(np.int64), np.round(Z.imag).astype(np.int64)
    if chaos:
        kq = info['kq']; c = LUT[(-8 * kq + 256) % 1024]; s = LUT[(-8 * kq) % 1024]
        Dr, Di = rot_fx(Dr, Di, c, s)
    return Dr, Di

def score(Dr, Di, info):
    eI = demap(Dr); eQ = demap(Di)
    bits = lambda v: np.stack([(v >> 1) & 1, v & 1])
    err = np.sum(bits(eI) != bits(info['bI'])) + np.sum(bits(eQ) != bits(info['bQ']))
    ref = info['Xr'] + 1j * info['Xi']; Z = Dr + 1j * Di
    evm2 = np.sum(np.abs(Z - ref) ** 2) / np.sum(np.abs(ref) ** 2)
    return err, 13 * N * 4, evm2
