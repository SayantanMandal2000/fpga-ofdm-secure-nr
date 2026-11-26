//==============================================================================
// chaos_keystream.v  -  digital-chaos module = 2 Lorenz generators + 2 FIFOs
//
// Paper Sec. III-B: "The digital chaos module is first configured with ...
// chaotic sequence generators ... The second is to use buffers to store chaotic
// sequences, using FIFO queuing. The valid signal output by the QAM mapper
// and the FFT block are used to control the read ... to obtain a synchronous
// chaotic sequence."  Fig. 7 shows separate sequences for the PRBS (bit) and
// the QAM (real/imag) encryption, so each side has two independent streams:
//
//   stream P (DOMAIN_P) -> ks_p : ks_p[3:0] XOR mask for the 4 data bits
//   stream Q (DOMAIN_Q) -> ks_q : ks_q[6:0] chaotic I/Q phase angle
//                                 (2*pi * ks_q[6:0] / 128, 128 angles)
//
// The generators run ahead and keep both FIFOs full; the consumer pops one
// byte from each per encrypted/decrypted sub-carrier (pop is driven by the
// QAM-mapper valid on TX and by the FFT-output valid on RX).
// reseed: flush both FIFOs and restart both Lorenz systems from the key.
//==============================================================================
`timescale 1ns / 1ps
module chaos_keystream #(
    parameter AW = 8,
    parameter [63:0] DOMAIN_P = 64'h5052_4253_5F44_4F4D,   // "PRBS_DOM"
    parameter [63:0] DOMAIN_Q = 64'h5141_4D5F_524F_5444    // "QAM_ROTD"
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         reseed,
    input  wire [127:0] key,
    input  wire         pop,
    output wire [7:0]   ks_p,
    output wire [7:0]   ks_q,
    output wire         ks_avail
);
    wire        gp_valid, gq_valid;
    wire [7:0]  gp_byte,  gq_byte;
    wire        fp_full, fp_empty, fq_full, fq_empty;
    wire [AW:0] fp_cnt, fq_cnt;

    // stop stepping when a FIFO is nearly full (2-clock step latency)
    wire step_p = (fp_cnt < ((1 << AW) - 2));
    wire step_q = (fq_cnt < ((1 << AW) - 2));

    lorenz_chaos #(.DOMAIN(DOMAIN_P)) u_lorenz_p (
        .clk(clk), .rst(rst), .seed_load(reseed), .key(key),
        .step_en(step_p), .ks_valid(gp_valid), .ks_byte(gp_byte));

    lorenz_chaos #(.DOMAIN(DOMAIN_Q)) u_lorenz_q (
        .clk(clk), .rst(rst), .seed_load(reseed), .key(key),
        .step_en(step_q), .ks_valid(gq_valid), .ks_byte(gq_byte));

    wire do_pop = pop && ks_avail;

    sync_fifo #(.DW(8), .AW(AW)) u_fifo_p (
        .clk(clk), .rst(rst), .flush(reseed),
        .wr_en(gp_valid), .din(gp_byte),
        .rd_en(do_pop), .dout(ks_p),
        .full(fp_full), .empty(fp_empty), .count(fp_cnt));

    sync_fifo #(.DW(8), .AW(AW)) u_fifo_q (
        .clk(clk), .rst(rst), .flush(reseed),
        .wr_en(gq_valid), .din(gq_byte),
        .rd_en(do_pop), .dout(ks_q),
        .full(fq_full), .empty(fq_empty), .count(fq_cnt));

    assign ks_avail = !fp_empty && !fq_empty;
endmodule
