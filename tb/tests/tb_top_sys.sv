//======================================================================
// tb_top_sys.sv
//
// Interconnect + both slaves. The system-level UVM top, and the one that
// makes a full regression affordable.
//
// WHY THIS IS THE TOP THAT MATTERS
//
// tb_top and tb_top_mem each hold ONE slave, driven directly, because
// until the interconnect existed there was nothing to route with. That
// had two costs and this top pays off both:
//
//   Coverage.  With one slave in the design, every address the master
//              issued was answered by that slave, so cg_address_region
//              recorded the address ISSUED rather than the traffic
//              ROUTED, and three of its five bins plus cg_response's
//              DECERR bin were justified as structurally unreachable
//              (docs/coverage_status.md). With a decode in front, they
//              are reachable and they mean what their names say.
//
//   Round trips.  UVM runs only on EDA Playground, by hand, one paste
//              per run. A top with one slave needs a separate paste per
//              slave AND per test. This top can host every test in the
//              vplan except the memory-only ones, which is what turns
//              sixteen pastes into three.
//
// The scoreboard is told SLAVE_SYS and does a real decode. The agent,
// driver, monitor and coverage collector are reused unmodified -- which
// is the third time the verification plan's reuse claim has been tested
// and the first time it has been tested against a design with more than
// one device in it.
//======================================================================

`ifndef AXI_TEST
  `define AXI_TEST "axi_regression_test"
`endif

// See tb_top.sv: Playground's command line is fixed, so the seed and the
// waveform switch arrive as defines written by `make playground`.
`ifndef AXI_SEED
  `define AXI_SEED 1
`endif

