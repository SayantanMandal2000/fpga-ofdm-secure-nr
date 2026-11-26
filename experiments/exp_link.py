from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
rng = np.random.default_rng(2026)
R = {}

def run(snr, nslot, eq=True, mp=False, eps=0.0, smooth=0):
    E = B = 0; S = 0.0
    for _ in range(nslot):
        tx, info = fx.tx_slot(rng)
        yr, yi = fx.channel(tx, snr, rng, mp=mp, eps=eps, n0=int(rng.integers(0, 10**6)))
        cfo = fx.cfo_est(yr, yi) if eps else None
        if smooth:
            # floating-point reference: LS estimate smoothed over 3 adjacent sub-carriers
            Dr, Di = fx.rx_slot(yr, yi, info, eq=False, cfo=cfo, chaos=False, backoff=4)
            n = np.arange(len(yr))
            if cfo:
                ph = np.round(-cfo * n / fx.N * 1024) % 1024
                yr2, yi2 = fx.rot_fx(yr, yi, fx.LUT[((ph + 256) % 1024).astype(int)], fx.LUT[ph.astype(int)])
            else: yr2, yi2 = yr, yi
            idx = (fx.STARTS - 4)[:, None] + np.arange(fx.N)[None, :]
            Yr, Yi = fx.fft_fx(yr2[idx], yi2[idx])
            H = (Yr[0] + 1j * Yi[0]) / fx.XTR
            kk = np.arange(fx.N); sl = np.angle(np.sum(H[1:] * np.conj(H[:-1])))
            Hd = H * np.exp(-1j * sl * kk)
            ker = np.ones(smooth); Hs = np.convolve(Hd, ker, 'same') / np.convolve(np.ones(fx.N), ker, 'same') * np.exp(1j * sl * kk)
            Z = (Yr[1:] + 1j * Yi[1:]) / Hs[None, :]
            kq = info['kq']; Z = Z * np.exp(-2j * np.pi * kq / 128)
            Dr, Di = np.round(Z.real).astype(np.int64), np.round(Z.imag).astype(np.int64)
        else:
            Dr, Di = fx.rx_slot(yr, yi, info, eq=eq, cfo=cfo)
        e, b, ev = fx.score(Dr, Di, info); E += e; B += b; S += ev
    return E / B, 100 * np.sqrt(S / nslot), B

snrs = np.arange(4, 31, 2)
cases = {'awgn_noeq': dict(eq=False), 'awgn_ls': dict(eq=True), 'awgn_sm7': dict(smooth=7), 'mp_cfo_ls': dict(eq=True, mp=True, eps=0.05), 'mp_cfo_sm7': dict(smooth=7, mp=True, eps=0.05)}
for name, kw in cases.items():
    R[name] = []
    for s in snrs:
        ns = n(40 if s < 12 else 150 if s < 18 else 300)
        ber, evm, bits = run(s, ns, **kw); R[name].append((float(s), ber, evm, bits))
    print(name, [(s, f'{b:.2e}') for s, b, _, _ in R[name]])

# EVM vs SNR, including the noise-free floor and the testbench SNR
snr2 = [20, 25, 30, 35, 38.8, 45, 50, None]
for name, kw in {'evm_noeq': dict(eq=False), 'evm_ls': dict(eq=True), 'evm_sm3': dict(smooth=3), 'evm_sm7': dict(smooth=7),
                 'evm_ls_mp': dict(eq=True, mp=True, eps=0.05)}.items():
    R[name] = [(s if s is not None else 99.0, run(s, n(30), **kw)[1]) for s in snr2]
    print(name, R[name])

# CFO estimator RMSE
R['cfo'] = []
for s in [0, 5, 10, 15, 20, 25, 30, 38.8]:
    e1 = []; e14 = []
    for _ in range(n(150)):
        tx, info = fx.tx_slot(rng)
        yr, yi = fx.channel(tx, s, rng, eps=0.05, n0=int(rng.integers(0, 10**6)))
        e1.append(fx.cfo_est(yr, yi, ncp=1) - 0.05); e14.append(fx.cfo_est(yr, yi, ncp=14) - 0.05)
    R['cfo'].append((s, float(np.sqrt(np.mean(np.square(e1)))), float(np.sqrt(np.mean(np.square(e14))))))
    print('cfo', R['cfo'][-1])
