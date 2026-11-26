from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
metrics, finder = sync.metrics, sync.finder
rng = np.random.default_rng(31)
R = {}
N = fx.N

# ---------- (a) timing-offset tolerance ----------
def run_off(off, snr, mp, n=n(12)):
    S = 0.0
    for _ in range(n):
        tx, info = fx.tx_slot(rng); tx2, _ = fx.tx_slot(rng)
        yr, yi = fx.channel(np.concatenate([tx, tx2[:64]]), snr, rng, mp=mp)
        st0 = fx.STARTS.copy()
        fx.STARTS = st0 + off
        try:
            Dr, Di = fx.rx_slot(yr, yi, info, eq=True, backoff=0)
        finally:
            fx.STARTS = st0
        S += fx.score(Dr, Di, info)[2]
    return 100 * np.sqrt(S / n)
offs = list(range(-40, 9, 2))
R['toff'] = {f'{"mp" if mp else "awgn"}': [run_off(o, 30, mp) for o in offs] for mp in (False, True)}
R['toff_x'] = offs; print('toff', R['toff'])

# ---------- (b) CFO range with and without correction ----------
epss = [-0.45, -0.3, -0.2, -0.1, -0.05, -0.02, 0, 0.02, 0.05, 0.1, 0.2, 0.3, 0.45]
def run_cfo(eps, corr, n=n(8)):
    S = 0.0; E = B = 0
    for _ in range(n):
        tx, info = fx.tx_slot(rng)
        yr, yi = fx.channel(tx, 30, rng, eps=eps, n0=int(rng.integers(0, 10**6)))
        c = fx.cfo_est(yr, yi) if corr else None
        Dr, Di = fx.rx_slot(yr, yi, info, eq=True, cfo=c)
        e, b, ev = fx.score(Dr, Di, info); S += ev; E += e; B += b
    return 100 * np.sqrt(S / n), E / B
R['cfo_x'] = epss
R['cfo_corr'] = [run_cfo(e, True) for e in epss]; R['cfo_nocorr'] = [run_cfo(e, False) for e in epss]
print('cfo corr', R['cfo_corr']); print('cfo nocorr', R['cfo_nocorr'])

# ---------- (c) word-length study ----------
def fft_w(xr, xi, inverse, scale, W, TF):
    tw = np.arange(64)
    TC = np.round(np.cos(2 * np.pi * tw / N) * 2 ** TF).astype(np.int64); TS = np.round(np.sin(2 * np.pi * tw / N) * 2 ** TF).astype(np.int64)
    lo, hi = -(1 << (W - 1)), (1 << (W - 1)) - 1
    re = np.asarray(xr, np.int64)[:, fx.BR].copy(); im = np.asarray(xi, np.int64)[:, fx.BR].copy()
    for top, bot, ti in fx._plan:
        wc = TC[ti]; ws = TS[ti] if inverse else -TS[ti]
        ar, ai, br, bi = re[:, top], im[:, top], re[:, bot], im[:, bot]
        tre = fx.conv_rnd(br * wc - bi * ws, TF); tim = fx.conv_rnd(br * ws + bi * wc, TF)
        out = []
        for v in (ar + tre, ai + tim, ar - tre, ai - tim):
            if scale: v = (v + ((v >> 1) & 1)) >> 1
            out.append(np.clip(v, lo, hi))
        re[:, top], im[:, top], re[:, bot], im[:, bot] = out
    return re, im
def wl_evm(W, TF, snr, n=n(10)):
    sc = 2.0 ** (W - 16); A = 2048 * sc; S = 0.0
    for _ in range(n):
        bI = rng.integers(0, 4, (13, N)); bQ = rng.integers(0, 4, (13, N))
        Xr = np.round(fx.GRAY[bI] * A).astype(np.int64); Xi = np.round(fx.GRAY[bQ] * A).astype(np.int64)
        tr, ti = fft_w(Xr, Xi, True, True, W, TF)
        x = tr + 1j * ti
        ps = np.mean(np.abs(x) ** 2)
        if snr is not None:
            sg = np.sqrt(ps / 10 ** (snr / 10) / 2); x = x + sg * (rng.standard_normal(x.shape) + 1j * rng.standard_normal(x.shape))
        yr, yi = np.round(x.real).astype(np.int64), np.round(x.imag).astype(np.int64)
        Yr, Yi = fft_w(yr, yi, False, False, W, TF)
        ref = Xr + 1j * Xi; S += np.sum(np.abs(Yr + 1j * Yi - ref) ** 2) / np.sum(np.abs(ref) ** 2)
    return 100 * np.sqrt(S / n)
R['wl'] = {}
for W in (10, 12, 14, 16, 18):
    R['wl'][W] = {TF: (wl_evm(W, TF, None), wl_evm(W, TF, 38.8)) for TF in (8, 10, 12, 14)}
    print('W', W, {k: (round(a, 3), round(b, 3)) for k, (a, b) in R['wl'][W].items()})

# ---------- (d) CP-correlator quantisation ----------
def cfo_sh(yr, yi, SH, BITS):
    lim = 1 << (BITS - 1)
    q = lambda v: np.clip(v >> SH, -lim, lim - 1)
    Ssum = 0
    for l in range(14):
        s0 = fx.STARTS[l]; n = np.arange(s0 - 28, s0)
        Ssum += np.sum((q(yr[n]) - 1j * q(yi[n])) * (q(yr[n + N]) + 1j * q(yi[n + N])))
    return np.angle(Ssum) / (2 * np.pi)