module tb_top_sys;

    logic ACLK = 1'b0;
    logic ARESETn;

    always #5 ACLK = ~ACLK;          // 100 MHz

    axi4lite_if vif (.ACLK(ACLK), .ARESETn(ARESETn));

    // Interconnect <-> slaves. Not an interface instance per port: the
    // bound checker reaches these through the slaves' own module binds,
    // and adding two more interface instances would mean two more
    // virtual-interface handles in the config_db for no observer to use.
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
        .ACLK(ACLK), .ARESETn(ARESETn),
        .S_AWADDR(vif.AWADDR), .S_AWPROT(vif.AWPROT), .S_AWVALID(vif.AWVALID), .S_AWREADY(vif.AWREADY),
        .S_WDATA (vif.WDATA),  .S_WSTRB (vif.WSTRB),  .S_WVALID (vif.WVALID),  .S_WREADY (vif.WREADY),
        .S_BRESP (vif.BRESP),  .S_BVALID(vif.BVALID), .S_BREADY (vif.BREADY),
        .S_ARADDR(vif.ARADDR), .S_ARPROT(vif.ARPROT), .S_ARVALID(vif.ARVALID), .S_ARREADY(vif.ARREADY),
        .S_RDATA (vif.RDATA),  .S_RRESP (vif.RRESP),  .S_RVALID (vif.RVALID),  .S_RREADY (vif.RREADY),

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
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWADDR(m0_awaddr), .AWPROT(m0_awprot), .AWVALID(m0_awvalid), .AWREADY(m0_awready),
        .WDATA (m0_wdata),  .WSTRB (m0_wstrb),  .WVALID (m0_wvalid),  .WREADY (m0_wready),
        .BRESP (m0_bresp),  .BVALID(m0_bvalid), .BREADY (m0_bready),
        .ARADDR(m0_araddr), .ARPROT(m0_arprot), .ARVALID(m0_arvalid), .ARREADY(m0_arready),
        .RDATA (m0_rdata),  .RRESP (m0_rresp),  .RVALID (m0_rvalid),  .RREADY (m0_rready)
    );

    axi4lite_mem_slave u_mem (
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWADDR(m1_awaddr), .AWPROT(m1_awprot), .AWVALID(m1_awvalid), .AWREADY(m1_awready),
        .WDATA (m1_wdata),  .WSTRB (m1_wstrb),  .WVALID (m1_wvalid),  .WREADY (m1_wready),
        .BRESP (m1_bresp),  .BVALID(m1_bvalid), .BREADY (m1_bready),
        .ARADDR(m1_araddr), .ARPROT(m1_arprot), .ARVALID(m1_arvalid), .ARREADY(m1_arready),
        .RDATA (m1_rdata),  .RRESP (m1_rresp),  .RVALID (m1_rvalid),  .RREADY (m1_rready)
    );

    //------------------------------------------------------------------
    // Reset. Spec section 1: asynchronous assert, synchronous deassert on
    // an active edge, so the DUTs need no reset synchroniser.
    //
    // Driven by a task rather than a one-shot initial block, because
    // axi_reset_test asserts reset again mid-simulation and needs the
    // same contract honoured the second time.
    //------------------------------------------------------------------
    initial begin
        ARESETn = 1'b0;
        repeat (5) @(posedge ACLK);
        ARESETn <= 1'b1;
    end

    //------------------------------------------------------------------
    // Mid-simulation reset, requested by a sequence (F09).
    //
    // The request arrives as a uvm_event rather than the sequence poking
    // ARESETn through a virtual interface. Two reasons, and the second is
    // the load-bearing one:
    //
    //   ARESETn has exactly ONE driver, here. A class writing it as well
    //   would be two drivers on one variable, which is a race whose
    //   winner depends on scheduler order.
    //
    //   The reset CONTRACT stays in one place. Spec section 1 requires
    //   asynchronous assert and synchronous deassert on an active edge,
    //   and the DUTs have no reset synchroniser because of it. A sequence
    //   that drove reset itself would be re-implementing that contract,
    //   and would eventually get it subtly wrong -- deasserting off a
    //   clock edge, which is precisely the case the DUTs are permitted
    //   not to survive.
    //------------------------------------------------------------------
    uvm_event #(uvm_object) reset_ev;
    uvm_event #(uvm_object) reset_done_ev;
    int                     reset_cycles = 5;

    initial begin
        reset_ev      = uvm_event_pool::get_global("axi_reset_request");
        reset_done_ev = uvm_event_pool::get_global("axi_reset_done");
        forever begin
            reset_ev.wait_trigger();
            @(posedge ACLK);
            ARESETn <= 1'b0;
            repeat (reset_cycles) @(posedge ACLK);
            ARESETn <= 1'b1;          // deassert on an active edge, spec section 1
            // Give the driver's supervisor a cycle to restart its channel
            // threads before the sequence resumes driving. Without it the
            // first post-reset transaction can be dispatched into a
            // driver whose channels are still being torn down.
            repeat (3) @(posedge ACLK);
            reset_done_ev.trigger();
        end
    end

    //------------------------------------------------------------------
    // Hold the master-driven signals at 0 from time 0 -- see tb_top.sv
    // for the a_reset_valids_low failure this prevents at 5 ns.
    //------------------------------------------------------------------
    initial begin
        vif.AWVALID = 1'b0;
        vif.WVALID  = 1'b0;
        vif.ARVALID = 1'b0;
        vif.BREADY  = 1'b0;
        vif.RREADY  = 1'b0;
        vif.AWADDR  = '0;
        vif.AWPROT  = '0;
        vif.WDATA   = '0;
        vif.WSTRB   = '0;
        vif.ARADDR  = '0;
        vif.ARPROT  = '0;
    end

    axi_watchdog u_wdog (
        .ACLK    (ACLK),       .ARESETn (ARESETn),
        .AWADDR  (vif.AWADDR), .AWVALID (vif.AWVALID), .AWREADY (vif.AWREADY),
        .WDATA   (vif.WDATA),  .WSTRB   (vif.WSTRB),   .WVALID  (vif.WVALID),  .WREADY (vif.WREADY),
        .BRESP   (vif.BRESP),  .BVALID  (vif.BVALID),  .BREADY  (vif.BREADY),
        .ARADDR  (vif.ARADDR), .ARVALID (vif.ARVALID), .ARREADY (vif.ARREADY),
        .RDATA   (vif.RDATA),  .RRESP   (vif.RRESP),   .RVALID  (vif.RVALID),  .RREADY (vif.RREADY)
    );

    initial begin
`ifdef AXI_DUMP
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_top_sys);
`endif
        uvm_config_db #(virtual axi4lite_if)::set(null, "*", "vif", vif);
        // A real decode exists now, so the scoreboard routes rather than
        // being told which single slave it faces.
        uvm_config_db #(axi_slave_kind_e)::set(null, "*", "slave_kind", SLAVE_SYS);
        uvm_config_db #(int unsigned)::set(null, "*", "axi_seed", `AXI_SEED);
        run_test(`AXI_TEST);
    end

endmodule : tb_top_sys
