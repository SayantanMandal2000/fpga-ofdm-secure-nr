from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
rng = np.random.default_rng(5)
R = {}
ph0 = fx.nr_phases(3.5e9)
def per_sym(df, pc=True, snr=38.8, eq=True, n=n(20), chan_off=0.0):
    ev = np.zeros(13); E = B = 0
    for _ in range(n):
        tx, info = fx.tx_slot(rng, pc=pc, phases=fx.nr_phases(3.5e9 + df))
        yr, yi = fx.channel(tx, snr, rng, phases=ph0 + chan_off)
        Dr, Di = fx.rx_slot(yr, yi, info, eq=eq)
        ref = info['Xr'] + 1j * info['Xi']; Z = Dr + 1j * Di
        ev += np.sum(np.abs(Z - ref) ** 2, 1) / np.sum(np.abs(ref) ** 2, 1)
        e, b, _ = fx.score(Dr, Di, info); E += e; B += b
    return 100 * np.sqrt(ev / n), E / B
R['df'] = {}
for df in [0, 10, 30, 100]:
    e, b = per_sym(df); R['df'][str(df)] = dict(evm=e.tolist(), ber=b); print(df, np.round(e, 2), b)
e, b = per_sym(0, pc=False); R['pc_off_eq'] = dict(evm=e.tolist(), ber=b); print('pc off', np.round(e, 1), b)
# slot-to-slot phase step when f0*T_slot is not an integer (0.5 cycle -> pi)
for eq in (True, False):
    e, b = per_sym(0, chan_off=np.pi, eq=eq, n=max(2, n(10))); R[f'slotstep_eq{int(eq)}'] = dict(evm=float(np.sqrt(np.mean(e ** 2))), ber=b)
    print('slot step pi, eq', eq, R[f'slotstep_eq{int(eq)}'])
# Q2.14 quantisation of the 14 coefficients
c = fx.q14(np.cos(-ph0)); s = fx.q14(np.sin(-ph0)); z = (c + 1j * s) / 16384
R['quant'] = dict(max_phase_deg=float(np.max(np.abs(np.angle(z * np.exp(1j * ph0)))) * 180 / np.pi),
                  max_mag_err=float(np.max(np.abs(np.abs(z) - 1))))
print(R['quant'])
# theory: symbol phase error with f0 mismatch, relative to symbol 0
Ts = 0.5e-3 / fx.SLOT
tl = np.array([fx.STARTS[l] for l in range(14)]) * Ts
R['tl_us'] = (tl * 1e6).tolist()
json.dump(R, open(RES / 'res_pc.json', 'w'), indent=1)
fig, ax = plt.subplots(figsize=(4.6, 2.9)); l = np.arange(1, 14)
for df, m in zip([0, 10, 30, 100], 'osd^'):
    ax.semilogy(l, R['df'][str(df)]['evm'], m + '-', mfc='none', lw=0.7, label=f'$\\Delta f_0$ = {df} Hz (model)')
    if df:
        th = 100 * 2 * np.abs(np.sin(np.pi * df * (tl[1:] - tl[0])))
        ax.semilogy(l, np.sqrt(th ** 2 + R['df']['0']['evm'][0] ** 2), 'k:', lw=0.6)
ax.semilogy(l, R['pc_off_eq']['evm'], 'x--', color='0.3', lw=0.7, label='compensation off (LS eq. on)')
ax.set_xlabel(r'OFDM symbol index $l$'); ax.set_ylabel('EVM (%)'); ax.set_xticks(l); ax.legend(fontsize=6.5, loc='center right')
save(fig, 'pc_mismatch')
