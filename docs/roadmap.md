# Roadmap

## Open issues

- [ ] Confirm the two-slot-flush system regression (Tests 2, 5, 6), then make the CI system job blocking.
- [ ] Correct the quoted test SNR to 38.2 dB everywhere (integer noise −8 … +8).
- [ ] First Icarus / Verilator CI runs: fix any portability warnings.
- [ ] Synthesise (`make synth`) and replace the analytical resource estimates with real reports.

## Planned enhancements (evaluated in the model, not yet in RTL)

| Enhancement | Cost | Model gain |
| --- | --- | --- |
| Slot nonce in the chaos seed | 64-bit counter + XOR per generator | closes key-stream reuse (Eve's BER 0.013 → 0.5) |
| De-sloped 7-sub-carrier smoothing of the channel estimate | 1 complex MAC, moving sum, 2 rotations per sub-carrier | 6.6-7.5 dB at BER 10⁻³ |
| TH0 as a register, default 76 | none | about 5 dB earlier reliable acquisition |
| Normalised \|P\|² test, plus AGC or adaptive shift | 2 squarers, 1 comparator | gain window 0 → about ±3 dB |
| FFT back-off 4 → 8 samples | none | late-lock tolerance +4 → +8 |
| Pipelined correlator adder tree; time-shared Lorenz multipliers | registers; −24 to −32 DSP | timing margin at 50 MHz |

## Longer term

- Hardware validation on a Zynq board with a DAC/ADC loop-back and an ILA.
- Full NIST SP 800-22 battery; comparison with AES-CTR.
- NR numerology: larger FFT (pipelined), 64-QAM, TDD pattern, uplink compensation.
