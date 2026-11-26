# Changelog

## [1.0.0] - 2026-11-26

### Added
- Unified RTL: NR phase compensation with timer triggers, two-stream Lorenz encryption with a 128-bit key and 128-angle QAM rotation, |P(d)|² and sign-bit timing metrics, CP-based CFO estimation with CORDIC, one-tap LS equaliser, convergent rounding, Bresenham sample pacing.
- System testbench with an NR-phase / CFO / multipath / noise channel, six functional tests, constellation dump and a per-symbol error monitor.
- Bit-accurate Python model, 26 unit tests, seven experiments, figure generation.
- Documentation: architecture, register map, verification, methodology, results, security, paper alignment, roadmap, thesis.
- CI (Python, C, Verilator, Icarus), results and release workflows.

### Known issues
- System regression: Tests 2, 5 and 6 failed with a one-slot flush (test-transition artefacts); the two-slot-flush rerun is pending.
- The quoted test SNR of 38.8 dB should read 38.2 dB.

## [0.1.0] - original RTL
- First RTL: 100 MHz, 64-bit key, quadrant rotation, sign-bit metric only, no CFO correction or equaliser. All four tests passed.
