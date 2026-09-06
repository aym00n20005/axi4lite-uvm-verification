//======================================================================
// sanity_rand_tb.sv
//
// Seeded constrained-random traffic against the whole subsystem, run by
// the free tool with every assertion and cover property live.
//
//   ./scripts/run_sim.sh verilator rand +seed=7 +n=400
//
// WHY THIS EXISTS, GIVEN THAT THE UVM ENVIRONMENT ALREADY RANDOMISES
//
// Because the UVM environment cannot be run here. Icarus and Verilator
// have no UVM support (docs/tooling_notes.md), so every UVM run costs a
// browser and a human. That is fine for sixteen tests. It is not fine
// for a REGRESSION, which is many seeds of the same test, and coverage
// closure is only reachable through a regression.
//
// So the split is deliberate and it is not duplication:
//
//   UVM environment    transaction-level verification -- spec-derived
//                      scoreboard, functional coverage model, RAL.
//                      Runs on Xcelium, by hand, a few times.
//
//   this bench         protocol-level stress -- assertions and cover
//                      properties, many seeds, unattended, locally.
//                      Runs on every `make regression`.
//
// The two check different things. This one owns the four cover points
// that had never been non-zero in this project and that no directed
// bench can reach: c_b2b_write, c_b2b_read, c_write_backpressure and
// c_read_backpressure. All four need a driver that keeps the NEXT
// transaction's VALID asserted while the current one is still
// completing -- which is why the engines below are per-channel threads
// walking their own index, exactly like axi_driver, and not a
// sequential task like sanity_tb's.
//
// WHAT IT CHECKS
//
// The RESPONSE CLASS only -- OKAY / SLVERR / DECERR, derived from spec
// sections 4, 5 and 6. Not read data: that is the UVM scoreboard's job and
// duplicating it here would be a second reference model to keep correct.
// A response-class model is small enough to be obviously right and is
// enough to catch a routing or precedence regression, which is what a
// nightly local regression is for.
//======================================================================

