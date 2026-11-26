//==============================================================================
// tb_ofdm_top.v  -  system testbench for ofdm_top
//
//  ofdm_top.tx_*  ->  channel_model (NR phase, multipath, CFO, noise, delay)
//                 ->  ofdm_top.rx_*
//
//  The testbench plays the role of the ARM processor: it computes the 14
//  phase-compensation coefficients from the NR up-conversion formula
//  (same as sw/pc_coef.c) and writes them through AXI-Lite.
//  Clock: 50 MHz (paper Sec. III-C system frequency), slot = 0.5 ms.
//
//  Test 1 : chaos ON , phase compensation OFF  -> BER > 0
//  Test 2 : chaos ON , phase compensation ON   -> BER = 0, low EVM
//  Test 3 : RX key != TX key (eavesdropper)    -> BER ~ 50 %   (security)
//  Test 4 : chaos OFF, phase compensation ON   -> BER = 0 (plain OFDM)
//  Test 5 : paper timing metric |P|^2 (R = 1)  -> BER = 0
//  Test 6 : CFO 0.05 sub-carrier + 2-tap multipath, CFO correction and
//           equaliser ON                       -> BER = 0
//  Final  : TX playout never underflowed / mis-aligned.
//==============================================================================
`timescale 1ns / 1ps
module tb_ofdm_top;
    localparam N = 128, CP = 32, CP0 = 36, W = 16, NSYM = 14;
    localparam real PI    = 3.14159265358979;
    localparam real F0_HZ = 3.5e9;
    localparam real T_SLOT = 0.5e-3;
    localparam real CFO_EPS = 0.05;

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;                      // 50 MHz

    // AXI-Lite
    reg  [7:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    // streams
    wire                tx_valid, tx_sof, tx_sos;
    wire signed [W-1:0] tx_i, tx_q;
    wire [3:0]          tx_sym_idx;
    wire                rx_valid;
    wire signed [W-1:0] rx_i, rx_q;
    wire                led_locked, led_ok, dbg_valid;
    wire signed [W-1:0] dbg_i, dbg_q;
    reg                 idle_noise_en = 1'b0;
    reg                 ch_cfo_en = 1'b0, ch_mp_en = 1'b0;

    ofdm_top #(.N(N), .LOGN(7), .CP(CP), .CP0(CP0), .W(W), .NSYM(NSYM), .SLOTS(20),
               .CLKS_PER_SLOT(25000)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .tx_valid(tx_valid), .tx_i(tx_i), .tx_q(tx_q), .tx_sof(tx_sof), .tx_sos(tx_sos),
        .tx_sym_idx(tx_sym_idx),
        .rx_valid(rx_valid), .rx_i(rx_i), .rx_q(rx_q),
        .led_rx_locked(led_locked), .led_ber_ok(led_ok),
        .dbg_valid(dbg_valid), .dbg_i(dbg_i), .dbg_q(dbg_q));

    channel_model #(.W(W), .NOISE(8), .NSYM(NSYM), .N(N), .CP(CP), .CP0(CP0),
                    .F0_HZ(F0_HZ), .T_SLOT(T_SLOT), .CFO_EPS(CFO_EPS)) u_ch (
        .clk(clk), .idle_noise_en(idle_noise_en), .cfo_en(ch_cfo_en), .mp_en(ch_mp_en),
        .in_valid(tx_valid), .in_re(tx_i), .in_im(tx_q), .in_sym_idx(tx_sym_idx),
        .out_valid(rx_valid), .out_re(rx_i), .out_im(rx_q));

    // ------------------------------------------------------------ AXI tasks --
    task axi_write(input [7:0] a, input [31:0] d);
        begin
            @(negedge clk);
            awaddr = a; awvalid = 1; wdata = d; wvalid = 1; bready = 1;
            fork
                begin wait (awready); @(negedge clk); awvalid = 0; end
                begin wait (wready);  @(negedge clk); wvalid  = 0; end
            join
            // keep bready high across a rising edge that sees bvalid
            wait (bvalid); @(posedge clk); #1; bready = 0;
        end
    endtask

    task axi_read(input [7:0] a, output [31:0] d);
        begin
            @(negedge clk);
            araddr = a; arvalid = 1; rready = 1;
            wait (arready); @(negedge clk); arvalid = 0;
            wait (rvalid); d = rdata; @(posedge clk); #1; rready = 0;
        end
    endtask

    // --------------------------------------------------------- EVM monitor --
    real evm_err, evm_ref;
    integer evm_n;
    integer fd_const = 0, test_no = 0;   // constellation dump: test,I,Q
    function real nearest; input real v;
        begin
            if      (v < -4096.0) nearest = -6144.0;
            else if (v <  0.0)    nearest = -2048.0;
            else if (v <  4096.0) nearest =  2048.0;
            else                  nearest =  6144.0;
        end
    endfunction
    always @(posedge clk) if (dbg_valid) begin : evm_acc
        real ri, rq;
        ri = nearest(dbg_i); rq = nearest(dbg_q);
        evm_err = evm_err + (dbg_i - ri) * (dbg_i - ri) + (dbg_q - rq) * (dbg_q - rq);
        evm_ref = evm_ref + ri * ri + rq * rq;
        evm_n   = evm_n + 1;
        if (fd_const != 0 && evm_n <= 1024) $fdisplay(fd_const, "%0d,%0d,%0d", test_no, dbg_i, dbg_q);
    end

    // ------------------------------------------- per-symbol error monitor --
    // Prints every OFDM symbol that has bit errors during the tests that
    // expect none (2, 4, 5, 6): time, symbol count since the BER clear,
    // symbol index in its slot (1..13) and the RX lock count.
    integer    sym_pts = 0, sym_no = 0;
    reg [31:0] err_prev = 0;
    always @(posedge clk) if (dbg_valid) begin
        sym_pts = sym_pts + 1;
        if (sym_pts == N) begin
            sym_pts = 0;
            if ((test_no == 2 || test_no == 4 || test_no == 5 || test_no == 6) &&
                dut.u_rx.ber_errs != err_prev)
                $display("   [%0t] test %0d: symbol %0d after clear (slot symbol %0d, RX locks %0d): %0d bit errors",
                         $time, test_no, sym_no, dut.u_rx.job_sym, dut.u_rx.slot_count,
                         dut.u_rx.ber_errs - err_prev);
            err_prev = dut.u_rx.ber_errs;
            sym_no   = sym_no + 1;
        end
    end

    // ----------------------------------------------------- helper routines --
    reg [31:0] rd, slots0, bits, errs, peak0, peak1, cfo, status;
    reg [31:0] ctrl_shadow;
    integer    fails = 0;

    task wait_slots(input integer n);
        begin
            axi_read(8'h20, slots0);
            rd = slots0;
            while (rd < slots0 + n) begin
                repeat (500) @(posedge clk);
                axi_read(8'h20, rd);
            end
        end
    endtask

    // measure over n complete slots: flush 'fl' slots, clear counters, run n slots
    // (fl = 2: the RX is still finishing the slot that straddled the CTRL write
    //  when the next lock arrives, and that slot's CPs feed the next CFO estimate)
    task measure(input [8*64-1:0] name, input integer fl, input integer n);
        real evm_pct, ber, eps;
        begin
            wait_slots(fl);
            axi_write(8'h00, ctrl_shadow | 32'h8);          // BER clear pulse
            evm_err = 0.0; evm_ref = 0.0; evm_n = 0;
            err_prev = 0; sym_no = 0;                       // restart error monitor
            wait_slots(n);
            axi_read(8'h18, bits);
            axi_read(8'h1C, errs);
            axi_read(8'h24, peak0);
            axi_read(8'h38, peak1);
            axi_read(8'h3C, cfo);
            evm_pct = (evm_ref > 0.0) ? 100.0 * $sqrt(evm_err / evm_ref) : 0.0;
            ber     = (bits > 0) ? (1.0 * errs) / bits : 0.0;
            eps     = $signed(cfo[15:0]) / 65536.0;
            $display("[%0t] %0s", $time, name);
            $display("        bits=%0d  errors=%0d  BER=%e  EVM(vs nearest)=%0.2f %%",
                     bits, errs, ber, evm_pct);
            $display("        sync peak: sign-bit=%0d/126  |P|^2=%0d   CFO estimate=%0.4f sub-carriers",
                     peak0, peak1, eps);
        end
    endtask

    // "ARM": NR phase-compensation coefficient c_l = e^{-j phi_l},
    //   phi_l = 2*pi*F0*(t_start,l + N_CP,l*Ts)   (3GPP TS 38.211 Sec. 5.4)
    integer l, cq, sq;
    real    ph, ts, st;
    task write_pc_coefs;
        begin
            ts = T_SLOT / ((N + CP0) + (NSYM - 1) * (N + CP));
            st = 0.0;
            for (l = 0; l < NSYM; l = l + 1) begin
                ph = F0_HZ * ts * (st + ((l == 0) ? CP0 : CP));
                ph = -2.0 * PI * (ph - $floor(ph));
                cq = $rtoi($cos(ph) * 16384.0 + ($cos(ph) >= 0 ? 0.5 : -0.5));
                sq = $rtoi($sin(ph) * 16384.0 + ($sin(ph) >= 0 ? 0.5 : -0.5));
                axi_write(8'h40 + 4*l, {cq[15:0], sq[15:0]});
                st = st + N + ((l == 0) ? CP0 : CP);
            end
        end
    endtask

    // ------------------------------------------------------------- stimulus --
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_ofdm_top.vcd");
            $dumpvars(0, tb_ofdm_top);
        end
        $timeformat(-6, 2, " us", 10);         // print times in microseconds
        evm_err = 0.0; evm_ref = 0.0; evm_n = 0;
        fd_const = $fopen("constellation.csv", "w");
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // "ARM": 128-bit keys and the 14 phase-compensation coefficients
        axi_write(8'h08, 32'hCAFE_F00D); axi_write(8'h0C, 32'h0BAD_5EED);
        axi_write(8'h28, 32'h0123_4567); axi_write(8'h2C, 32'h89AB_CDEF);
        axi_write(8'h10, 32'hCAFE_F00D); axi_write(8'h14, 32'h0BAD_5EED);
        axi_write(8'h30, 32'h0123_4567); axi_write(8'h34, 32'h89AB_CDEF);
        write_pc_coefs;
        axi_read(8'h40 + 4*3, rd);
        $display("coef[3] read back = 0x%08h", rd);

        // unknown arrival time: 77 idle noise samples before the first slot
        idle_noise_en = 1'b1;
        repeat (77) @(posedge clk);
        idle_noise_en = 1'b0;

        // CTRL: [0] tx [1] pc [2] chaos [4] eq [5] cfo [6] metric_sel
        // ---------------- Test 1 : no phase compensation ----------------
        ctrl_shadow = 32'h35;                     // tx | chaos | eq | cfo
        axi_write(8'h00, ctrl_shadow);
        test_no = 1;
        measure("TEST 1: chaos ON,  phase compensation OFF", 2, 2);
        if (errs == 0) begin fails = fails + 1; $display("        -> FAIL (expected errors)"); end
        else $display("        -> OK  (per-symbol phase not removed, data corrupted as expected)");

        // ---------------- Test 2 : phase compensation ON ----------------
        ctrl_shadow = 32'h37;                     // + pc
        axi_write(8'h00, ctrl_shadow);
        test_no = 2;
        measure("TEST 2: chaos ON,  phase compensation ON ", 2, 3);
        if (errs != 0 || bits == 0) begin fails = fails + 1; $display("        -> FAIL"); end
        else $display("        -> PASS (error-free, encrypted link)");

        // ---------------- Test 3 : wrong RX key ----------------
        axi_write(8'h10, 32'hCAFE_F00C);          // one key bit different
        test_no = 3;
        measure("TEST 3: RX key differs by 1 bit (eavesdropper)", 2, 2);
        if (errs < bits / 10) begin fails = fails + 1; $display("        -> FAIL (expected ~50%% BER)"); end
        else $display("        -> OK  (cannot decrypt without the exact key)");
        axi_write(8'h10, 32'hCAFE_F00D);

        // ---------------- Test 4 : chaos OFF ----------------
        ctrl_shadow = 32'h33;                     // tx | pc | eq | cfo
        axi_write(8'h00, ctrl_shadow);
        test_no = 4;
        measure("TEST 4: chaos OFF, phase compensation ON  (plain OFDM)", 2, 2);
        if (errs != 0 || bits == 0) begin fails = fails + 1; $display("        -> FAIL"); end
        else $display("        -> PASS");

        // ---------------- Test 5 : paper timing metric ----------------
        ctrl_shadow = 32'h77;                     // tx | pc | chaos | eq | cfo | metric_sel
        axi_write(8'h00, ctrl_shadow);
        test_no = 5;
        measure("TEST 5: paper timing metric |P(d)|^2, R(d) = 1", 2, 2);
        if (errs != 0 || bits == 0) begin fails = fails + 1; $display("        -> FAIL"); end
        else $display("        -> PASS");

        // ---------------- Test 6 : CFO + multipath ----------------
        ctrl_shadow = 32'h37;
        axi_write(8'h00, ctrl_shadow);
        ch_cfo_en = 1'b1; ch_mp_en = 1'b1;
        test_no = 6;
        measure("TEST 6: CFO 0.05 + 2-tap multipath, CFO corr + equaliser ON", 2, 2);
        if (errs != 0 || bits == 0) begin fails = fails + 1; $display("        -> FAIL"); end
        else $display("        -> PASS (expected CFO estimate ~%0.4f)", CFO_EPS);

        // ---------------- TX playout health ----------------
        axi_read(8'h04, status);
        if (status[2:1] != 2'b00) begin
            fails = fails + 1;
            $display("TX playout FAIL: underflow=%0d align_err=%0d", status[1], status[2]);
        end else $display("TX playout OK (no underflow, slot starts aligned with the 0.5 ms timer)");

        axi_read(8'h20, rd);
        $display("RX slots synchronised: %0d", rd);
        $fclose(fd_const);
        if (fails == 0) $display("*** ALL TESTS PASSED ***");
        else            $display("*** %0d TEST(S) FAILED ***", fails);
        $finish;
    end

    // watchdog
    initial begin
        #40_000_000;
        $display("*** TIMEOUT ***");
        $finish;
    end
endmodule
