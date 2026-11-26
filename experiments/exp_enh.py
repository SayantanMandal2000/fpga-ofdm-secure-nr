from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
metrics, finder = sync.metrics, sync.finder
qmetrics = sync.qmetrics
rng = np.random.default_rng(77)
N = fx.N; R = {}

def gen(snr, mp, eps, gain_db=0.0):
    a, _ = fx.tx_slot(rng); b, _ = fx.tx_slot(rng)
    x = np.concatenate([a, b]) * 10 ** (gain_db / 20)
    return fx.channel(x, snr, rng, apply_nr=False, mp=mp, eps=eps)

# nominal normalised threshold: same ratio as TH1 at the nominal received power
yr, yi = gen(None, False, 0.0); m1, Rq = qmetrics(yr, yi)
d = fx.SLOT + fx.CP0; Rnom = np.median(Rq[d - 1500:d + 1500])
THN = 380000 / Rnom ** 2; R['thn'] = float(THN); R['Rnom'] = float(Rnom); print('normalised threshold', THN, Rnom)

def finder_n(m1, Rq, Rgate, start, th):
    ratio = m1 / np.maximum(Rq, 1) ** 2
    return finder(ratio, Rgate, th, start)

gains = [-9, -6, -3, 0, 3, 6, 9]
R['gain'] = []
for g in gains:
    cf = cn = ff = fn = 0; T = n(60)
    for _ in range(T):
        yr, yi = gen(15, True, 0.05, g); m0, m1, Rg = metrics(yr, yi); m1q, Rq = qmetrics(yr, yi)
        start = d - 1500
        a = finder(m1, Rg, 380000, start); b = finder_n(m1q, Rq, Rg, start, THN)
        cf += a is not None and abs(a - d) <= 2; ff += a is not None and a - d < -16
        cn += b is not None and abs(b - d) <= 2; fn += b is not None and b - d < -16
    R['gain'].append([g, cf / T, ff / T, cn / T, fn / T]); print('gain', R['gain'][-1], flush=True)

snrs = [6, 9, 12, 15, 20]
R['th0'] = {}
for th in (88, 76):
    R['th0'][th] = []
    for s in snrs:
        ok = fl = 0; T = n(80)
        for _ in range(T):
            yr, yi = gen(s, True, 0.05); m0, m1, Rg = metrics(yr, yi)
            a = finder(m0, Rg, th, d - 1500); ok += a is not None and -24 <= a - d <= 4; fl += a is not None and a - d < -24
        R['th0'][th].append([s, ok / T, fl / T]); print('th0', th, R['th0'][th][-1], flush=True)
json.dump(R, open(RES / 'res_enh.json', 'w'), indent=1)

L = json.load(open(RES / 'res_link.json'))
fig, axs = plt.subplots(1, 2, figsize=(6.4, 2.7))
ax = axs[0]
for k, m, lab in (('mp_cfo_ls', '^--', 'baseline (LS)'), ('mp_cfo_sm7', 'D-', 'enhanced (LS + smoothing)')):
    dd = np.array([(s, b) for s, b, _, _ in L[k] if b > 0]); ax.semilogy(dd[:, 0], dd[:, 1], m, mfc='none', lw=0.7, label=lab)
ax.set_xlabel(r'$E_s/N_0$ (dB)'); ax.set_ylabel('BER'); ax.set_title('(a) BER, multipath + CFO 0.05'); ax.legend(fontsize=6.5); ax.set_ylim(1e-5, 0.5)
ax = axs[1]
for th, m, lab in ((88, 'o--', 'baseline $TH_0$ = 88'), (76, 's-', 'enhanced $TH_0$ = 76')):
    v = np.array(R['th0'][th]); ax.plot(v[:, 0], v[:, 1], m, mfc='none', lw=0.7, label=lab)
ax.set_xlabel('SNR (dB)'); ax.set_ylabel('P(usable lock)'); ax.set_title('(b) acquisition, multipath + CFO'); ax.legend(fontsize=6.5); ax.set_ylim(-0.03, 1.03)
fig.tight_layout(); save(fig, 'enh_compare')
fig, ax = plt.subplots(figsize=(4.6, 2.7)); v = np.array(R['gain'])
ax.plot(v[:, 0], v[:, 1], 'o--', mfc='none', label=r'fixed $TH_1$, correct'); ax.plot(v[:, 0], v[:, 2], 'x--', label=r'fixed $TH_1$, false')
ax.plot(v[:, 0], v[:, 3], 's-', mfc='none', label=r'normalised $|P|^2/R_q^2$, correct'); ax.plot(v[:, 0], v[:, 4], '+-', label='normalised, false')
ax.set_xlabel('receiver gain relative to design (dB)'); ax.set_ylabel('probability'); ax.set_ylim(-0.03, 1.03); ax.legend(fontsize=6.3)
save(fig, 'gain_norm')
