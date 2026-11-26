"""Cross-checks between the RTL sources and the Python model / generator scripts."""
import re
import subprocess
import sys
from pathlib import Path


from ofdm_model import fx

ROOT = Path(__file__).resolve().parents[1]


def test_sincos_lut_is_up_to_date(tmp_path):
    out = tmp_path / "sincos_lut.v"
    subprocess.run([sys.executable, str(ROOT / "scripts/gen_sincos_lut.py"), str(out)], check=True)
    assert out.read_text() == (ROOT / "rtl/sincos_lut.v").read_text()


def test_twiddle_rom_matches_model():
    src = (ROOT / "rtl/twiddle_rom.v").read_text()
    pairs = re.findall(r"cos_o = 16'h([0-9A-Fa-f]{4}); sin_o = 16'h([0-9A-Fa-f]{4})", src)
    pairs = pairs[:64]          # entry 65 is the default branch
    assert len(pairs) == 64

    def s16(h):
        v = int(h, 16)
        return v - 0x10000 if v >= 0x8000 else v

    assert [s16(c) for c, _ in pairs] == fx.TWC.tolist()
    assert [s16(s) for _, s in pairs] == fx.TWS.tolist()


def test_top_parameters():
    src = (ROOT / "rtl/ofdm_top.v").read_text()
    for name, val in {"N": 128, "CP": 32, "CP0": 36, "NSYM": 14, "CLKS_PER_SLOT": 25000}.items():
        assert re.search(rf"parameter\s+{name}\s*=\s*{val}\b", src), name
