//==============================================================================
// cplx_rot.v  -  combinational complex multiply  y = x * (c + j s)
//   x : signed W-bit I/Q,  c/s : signed CW-bit, CF fractional bits (Q.14)
//   Convergent (round-half-even) rounding, saturation back to W bits.
// Used for: chaotic I/Q phase encryption (TX) / decryption (RX), the RX CFO
// de-rotator and the RX one-tap equaliser (CW = 18).
//==============================================================================
`timescale 1ns / 1ps
module cplx_rot #(
    parameter W  = 16,
    parameter CW = 16,
    parameter CF = 14
)(
    input  wire signed [W-1:0]  i_i,
    input  wire signed [W-1:0]  q_i,
    input  wire signed [CW-1:0] c,
    input  wire signed [CW-1:0] s,
    output wire signed [W-1:0]  i_o,
    output wire signed [W-1:0]  q_o
);
    localparam PW = W + CW + 1;                 // product-sum width

    wire signed [PW-1:0] re = i_i * c - q_i * s;
    wire signed [PW-1:0] im = i_i * s + q_i * c;

    // round-half-even: add (half - 1) plus the LSB of the kept part
    function signed [PW-1:0] rnd;
        input signed [PW-1:0] v;
        begin
            rnd = (v + ((1 <<< (CF-1)) - 1) + $signed({1'b0, v[CF]})) >>> CF;
        end
    endfunction

    function signed [W-1:0] sat;
        input signed [PW-1:0] v;
        begin
            if (v > $signed((1 <<< (W-1)) - 1))  sat = {1'b0, {(W-1){1'b1}}};
            else if (v < -$signed(1 <<< (W-1)))  sat = {1'b1, {(W-1){1'b0}}};
            else                                 sat = v[W-1:0];
        end
    endfunction

    assign i_o = sat(rnd(re));
    assign q_o = sat(rnd(im));
endmodule
