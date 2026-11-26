//==============================================================================
// timing_sync.v  -  OFDM timing + frequency synchronisation with a
//                   conjugate-symmetric training sequence
//                   (paper Sec. II-B, III-C, Fig. 9, ref [14])
//
// Fig. 9 structure : data input is split into three branches
//   (1) ts_sliding_corr  - "sliding window energy computing module"  -> P(d)
//   (2) ts_energy_acc    - "average energy accumulation module"      -> R(d)
//   (3) ts_data_buffer   - "data buffer module" (delay + CP removal)
//   and ts_frame_find    - "frame finding module" : M(d) peak search,
//                          gives the enable to the data buffer.
//   plus ts_cfo_corr + cordic_vec : carrier-frequency-offset estimation
//   (the paper says the method gives timing AND frequency synchronisation).
//
// Timing metric for a window starting at sample d (training without CP):
//     P(d) = sum_{k=1}^{N/2-1} r(d+k) * r(d+N-k)
// For the conjugate-symmetric training x(N-k) = x*(k) every product equals
// |x(k)|^2, so P(d) peaks when the window is aligned.  Two metrics are
// computed every sample and metric_sel picks the one used for detection:
//   metric_sel = 1 (paper) : M(d) = |P(d)|^2 with the energy term set to 1
//                            (the paper's approximation), on QB-bit samples.
//   metric_sel = 0         : r quantised to sign bits (1-bit I/Q), and
//                            M(d) = |Re P| + |Im P|. This is NOT in the paper;
//                            it is a cheaper multiplier-free alternative
//                            (ideal aligned peak = 2*(N/2-1) = 126).
// R(d) (sliding |r| sum) gates both detectors so idle noise cannot trigger.
// After a lock the search re-arms ARM_EARLY samples before the next expected
// training position (d_hat + SLOT_LEN), so data symbols are never searched.
//
// CFO: the cyclic prefix of every symbol is a copy of the symbol tail, so
//     S = sum conj(r(n-N)) * r(n)  over the last L CP samples = |.| e^{j2*pi*eps}
// S is taken from the training symbol of the new slot plus the 13 data-symbol
// CPs of the previous slot, its angle is found with a CORDIC, and the data
// buffer de-rotates every forwarded sample by e^{-j2*pi*eps*(n-d_hat)/N}.
//==============================================================================
`timescale 1ns / 1ps

// ------------------------------------------------------------------------------
module ts_sliding_corr #(
    parameter N  = 128,
    parameter W  = 16,
    parameter QB = 4,             // bits per I/Q sample for the paper metric
    parameter SH = 7              // input >>> SH before QB-bit saturation
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    input  wire [31:0]         in_idx,        // absolute sample index
    output reg                 p_valid,
    output reg  [31:0]         p_m0,          // |Re P1|+|Im P1|, sign-bit P1
    output reg  [31:0]         p_m1,          // |P|^2, QB-bit P
    output reg  [31:0]         p_d            // window start index d
);
    function [QB-1:0] quant;
        input signed [W-1:0] v;
        reg   signed [W-1:0] t;
        begin
            t = v >>> SH;
            if (t > (1 <<< (QB-1)) - 1)   quant = {1'b0, {(QB-1){1'b1}}};
            else if (t < -(1 <<< (QB-1))) quant = {1'b1, {(QB-1){1'b0}}};
            else                          quant = t[QB-1:0];
        end
    endfunction

    // element 0 = oldest = r(d) ... element N-1 = newest = r(d+N-1)
    reg [N-1:0]    buf_i, buf_q;
    reg [N*QB-1:0] qb_re, qb_im;

    // sign-bit pair : (a1 + j b1)(a2 + j b2),  a,b in {+1,-1}  (sign bit 1 -> -1)
    //   Re = a1a2 - b1b2 , Im = a1b2 + b1a2 ;  a1a2 = +1 when sign bits equal
    integer k;
    reg signed [10:0]   acc_re, acc_im;
    reg signed [15:0]   a1_re,  a1_im;
    reg signed [QB-1:0] xr1, xi1, xr2, xi2;
    always @(*) begin
        acc_re = 0; acc_im = 0; a1_re = 0; a1_im = 0;
        xr1 = 0; xi1 = 0; xr2 = 0; xi2 = 0;
        for (k = 1; k < N/2; k = k + 1) begin
            acc_re = acc_re + ((buf_i[k] ~^ buf_i[N-k]) ? 11'sd1 : -11'sd1)
                            - ((buf_q[k] ~^ buf_q[N-k]) ? 11'sd1 : -11'sd1);
            acc_im = acc_im + ((buf_i[k] ~^ buf_q[N-k]) ? 11'sd1 : -11'sd1)
                            + ((buf_q[k] ~^ buf_i[N-k]) ? 11'sd1 : -11'sd1);
            xr1 = qb_re[k*QB +: QB];     xi1 = qb_im[k*QB +: QB];
            xr2 = qb_re[(N-k)*QB +: QB]; xi2 = qb_im[(N-k)*QB +: QB];
            a1_re = a1_re + xr1 * xr2 - xi1 * xi2;
            a1_im = a1_im + xr1 * xi2 + xi1 * xr2;
        end
    end

    reg        sh_v;
    reg [31:0] sh_idx;
    always @(posedge clk) begin
        if (rst) begin
            buf_i <= 0; buf_q <= 0; qb_re <= 0; qb_im <= 0;
            sh_v <= 1'b0; p_valid <= 1'b0;
            p_m0 <= 0; p_m1 <= 0; p_d <= 0; sh_idx <= 0;
        end else begin
            sh_v <= in_valid;
            if (in_valid) begin
                buf_i  <= {in_re[W-1], buf_i[N-1:1]};
                buf_q  <= {in_im[W-1], buf_q[N-1:1]};
                qb_re  <= {quant(in_re), qb_re[N*QB-1:QB]};
                qb_im  <= {quant(in_im), qb_im[N*QB-1:QB]};
                sh_idx <= in_idx - (N - 1);
            end
            // register the adder-tree results one clock after the shift
            p_valid <= sh_v;
            if (sh_v) begin
                p_m0 <= (acc_re[10] ? -acc_re : acc_re) + (acc_im[10] ? -acc_im : acc_im);
                p_m1 <= a1_re * a1_re + a1_im * a1_im;
                p_d  <= sh_idx;
            end
        end
    end
endmodule

// ------------------------------------------------------------------------------
module ts_energy_acc #(
    parameter N = 128,
    parameter W = 16
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    output reg                 r_valid,
    output reg  [W+8:0]        r_sum             // sum of |re|+|im| over N samples
);
    wire [W:0] mag = (in_re[W-1] ? -in_re : in_re) + (in_im[W-1] ? -in_im : in_im);
    reg  [W:0] dly [0:N-1];
    integer i;
    reg  [W+8:0] acc;
    always @(posedge clk) begin
        if (rst) begin
            acc <= 0; r_valid <= 1'b0; r_sum <= 0;
            for (i = 0; i < N; i = i + 1) dly[i] <= 0;
        end else begin
            r_valid <= in_valid;
            if (in_valid) begin
                for (i = N-1; i > 0; i = i - 1) dly[i] <= dly[i-1];
                dly[0] <= mag;
                acc    <= acc + mag - dly[N-1];
            end
            r_sum <= acc;
        end
    end
endmodule

// ------------------------------------------------------------------------------
// CP correlator: S(n) = sum_{i=n-L+1}^{n} conj(r(i-N)) * r(i), on 8-bit samples.
// Same 2-clock latency as ts_sliding_corr, so s_* lines up with p_d.
module ts_cfo_corr #(
    parameter N  = 128,
    parameter W  = 16,
    parameter L  = 28,            // window (ISI-free part of the CP)
    parameter SH = 4              // input >>> SH before 8-bit saturation
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    output reg                 s_valid,
    output reg  signed [23:0]  s_re,
    output reg  signed [23:0]  s_im
);
    function signed [7:0] q8;
        input signed [W-1:0] v;
        reg   signed [W-1:0] t;
        begin
            t = v >>> SH;
            if (t > 127)       q8 = 8'sd127;
            else if (t < -128) q8 = -8'sd128;
            else               q8 = t[7:0];
        end
    endfunction

    wire signed [7:0] b_re = q8(in_re);
    wire signed [7:0] b_im = q8(in_im);

    // sample delay line (dq[N-1] = r(n-N) when r(n) arrives) and product
    // delay line (dp[L-1] = product that leaves the window). No reset (SRL);
    // the fill counter masks the undefined start-up contents.
    reg [15:0] dq [0:N-1];
    reg [35:0] dp [0:L-1];
    wire signed [7:0]  a_re = dq[N-1][7:0];
    wire signed [7:0]  a_im = dq[N-1][15:8];
    wire signed [17:0] pr_re = a_re * b_re + a_im * b_im;      // conj(a) * b
    wire signed [17:0] pr_im = a_re * b_im - a_im * b_re;
    wire signed [17:0] o_re  = dp[L-1][17:0];
    wire signed [17:0] o_im  = dp[L-1][35:18];

    reg  [8:0] fill;
    wire       have_a = (fill >= N);
    wire       have_o = (fill >= N + L);
    wire signed [17:0] pe_re = have_a ? pr_re : 18'sd0;
    wire signed [17:0] pe_im = have_a ? pr_im : 18'sd0;
    wire signed [17:0] oe_re = have_o ? o_re  : 18'sd0;
    wire signed [17:0] oe_im = have_o ? o_im  : 18'sd0;

    integer i;
    always @(posedge clk) begin
        if (in_valid) begin
            dq[0] <= {b_im, b_re};
            for (i = 1; i < N; i = i + 1) dq[i] <= dq[i-1];
            dp[0] <= {pe_im, pe_re};
            for (i = 1; i < L; i = i + 1) dp[i] <= dp[i-1];
        end
    end

    reg signed [23:0] acc_re, acc_im;
    reg               sh_v;
    always @(posedge clk) begin
        if (rst) begin
            fill <= 0; acc_re <= 0; acc_im <= 0; sh_v <= 1'b0;
            s_valid <= 1'b0; s_re <= 0; s_im <= 0;
        end else begin
            sh_v <= in_valid;
            if (in_valid) begin
                if (fill < N + L) fill <= fill + 1'b1;
                acc_re <= acc_re + pe_re - oe_re;
                acc_im <= acc_im + pe_im - oe_im;
            end
            s_valid <= sh_v;
            if (sh_v) begin s_re <= acc_re; s_im <= acc_im; end
        end
    end
endmodule

// ------------------------------------------------------------------------------
module ts_frame_find #(
    parameter N         = 128,
    parameter SLOT_LEN  = 2244,      // samples per slot
    parameter ARM_EARLY = 32,        // re-arm this many samples before next training
    parameter TH0       = 88,        // sign-bit metric threshold (ideal peak 126)
    parameter TH1       = 380000,    // |P|^2 metric threshold (QB = 4, SH = 7)
    parameter E_MIN     = 16384,     // minimum window energy
    parameter HOLD      = 80         // samples without a new max before lock
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               metric_sel,
    input  wire               p_valid,
    input  wire [31:0]        p_m0,
    input  wire [31:0]        p_m1,
    input  wire [31:0]        p_d,
    input  wire [24:0]        r_sum,
    input  wire signed [23:0] s_re,          // CP correlation aligned with p_d
    input  wire signed [23:0] s_im,
    output reg                lock,          // 1-clock pulse
    output reg  [31:0]        d_hat,         // index of training start (after CP)
    output reg  [31:0]        peak0,         // sign-bit metric at d_hat
    output reg  [31:0]        peak1,         // |P|^2 metric at d_hat
    output reg  signed [23:0] lk_s_re,       // training CP correlation at d_hat
    output reg  signed [23:0] lk_s_im,
    output reg                searching
);
    wire [31:0] m  = metric_sel ? p_m1 : p_m0;
    wire [31:0] th = metric_sel ? TH1  : TH0;

    reg  [31:0]        best, best_d, best0, best1, arm_at;
    reg  signed [23:0] bs_re, bs_im;
    reg  [7:0]         since;
    reg                have;

    always @(posedge clk) begin
        if (rst) begin
            searching <= 1'b1; lock <= 1'b0; have <= 1'b0; best <= 0;
            best_d <= 0; best0 <= 0; best1 <= 0; bs_re <= 0; bs_im <= 0;
            since <= 0; d_hat <= 0; peak0 <= 0; peak1 <= 0;
            lk_s_re <= 0; lk_s_im <= 0; arm_at <= 0;
        end else begin
            lock <= 1'b0;
            if (!searching) begin
                // re-arm shortly before the next expected training symbol
                if (p_valid && ($signed(p_d - arm_at) >= 0)) begin
                    searching <= 1'b1; have <= 1'b0; best <= 0; since <= 0;
                end
            end else if (p_valid) begin
                if (m >= th && r_sum >= E_MIN && (!have || m > best)) begin
                    have <= 1'b1; best <= m; best_d <= p_d; since <= 0;
                    best0 <= p_m0; best1 <= p_m1; bs_re <= s_re; bs_im <= s_im;
                end else if (have) begin
                    if (since == HOLD-1) begin
                        lock      <= 1'b1;
                        d_hat     <= best_d;
                        peak0     <= best0;
                        peak1     <= best1;
                        lk_s_re   <= bs_re;
                        lk_s_im   <= bs_im;
                        searching <= 1'b0;
                        have      <= 1'b0;
                        arm_at    <= best_d + SLOT_LEN - ARM_EARLY;
                    end
                    since <= since + 1'b1;
                end
            end
        end
    end
endmodule

// ------------------------------------------------------------------------------
// Data buffer: delays the stream by DBUF samples (SRL-friendly, no reset).
// On slot_go (training position d_hat + CFO step from the estimator) it
// removes the CP of every symbol and forwards N useful samples per symbol
// (training symbol + NDATA data symbols) into a FIFO, de-rotated by the
// CFO correction e^{j*2*pi*ph}, ph = dphi*(n - d_hat) (24-bit turn fraction).
// The FFT window starts BO samples early inside the CP (bo input), which the
// equaliser removes; bo = 0 keeps the window exactly at d_hat.
// A slot_go that arrives while the previous slot is still being forwarded is
// held (pending) and started as soon as that slot is done.
// Output word: {first_of_slot (training sample 0), im, re}
module ts_data_buffer #(
    parameter N      = 128,
    parameter CP     = 32,
    parameter W      = 16,
    parameter NSYMRX = 14,          // training + data symbols per slot
    parameter DBUF   = 256,
    parameter FAW    = 9
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    input  wire [31:0]         in_idx,
    input  wire                slot_go,
    input  wire [31:0]         go_dhat,
    input  wire [23:0]         go_dphi,
    input  wire [3:0]          go_bo,
    output reg                 slot_done,   // 1-clock pulse
    // FIFO read side
    input  wire                rd_en,
    output wire [2*W:0]        rd_data,
    output wire                rd_avail
);
    // ---- delay line (shift register enabled by valid -> SRL inference) ----
    reg [2*W+31:0] dl [0:DBUF-1];
    integer i;
    always @(posedge clk) begin
        if (in_valid) begin
            dl[0] <= {in_idx, in_im, in_re};
            for (i = 1; i < DBUF; i = i + 1) dl[i] <= dl[i-1];
        end
    end
    wire [2*W+31:0]     d_out = dl[DBUF-1];
    wire [31:0]         d_idx = d_out[2*W+31:2*W];
    wire signed [W-1:0] d_re  = d_out[W-1:0];
    wire signed [W-1:0] d_im  = d_out[2*W-1:W];

    // valid of delayed sample: becomes true after DBUF inputs
    reg [15:0] fill;
    wire       d_valid = in_valid && (fill >= DBUF);
    always @(posedge clk) begin
        if (rst) fill <= 0;
        else if (in_valid && fill < DBUF) fill <= fill + 1'b1;
    end

    // ---- symbol framing ----
    reg        active, pend;
    reg [31:0] p_dhat;
    reg [23:0] p_dphi;
    reg [3:0]  p_bo;
    reg [31:0] sym_start;      // index of first FFT-window sample of current symbol
    reg [31:0] ref_idx;        // d_hat : CFO phase reference
    reg [23:0] dphi;
    reg [3:0]  sym_cnt;
    reg        first_flag;

    wire [31:0] off  = d_idx - sym_start;
    wire [31:0] rel  = d_idx - ref_idx;
    wire [23:0] ph24 = dphi * rel[23:0];               // modulo 2^24 turns
    wire [23:0] ph24r = ph24 + 24'h002000;              // round to 10 bits

    // stage A : selected sample + its correction phase
    reg                a_v, a_first;
    reg signed [W-1:0] a_re, a_im;
    reg [9:0]          a_ph;

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0; pend <= 1'b0; p_dhat <= 0; p_dphi <= 0; p_bo <= 0;
            sym_start <= 0; ref_idx <= 0; dphi <= 0; sym_cnt <= 0;
            first_flag <= 1'b0; slot_done <= 1'b0;
            a_v <= 1'b0; a_first <= 1'b0; a_re <= 0; a_im <= 0; a_ph <= 0;
        end else begin
            slot_done <= 1'b0;
            a_v       <= 1'b0;

            // ---- slot start / pending start ----
            if (slot_go && active) begin
                pend <= 1'b1; p_dhat <= go_dhat; p_dphi <= go_dphi; p_bo <= go_bo;
            end else if (slot_go) begin            // idle: start now
                pend       <= 1'b0;
                active     <= 1'b1;
                sym_start  <= go_dhat - go_bo;
                ref_idx    <= go_dhat;
                dphi       <= go_dphi;
                sym_cnt    <= 0;
                first_flag <= 1'b1;
            end else if (!active && pend) begin    // previous slot finished
                pend       <= 1'b0;
                active     <= 1'b1;
                sym_start  <= p_dhat - p_bo;
                ref_idx    <= p_dhat;
                dphi       <= p_dphi;
                sym_cnt    <= 0;
                first_flag <= 1'b1;
            end

            // ---- forward the N useful samples of each symbol ----
            // (in_valid is the shift strobe: d_out is the sample being shifted
            //  out of the delay line in this cycle)
            if (active && d_valid && (off < N)) begin
                a_v     <= 1'b1;
                a_first <= first_flag && (off == 0);
                a_re    <= d_re;
                a_im    <= d_im;
                a_ph    <= ph24r[23:14];
                if (off == N-1) begin
                    first_flag <= 1'b0;
                    sym_start  <= sym_start + N + CP;
                    if (sym_cnt == NSYMRX-1) begin
                        active    <= 1'b0;
                        slot_done <= 1'b1;
                    end
                    sym_cnt <= sym_cnt + 1'b1;
                end
            end
        end
    end

    // stage B : CFO de-rotation, then into the FIFO
    wire signed [15:0]  cf_c, cf_s;
    wire signed [W-1:0] b_re, b_im;
    sincos_lut u_cfo_lut (.phase(a_ph), .cos_o(cf_c), .sin_o(cf_s));
    cplx_rot #(.W(W), .CW(16), .CF(14)) u_cfo_rot (
        .i_i(a_re), .q_i(a_im), .c(cf_c), .s(cf_s), .i_o(b_re), .q_o(b_im));

    reg         push;
    reg [2*W:0] push_data;
    always @(posedge clk) begin
        if (rst) begin
            push <= 1'b0; push_data <= 0;
        end else begin
            push      <= a_v;
            push_data <= {a_first, b_im, b_re};
        end
    end

    wire f_full, f_empty;
    wire [FAW:0] f_cnt;
    sync_fifo #(.DW(2*W+1), .AW(FAW)) u_fifo (
        .clk(clk), .rst(rst), .flush(1'b0),
        .wr_en(push), .din(push_data),
        .rd_en(rd_en), .dout(rd_data),
        .full(f_full), .empty(f_empty), .count(f_cnt));
    assign rd_avail = !f_empty;
endmodule

// ------------------------------------------------------------------------------
module timing_sync #(
    parameter N         = 128,
    parameter CP        = 32,
    parameter CP0       = 36,
    parameter W         = 16,
    parameter NDATA     = 13,
    parameter TH0       = 88,
    parameter TH1       = 380000,
    parameter E_MIN     = 16384,
    parameter BACKOFF   = 4          // FFT window advance when the equaliser is on
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                metric_sel,   // 1 = paper |P|^2 metric
    input  wire                cfo_en,
    input  wire                eq_en,        // enables the FFT-window back-off
    input  wire                in_valid,
    input  wire signed [W-1:0] in_re,
    input  wire signed [W-1:0] in_im,
    // to the demodulator
    input  wire                rd_en,
    output wire [2*W:0]        rd_data,
    output wire                rd_avail,
    // status
    output wire                lock_pulse,
    output wire                locked,
    output wire [31:0]         peak0,
    output wire [31:0]         peak1,
    output reg  [15:0]         cfo_est,      // angle of S: eps = cfo_est/65536 subcarriers
    output reg  [31:0]         slot_count
);
    localparam SLOT_LEN = (N + CP0) + NDATA * (N + CP);

    reg [31:0] idx;
    always @(posedge clk) begin
        if (rst) idx <= 0;
        else if (in_valid) idx <= idx + 1'b1;
    end

    wire               p_valid, r_valid, s_valid;
    wire [31:0]        p_m0, p_m1, p_d;
    wire [W+8:0]       r_sum;
    wire signed [23:0] s_re, s_im, lk_s_re, lk_s_im;
    wire [31:0]        d_hat;
    wire               slot_done, searching;

    ts_sliding_corr #(.N(N), .W(W)) u_corr (
        .clk(clk), .rst(rst), .in_valid(in_valid),
        .in_re(in_re), .in_im(in_im), .in_idx(idx),
        .p_valid(p_valid), .p_m0(p_m0), .p_m1(p_m1), .p_d(p_d));

    // energy sum: same 2-clock latency as the correlator -> R(d) aligned with P(d)
    ts_energy_acc #(.N(N), .W(W)) u_energy (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_re(in_re), .in_im(in_im),
        .r_valid(r_valid), .r_sum(r_sum));

    ts_cfo_corr #(.N(N), .W(W)) u_cfo (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_re(in_re), .in_im(in_im),
        .s_valid(s_valid), .s_re(s_re), .s_im(s_im));

    ts_frame_find #(.N(N), .SLOT_LEN(SLOT_LEN), .TH0(TH0), .TH1(TH1), .E_MIN(E_MIN)) u_find (
        .clk(clk), .rst(rst), .metric_sel(metric_sel),
        .p_valid(p_valid), .p_m0(p_m0), .p_m1(p_m1), .p_d(p_d), .r_sum(r_sum),
        .s_re(s_re), .s_im(s_im),
        .lock(lock_pulse), .d_hat(d_hat), .peak0(peak0), .peak1(peak1),
        .lk_s_re(lk_s_re), .lk_s_im(lk_s_im), .searching(searching));

    // ---------------- CFO: accumulate the data-symbol CPs of each slot -------
    reg  [31:0]        cap_at;
    reg  [3:0]         cap_cnt;
    reg  signed [27:0] sacc_re, sacc_im;
    reg                cv_start;
    reg  signed [25:0] cv_x, cv_y;
    reg  [31:0]        cv_dhat;
    wire               cv_done;
    wire [15:0]        cv_angle;

    wire               hist_ok = (cap_cnt == NDATA);   // previous slot complete

    always @(posedge clk) begin
        if (rst) begin
            cap_at <= 0; cap_cnt <= 0; sacc_re <= 0; sacc_im <= 0;
            cv_start <= 1'b0; cv_x <= 0; cv_y <= 0; cv_dhat <= 0;
        end else begin
            cv_start <= 1'b0;
            if (lock_pulse) begin
                // training CP + (previous slot's 13 data CPs if complete)
                cv_x     <= (lk_s_re + (hist_ok ? sacc_re : 28'sd0)) >>> 2;
                cv_y     <= (lk_s_im + (hist_ok ? sacc_im : 28'sd0)) >>> 2;
                cv_start <= 1'b1;
                cv_dhat  <= d_hat;
                // start collecting this slot's data-symbol CPs
                sacc_re  <= 0; sacc_im <= 0; cap_cnt <= 0;
                cap_at   <= d_hat + N + CP;            // useful start of symbol 1
            end else if (p_valid && (cap_cnt < NDATA) && (p_d == cap_at)) begin
                sacc_re <= sacc_re + s_re;
                sacc_im <= sacc_im + s_im;
                cap_cnt <= cap_cnt + 1'b1;
                cap_at  <= cap_at + N + CP;
            end
        end
    end

    cordic_vec #(.IW(26)) u_cordic (
        .clk(clk), .rst(rst), .start(cv_start), .x_in(cv_x), .y_in(cv_y),
        .done(cv_done), .angle(cv_angle));

    // per-sample correction step: -(eps/N) turns in 2^-24 units
    //   = -(angle/65536)/N * 2^24 = -angle * 2^(8 - log2 N)   (N <= 256)
    localparam DSH = 8 - $clog2(N);
    reg         slot_go;
    reg  [31:0] go_dhat;
    reg  [23:0] go_dphi;
    reg  [3:0]  go_bo;
    always @(posedge clk) begin
        if (rst) begin
            slot_go <= 1'b0; go_dhat <= 0; go_dphi <= 0; go_bo <= 0; cfo_est <= 0;
        end else begin
            slot_go <= 1'b0;
            if (cv_done) begin
                slot_go <= 1'b1;
                go_dhat <= cv_dhat;
                go_dphi <= cfo_en ? (24'd0 - ({{8{cv_angle[15]}}, cv_angle} << DSH)) : 24'd0;
                go_bo   <= eq_en ? BACKOFF : 4'd0;
                cfo_est <= cv_angle;
            end
        end
    end

    ts_data_buffer #(.N(N), .CP(CP), .W(W), .NSYMRX(NDATA+1), .DBUF(2*N)) u_buf (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_re(in_re), .in_im(in_im),
        .in_idx(idx), .slot_go(slot_go), .go_dhat(go_dhat), .go_dphi(go_dphi),
        .go_bo(go_bo), .slot_done(slot_done),
        .rd_en(rd_en), .rd_data(rd_data), .rd_avail(rd_avail));

    assign locked = !searching;
    always @(posedge clk) begin
        if (rst) slot_count <= 0;
        else if (lock_pulse) slot_count <= slot_count + 1'b1;
    end
endmodule
