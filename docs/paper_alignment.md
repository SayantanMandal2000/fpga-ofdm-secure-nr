# Alignment with the reference paper

Reference: Z. Tang, "OFDM communication system based on FPGA," ACCTCS 2023, doi:10.1109/ACCTCS58815.2023.00126. The paper surveys three FPGA-OFDM works (5G NR phase compensation, secure OFDM with digital chaos, conjugate-symmetric timing synchronisation).

The original RTL was compared line by line with the paper. 34 differences were found and graded **High** (changes the algorithm or results), **Medium** (different implementation or missing function) or **Low** (scope, platform, naming, ambiguity).

| Status in the final RTL | Count | Items |
| --- | --- | --- |
| Fixed | 11 | P1, P2, P5, C3, C4, C10, T2, T3, T5, T6, S1 |
| Equivalent / RTL correct | 3 | P9, C7, T8 |
| Assumption (confirm in the primary chaos paper) | 2 | C1, C2 |
| Deliberate deviation / convention / design choice | 7 | T1, T4, T7, T9, C5, S2, S3 |
| Not addressed | 1 | C6 (throughput) |
| Out of scope of an RTL study | 10 | P3, P4, P6, P7, P8, P10, C8, C9, S4, S5 |

The one deliberate deviation that changes numbers is **T1**: the transmitter IFFT is scaled by 1/N to keep 16-bit samples. **C1** (how the QAM real/imaginary parts are encrypted) and **C2** (Lorenz vs the Qi system cited in the text) are documented assumptions.


## Phase compensation

| Item | Paper | Original RTL | Severity | Final RTL |
| --- | --- | --- | --- | --- |
| P1 | Real 10 ms / 0.5 ms triggers | Triggers from TX data, not timed | High | Fixed: tx_rate_ctrl timer |
| P2 | ARM computes c_l from NR parameters | Arbitrary φ_l in testbench | Medium | Fixed: pc_coef.c, 38.211 formula |
| P3 | DL and UL compensation | DL only | Medium | Out of scope |
| P4 | 100 MHz, 273 RB grid | N = 128, all sub-carriers | Medium | Out of scope |
| P5 | NR long first-symbol CP | Uniform CP | Medium | Fixed: CP0 = 36 |
| P6 | TDD DDDSU | All slots DL | Low | Out of scope |
| P7 | SSB, DMRS, PDSCH | Custom training + data | Low | Out of scope |
| P8 | 64-QAM PDSCH | 16-QAM | Low | Out of scope |
| P9 | Symbols "0 to 14" (typo) | 0..13 | Low | RTL correct |
| P10 | CPRI, JESD204B, DFE | None | Low | Out of scope |

## Digital chaos

| Item | Paper | Original RTL | Severity | Final RTL |
| --- | --- | --- | --- | --- |
| C1 | Chaos encrypts QAM real/imag parts | 90° quadrant rotation only | High | Fixed (assumed method): 128-angle rotation |
| C2 | Qi system [Qi 2005] cited; Lorenz_DATA in figure | Lorenz | Medium | Kept Lorenz (assumption) |
| C3 | Separate sequences per stage | One byte stream | Medium | Fixed: streams P and Q |
| C4 | Key space ≈ 10^22 | 64-bit key | Medium | Fixed: 128-bit key, 2^120 states |
| C5 | Vivado FFT IP | Custom FFT | Medium | Deviation kept |
| C6 | 100 MB/s per channel | ≈ 40 Mbit/s | Medium | Not addressed |
| C7 | Valids control buffer R/W | Valids drive reads | Low | Equivalent |
| C8 | XSG model | Verilog testbench | Low | Out of scope |
| C9 | PON scenario | Generic channel | Low | Out of scope |
| C10 | Handshake between modules | No back-pressure at TX output | Low | Fixed: FIFO + out_ready |

## Timing synchronisation

| Item | Paper | Original RTL | Severity | Final RTL |
| --- | --- | --- | --- | --- |
| T1 | IFFT IP unscaled | Scaled 1/N | High | Deviation kept, documented |
| T2 | \|P(d)\|^2 with R = 1 | Sign-bit L1 metric | High | Fixed: both, run-time select |
| T3 | Convergent rounding | Round-half-up | Medium | Fixed |
| T4 | Pipelined streaming IP | Burst core | Medium | Kept; FIFO hides it |
| T5 | 50 MHz | 100 MHz testbench | Medium | Fixed |
| T6 | Timing and frequency sync | Timing only | Medium | Fixed: CP-based CFO |
| T7 | Peak at window centre | Training start | Low | Convention, kept |
| T8 | 256-bit M-sequence, imag = 0 | 2 bits / sub-carrier, Q = 0 | Low | Equivalent |
| T9 | Training placement not stated | Every slot | Low | Design choice |

## System

| Item | Paper | Original RTL | Severity | Final RTL |
| --- | --- | --- | --- | --- |
| S1 | DMRS-based channel estimation [Nguyen 2021] | No equaliser | Medium | Fixed: one-tap equaliser |
| S2 | EVM by VSA | EVM vs nearest point | Medium | Documented |
| S3 | Three separate works | One chain | Low | By design |
| S4 | x86 DU, RRU, ADRV9009, VSA | Simulation | Low | Out of scope |
| S5 | ARM inside SoC | No PS instance | Low | PS code provided |
