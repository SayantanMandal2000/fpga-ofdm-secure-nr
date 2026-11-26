from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
from scipy.stats import chi2  # noqa: E402
from ofdm_model.chaos import *  # noqa: F401,F403,E402
rng = np.random.default_rng(11)
def rkey(): return int(rng.integers(0, 2**63)) | (int(rng.integers(0, 2**63)) << 64) | (int(rng.integers(0, 2)) << 127)
R = {}

NK = n(10); NB = n(65536, 4096)
keys = [rkey() for _ in range(NK)]
SP = streams(keys, DP, NB); SQ = streams(keys, DQ, NB)
R['tests'] = {}
for nm, f in TESTS:
    pp = [f(bits_of(SP[i] & 0xF, 4)) for i in range(NK)]; pq = [f(bits_of(SQ[i] & 0x7F, 7)) for i in range(NK)]
    R['tests'][nm] = dict(P=[float(v) for v in pp], Q=[float(v) for v in pq])
    print(nm, 'P pass', sum(v >= 0.01 for v in pp), 'min p %.3g' % min(pp), '| Q pass', sum(v >= 0.01 for v in pq), 'min p %.3g' % min(pq), flush=True)
# chi-square uniformity of symbols
cp = [chi2.sf(np.sum((np.bincount(SP[i] & 0xF, minlength=16) - NB / 16) ** 2 / (NB / 16)), 15) for i in range(NK)]
cq = [chi2.sf(np.sum((np.bincount(SQ[i] & 0x7F, minlength=128) - NB / 128) ** 2 / (NB / 128)), 127) for i in range(NK)]
R['chi'] = dict(P=[float(v) for v in cp], Q=[float(v) for v in cq]); print('chi P', np.round(cp, 3), 'chi Q', np.round(cq, 3))
# autocorrelation / cross-correlation
b = 2 * bits_of(SP[0] & 0xF, 4) - 1.0; NACF = len(b); bq = 2 * bits_of(SQ[0] & 0x7F, 7)[:len(b)] - 1.0
ac = [float(np.mean(b[:-k] * b[k:])) for k in range(1, 257)]
xc = float(np.mean(b * bq)); R['autocorr_max'] = float(np.max(np.abs(ac))); R['xcorr'] = xc
R['autocorr'] = ac; print('max |autocorr| lag1..256', R['autocorr_max'], 'P-Q xcorr', xc, 'bound 3/sqrt(n)', 3 / np.sqrt(len(b)))
R['nbits'] = dict(P=NB * 4, Q=NB * 7)

# ---------------- key sensitivity ----------------
K0 = keys[0]; L = 13 * 128
flips = [K0 ^ (1 << i) for i in range(128)]
P0 = streams([K0], DP, L)[0]; Q0 = streams([K0], DQ, L)[0]
PF = streams(flips, DP, L); QF = streams(flips, DQ, L)
hp = [np.mean(bits_of(PF[i] & 0xF, 4) != bits_of(P0 & 0xF, 4)) for i in range(128)]
hq = [np.mean(bits_of(QF[i] & 0x7F, 7) != bits_of(Q0 & 0x7F, 7)) for i in range(128)]
first = [int(np.argmax((PF[i] != P0) | (QF[i] != Q0))) for i in range(128)]
R['avalanche'] = dict(P=[float(min(hp)), float(np.mean(hp)), float(max(hp))], Q=[float(min(hq)), float(np.mean(hq)), float(max(hq))], first_max=int(max(first)))
print('avalanche', R['avalanche'])

# ---------------- Lyapunov exponent of the fixed-point map ----------------
NL = n(128, 16); T = 4000
S = np.array([seed(k, DP) for k in [rkey() for _ in range(NL)]], dtype=np.int64).T
x, y, z = S[0].copy(), S[1].copy(), S[2].copy()
for _ in range(2000): x, y, z = step(x, y, z)           # move onto the attractor
x2, y2, z2 = x + 1, y.copy(), z.copy()
LG = []; BD = []
for t in range(T):
    x, y, z = step(x, y, z); x2, y2, z2 = step(x2, y2, z2)
    d = np.sqrt(((x - x2) ** 2 + (y - y2) ** 2 + (z - z2) ** 2).astype(float)) / 2 ** F
    LG.append(np.log2(np.maximum(d, 2.0 ** -21))); BD.append(byte(x, y, z) != byte(x2, y2, z2))
LG = np.array(LG); BD = np.array(BD)
merged = LG[-1] < -20.5
surv = ~merged
t1 = np.argmax(LG[:, surv] > -16, axis=0); t2 = np.argmax(LG[:, surv] > -4, axis=0)
ok = t2 > t1
lam_bits = 12.0 / np.median(t2[ok] - t1[ok])
R['lyap'] = dict(bits_per_step=float(lam_bits), per_time=float(lam_bits * np.log(2) * 128),
                 merged_frac=float(merged.mean()), merged_by_slot=float((LG[1663] < -20.5).mean()), n=NL)