`timescale 1ns/1ps

module sanity_rand_tb;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    localparam int MAX_N = 4096;

    int seed = 1;
    int n_txn = 200;

    logic ACLK, ARESETn;

    logic [31:0] AWADDR;  logic [2:0] AWPROT;  logic AWVALID, AWREADY;
    logic [31:0] WDATA;   logic [3:0] WSTRB;   logic WVALID,  WREADY;
    logic [1:0]  BRESP;                        logic BVALID,  BREADY;
    logic [31:0] ARADDR;  logic [2:0] ARPROT;  logic ARVALID, ARREADY;
    logic [31:0] RDATA;   logic [1:0] RRESP;   logic RVALID,  RREADY;

    logic [31:0] m0_awaddr, m1_awaddr;  logic [2:0] m0_awprot, m1_awprot;
    logic        m0_awvalid, m1_awvalid, m0_awready, m1_awready;
    logic [31:0] m0_wdata,  m1_wdata;   logic [3:0] m0_wstrb,  m1_wstrb;
    logic        m0_wvalid, m1_wvalid,  m0_wready,  m1_wready;
    logic [1:0]  m0_bresp,  m1_bresp;   logic m0_bvalid, m1_bvalid, m0_bready, m1_bready;
    logic [31:0] m0_araddr, m1_araddr;  logic [2:0] m0_arprot, m1_arprot;
    logic        m0_arvalid, m1_arvalid, m0_arready, m1_arready;
    logic [31:0] m0_rdata,  m1_rdata;   logic [1:0] m0_rresp,  m1_rresp;
    logic        m0_rvalid, m1_rvalid,  m0_rready,  m1_rready;

    axi4lite_interconnect u_ic (
        .ACLK, .ARESETn,
        .S_AWADDR(AWADDR), .S_AWPROT(AWPROT), .S_AWVALID(AWVALID), .S_AWREADY(AWREADY),
        .S_WDATA (WDATA),  .S_WSTRB (WSTRB),  .S_WVALID (WVALID),  .S_WREADY (WREADY),
        .S_BRESP (BRESP),  .S_BVALID(BVALID), .S_BREADY (BREADY),
        .S_ARADDR(ARADDR), .S_ARPROT(ARPROT), .S_ARVALID(ARVALID), .S_ARREADY(ARREADY),
        .S_RDATA (RDATA),  .S_RRESP (RRESP),  .S_RVALID (RVALID),  .S_RREADY (RREADY),
        .M0_AWADDR(m0_awaddr), .M0_AWPROT(m0_awprot), .M0_AWVALID(m0_awvalid), .M0_AWREADY(m0_awready),
        .M0_WDATA (m0_wdata),  .M0_WSTRB (m0_wstrb),  .M0_WVALID (m0_wvalid),  .M0_WREADY (m0_wready),
        .M0_BRESP (m0_bresp),  .M0_BVALID(m0_bvalid), .M0_BREADY (m0_bready),
        .M0_ARADDR(m0_araddr), .M0_ARPROT(m0_arprot), .M0_ARVALID(m0_arvalid), .M0_ARREADY(m0_arready),
        .M0_RDATA (m0_rdata),  .M0_RRESP (m0_rresp),  .M0_RVALID (m0_rvalid),  .M0_RREADY (m0_rready),
        .M1_AWADDR(m1_awaddr), .M1_AWPROT(m1_awprot), .M1_AWVALID(m1_awvalid), .M1_AWREADY(m1_awready),
        .M1_WDATA (m1_wdata),  .M1_WSTRB (m1_wstrb),  .M1_WVALID (m1_wvalid),  .M1_WREADY (m1_wready),
        .M1_BRESP (m1_bresp),  .M1_BVALID(m1_bvalid), .M1_BREADY (m1_bready),
        .M1_ARADDR(m1_araddr), .M1_ARPROT(m1_arprot), .M1_ARVALID(m1_arvalid), .M1_ARREADY(m1_arready),
        .M1_RDATA (m1_rdata),  .M1_RRESP (m1_rresp),  .M1_RVALID (m1_rvalid),  .M1_RREADY (m1_rready)
    );

    axi4lite_reg_slave u_reg (
        .ACLK, .ARESETn,
        .AWADDR(m0_awaddr), .AWPROT(m0_awprot), .AWVALID(m0_awvalid), .AWREADY(m0_awready),
        .WDATA (m0_wdata),  .WSTRB (m0_wstrb),  .WVALID (m0_wvalid),  .WREADY (m0_wready),
        .BRESP (m0_bresp),  .BVALID(m0_bvalid), .BREADY (m0_bready),
        .ARADDR(m0_araddr), .ARPROT(m0_arprot), .ARVALID(m0_arvalid), .ARREADY(m0_arready),
        .RDATA (m0_rdata),  .RRESP (m0_rresp),  .RVALID (m0_rvalid),  .RREADY (m0_rready)
    );

    axi4lite_mem_slave u_mem (
        .ACLK, .ARESETn,
        .AWADDR(m1_awaddr), .AWPROT(m1_awprot), .AWVALID(m1_awvalid), .AWREADY(m1_awready),
        .WDATA (m1_wdata),  .WSTRB (m1_wstrb),  .WVALID (m1_wvalid),  .WREADY (m1_wready),
        .BRESP (m1_bresp),  .BVALID(m1_bvalid), .BREADY (m1_bready),
        .ARADDR(m1_araddr), .ARPROT(m1_arprot), .ARVALID(m1_arvalid), .ARREADY(m1_arready),
        .RDATA (m1_rdata),  .RRESP (m1_rresp),  .RVALID (m1_rvalid),  .RREADY (m1_rready)
    );

    initial ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    //==================================================================
    // Stimulus, generated up front so the three write engines and the
    // two read engines can walk the same items by index without sharing
    // a random stream. Same seed, same item list, byte for byte.
    //==================================================================
    logic [31:0] w_addr [MAX_N];
    logic [31:0] w_data [MAX_N];
    logic [3:0]  w_strb [MAX_N];
    int          w_awd  [MAX_N];
    int          w_wd   [MAX_N];
    int          w_bd   [MAX_N];
    logic [1:0]  w_exp  [MAX_N];

    logic [31:0] r_addr [MAX_N];
    int          r_ard  [MAX_N];
    int          r_rd   [MAX_N];
    logic [1:0]  r_exp  [MAX_N];

    int aw_i = 0, w_i = 0, b_i = 0;      // per-channel indices
    int ar_i = 0, r_i = 0;

    int errors = 0;
    int checks = 0;
    realtime last_activity;

    //==================================================================
    // Expected RESPONSE CLASS, from the spec. Sections 4 (precedence and
    // the map), 5 (register slave) and 6 (memory slave).
    //
    // Precedence is strict and its ORDER is the rule: unmapped outranks
    // misaligned, because the interconnect answers before any slave sees
    // the transaction.
    //==================================================================
    function automatic logic [1:0] exp_resp(input logic [31:0] a,
                                            input bit          is_write,
                                            input logic [3:0]  strb);
        if (a > 32'h0000_13FF)                  return RESP_DECERR;  // unmapped
        if (a[1:0] != 2'b00)                    return RESP_SLVERR;  // misaligned
        if (a <= 32'h0000_0FFF) begin                                // register region
            if (a[11:5] != 7'b0)                return RESP_SLVERR;  // unimplemented
            if (is_write && strb != 4'b1111)    return RESP_SLVERR;  // partial strobe
            return RESP_OKAY;
        end
        return RESP_OKAY;                                            // memory, aligned
    endfunction

    // Region picked first, then an address inside it -- a freely random
    // 32-bit address lands unmapped virtually every time, since the
    // mapped regions are 5 KB out of 4 GB. Same reasoning, and roughly
    // the same weights, as axi_transaction's c_region_dist.
    function automatic logic [31:0] pick_addr();
        int          region;
        bit          misaligned;
        logic [31:0] a;
        region     = $urandom_range(0, 99);
        misaligned = ($urandom_range(0, 99) < 8);
        if      (region < 40) a = 32'h0000_0000 + ($urandom_range(0, 7)   << 2);   // implemented regs
        else if (region < 46) a = 32'h0000_0020 + ($urandom_range(0, 823) << 2);   // unimplemented
        else if (region < 88) a = 32'h0000_1000 + ($urandom_range(0, 255) << 2);   // memory
        else if (region < 94) a = 32'h0000_1400 + ($urandom_range(0, 383) << 2);   // the gap
        else                  a = 32'h0000_2000 + ($urandom_range(0, 1023) << 2);  // unmapped high
        if (misaligned) a[1:0] = 2'($urandom_range(1, 3));
        return a;
    endfunction

    function automatic int pick_delay();
        // Bin edges match cg_valid_delay / cg_backpressure: 0, 1-3, 4-10, >10.
        // Zero is weighted heavily on purpose -- it is what produces
        // back-to-back traffic, and c_b2b_write/c_b2b_read need it.
        int r;
        r = $urandom_range(0, 99);
        if (r < 40) return 0;
        if (r < 75) return $urandom_range(1, 3);
        if (r < 92) return $urandom_range(4, 10);
        return $urandom_range(11, 20);
    endfunction

    //==================================================================
    // Per-channel engines. One thread each, walking its own index.
    //
    // This shape is the entire point of the file. A sequential
    // "drive AW, drive W, wait for B, repeat" task can never assert the
    // NEXT transaction's AWVALID while the current B is outstanding, so
    // it can never produce back-to-back accepts and never produces three
    // consecutive cycles of AWVALID with AWREADY low. Those are four of
    // this project's five permanently-zero cover points.
    //==================================================================
    task automatic aw_engine();
        forever begin
            if (aw_i >= n_txn) break;
            repeat (w_awd[aw_i]) @(posedge ACLK);
            @(posedge ACLK);
            AWADDR <= w_addr[aw_i]; AWPROT <= 3'b000; AWVALID <= 1'b1;
            forever begin @(posedge ACLK); if (AWREADY) break; end
            AWVALID <= 1'b0;
            aw_i++;
        end
    endtask

    task automatic w_engine();
        forever begin
            if (w_i >= n_txn) break;
            repeat (w_wd[w_i]) @(posedge ACLK);
            @(posedge ACLK);
            WDATA <= w_data[w_i]; WSTRB <= w_strb[w_i]; WVALID <= 1'b1;
            forever begin @(posedge ACLK); if (WREADY) break; end
            WVALID <= 1'b0;
            w_i++;
        end
    endtask

    task automatic b_engine();
        forever begin
            if (b_i >= n_txn) break;
            // Wait for the response, THEN hold off. Holding BREADY low
            // while BVALID is high is what backpressure means; raising
            // BREADY early and waiting is not backpressure at all.
            forever begin @(posedge ACLK); if (BVALID) break; end
            repeat (w_bd[b_i]) @(posedge ACLK);
            BREADY <= 1'b1;
            forever begin @(posedge ACLK); if (BVALID && BREADY) break; end
            checks++;
            if (BRESP !== w_exp[b_i]) begin
                errors++;
                $display("  FAIL  write %0d addr=0x%08h strb=%04b : BRESP %02b, spec says %02b",
                         b_i, w_addr[b_i], w_strb[b_i], BRESP, w_exp[b_i]);
            end
            BREADY <= 1'b0;
            last_activity = $realtime;
            b_i++;
        end
    endtask

    task automatic ar_engine();
        forever begin
            if (ar_i >= n_txn) break;
            repeat (r_ard[ar_i]) @(posedge ACLK);
            @(posedge ACLK);
            ARADDR <= r_addr[ar_i]; ARPROT <= 3'b000; ARVALID <= 1'b1;
            forever begin @(posedge ACLK); if (ARREADY) break; end
            ARVALID <= 1'b0;
            ar_i++;
        end
    endtask

    task automatic r_engine();
        forever begin
            if (r_i >= n_txn) break;
            forever begin @(posedge ACLK); if (RVALID) break; end
            repeat (r_rd[r_i]) @(posedge ACLK);
            RREADY <= 1'b1;
            forever begin @(posedge ACLK); if (RVALID && RREADY) break; end
            checks++;
            if (RRESP !== r_exp[r_i]) begin
                errors++;
                $display("  FAIL  read %0d addr=0x%08h : RRESP %02b, spec says %02b",
                         r_i, r_addr[r_i], RRESP, r_exp[r_i]);
            end
            // Spec section 4: RDATA is a deterministic zero on any error.
            if (RRESP !== RESP_OKAY) begin
                checks++;
                if (RDATA !== 32'h0) begin
                    errors++;
                    $display("  FAIL  read %0d addr=0x%08h : RDATA 0x%08h on an error response, spec says 0",
                             r_i, r_addr[r_i], RDATA);
                end
            end
            RREADY <= 1'b0;
            last_activity = $realtime;
            r_i++;
        end
    endtask

    //==================================================================
    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("n=%d", n_txn))   n_txn = 200;
        if (n_txn > MAX_N) n_txn = MAX_N;

        // One call seeds the stream for the whole run. Every array below
        // is a pure function of it, so +seed=N reproduces exactly.
        void'($urandom(seed));

        for (int i = 0; i < n_txn; i++) begin
            w_addr[i] = pick_addr();
            w_data[i] = $urandom();
            w_strb[i] = ($urandom_range(0, 99) < 55) ? 4'b1111
                                                     : 4'($urandom_range(0, 15));
            w_awd [i] = pick_delay();
            w_wd  [i] = pick_delay();
            w_bd  [i] = pick_delay();
            w_exp [i] = exp_resp(w_addr[i], 1'b1, w_strb[i]);

            r_addr[i] = pick_addr();
            r_ard [i] = pick_delay();
            r_rd  [i] = pick_delay();
            r_exp [i] = exp_resp(r_addr[i], 1'b0, 4'b1111);
        end

        ARESETn = 1'b0;
        AWADDR = '0; AWPROT = '0; AWVALID = 1'b0;
        WDATA  = '0; WSTRB  = '0; WVALID  = 1'b0;
        ARADDR = '0; ARPROT = '0; ARVALID = 1'b0;
        BREADY = 1'b0;
        RREADY = 1'b0;

        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
        repeat (2) @(posedge ACLK);
        last_activity = $realtime;

        $display("");
        $display("========================================================================");
        $display(" sanity_rand_tb  seed=%0d  n=%0d  (%0d writes + %0d reads)",
                 seed, n_txn, n_txn, n_txn);
        $display("========================================================================");

        fork
            aw_engine();
            w_engine();
            b_engine();
            ar_engine();
            r_engine();
        join

        repeat (10) @(posedge ACLK);

        $display("");
        $display("========================================================================");
        $display(" seed=%0d  %0d checks", seed, checks);
        if (errors == 0) $display(" RESULT: all %0d checks passed", checks);
        else             $display(" RESULT: %0d of %0d checks FAILED", errors, checks);
        $display("========================================================================");
        $display("");

        if (errors != 0) $fatal(1, "sanity_rand_tb failed (seed %0d)", seed);
        $finish;
    end

    //==================================================================
    // Inactivity watchdog, not an absolute one.
    //
    // The absolute #50us watchdog this project used to carry cannot tell
    // "stalled" from "still working", and n is a plusarg -- a longer run
    // is not a hang. Nothing completing for 20 us is.
    //==================================================================
    initial begin
        forever begin
            #20us;
            if ($realtime - last_activity >= 20us) begin
                $display("");
                $display("=================== WATCHDOG ===================");
                $display(" no completion for 20us. seed=%0d", seed);
                $display("   progress: aw=%0d w=%0d b=%0d ar=%0d r=%0d of %0d",
                         aw_i, w_i, b_i, ar_i, r_i, n_txn);
                $display("   AW VALID=%b READY=%b ADDR=0x%08h", AWVALID, AWREADY, AWADDR);
                $display("   W  VALID=%b READY=%b", WVALID, WREADY);
                $display("   B  VALID=%b READY=%b RESP=%02b", BVALID, BREADY, BRESP);
                $display("   AR VALID=%b READY=%b ADDR=0x%08h", ARVALID, ARREADY, ARADDR);
                $display("   R  VALID=%b READY=%b RESP=%02b", RVALID, RREADY, RRESP);
                $display("================================================");
                $fatal(1, "sanity_rand_tb watchdog (seed %0d)", seed);
            end
        end
    end

endmodule : sanity_rand_tb
