//==============================================================================
// tx_rate_ctrl.v  -  TX output FIFO, real-time sample pacing and the
//                    0.5 ms (slot) / 10 ms (frame) triggers
//
// Paper Sec. III-A: the phase-compensation block uses "the 10ms trigger,
// 0.5ms trigger" and the sample valid to find the OFDM symbol of each IQ
// sample. Here those triggers come from a timer, not from the data:
//
//  * A Bresenham rate generator makes exactly SAMP_PER_SLOT sample ticks every
//    CLKS_PER_SLOT clocks, e.g. 2244 samples per 25000 clocks = 0.5 ms at
//    50 MHz. A frame is SLOTS slots = 10 ms.
//  * The symbol generator (ofdm_tx) writes bursts into the FIFO; one sample is
//    played out per tick (constant DAC-style rate, no gaps).
//  * Playout starts on a slot boundary (first sample marked sos) once a whole
//    first symbol is buffered. trig_0p5ms / trig_10ms are produced from the
//    sample/slot counters at the first sample of every slot / frame.
//  * underflow : FIFO ran dry while playing (e.g. TX disabled) - playout stops
//                and restarts at the next slot boundary.
//    align_err : a slot-start sample was not where the timer expected it.
//    Both are sticky until clr_flags.
//==============================================================================
`timescale 1ns / 1ps
module tx_rate_ctrl #(
    parameter W             = 16,
    parameter N             = 128,
    parameter CP            = 32,
    parameter CP0           = 36,
    parameter NSYM          = 14,
    parameter SLOTS         = 20,
    parameter CLKS_PER_SLOT = 25000,           // 0.5 ms at 50 MHz
    parameter FAW           = 9                // FIFO depth 2^FAW
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 clr_flags,
    // from ofdm_tx
    input  wire                 in_valid,
    input  wire signed [W-1:0]  in_re,
    input  wire signed [W-1:0]  in_im,
    input  wire                 in_sos,
    output wire                 out_ready,     // room for one whole symbol
    // paced output
    output reg                  out_valid,
    output reg  signed [W-1:0]  out_re,
    output reg  signed [W-1:0]  out_im,
    output reg                  trig_0p5ms,
    output reg                  trig_10ms,
    // status
    output reg                  underflow,
    output reg                  align_err
);
    localparam SYM0_LEN      = N + CP0;
    localparam SAMP_PER_SLOT = (N + CP0) + (NSYM - 1) * (N + CP);

    // ---------------- sample-rate tick ----------------
    reg [31:0] acc;
    reg        tick;
    always @(posedge clk) begin
        if (rst) begin
            acc <= 32'd0; tick <= 1'b0;
        end else if (acc + SAMP_PER_SLOT >= CLKS_PER_SLOT) begin
            acc  <= acc + SAMP_PER_SLOT - CLKS_PER_SLOT;
            tick <= 1'b1;
        end else begin
            acc  <= acc + SAMP_PER_SLOT;
            tick <= 1'b0;
        end
    end

    // ---------------- output FIFO ----------------
    wire [2*W:0] f_dout;
    wire         f_full, f_empty;
    wire [FAW:0] f_cnt;
    wire         head_sos = f_dout[2*W];

    reg          run;
    reg [11:0]   samp;            // sample index inside slot
    reg [4:0]    slot;            // slot index inside frame

    wire drop  = !run && !f_empty && !head_sos;      // discard until a slot start
    wire take  =  run && tick && !f_empty;
    wire start = !run && !f_empty && head_sos && (f_cnt >= SYM0_LEN);

    sync_fifo #(.DW(2*W+1), .AW(FAW)) u_fifo (
        .clk(clk), .rst(rst), .flush(1'b0),
        .wr_en(in_valid), .din({in_sos, in_im, in_re}),
        .rd_en(drop || take), .dout(f_dout),
        .full(f_full), .empty(f_empty), .count(f_cnt));

    assign out_ready = (f_cnt <= ((1 << FAW) - SYM0_LEN));

    // ---------------- playout + triggers ----------------
    always @(posedge clk) begin
        if (rst) begin
            run <= 1'b0; samp <= 0; slot <= 0;
            out_valid <= 1'b0; out_re <= 0; out_im <= 0;
            trig_0p5ms <= 1'b0; trig_10ms <= 1'b0;
            underflow <= 1'b0; align_err <= 1'b0;
        end else begin
            out_valid  <= 1'b0;
            trig_0p5ms <= 1'b0;
            trig_10ms  <= 1'b0;
            if (clr_flags) begin underflow <= 1'b0; align_err <= 1'b0; end

            if (start) begin
                run  <= 1'b1;
                samp <= 0;
                slot <= 0;
            end else if (run && tick) begin
                if (f_empty) begin
                    run       <= 1'b0;
                    underflow <= 1'b1;
                end else begin
                    out_valid  <= 1'b1;
                    out_re     <= f_dout[W-1:0];
                    out_im     <= f_dout[2*W-1:W];
                    trig_0p5ms <= (samp == 0);
                    trig_10ms  <= (samp == 0) && (slot == 0);
                    if (head_sos != (samp == 0)) align_err <= 1'b1;
                    if (samp == SAMP_PER_SLOT-1) begin
                        samp <= 0;
                        slot <= (slot == SLOTS-1) ? 5'd0 : slot + 1'b1;
                    end else begin
                        samp <= samp + 1'b1;
                    end
                end
            end
        end
    end
endmodule