json.dump(R, open(RES / 'res_link.json', 'w'), indent=1)

# ------------- plots -------------
fig, ax = plt.subplots(figsize=(4.6, 3.3))
x = np.linspace(0, 22, 200); ax.semilogy(x, fx.ber16_theory(x), 'k-', lw=0.8, label='Theory, 16-QAM Gray, AWGN')
mk = {'awgn_noeq': ('o', 'Fixed-point model, ideal channel knowledge'), 'awgn_ls': ('s', 'Fixed-point model, LS one-tap equaliser'),
      'awgn_sm7': ('v', 'LS + 7-sub-carrier smoothing (float)'),
      'mp_cfo_ls': ('^', 'Multipath + CFO 0.05, CFO corr. + LS eq.'), 'mp_cfo_sm7': ('D', 'Multipath + CFO 0.05, LS + smoothing')}
for k, (m, lab) in mk.items():
    d = np.array([(s, b) for s, b, _, _ in R[k] if b > 0]); ax.semilogy(d[:, 0], d[:, 1], m + '--', mfc='none', lw=0.7, label=lab)
ax.set_xlabel(r'$E_s/N_0$ per sub-carrier (dB)'); ax.set_ylabel('Bit error ratio'); ax.set_ylim(1e-6, 0.4); ax.set_xlim(2, 30)
ax.legend(loc='lower left'); save(fig, 'ber_snr')

fig, ax = plt.subplots(figsize=(4.6, 3.1))
for k, m, lab in [('evm_noeq', 'o', 'Ideal channel knowledge'), ('evm_ls', 's', 'LS one-tap equaliser (RTL)'),
                  ('evm_sm3', 'd', 'LS + 3-sub-carrier smoothing'), ('evm_sm7', 'v', 'LS + 7-sub-carrier smoothing'), ('evm_ls_mp', '^', 'LS eq., multipath + CFO 0.05')]:
    d = np.array(R[k]); fin = d[:-1]; ax.semilogy(fin[:, 0], fin[:, 1], m + '-', mfc='none', lw=0.7, label=lab)
s = np.linspace(20, 50, 100); e0 = 100 / np.sqrt(10 ** (s / 10))
ax.semilogy(s, e0, 'k:', lw=0.8, label=r'Theory $1/\sqrt{\mathrm{SNR}}$')
ax.semilogy(s, e0 * np.sqrt(1 + 10 * 0.5556), 'k--', lw=0.6, label='Theory, LS equaliser')
ax.plot([38.8], [1.18], 'k*', ms=8, label='RTL, original (1.18 %)'); ax.plot([38.8], [3.07], 'r*', ms=8, label='RTL, updated (3.07 %)')
ax.set_xlabel('SNR per sample (dB)'); ax.set_ylabel('EVM (%)'); ax.legend(loc='upper right', fontsize=6.5)
save(fig, 'evm_snr')

fig, ax = plt.subplots(figsize=(4.6, 3.1))
d = np.array(R['cfo']); s = np.linspace(0, 40, 200); sn = 10 ** (s / 10)
th = lambda L: np.sqrt((1 / sn + 1 / (2 * sn ** 2)) / (4 * np.pi ** 2 * L))
ax.semilogy(d[:, 0], d[:, 1], 'o', mfc='none', label='Model, one CP (L = 28)')
ax.semilogy(d[:, 0], d[:, 2], 's', mfc='none', label='Model, 14 CPs (L = 392)')
ax.semilogy(s, th(28), 'k-', lw=0.7, label='Theory, L = 28'); ax.semilogy(s, th(392), 'k--', lw=0.7, label='Theory, L = 392')
ax.set_xlabel('SNR per sample (dB)'); ax.set_ylabel(r'RMSE of $\hat\varepsilon$ (sub-carrier spacings)'); ax.legend()
save(fig, 'cfo_rmse')