R['byte_diverge_step'] = int(np.median(np.argmax(BD[:, surv], axis=0)))
print('lyapunov', R['lyap'], 'byte diverge median step', R['byte_diverge_step'])
tt = np.arange(1, T + 1); sep = np.median(LG[:, surv], axis=1)
lo = int(np.argmax(sep > -16)); hi = int(np.argmax(sep > -4))
# ---------------- cycle search (Brent) ----------------
NC = 32; TC = n(1 << 18, 4096)
S = np.array([seed(k, DQ) for k in [rkey() for _ in range(NC)]], dtype=np.int64).T
x, y, z = S[0].copy(), S[1].copy(), S[2].copy(); sx, sy, sz = x.copy(), y.copy(), z.copy()
found = np.zeros(NC, bool); power = 1; lam = 0
for t in range(1, TC + 1):
    x, y, z = step(x, y, z); lam += 1
    found |= (x == sx) & (y == sy) & (z == sz)
    if lam == power: sx, sy, sz = x.copy(), y.copy(), z.copy(); power *= 2; lam = 0
R['cycle'] = dict(keys=NC, steps=TC, cycles_found=int(found.sum())); print('cycle', R['cycle'])

# ---------------- key-stream reuse across slots: known-plaintext attack ----------------
GR = np.array([-3, -1, 3, 1]); PTS = np.array([GR[c >> 2] + 1j * GR[c & 3] for c in range(16)])
TH = np.exp(2j * np.pi * np.arange(128) / 128)
CAND = PTS[None, :, None] * TH[None, None, :]             # (1,16 masks... ) built below
def encrypt(bits, m, q): return PTS[bits ^ m] * TH[q]
NPOS = 128 * 13
m = rng.integers(0, 16, NPOS); q = rng.integers(0, 128, NPOS)
res = []
for reuse in (True, False):
    alive = np.ones((NPOS, 16, 128), bool)
    known_counts = []
    for s in range(4):
        b = rng.integers(0, 16, NPOS)
        mm, qq = (m, q) if reuse else (rng.integers(0, 16, NPOS), rng.integers(0, 128, NPOS))
        c = encrypt(b, mm, qq)
        if s < 3:      # Eve knows this slot's plaintext: keep (m', q') consistent with it
            pred = PTS[(b[:, None] ^ np.arange(16)[None, :])][:, :, None] * TH[None, None, :]
            alive &= np.abs(pred - c[:, None, None]) < 1e-6
            known_counts.append(float(alive.sum(axis=(1, 2)).mean()))
        else:          # decrypt an unknown slot with the first surviving candidate
            idx = alive.reshape(NPOS, -1).argmax(1); mg, qg = idx // 128, idx % 128
            z = c * np.conj(TH[qg]); dec = np.array([np.argmin(np.abs(PTS - v)) for v in z]) ^ mg
            ber = np.mean(((dec[:, None] >> np.arange(4)) & 1) != ((b[:, None] >> np.arange(4)) & 1))
    res.append(dict(reuse=reuse, candidates=known_counts, eve_ber=float(ber)))
R['reuse'] = res; print('reuse attack', res)
json.dump(R, open(RES / 'res_chaos.json', 'w'), indent=1)

fig, ax = plt.subplots(1, 2, figsize=(6.4, 2.5))
ax[0].plot(tt, sep, 'k-', lw=0.7); ax[0].plot(tt[lo:hi], np.polyval(np.polyfit(tt[lo:hi], sep[lo:hi], 1), tt[lo:hi]), 'r--', lw=0.8)
ax[0].set_xlabel('Euler step'); ax[0].set_ylabel(r'median $\log_2\|\delta\|$'); ax[0].set_title('(a) divergence of a 1-LSB perturbation')
ax[1].bar(np.arange(1, 129), np.array(hq), color='0.4', width=1.0, label='stream Q (7 bits)')
ax[1].plot(np.arange(1, 129), hp, 'k.', ms=2, label='stream P (4 bits)')
ax[1].axhline(0.5, color='r', lw=0.6, ls='--'); ax[1].set_ylim(0.4, 0.6); ax[1].set_xlabel('flipped key bit'); ax[1].set_ylabel('fraction of changed bits')
ax[1].set_title('(b) key sensitivity (first slot)'); ax[1].legend(fontsize=6.5, loc='lower right')
fig.tight_layout(); save(fig, 'chaos_sens')
fig, ax = plt.subplots(figsize=(4.6, 2.2))
ax.plot(np.arange(1, 257), ac, 'k-', lw=0.5); ax.axhline(3 / np.sqrt(NACF), color='r', ls='--', lw=0.6, label=r'$\pm 3/\sqrt{n}$'); ax.axhline(-3 / np.sqrt(NACF), color='r', ls='--', lw=0.6); ax.legend(fontsize=7)
ax.set_xlabel('lag (bits)'); ax.set_ylabel('autocorrelation'); save(fig, 'chaos_acf')
