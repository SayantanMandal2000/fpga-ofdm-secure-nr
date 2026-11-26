from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
rng = np.random.default_rng(7)
N = fx.N
metrics, finder = sync.metrics, sync.finder
TH = sync.TH

def trial(snr, mp, eps, acq):
    a, _ = fx.tx_slot(rng); b, _ = fx.tx_slot(rng)
    x = np.concatenate([a, b])
    yr, yi = fx.channel(x, snr, rng, apply_nr=False, mp=mp, eps=eps)
    dtrue = fx.SLOT                      # window start of slot-2 training = first sample of its CP? use body start
    dtrue = fx.SLOT + fx.CP0
    m0, m1, R = metrics(yr, yi)
    start = dtrue - (1500 if acq else 32)
    out = []
    for ms, th in ((m0, TH[0]), (m1, TH[1])):
        d = finder(ms, R, th, start)
        out.append(None if d is None else d - dtrue)
    return out

snrs = [0, 3, 6, 9, 12, 15, 20, 25, 30, 38.8]
res = {}
for chan, (mp, eps) in {'awgn': (False, 0.0), 'mp_cfo': (True, 0.05)}.items():
    for acq in (False, True):
        key = f'{chan}_{"acq" if acq else "trk"}'; res[key] = []
        for s in snrs:
            T = n(120)
            r = [trial(s, mp, eps, acq) for _ in range(T)]
            row = [s]
            for j in (0, 1):
                e = [x[j] for x in r]
                exact = np.mean([v == 0 for v in e]); near = np.mean([v is not None and abs(v) <= 2 for v in e])
                early = np.mean([v is not None and v < -16 for v in e]); miss = np.mean([v is None or v > 16 for v in e])
                row += [float(exact), float(near), float(early), float(miss)]
            res[key].append(row); print(key, row, flush=True)
json.dump(res, open(RES / 'res_sync.json', 'w'), indent=1)

fig, axs = plt.subplots(1, 2, figsize=(6.4, 2.7), sharey=True)
for ax, chan, ttl in zip(axs, ('awgn', 'mp_cfo'), ('(a) AWGN', '(b) multipath + CFO 0.05')):
    for acq, ls in ((False, '-'), (True, '--')):
        d = np.array(res[f'{chan}_{"acq" if acq else "trk"}'])
        tag = 'acquisition' if acq else 'tracking'
        ax.plot(d[:, 0], d[:, 2], 'o' + ls, mfc='none', lw=0.7, label=f'$M_0$ sign-bit, {tag}')
        ax.plot(d[:, 0], d[:, 6], 's' + ls, mfc='none', lw=0.7, label=f'$M_1$ $|P|^2$, {tag}')
    ax.set_title(ttl); ax.set_xlabel('SNR per sample (dB)'); ax.set_ylim(-0.03, 1.03)
axs[0].set_ylabel(r'$P(|\hat d-d|\leq 2)$'); axs[1].legend(fontsize=6.3, loc='lower right')
fig.tight_layout(); save(fig, 'sync_pd')
