//==============================================================================
// ofdm_top.v  -  FPGA-based OFDM communication system (top level)
//
// Implements the three FPGA-OFDM works compared in
//   Z. Tang, "OFDM communication system based on FPGA", ACCTCS 2023 (Table I):
//
//   1. Phase compensation in 5G      : NR slot structure (14 symbols/slot,
//      20 slots / 10 ms frame, long CP on symbol 0), 14 coefficients written
//      by the ARM/PS over AXI-Lite, real-time 10 ms / 0.5 ms triggers select
//      the coefficient per symbol.
//   2. Secure OFDM using digital chaos: two Lorenz chaotic key streams per side
//      + FIFO buffers; encrypts the PRBS data bits (stream P) and the QAM
//      real/imag parts by a chaotic phase rotation (stream Q). 128-bit key.
//   3. Timing synchronisation          : M-sequence -> 16-QAM -> imag=0 ->
//      IFFT -> CP  conjugate-symmetric training; sliding correlation, energy
//      accumulation, frame finding and data-buffer modules at the RX, plus
//      CP-based CFO estimation/correction and a one-tap equaliser.
//
//   TX : ofdm_tx -> tx_rate_ctrl (FIFO, sample pacing, triggers)
//                -> phase_comp_core -> tx_* (to DAC / RF / channel)
//   RX : rx_* -> ofdm_rx (timing/CFO sync -> FFT -> equaliser -> decrypt
//                -> demap -> BER)
//
// For a hardware loop-back on a board, connect tx_* to rx_* (or through the
// DAC/ADC); in simulation the testbench inserts a channel model in between.
// CLKS_PER_SLOT must equal clk frequency * 0.5 ms (25000 at 50 MHz).
//==============================================================================
`timescale 1ns / 1ps
module ofdm_top #(
    parameter N             = 128,       // FFT size
    parameter LOGN          = 7,
    parameter CP            = 32,        // cyclic prefix length (paper Sec. III-C)
    parameter CP0           = 36,        // symbol-0 CP (NR long first-symbol CP)
    parameter W             = 16,        // IQ sample width
    parameter NSYM          = 14,        // OFDM symbols per slot (normal CP, NR)
    parameter SLOTS         = 20,        // slots per 10 ms frame
    parameter CLKS_PER_SLOT = 25000      // 0.5 ms at 50 MHz (paper system clock)
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // ---------------- AXI4-Lite slave (ARM / PS side) ----------------
    input  wire [7:0]           s_axil_awaddr,
    input  wire                 s_axil_awvalid,
    output wire                 s_axil_awready,
    input  wire [31:0]          s_axil_wdata,
    input  wire [3:0]           s_axil_wstrb,
    input  wire                 s_axil_wvalid,
    output wire                 s_axil_wready,
    output wire [1:0]           s_axil_bresp,
    output wire                 s_axil_bvalid,
    input  wire                 s_axil_bready,
    input  wire [7:0]           s_axil_araddr,
    input  wire                 s_axil_arvalid,
    output wire                 s_axil_arready,
    output wire [31:0]          s_axil_rdata,
    output wire [1:0]           s_axil_rresp,
    output wire                 s_axil_rvalid,
    input  wire                 s_axil_rready,

    // ---------------- TX baseband stream ----------------
    output wire                 tx_valid,
    output wire signed [W-1:0]  tx_i,
    output wire signed [W-1:0]  tx_q,
    output wire                 tx_sof,        // 10 ms frame trigger
    output wire                 tx_sos,        // 0.5 ms slot trigger
    output wire [3:0]           tx_sym_idx,    // OFDM symbol 0..13 in slot

    // ---------------- RX baseband stream ----------------
    input  wire                 rx_valid,
    input  wire signed [W-1:0]  rx_i,
    input  wire signed [W-1:0]  rx_q,

    // ---------------- status / debug ----------------
    output wire                 led_rx_locked,
    output wire                 led_ber_ok,
    output wire                 dbg_valid,
    output wire signed [W-1:0]  dbg_i,
    output wire signed [W-1:0]  dbg_q
);
    wire rst = ~rst_n;

    wire                 tx_enable, pc_enable, chaos_enable, eq_enable, cfo_enable;
    wire                 metric_sel, ber_clear;
    wire [127:0]         tx_key, rx_key;
    wire [32*NSYM-1:0]   coef_flat;
    wire                 rx_locked, tx_underflow, tx_align_err;
    wire [31:0]          ber_bits, ber_errs, rx_slots, sync_peak0, sync_peak1;
    wire [15:0]          cfo_est;

    // ---------------- AXI-Lite registers ----------------
    ofdm_axil_regs #(.NSYM(NSYM), .AW(8)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready), .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready), .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready), .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .tx_enable(tx_enable), .pc_enable(pc_enable), .chaos_enable(chaos_enable),
        .eq_enable(eq_enable), .cfo_enable(cfo_enable), .metric_sel(metric_sel),
        .ber_clear(ber_clear), .tx_key(tx_key), .rx_key(rx_key), .coef_flat(coef_flat),
        .rx_locked(rx_locked), .tx_underflow(tx_underflow), .tx_align_err(tx_align_err),
        .ber_bits(ber_bits), .ber_errs(ber_errs), .rx_slots(rx_slots),
        .sync_peak0(sync_peak0), .sync_peak1(sync_peak1), .cfo_est(cfo_est));

    // ---------------- transmitter (symbol generator) ----------------
    wire                 g_valid, g_sos, g_ready;
    wire signed [W-1:0]  g_re, g_im;

    ofdm_tx #(.N(N), .LOGN(LOGN), .CP(CP), .CP0(CP0), .W(W), .NSYM(NSYM)) u_tx (
        .clk(clk), .rst(rst), .enable(tx_enable), .chaos_en(chaos_enable), .key(tx_key),
        .out_ready(g_ready),
        .tx_valid(g_valid), .tx_re(g_re), .tx_im(g_im), .tx_sos(g_sos));

    // ---------------- sample pacing + real-time triggers ----------------
    wire                 t_valid, t_sos, t_sof;
    wire signed [W-1:0]  t_re, t_im;

    tx_rate_ctrl #(.W(W), .N(N), .CP(CP), .CP0(CP0), .NSYM(NSYM), .SLOTS(SLOTS),
                   .CLKS_PER_SLOT(CLKS_PER_SLOT)) u_rate (
        .clk(clk), .rst(rst), .clr_flags(ber_clear),
        .in_valid(g_valid), .in_re(g_re), .in_im(g_im), .in_sos(g_sos), .out_ready(g_ready),
        .out_valid(t_valid), .out_re(t_re), .out_im(t_im),
        .trig_0p5ms(t_sos), .trig_10ms(t_sof),
        .underflow(tx_underflow), .align_err(tx_align_err));

    // ---------------- 5G NR phase compensation ----------------
    phase_comp_core #(.W(W), .N(N), .CP(CP), .CP0(CP0), .NSYM(NSYM), .SLOTS(SLOTS)) u_pc (
        .clk(clk), .rst(rst), .pc_enable(pc_enable), .coef_flat(coef_flat),
        .in_valid(t_valid), .in_re(t_re), .in_im(t_im),
        .trig_10ms(t_sof), .trig_0p5ms(t_sos),
        .out_valid(tx_valid), .out_re(tx_i), .out_im(tx_q),
        .out_sof(tx_sof), .out_sos(tx_sos), .out_sym_idx(tx_sym_idx), .slot_idx());

    // ---------------- receiver ----------------
    wire [3:0] dbg_bits;
    ofdm_rx #(.N(N), .LOGN(LOGN), .CP(CP), .CP0(CP0), .W(W), .NDATA(NSYM-1)) u_rx (
        .clk(clk), .rst(rst), .chaos_en(chaos_enable), .eq_en(eq_enable),
        .cfo_en(cfo_enable), .metric_sel(metric_sel), .key(rx_key), .ber_clear(ber_clear),
        .rx_valid(rx_valid), .rx_re(rx_i), .rx_im(rx_q),
        .locked(rx_locked), .slot_count(rx_slots), .peak0(sync_peak0), .peak1(sync_peak1),
        .cfo_est(cfo_est), .ber_bits(ber_bits), .ber_errs(ber_errs),
        .dbg_valid(dbg_valid), .dbg_re(dbg_i), .dbg_im(dbg_q), .dbg_bits(dbg_bits));

    assign led_rx_locked = rx_locked;
    assign led_ber_ok    = (ber_bits != 0) && (ber_errs == 0);
endmodule