R['cpq'] = {}
for BITS, SH in ((4, 8), (6, 6), (8, 4), (10, 2), (12, 0)):
    e = []
    for _ in range(n(80)):
        tx, info = fx.tx_slot(rng); yr, yi = fx.channel(tx, 38.8, rng, eps=0.05, n0=int(rng.integers(0, 10**6)))
        e.append(cfo_sh(yr, yi, SH, BITS) - 0.05)
    R['cpq'][BITS] = float(np.sqrt(np.mean(np.square(e)))); print('cp bits', BITS, R['cpq'][BITS])

# ---------- (e) threshold ROC for the timing metrics ----------
def roc(snr, n=n(60)):
    th0 = np.arange(60, 127, 4); th1 = np.array([1, 1.5, 2, 2.5, 3, 3.5, 3.8, 4.5, 5, 6, 7]) * 1e5
    det0 = np.zeros(len(th0)); fal0 = np.zeros(len(th0)); det1 = np.zeros(len(th1)); fal1 = np.zeros(len(th1))
    for _ in range(n):
        a, _ = fx.tx_slot(rng); b, _ = fx.tx_slot(rng)
        yr, yi = fx.channel(np.concatenate([a, b]), snr, rng, apply_nr=False)
        m0, m1, Rr = metrics(yr, yi); d = fx.SLOT + fx.CP0
        for arr, ths, det, fal in ((m0, th0, det0, fal0), (m1, th1, det1, fal1)):
            for i, th in enumerate(ths):
                dd = finder(arr, Rr, th, d - 1500)
                if dd is not None and abs(dd - d) <= 2: det[i] += 1
                elif dd is not None and dd - d < -16: fal[i] += 1
    return dict(th0=th0.tolist(), det0=(det0 / n).tolist(), fal0=(fal0 / n).tolist(),
                th1=th1.tolist(), det1=(det1 / n).tolist(), fal1=(fal1 / n).tolist())
R['roc'] = {s: roc(s) for s in (9, 15)}
for s, v in R['roc'].items(): print('roc', s, v)
json.dump(R, open(RES / 'res_dse.json', 'w'), indent=1, default=float)

# ---------- plots ----------
fig, ax = plt.subplots(figsize=(4.6, 2.8))
ax.semilogy(offs, R['toff']['awgn'], 'o-', mfc='none', label='AWGN'); ax.semilogy(offs, R['toff']['mp'], 's-', mfc='none', label='2-tap multipath (delay 3)')
ax.axvspan(-32, 0, color='0.9', zorder=0); ax.text(-16, 40, 'inside CP', ha='center', fontsize=7)
ax.set_xlabel(r'FFT window offset $\Delta$ (samples, negative = early)'); ax.set_ylabel('EVM (%) at 30 dB'); ax.legend()
save(fig, 'timing_offset')
fig, ax = plt.subplots(figsize=(4.6, 2.8))
ax.semilogy(epss, [v[0] for v in R['cfo_corr']], 'o-', mfc='none', label='with 14-CP CFO correction')
ax.semilogy(epss, [v[0] for v in R['cfo_nocorr']], 's--', mfc='none', label='without correction (LS eq. only)')
ax.set_xlabel(r'CFO $\varepsilon$ (sub-carrier spacings)'); ax.set_ylabel('EVM (%) at 30 dB'); ax.legend()
save(fig, 'cfo_range')
fig, ax = plt.subplots(figsize=(4.6, 2.8))
for TF, m in zip((8, 10, 12, 14), 'osd^'):
    ax.semilogy([10, 12, 14, 16, 18], [R['wl'][W][TF][0] for W in (10, 12, 14, 16, 18)], m + '-', mfc='none', label=f'twiddle {TF} fraction bits, noise-free')
ax.semilogy([10, 12, 14, 16, 18], [R['wl'][W][14][1] for W in (10, 12, 14, 16, 18)], 'k*--', label='twiddle 14 bits, SNR 38.8 dB')
ax.set_xlabel('FFT data word length W (bits)'); ax.set_ylabel('EVM (%)'); ax.legend(fontsize=6.5)
save(fig, 'wordlength')
fig, axs = plt.subplots(1, 2, figsize=(6.4, 2.6))
for ax, key, xl in ((axs[0], '0', r'threshold $TH_0$'), (axs[1], '1', r'threshold $TH_1$ ($\times10^5$)')):
    for s, ls in ((9, '-'), (15, '--')):
        v = R['roc'][s]; x = np.array(v['th' + key]) / (1e5 if key == '1' else 1)
        ax.plot(x, v['det' + key], 'o' + ls, mfc='none', ms=3, lw=0.7, label=f'correct, {s} dB')
        ax.plot(x, v['fal' + key], 'x' + ls, ms=3, lw=0.7, label=f'false (early), {s} dB')
    ax.axvline(88 if key == '0' else 3.8, color='r', lw=0.6, ls=':')
    ax.set_xlabel(xl); ax.set_ylim(-0.03, 1.03)
axs[0].set_ylabel('probability (acquisition)'); axs[0].set_title('(a) sign-bit metric $M_0$'); axs[1].set_title(r'(b) $|P|^2$ metric $M_1$')
axs[1].legend(fontsize=6, loc='center right'); fig.tight_layout(); save(fig, 'threshold_roc')
