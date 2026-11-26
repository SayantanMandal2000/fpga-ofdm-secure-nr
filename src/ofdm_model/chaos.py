"""Bit-exact model of lorenz_chaos.v / chaos_keystream.v and a NIST SP 800-22 test subset."""
import numpy as np
from scipy.special import gammaincc, erfc
M64 = (1 << 64) - 1; F = 20; RHO = 28 << F; BETA = 2796203
DP, DQ = 0x5052_4253_5F44_4F4D, 0x5141_4D5F_524F_5444

def xs64(v):
    t = (v ^ 0x9E3779B97F4A7C15) & M64
    for _ in range(4):
        t ^= (t << 13) & M64; t ^= t >> 7; t ^= (t << 17) & M64
    return t
def seed(key, dom):
    h = xs64(xs64((key & M64) ^ dom) ^ (key >> 64))
    return (1 << F) + (h & 0xFFFFF), (1 << F) + ((h >> 20) & 0xFFFFF), (20 << F) + ((h >> 40) & 0xFFFFF)
def s32(v): return ((v + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)
def step(x, y, z):
    pxy = x * y; pxr = x * (RHO - z); pbz = z * BETA
    dx = 10 * (y - x); dy = (pxr >> F) - y; dz = (pxy >> F) - (pbz >> F)
    return s32(x + (dx >> 7)), s32(y + (dy >> 7)), s32(z + (dz >> 7))
def byte(x, y, z):
    return ((x >> 4) & 0xFF) ^ ((y >> 6) & 0xFF) ^ ((z >> 2) & 0xFF) ^ ((((x >> 16) & 0xF) << 4) | ((y >> 16) & 0xF))
def streams(keys, dom, n):
    S = np.array([seed(k, dom) for k in keys], dtype=np.int64).T
    x, y, z = S[0].copy(), S[1].copy(), S[2].copy(); out = np.zeros((len(keys), n), np.int64)
    for i in range(n):
        x, y, z = step(x, y, z); out[:, i] = byte(x, y, z)
    return out


# ---------------- statistical tests (NIST SP 800-22 subset) ----------------
def bits_of(stream, nb):
    return ((stream[:, None] >> np.arange(nb)[None, :]) & 1).ravel()
def t_monobit(b): n = len(b); s = abs(np.sum(2 * b - 1)) / np.sqrt(n); return erfc(s / np.sqrt(2))
def t_block(b, M=128):
    nb = len(b) // M; p = b[:nb * M].reshape(nb, M).mean(1); return gammaincc(nb / 2, 4 * M * np.sum((p - 0.5) ** 2) / 2)
def t_runs(b):
    n = len(b); pi = b.mean()
    if abs(pi - 0.5) >= 2 / np.sqrt(n): return 0.0
    v = 1 + np.sum(b[1:] != b[:-1]); return erfc(abs(v - 2 * n * pi * (1 - pi)) / (2 * np.sqrt(2 * n) * pi * (1 - pi)))
def t_cusum(b):
    from scipy.stats import norm
    x = 2 * b - 1; n = len(x); z = np.max(np.abs(np.cumsum(x)))
    k1 = np.arange(int((-n / z + 1) // 4), int((n / z - 1) // 4) + 1)
    k2 = np.arange(int((-n / z - 3) // 4), int((n / z - 1) // 4) + 1)
    p = 1 - np.sum(norm.cdf((4 * k1 + 1) * z / np.sqrt(n)) - norm.cdf((4 * k1 - 1) * z / np.sqrt(n))) \
          + np.sum(norm.cdf((4 * k2 + 3) * z / np.sqrt(n)) - norm.cdf((4 * k2 + 1) * z / np.sqrt(n)))
    return float(p)
def phi(b, m):
    if m == 0: return 0.0
    n = len(b); e = np.concatenate([b, b[:m - 1]]); v = np.zeros(n, np.int64)
    for i in range(m): v = (v << 1) | e[i:i + n]
    c = np.bincount(v, minlength=2 ** m) / n; c = c[c > 0]; return np.sum(c * np.log(c))
def t_apen(b, m=6):
    n = len(b); ap = phi(b, m) - phi(b, m + 1); return gammaincc(2 ** (m - 1), 2 * n * (np.log(2) - ap) / 2)
def psi2(b, m):
    if m <= 0: return 0.0
    n = len(b); e = np.concatenate([b, b[:m - 1]]); v = np.zeros(n, np.int64)
    for i in range(m): v = (v << 1) | e[i:i + n]
    c = np.bincount(v, minlength=2 ** m); return 2 ** m / n * np.sum(c.astype(float) ** 2) - n
def t_serial(b, m=5):
    d1 = psi2(b, m) - psi2(b, m - 1); return gammaincc(2 ** (m - 2), d1 / 2)
TESTS = [('Frequency (monobit)', t_monobit), ('Block frequency, M = 128', t_block), ('Runs', t_runs),
         ('Cumulative sums', t_cusum), ('Approximate entropy, m = 6', t_apen), ('Serial, m = 5', t_serial)]

