//==============================================================================
// channel_model.v  (simulation only)
//
// Models what sits between the FPGA TX and RX in the paper's test bench
// (Fig. 5: RRU -> mixer -> RF -> VSA):
//   * NR up-conversion phase per OFDM symbol (3GPP TS 38.211 Sec. 5.4):
//       phi_l = 2*pi*F0_HZ*(t_start,l + N_CP,l*Ts)   (mod 2*pi)
//     i.e. the phase term a plain mixer adds and the transmitter phase
//     compensation must pre-cancel. Symbol 0 has the long CP0.
//   * optional 2-tap multipath  h = [1, MP_GAIN*e^{j MP_DEG}] at MP_DLY samples
//   * optional carrier frequency offset of CFO_EPS sub-carrier spacings
//   * additive uniform noise of +-NOISE LSB on I and Q
//   * idle noise samples before the burst (unknown arrival time)
//==============================================================================
`timescale 1ns / 1ps
module channel_model #(
    parameter W       = 16,
    parameter NOISE   = 8,
    parameter NSYM    = 14,
    parameter N       = 128,
    parameter CP      = 32,
    parameter CP0     = 36,
    parameter real F0_HZ   = 3.5e9,       // carrier frequency
    parameter real T_SLOT  = 0.5e-3,      // slot duration
    parameter real CFO_EPS = 0.05,        // CFO in sub-carrier spacings
    parameter real MP_GAIN = 0.3,
    parameter real MP_DEG  = 45.0,
    parameter      MP_DLY  = 3
)(
    input  wire                 clk,
    input  wire                 idle_noise_en,
    input  wire                 cfo_en,
    input  wire                 mp_en,
    input  wire                 in_valid,
    input  wire signed [W-1:0]  in_re,
    input  wire signed [W-1:0]  in_im,
    input  wire [3:0]           in_sym_idx,
    output reg                  out_valid,
    output reg  signed [W-1:0]  out_re,
    output reg  signed [W-1:0]  out_im
);
    localparam real PI = 3.14159265358979;
    localparam SLOT_SAMPLES = (N + CP0) + (NSYM - 1) * (N + CP);

    real    phi_rad [0:NSYM-1];
    real    hr [0:7];                 // multipath history (MP_DLY <= 7)
    real    hi [0:7];
    real    c, s, xr, xi, yr, yi, zr, zi, ph, ts, st;
    real    mp_c, mp_s;
    integer l, j, seed;
    real    ncnt;                     // output sample counter (for the CFO)

    initial begin
        seed = 2026;
        ts   = T_SLOT / SLOT_SAMPLES;
        st   = 0.0;                   // start of symbol l (samples, incl. its CP)
        for (l = 0; l < NSYM; l = l + 1) begin
            ph = F0_HZ * ts * (st + ((l == 0) ? CP0 : CP));    // cycles
            ph = ph - $floor(ph);
            phi_rad[l] = 2.0 * PI * ph;
            $display("channel: phi[%0d] = %0.1f deg", l, phi_rad[l] * 180.0 / PI);
            st = st + N + ((l == 0) ? CP0 : CP);
        end
        mp_c = MP_GAIN * $cos(MP_DEG * PI / 180.0);
        mp_s = MP_GAIN * $sin(MP_DEG * PI / 180.0);
        for (j = 0; j < 8; j = j + 1) begin hr[j] = 0.0; hi[j] = 0.0; end
        ncnt = 0.0;
        out_valid = 0; out_re = 0; out_im = 0;
    end

    function integer noise;
        input integer dummy;
        begin
            noise = ($random(seed) % (NOISE + 1));
        end
    endfunction

    function signed [W-1:0] sat;
        input real v;
        integer iv;
        begin
            iv = (v >= 0.0) ? $rtoi(v + 0.5) : -$rtoi(-v + 0.5);
            if (iv >  32767) iv =  32767;
            if (iv < -32768) iv = -32768;
            sat = iv;
        end
    endfunction

    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (in_valid || idle_noise_en) begin
            // 1) NR up-conversion phase of this symbol
            if (in_valid) begin
                c  = $cos(phi_rad[in_sym_idx]);
                s  = $sin(phi_rad[in_sym_idx]);
                xr = in_re; xi = in_im;
                yr = xr * c - xi * s;
                yi = xr * s + xi * c;
            end else begin
                yr = 0.0; yi = 0.0;
            end
            // 2) multipath
            zr = yr; zi = yi;
            if (mp_en) begin
                zr = zr + mp_c * hr[MP_DLY-1] - mp_s * hi[MP_DLY-1];
                zi = zi + mp_c * hi[MP_DLY-1] + mp_s * hr[MP_DLY-1];
            end
            for (j = 7; j > 0; j = j - 1) begin hr[j] = hr[j-1]; hi[j] = hi[j-1]; end
            hr[0] = yr; hi[0] = yi;
            // 3) carrier frequency offset
            if (cfo_en) begin
                ph = 2.0 * PI * CFO_EPS * ncnt / N;
                c  = $cos(ph); s = $sin(ph);
                yr = zr * c - zi * s;
                yi = zr * s + zi * c;
                zr = yr; zi = yi;
            end
            ncnt = ncnt + 1.0;
            // 4) noise
            out_valid <= 1'b1;
            out_re    <= sat(zr + noise(0));
            out_im    <= sat(zi + noise(0));
        end
    end
endmodule
