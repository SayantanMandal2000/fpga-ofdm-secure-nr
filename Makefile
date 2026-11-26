# FPGA OFDM baseband: one entry point for lint, simulation, models and figures.
#   make lint        Verilator lint of the synthesizable RTL
#   make sim-fft     Icarus Verilog: FFT unit test (fast)
#   make sim-top     Icarus Verilog: full system regression (6 tests, ~11 ms simulated)
#   make sw          Build and run the PS coefficient program
#   make test        Python unit tests (pytest)
#   make quick       All model experiments in quick mode (CI smoke run)
#   make results     All model experiments at full size -> results/*.json, docs/figures/*.png
#   make vivado      Create the Vivado project (needs Vivado on PATH)
#   make vivado-sim  Run tb_ofdm_top in Vivado xsim (batch)
#   make synth       Out-of-context synthesis + utilisation report (Vivado)

RTL   := $(sort $(wildcard rtl/*.v))
BUILD := build
PY    ?= python3
IVFLAGS := -g2012 -Wall -Wno-timescale

.PHONY: all lint sim-fft sim-top sw test quick results vivado vivado-sim synth clean
all: lint sim-fft test

$(BUILD):
	mkdir -p $(BUILD)

lint:
	verilator --lint-only -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDPARAM --top-module ofdm_top $(RTL)

sim-fft: | $(BUILD)
	iverilog $(IVFLAGS) -s tb_fft_core -o $(BUILD)/tb_fft.vvp $(RTL) tb/tb_fft_core.v
	cd $(BUILD) && vvp -n tb_fft.vvp | tee tb_fft.log
	grep -q "TB_FFT PASS" $(BUILD)/tb_fft.log

sim-top: | $(BUILD)
	iverilog $(IVFLAGS) -s tb_ofdm_top -o $(BUILD)/tb_top.vvp $(RTL) tb/channel_model.v tb/tb_ofdm_top.v
	cd $(BUILD) && vvp -n tb_top.vvp | tee tb_top.log
	grep -q "ALL TESTS PASSED" $(BUILD)/tb_top.log

sw: | $(BUILD)
	cc -std=c99 -O2 -Wall -o $(BUILD)/pc_coef sw/pc_coef.c -lm
	$(BUILD)/pc_coef | tee $(BUILD)/pc_coef.log
	grep -q "0x2AB82FA8" $(BUILD)/pc_coef.log

test:
	$(PY) -m pytest

quick:
	cd experiments && OFDM_QUICK=1 OFDM_FIGDIR=../$(BUILD)/figures-quick sh -c 'for s in exp_link exp_sync exp_pc exp_dse exp_chaos exp_enh fig_method; do $(PY) $$s.py > /dev/null || exit 1; done'

results:
	cd experiments && for s in exp_link exp_sync exp_pc exp_dse exp_chaos exp_enh fig_method; do echo "== $$s"; $(PY) $$s.py || exit 1; done

vivado:
	vivado -mode batch -nojournal -nolog -source scripts/vivado/create_project.tcl

vivado-sim: vivado
	vivado -mode batch -nojournal -nolog -source scripts/vivado/run_sim.tcl

synth:
	vivado -mode batch -nojournal -nolog -source scripts/vivado/synth.tcl

clean:
	rm -rf $(BUILD) results/quick .pytest_cache
