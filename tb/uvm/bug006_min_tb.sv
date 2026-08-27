// Minimal bench for the BUG-006 run. Cut down from the full environment:
// no monitor, no scoreboard, no coverage, no randomisation. Directed
// checks only -- which is what spec section 9 asks of BUG-006.
// The clocking-grid alignment from BUG-009 is kept; it is load-bearing.
// Phase argument must be named 'phase': SystemVerilog requires a virtual
// override to reuse the base class's formal argument names, and Xcelium
// enforces it (*E,CVMNMM). Abbreviating it saved 40 characters and a compile.
`include "uvm_macros.svh"
import uvm_pkg::*;

`define A_CTRL    32'h0000_0000
`define A_SCRATCH 32'h0000_0014
`define A_COUNTER 32'h0000_0018

class axi_tr extends uvm_sequence_item;
  bit kind;                       // 1 = write
  bit [31:0] addr, data;
  bit [3:0]  strb;
  bit [1:0]  resp;
  bit [31:0] rdata;
  `uvm_object_utils(axi_tr)
  function new(string n="axi_tr"); super.new(n); endfunction
endclass

typedef uvm_sequencer #(axi_tr) axi_sqr;

class axi_drv extends uvm_driver #(axi_tr);
  `uvm_component_utils(axi_drv)
  virtual axi4lite_if vif;
  function new(string n, uvm_component p); super.new(n,p); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi4lite_if)::get(this,"","vif",vif))
      `uvm_fatal("DRV","no vif in config_db")
  endfunction
  task run_phase(uvm_phase phase);
    wait (vif.ARESETn === 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      if (req.kind) wr(req); else rd(req);
      seq_item_port.item_done();
    end
  endtask
  task wr(axi_tr t);
    fork
      begin @(vif.master_cb);
        vif.master_cb.AWADDR<=t.addr; vif.master_cb.AWPROT<=3'b0; vif.master_cb.AWVALID<=1'b1;
        do @(vif.master_cb); while (vif.master_cb.AWREADY!==1'b1);
        vif.master_cb.AWVALID<=1'b0; end
      begin @(vif.master_cb);
        vif.master_cb.WDATA<=t.data; vif.master_cb.WSTRB<=t.strb; vif.master_cb.WVALID<=1'b1;
        do @(vif.master_cb); while (vif.master_cb.WREADY!==1'b1);
        vif.master_cb.WVALID<=1'b0; end
      begin @(vif.master_cb); vif.master_cb.BREADY<=1'b1;
        do @(vif.master_cb); while (vif.master_cb.BVALID!==1'b1);
        t.resp = vif.master_cb.BRESP; vif.master_cb.BREADY<=1'b0; end
    join
  endtask
  task rd(axi_tr t);
    fork
      begin @(vif.master_cb);
        vif.master_cb.ARADDR<=t.addr; vif.master_cb.ARPROT<=3'b0; vif.master_cb.ARVALID<=1'b1;
        do @(vif.master_cb); while (vif.master_cb.ARREADY!==1'b1);
        vif.master_cb.ARVALID<=1'b0; end
      begin @(vif.master_cb); vif.master_cb.RREADY<=1'b1;
        do @(vif.master_cb); while (vif.master_cb.RVALID!==1'b1);
        t.rdata=vif.master_cb.RDATA; t.resp=vif.master_cb.RRESP; vif.master_cb.RREADY<=1'b0; end
    join
  endtask
endclass

class axi_ag extends uvm_agent;
  `uvm_component_utils(axi_ag)
  axi_sqr sqr; axi_drv drv;
  function new(string n, uvm_component p); super.new(n,p); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    sqr = axi_sqr::type_id::create("sqr", this);
    drv = axi_drv::type_id::create("drv", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

class f26_seq extends uvm_sequence #(axi_tr);
  `uvm_object_utils(f26_seq)
  int errors=0, checks=0;
  function new(string n="f26_seq"); super.new(n); endfunction

  function void ck(string what, bit [31:0] got, bit [31:0] exp);
    checks++;
    if (got === exp) `uvm_info("F26",$sformatf("  PASS  %-34s 0x%08h",what,got),UVM_LOW)
    else begin errors++;
      `uvm_error("F26",$sformatf("  FAIL  %-34s 0x%08h (expected 0x%08h)",what,got,exp)) end
  endfunction

  task wr(bit [31:0] a, bit [31:0] d);
    axi_tr t = axi_tr::type_id::create("w");
    t.kind=1; t.addr=a; t.data=d; t.strb=4'b1111;
    start_item(t); finish_item(t);
  endtask
  task rd(bit [31:0] a, output bit [31:0] d);
    axi_tr t = axi_tr::type_id::create("r");
    t.kind=0; t.addr=a;
    start_item(t); finish_item(t);
    d = t.rdata;
  endtask

  task body();
    bit [31:0] d;
    `uvm_info("F26","---- COUNTER / reset_stats (F26, BUG-006) ----",UVM_LOW)

    wr(`A_CTRL, 32'h1);                 // enable
    rd(`A_CTRL, d);
    ck("CTRL enable=1, reset_stats=0", d, 32'h1);

    // Let it run, then confirm it is actually counting. If this reads 0
    // the rest proves nothing -- a stuck counter would "pass" the clear.
    repeat (4) rd(`A_SCRATCH, d);
    rd(`A_COUNTER, d);
    `uvm_info("F26",$sformatf("  COUNTER before clear = 0x%08h",d),UVM_LOW)
    ck("COUNTER is running (nonzero)", (d != 0), 1'b1);

    // reset_stats with enable clear: 0 AND frozen there (spec section 5,
    // reset_stats has priority over increment).
    wr(`A_CTRL, 32'h2);
    rd(`A_COUNTER, d);
    ck("reset_stats cleared COUNTER", d, 32'h0);

    // Still 0 several transactions later -- frozen, not merely passing
    // through zero. Note the CTRL=0x2 write also clears enable, so a
    // counter that reset_stats failed to clear FREEZES at its old value
    // here rather than climbing; the check fails either way.
    repeat (4) rd(`A_SCRATCH, d);
    rd(`A_COUNTER, d);
    ck("COUNTER frozen while disabled", d, 32'h0);

    // enable and reset_stats together: enable survives (section 5, the two
    // bits are independently testable).
    wr(`A_CTRL, 32'h3);
    rd(`A_CTRL, d);
    ck("reset_stats did not disturb enable", d, 32'h1);

    if (errors==0) `uvm_info("F26",$sformatf("all %0d checks passed",checks),UVM_LOW)
    else `uvm_error("F26",$sformatf("%0d of %0d checks FAILED",errors,checks))
  endtask
endclass

class f26_test extends uvm_test;
  `uvm_component_utils(f26_test)
  axi_ag ag;
  function new(string n, uvm_component p); super.new(n,p); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ag = axi_ag::type_id::create("ag", this);
  endfunction
  task run_phase(uvm_phase phase);
    f26_seq s;
    phase.raise_objection(this);
    s = f26_seq::type_id::create("s");
    s.start(ag.sqr);
    #200ns;
    phase.drop_objection(this);
  endtask
endclass

module tb_top;
  logic ACLK = 0, ARESETn;
  always #5 ACLK = ~ACLK;
  axi4lite_if vif (.ACLK(ACLK), .ARESETn(ARESETn));
  axi4lite_reg_slave dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWADDR(vif.AWADDR), .AWPROT(vif.AWPROT), .AWVALID(vif.AWVALID), .AWREADY(vif.AWREADY),
    .WDATA(vif.WDATA), .WSTRB(vif.WSTRB), .WVALID(vif.WVALID), .WREADY(vif.WREADY),
    .BRESP(vif.BRESP), .BVALID(vif.BVALID), .BREADY(vif.BREADY),
    .ARADDR(vif.ARADDR), .ARPROT(vif.ARPROT), .ARVALID(vif.ARVALID), .ARREADY(vif.ARREADY),
    .RDATA(vif.RDATA), .RRESP(vif.RRESP), .RVALID(vif.RVALID), .RREADY(vif.RREADY));

  // Held at 0 from time 0, or a_reset_valids_low fails at 5ns on X.
  initial begin
    vif.AWVALID=0; vif.WVALID=0; vif.ARVALID=0; vif.BREADY=0; vif.RREADY=0;
    vif.AWADDR='0; vif.AWPROT='0; vif.WDATA='0; vif.WSTRB='0; vif.ARADDR='0; vif.ARPROT='0;
  end
  initial begin ARESETn=0; repeat(5) @(posedge ACLK); ARESETn<=1; end
  initial begin #50us; $fatal(1,"watchdog: bus stalled"); end
  initial begin
    uvm_config_db #(virtual axi4lite_if)::set(null,"*","vif",vif);
    run_test("f26_test");
  end
endmodule
