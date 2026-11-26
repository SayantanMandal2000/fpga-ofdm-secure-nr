"""Bit-accurate Python models of the FPGA OFDM baseband (RTL in ../rtl)."""
from . import chaos, fx, sync

__all__ = ["fx", "sync", "chaos"]
__version__ = "1.0.0"
