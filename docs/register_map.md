# Register map

AXI4-Lite slave `ofdm_axil_regs`. All registers are 32 bits, word aligned, with byte strobes on writes. Unmapped reads return `0xDEADBEEF`.

## Register Summary

**Register summary with access type and reset value**

| Offset | Name | Access | Reset value | Description |
| --- | --- | --- | --- | --- |
| 0x00 | CTRL | RW | 0x00000034 | Control bits (below) |
| 0x04 | STATUS | RO | 0x00000000 | Lock and transmitter error flags |
| 0x08 | TX_KEY0 | RW | 0x12345678 | TX key bits 31:0 |
| 0x0C | TX_KEY1 | RW | 0x9ABCDEF0 | TX key bits 63:32 |
| 0x10 | RX_KEY0 | RW | 0x12345678 | RX key bits 31:0 |
| 0x14 | RX_KEY1 | RW | 0x9ABCDEF0 | RX key bits 63:32 |
| 0x18 | BER_BITS | RO | 0 | Number of checked bits |
| 0x1C | BER_ERRS | RO | 0 | Number of bit errors |
| 0x20 | RX_SLOTS | RO | 0 | Slots synchronised by the receiver |
| 0x24 | SYNC_PEAK0 | RO | 0 | Sign-bit metric at the last lock (ideal 126) |
| 0x28 | TX_KEY2 | RW | 0x0F1E2D3C | TX key bits 95:64 |
| 0x2C | TX_KEY3 | RW | 0x4B5A6978 | TX key bits 127:96 |
| 0x30 | RX_KEY2 | RW | 0x0F1E2D3C | RX key bits 95:64 |
| 0x34 | RX_KEY3 | RW | 0x4B5A6978 | RX key bits 127:96 |
| 0x38 | SYNC_PEAK1 | RO | 0 | \|P\|² metric at the last lock |
| 0x3C | CFO_EST | RO | 0 | [15:0] ε̂ = signed(value)/65536 sub-carriers |
| 0x40-0x74 | PC_COEF[0..13] | RW | 0x40000000 | [31:16] cos, [15:0] sin of the compensation angle, Q2.14 |

## Control and Status Bits

**CTRL register bit fields**

| Bit | Name | Reset | Function |
| --- | --- | --- | --- |
| 0 | tx_enable | 0 | Start the transmitter and the real-time playout |
| 1 | pc_enable | 0 | Apply the NR phase-compensation coefficients (0 = multiply by 1 + j0) |
| 2 | chaos_enable | 1 | Encrypt the bits (stream P) and rotate the QAM symbols (stream Q) |
| 3 | ber_clear | 0 | Self-clearing pulse: clears the BER counters and the TX flags |
| 4 | eq_enable | 1 | Use the one-tap equaliser and the 4-sample FFT-window back-off |
| 5 | cfo_enable | 1 | De-rotate the received samples by the CFO estimate |
| 6 | metric_sel | 0 | 0 = sign-bit metric M0 (TH0 = 88), 1 = paper metric \|P\|² (TH1 = 380 000) |
| 31:7 | - | 0 | Reserved, read as zero |

**STATUS register bit fields**

| Bit | Name | Meaning |
| --- | --- | --- |
| 0 | rx_locked | Receiver has found at least one training symbol |
| 1 | tx_underflow | Sticky: the playout timer found the output FIFO empty |
| 2 | tx_align_err | Sticky: a slot-start sample did not fall on sample 0 of the timer |
| 31:3 | - | Read as zero |

## Phase-Compensation Coefficients for f0 = 3.5 GHz

The table below lists the 14 coefficients computed by `sw/pc_coef.c` for f0 = 3.5 GHz, N = 128, CP = 32, CP0 = 36 and a 0.5 ms slot of 2244 samples. Since f0 · T<sub>slot</sub> = 1.75 × 10⁶ is an integer, the table repeats every slot. The same values are computed by the testbench and were read back from the registers in simulation.

**Phase-compensation coefficients written to PC_COEF[0..13]**

| l | t_start (samples) | CP | φ<sub>l</sub> (deg) | cos (Q2.14) | sin (Q2.14) | PC_COEF[l] |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 36 | 311.9 | 10936 | 12200 | 0x2AB82FA8 |
| 1 | 164 | 32 | 18.0 | 15585 | -5054 | 0x3CE1EC42 |
| 2 | 324 | 32 | 84.1 | 1694 | -16296 | 0x069EC058 |
| 3 | 484 | 32 | 150.2 | -14212 | -8152 | 0xC87CE028 |
| 4 | 644 | 32 | 216.3 | -13212 | 9690 | 0xCC6425DA |
| 5 | 804 | 32 | 282.4 | 3505 | 16005 | 0x0DB13E85 |
| 6 | 964 | 32 | 348.4 | 16052 | 3281 | 0x3EB40CD1 |
| 7 | 1124 | 32 | 54.5 | 9504 | -13346 | 0x2520CBDE |
| 8 | 1284 | 32 | 120.6 | -8350 | -14096 | 0xDF62C8F0 |
| 9 | 1444 | 32 | 186.7 | -16271 | 1922 | 0xC0710782 |
| 10 | 1604 | 32 | 252.8 | -4836 | 15654 | 0xED1C3D26 |
| 11 | 1764 | 32 | 318.9 | 12352 | 10764 | 0x30402A0C |
| 12 | 1924 | 32 | 25.0 | 14846 | -6931 | 0x39FEE4ED |
| 13 | 2084 | 32 | 91.1 | -321 | -16381 | 0xFEBFC003 |

## Software Programming Sequence

1. Write CTRL = 0x34 (transmitter off) and the TX and RX keys TX_KEY0..3 and RX_KEY0..3.
1. Compute the 14 coefficients with pc_compute() and write them to PC_COEF[0..13].
1. Write CTRL with tx_enable = 1 and the desired options (for example 0x37: transmitter, compensation, encryption, equaliser and CFO correction).
1. Poll STATUS until rx_locked = 1, wait at least two slots, then pulse ber_clear (CTRL | 0x08).
1. After the measurement interval, read BER_BITS, BER_ERRS, RX_SLOTS, SYNC_PEAK0/1 and CFO_EST.

Software: `sw/pc_coef.c` computes the coefficients (`gcc sw/pc_coef.c -lm && ./a.out`). For Zynq, build with `-DUSE_XIL_IO` and set `OFDM_BASEADDR`.
