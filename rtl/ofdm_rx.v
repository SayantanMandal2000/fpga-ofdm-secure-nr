//==============================================================================
// ofdm_rx.v  -  OFDM receiver (baseband)
//
//  rx samples -> timing_sync (training detection, CFO estimate + correction,
//                CP removal, data buffer)
//             -> FFT (unscaled, natural order)
//             -> training symbol : rx_equalizer computes W(k) = 1/H(k)
//             -> data symbols    : one-tap equalisation Y(k) * W(k)
//                -> chaotic I/Q de-rotation by -2*pi*ks_q[6:0]/128
//                -> 16-QAM hard demap -> XOR ks_p[3:0] -> recovered PRBS bits
//                -> self-synchronising PRBS-15 checker (bit / error counters)
//
// The RX chaos generators are re-seeded with the RX key when the first data
// symbol of a slot enters the FFT; the key-stream FIFO pop is driven by the
// FFT-output valid (paper: "valid signal of ... the FFT block").
//==============================================================================
`timescale 1ns / 1ps
module ofdm_rx #(
    parameter N     = 128,
    parameter LOGN  = 7,
    parameter CP    = 32,
    parameter CP0   = 36,
    parameter W     = 16,
    parameter NDATA = 13
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 chaos_en,
    input  wire                 eq_en,
    input  wire                 cfo_en,
    input  wire                 metric_sel,
    input  wire [127:0]         key,
    input  wire                 ber_clear,
    input  wire                 rx_valid,
    input  wire signed [W-1:0]  rx_re,
    input  wire signed [W-1:0]  rx_im,
    // status
    output wire                 locked,
    output wire [31:0]          slot_count,
    output wire [31:0]          peak0,
    output wire [31:0]          peak1,
    output wire [15:0]          cfo_est,
    output reg  [31:0]          ber_bits,
    output reg  [31:0]          ber_errs,
    // debug: equalised / decrypted constellation (before decision)
    output reg                  dbg_valid,
    output reg  signed [W-1:0]  dbg_re,
    output reg  signed [W-1:0]  dbg_im,
    output reg  [3:0]           dbg_bits
);
    // ---------------- timing + frequency synchronisation ----------------
    wire          buf_rd;
    wire [2*W:0]  buf_data;
    wire          buf_avail;
    wire          lock_pulse;

    timing_sync #(.N(N), .CP(CP), .CP0(CP0), .W(W), .NDATA(NDATA)) u_sync (
        .clk(clk), .rst(rst), .metric_sel(metric_sel), .cfo_en(cfo_en), .eq_en(eq_en),
        .in_valid(rx_valid), .in_re(rx_re), .in_im(rx_im),
        .rd_en(buf_rd), .rd_data(buf_data), .rd_avail(buf_avail),
        .lock_pulse(lock_pulse), .locked(locked), .peak0(peak0), .peak1(peak1),
        .cfo_est(cfo_est), .slot_count(slot_count));

    // ---------------- FFT ----------------
    wire                fft_in_ready, fft_done, fft_busy;
    wire [LOGN-1:0]     fft_rd_addr;
    wire signed [W-1:0] fft_rd_re, fft_rd_im;
    reg                 fft_release;

    assign buf_rd = buf_avail && fft_in_ready;

    fft_core #(.N(N), .LOGN(LOGN), .W(W), .SCALE(0)) u_fft (
        .clk(clk), .rst(rst), .inverse(1'b0),
        .in_valid(buf_rd), .in_re(buf_data[W-1:0]), .in_im(buf_data[2*W-1:W]),
        .in_ready(fft_in_ready), .busy(fft_busy), .done(fft_done),
        .rd_addr(fft_rd_addr), .rd_re(fft_rd_re), .rd_im(fft_rd_im),
        .out_release(fft_release));

    // ---------------- which symbol is in the FFT ----------------
    // ld_sym : index in slot of the symbol being loaded (0 = training),
    // captured as job_sym when the transform starts.
    reg [LOGN-1:0] ld_cnt;
    reg [3:0]      ld_sym, job_sym;
    reg            job_train, busy_d, ks_reseed;
    always @(posedge clk) begin
        if (rst) begin
            ld_cnt <= 0; ld_sym <= 4'd15; job_sym <= 4'd15; job_train <= 1'b0;
            busy_d <= 1'b0; ks_reseed <= 1'b0;
        end else begin
            busy_d    <= fft_busy;
            ks_reseed <= 1'b0;
            if (buf_rd) begin
                if (buf_data[2*W]) begin                 // training sample 0
                    ld_sym <= 4'd0;
                    ld_cnt <= 1;
                end else begin
                    if (ld_cnt == 0) ld_sym <= (ld_sym == 4'd15) ? 4'd15 : ld_sym + 1'b1;
                    ld_cnt <= ld_cnt + 1'b1;
                end
            end
            if (fft_busy && !busy_d) begin
                job_sym   <= ld_sym;
                job_train <= (ld_sym == 4'd0);
                if (ld_sym == 4'd1) ks_reseed <= 1'b1;   // first data symbol
            end
        end
    end

    // ---------------- chaos key streams + equaliser ----------------
    wire [7:0]        ks_p, ks_q;
    wire              ks_avail;
    wire              w_ready;
    reg               rd_active;
    reg [LOGN:0]      k;
    wire              rd_go = rd_active &&
                              (job_train || ((!chaos_en || ks_avail) && w_ready));

    chaos_keystream #(.AW(8)) u_chaos (
        .clk(clk), .rst(rst), .reseed(ks_reseed), .key(key),
        .pop(rd_go && chaos_en && !job_train),
        .ks_p(ks_p), .ks_q(ks_q), .ks_avail(ks_avail));

    // ---------------- read-out FSM ----------------
    reg                s1_v, s1_train;
    reg [LOGN-1:0]     s1_k;
    reg signed [W-1:0] s1_re, s1_im;
    reg [7:0]          s1_ksp, s1_ksq;

    always @(posedge clk) begin
        if (rst) begin
            rd_active <= 1'b0; k <= 0; fft_release <= 1'b0; s1_v <= 1'b0;
            s1_train <= 1'b0; s1_k <= 0;
            s1_re <= 0; s1_im <= 0; s1_ksp <= 0; s1_ksq <= 0;
        end else begin
            fft_release <= 1'b0;
            s1_v        <= 1'b0;
            if (fft_done && !rd_active && !fft_release) begin
                rd_active <= 1'b1;
                k <= 0;
            end
            if (rd_go) begin
                // combinational FFT read at address k
                s1_v     <= 1'b1;
                s1_train <= job_train;
                s1_k     <= k[LOGN-1:0];
                s1_re    <= fft_rd_re;
                s1_im    <= fft_rd_im;
                s1_ksp   <= (chaos_en && !job_train) ? ks_p : 8'h00;
                s1_ksq   <= (chaos_en && !job_train) ? ks_q : 8'h00;
                if (k == N-1) begin
                    rd_active   <= 1'b0;
                    fft_release <= 1'b1;
                end
                k <= k + 1'b1;
            end
        end
    end
    assign fft_rd_addr = k[LOGN-1:0];

    // ---------------- one-tap equaliser ----------------
    wire signed [17:0]  w_re, w_im;
    wire signed [W-1:0] e_re, e_im;

    rx_equalizer #(.N(N), .LOGN(LOGN), .W(W)) u_eq (
        .clk(clk), .rst(rst), .eq_en(eq_en),
        .tr_valid(s1_v && s1_train), .tr_k(s1_k), .tr_re(s1_re), .tr_im(s1_im),
        .rd_k(s1_k), .w_re(w_re), .w_im(w_im), .w_ready(w_ready));

    cplx_rot #(.W(W), .CW(18), .CF(14)) u_eqmul (
        .i_i(s1_re), .q_i(s1_im), .c(w_re), .s(w_im), .i_o(e_re), .q_o(e_im));

    reg                s2_v;
    reg signed [W-1:0] s2_re, s2_im;
    reg [7:0]          s2_ksp, s2_ksq;
    always @(posedge clk) begin
        if (rst) begin
            s2_v <= 1'b0; s2_re <= 0; s2_im <= 0; s2_ksp <= 0; s2_ksq <= 0;
        end else begin
            s2_v <= s1_v && !s1_train;
            if (s1_v) begin
                s2_re <= e_re; s2_im <= e_im; s2_ksp <= s1_ksp; s2_ksq <= s1_ksq;
            end
        end
    end

    // ---------------- decryption + demapping ----------------
    wire [9:0]          dec_ph = 10'd0 - {s2_ksq[6:0], 3'b000};
    wire signed [15:0]  dec_c, dec_s;
    wire signed [W-1:0] d_re, d_im;
    wire [3:0]          dm_bits;
    sincos_lut u_dec_lut (.phase(dec_ph), .cos_o(dec_c), .sin_o(dec_s));
    cplx_rot #(.W(W), .CW(16), .CF(14)) u_dec (
        .i_i(s2_re), .q_i(s2_im), .c(dec_c), .s(dec_s), .i_o(d_re), .q_o(d_im));
    qam16_demapper #(.W(W)) u_demap (.i_i(d_re), .q_i(d_im), .bits(dm_bits));
    wire [3:0] plain_bits = dm_bits ^ s2_ksp[3:0];

    always @(posedge clk) begin
        if (rst) begin
            dbg_valid <= 1'b0; dbg_re <= 0; dbg_im <= 0; dbg_bits <= 0;
        end else begin
            dbg_valid <= s2_v;
            if (s2_v) begin dbg_re <= d_re; dbg_im <= d_im; dbg_bits <= plain_bits; end
        end
    end

    // ---------------- self-synchronising PRBS-15 checker ----------------
    // Expected bit = h[14] ^ h[13] (history of received bits). Errors are
    // counted after 32 bits have filled the history.
    reg [14:0] hist;
    reg [5:0]  warm;
    reg [14:0] h_t;
    reg [2:0]  e_t;
    integer b;
    always @(posedge clk) begin
        if (rst || ber_clear) begin
            hist <= 0; warm <= 0; ber_bits <= 0; ber_errs <= 0;
        end else if (dbg_valid) begin
            h_t = hist; e_t = 0;
            for (b = 3; b >= 0; b = b - 1) begin
                if ((h_t[14] ^ h_t[13]) != dbg_bits[b]) e_t = e_t + 1'b1;
                h_t = {h_t[13:0], dbg_bits[b]};
            end
            hist <= h_t;
            if (warm < 6'd8) warm <= warm + 1'b1;   // 8 x 4 = 32 bits warm-up
            else begin
                ber_bits <= ber_bits + 4;
                ber_errs <= ber_errs + e_t;
            end
        end
    end
endmodule
