//==============================================================================
// cordic_vec.v  -  iterative CORDIC in vectoring mode: angle of (x + j y)
//   angle is returned as an unsigned 16-bit fraction of a full turn
//   (0x4000 = +90 deg, 0x8000 = 180 deg, 0xC000 = -90 deg).
//   16 iterations, one per clock; 'done' pulses 17 clocks after 'start'.
//   Used once per slot by the RX CFO estimator.
//==============================================================================
`timescale 1ns / 1ps
module cordic_vec #(
    parameter IW = 26                       // input width (signed)
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 start,
    input  wire signed [IW-1:0] x_in,
    input  wire signed [IW-1:0] y_in,
    output reg                  done,
    output reg  [15:0]          angle
);
    // atan(2^-i) / (2*pi) * 65536
    function [15:0] atan_t;
        input [3:0] i;
        begin
            case (i)
                4'd0:  atan_t = 16'd8192;
                4'd1:  atan_t = 16'd4836;
                4'd2:  atan_t = 16'd2555;
                4'd3:  atan_t = 16'd1297;
                4'd4:  atan_t = 16'd651;
                4'd5:  atan_t = 16'd326;
                4'd6:  atan_t = 16'd163;
                4'd7:  atan_t = 16'd81;
                4'd8:  atan_t = 16'd41;
                4'd9:  atan_t = 16'd20;
                4'd10: atan_t = 16'd10;
                4'd11: atan_t = 16'd5;
                4'd12: atan_t = 16'd3;
                4'd13: atan_t = 16'd1;
                4'd14: atan_t = 16'd1;
                default: atan_t = 16'd0;
            endcase
        end
    endfunction

    reg signed [IW+1:0] x, y;               // 2 guard bits for the CORDIC gain
    reg [15:0]          z;
    reg [3:0]           it;
    reg                 busy;

    wire                pos  = (y > 0);
    wire signed [IW+1:0] x_nx = pos ? x + (y >>> it) : x - (y >>> it);
    wire signed [IW+1:0] y_nx = pos ? y - (x >>> it) : y + (x >>> it);
    wire [15:0]          z_nx = pos ? z + atan_t(it) : z - atan_t(it);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; done <= 1'b0; it <= 4'd0;
            x <= 0; y <= 0; z <= 16'd0; angle <= 16'd0;
        end else begin
            done <= 1'b0;
            if (start) begin
                busy <= 1'b1;
                it   <= 4'd0;
                if (x_in < 0) begin                 // pre-rotate by 180 deg
                    x <= -x_in; y <= -y_in; z <= 16'h8000;
                end else begin
                    x <=  x_in; y <=  y_in; z <= 16'h0000;
                end
            end else if (busy) begin
                x <= x_nx; y <= y_nx; z <= z_nx;
                if (it == 4'd15) begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    angle <= z_nx;
                end
                it <= it + 1'b1;
            end
        end
    end
endmodule
