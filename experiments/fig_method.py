from _common import RES, chaos, fx, json, n, np, plt, save, sync  # noqa: F401
from matplotlib.patches import FancyBboxPatch
fig, ax = plt.subplots(figsize=(6.6, 2.7)); ax.set_xlim(0, 100); ax.set_ylim(0, 46); ax.axis('off')
def box(x, y, w, h, t, fc='#E8EEF7'):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0.4,rounding_size=1.2', fc=fc, ec='0.25', lw=0.7))
    ax.text(x + w / 2, y + h / 2, t, ha='center', va='center', fontsize=7.2)
def arr(x1, y1, x2, y2, t=''):
    ax.annotate('', xy=(x2, y2), xytext=(x1, y1), arrowprops=dict(arrowstyle='->', lw=0.7, color='0.2'))
    if t: ax.text((x1 + x2) / 2, (y1 + y2) / 2 + 1.2, t, ha='center', fontsize=6.2, style='italic')
Y = 27; H = 10
box(1, Y, 15, H, 'Reference paper\n+ three primary\nworks', '#F3F3F3')
box(21, Y, 15, H, 'Analysis\n(closed-form\nbounds, Ch. 3)')
box(41, Y, 17, H, 'Bit-accurate\nPython models\n(word lengths)')
box(63, Y, 15, H, 'Verilog RTL\n(19 modules,\nCh. 4-5)')
box(83, Y, 16, H, 'RTL simulation\nVivado xsim\n(Ch. 12)')
for a, b in ((16.8, 20.2), (36.8, 40.2), (58.8, 62.2), (78.8, 82.2)): arr(a, Y + H / 2, b, Y + H / 2)
Y2 = 4
box(21, Y2, 22, H, 'Fidelity analysis\n34 mismatches (Ch. 11)', '#FFF4E0')
box(47, Y2, 16, H, 'Performance and\nexploration (Ch. 6-7)', '#FFF4E0')
box(66, Y2, 15, H, 'Security\n(Ch. 8)', '#FFF4E0')
box(84, Y2, 15, H, 'Complexity and\nenhancements (Ch. 9-10)', '#FFF4E0')
arr(70, Y, 32, Y2 + H + 0.8, ''); arr(49, Y, 55, Y2 + H + 0.8, ''); arr(51, Y, 73, Y2 + H + 0.8, ''); arr(72, Y, 91, Y2 + H + 0.8, '')
ax.annotate('', xy=(49.5, Y + H + 1.2), xytext=(91, Y + H + 1.2), arrowprops=dict(arrowstyle='->', lw=0.7, ls='--', color='0.3', connectionstyle='arc3,rad=0.25'))
ax.text(70, 44.5, 'validation at the test operating point', ha='center', fontsize=6.2, style='italic')
save(fig, 'method')
