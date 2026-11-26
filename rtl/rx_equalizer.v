//==============================================================================
// rx_equalizer.v  -  one-tap (per sub-carrier) frequency-domain equaliser
//
// Channel estimate from the known training symbol of every slot:
//   X(k) : 16-QAM real level from the same M-sequence (x^9 + x^5 + 1, seed
//          0x1FF, 2 bits per sub-carrier) the TX uses, imaginary part 0
//   Y(k) : RX FFT output of the training symbol
//   W(k) = 1/H(k) = X(k) / Y(k) = X(k) * conj(Y(k)) / |Y(k)|^2
// W is stored as signed Q4.14 (18 bit, |W| < 8) and applied to the data
// symbols by the caller as Z(k) = Y(k) * W(k). W also absorbs the common
// phase left after CFO correction and the linear phase of the FFT-window
// back-off. The two divisions per sub-carrier use a 17-step restoring divider
// (about 19 clocks per sub-carrier, ~2.5k clocks per slot).
//
// eq_en = 0 : W(k) = 1 for all k and w_ready is held high (bypass).
//==============================================================================
`timescale 1ns / 1ps
module rx_equalizer #(
    parameter N    = 128,
    parameter LOGN = 7,
    parameter W    = 16,
    parameter A    = 2048
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 eq_en,
    // training-symbol FFT output, k = 0 .. N-1 in order
    input  wire                 tr_valid,
    input  wire [LOGN-1:0]      tr_k,
    input  wire signed [W-1:0]  tr_re,
    input  wire signed [W-1:0]  tr_im,
    // coefficient read port (combinational)
    input  wire [LOGN-1:0]      rd_k,
    output wire signed [17:0]   w_re,
    output wire signed [17:0]   w_im,
    output wire                 w_ready
);
    localparam QW = 17;                       // quotient magnitude bits

    reg signed [W-1:0] y_re [0:N-1];
    reg signed [W-1:0] y_im [0:N-1];
    reg [1:0]          xc   [0:N-1];          // Gray code of the training level
    reg signed [17:0]  wr   [0:N-1];
    reg signed [17:0]  wi   [0:N-1];

    // ---------------- training capture + RX copy of the M-sequence ----------
    reg  [8:0] mseq;
    wire [8:0] m_cur = (tr_k == 0) ? 9'h1FF : mseq;
    wire       m_b1  = m_cur[8] ^ m_cur[4];
    wire [8:0] m_1   = {m_cur[7:0], m_b1};
    wire       m_b0  = m_1[8] ^ m_1[4];

    function signed [14:0] lvl;               // Gray: 00 -3A, 01 -A, 11 +A, 10 +3A
        input [1:0] b;
        case (b)
            2'b00:   lvl = -3 * A;
            2'b01:   lvl = -1 * A;
            2'b11:   lvl =  1 * A;
            default: lvl =  3 * A;
        endcase
    endfunction

    // ---------------- coefficient computation FSM ----------------
    localparam E_IDLE = 2'd0, E_LOAD = 2'd1, E_DIV = 2'd2, E_STORE = 2'd3;
    reg [1:0]      st;
    reg            ready_r;
    reg [LOGN-1:0] kk;
    reg [4:0]      it;
    reg [49:0]     rr, ri;                     // remainders (numerator << 14)
    reg [31:0]     dd;                         // divisor |Y|^2
    reg [QW-1:0]   qr, qi;
    reg            sr, si, ovr, ovi, zden;

    // operands of sub-carrier kk
    wire signed [W-1:0]  yk_re = y_re[kk];
    wire signed [W-1:0]  yk_im = y_im[kk];
    wire signed [14:0]   xk    = lvl(xc[kk]);
    wire signed [31:0]   nr    = xk * yk_re;              //  X * Re(Y)
    wire signed [31:0]   ni    = -(xk * yk_im);           // -X * Im(Y)
    wire signed [32:0]   den_s = yk_re * yk_re + yk_im * yk_im;
    wire [31:0]          den   = den_s[31:0];
    wire [30:0]          nr_m  = nr[31] ? -nr : nr;
    wire [30:0]          ni_m  = ni[31] ? -ni : ni;
    wire [49:0]          nr_s  = {5'd0, nr_m, 14'd0};     // |num| * 2^14
    wire [49:0]          ni_s  = {5'd0, ni_m, 14'd0};
    wire [49:0]          dlim  = {1'b0, dd, 17'd0};       // den * 2^QW
    wire [49:0]          dsh   = {18'd0, dd} << it;

    function signed [17:0] sgn_q;
        input [QW-1:0] q;
        input          neg, ov, z;
        reg   [QW-1:0] m;
        begin
            m     = z ? {QW{1'b0}} : (ov ? {QW{1'b1}} : q);
            sgn_q = neg ? -$signed({1'b0, m}) : $signed({1'b0, m});
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            st <= E_IDLE; ready_r <= 1'b0; kk <= 0; it <= 0; mseq <= 9'h1FF;
            rr <= 0; ri <= 0; dd <= 0; qr <= 0; qi <= 0;
            sr <= 1'b0; si <= 1'b0; ovr <= 1'b0; ovi <= 1'b0; zden <= 1'b0;
        end else begin
            // capture (has priority: a new training restarts the estimate)
            if (tr_valid) begin
                y_re[tr_k] <= tr_re;
                y_im[tr_k] <= tr_im;
                xc[tr_k]   <= {m_b1, m_b0};
                mseq       <= {m_1[7:0], m_b0};
                ready_r    <= 1'b0;
                st         <= E_IDLE;
                if (tr_k == N-1) begin kk <= 0; st <= E_LOAD; end
            end else begin
                case (st)
                E_LOAD: begin
                    rr   <= nr_s;  ri <= ni_s;  dd <= den;
                    sr   <= nr[31]; si <= ni[31];
                    zden <= (den == 0);
                    qr   <= 0; qi <= 0;
                    it   <= QW - 1;
                    st   <= E_DIV;
                end
                E_DIV: begin
                    if (it == QW - 1) begin         // overflow check on first step
                        ovr <= (rr >= dlim);
                        ovi <= (ri >= dlim);
                    end
                    if (rr >= dsh) begin rr <= rr - dsh; qr[it] <= 1'b1; end
                    if (ri >= dsh) begin ri <= ri - dsh; qi[it] <= 1'b1; end
                    if (it == 0) st <= E_STORE;
                    else         it <= it - 1'b1;
                end
                E_STORE: begin
                    wr[kk] <= sgn_q(qr, sr, ovr, zden);
                    wi[kk] <= sgn_q(qi, si, ovi, zden);
                    if (kk == N-1) begin ready_r <= 1'b1; st <= E_IDLE; end
                    else begin kk <= kk + 1'b1; st <= E_LOAD; end
                end
                default: ;
                endcase
            end
        end
    end

    assign w_ready = eq_en ? ready_r : 1'b1;
    assign w_re    = eq_en ? wr[rd_k] : 18'sd16384;
    assign w_im    = eq_en ? wi[rd_k] : 18'sd0;
endmodule
