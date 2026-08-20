//======================================================================
// axi_seqs.sv  —  sequences
//
// item_done() fires on acceptance, so finish_item() returns BEFORE the
// transaction has completed on the bus. A sequence that needs the result
// waits on the handle it already owns:
//
//     finish_item(t);
//     wait (t.completed == 1'b1);
//
// That is deliberate. Blocking inside finish_item would serialise reads
// behind writes and make F24 unobservable -- see docs/uvm_agent_design.md §2.
// The formal alternative (put_response / get_response) arrives with the
// scoreboard; this is the same information with less plumbing.
//======================================================================

// Register offsets, spec §5
`define A_CTRL       32'h0000_0000
`define A_STATUS     32'h0000_0004
`define A_CONFIG     32'h0000_0008
`define A_INT_STATUS 32'h0000_0010
`define A_SCRATCH    32'h0000_0014
`define A_ID         32'h0000_001C


virtual class axi_base_seq extends uvm_sequence #(axi_transaction);

    function new(string name = "axi_base_seq");
        super.new(name);
    endfunction

    // Blocking write. Returns the response once the B handshake is done.
    task write(input bit [31:0] addr, input bit [31:0] data,
               input bit [3:0] strb, output bit [1:0] resp,
               input int aw_d = -1, input int w_d = -1);
        axi_transaction t;
        t = axi_transaction::type_id::create("wr");
        start_item(t);
        // The distribution constraints are soft, so pinning fields here
        // steers the transaction instead of contradicting it.
        if (!t.randomize() with {
                kind       == AXI_WRITE;
                addr       == local::addr;
                data       == local::data;
                strb       == local::strb;
                misaligned == (local::addr[1:0] != 2'b00);
                (local::aw_d >= 0) -> aw_delay == local::aw_d;
                (local::w_d  >= 0) -> w_delay  == local::w_d;
            })
            `uvm_error(get_type_name(), $sformatf("write randomize failed addr=0x%08h", addr))
        finish_item(t);
        wait (t.completed == 1'b1);
        resp = t.resp;
    endtask

    // Blocking read.
    task read(input bit [31:0] addr, output bit [31:0] data, output bit [1:0] resp);
        axi_transaction t;
        t = axi_transaction::type_id::create("rd");
        start_item(t);
        if (!t.randomize() with {
                kind       == AXI_READ;
                addr       == local::addr;
                misaligned == (local::addr[1:0] != 2'b00);
            })
            `uvm_error(get_type_name(), $sformatf("read randomize failed addr=0x%08h", addr))
        finish_item(t);
        wait (t.completed == 1'b1);
        data = t.rdata;
        resp = t.resp;
    endtask

endclass


//======================================================================
// The smoke sequence.
//
// Deliberately mirrors sanity_tb.sv, so a failure here can be compared
// against a bench that is known to pass on the same RTL. When the UVM
// environment first touches pins, "is it the DUT or is it me?" is the
// only question worth being able to answer quickly.
//======================================================================
class axi_smoke_seq extends axi_base_seq;

    `uvm_object_utils(axi_smoke_seq)

    int errors = 0;
    int checks = 0;

    function new(string name = "axi_smoke_seq");
        super.new(name);
    endfunction

    function void check(string what, bit [31:0] got, bit [31:0] exp);
        checks++;
        if (got === exp)
            `uvm_info("SMOKE", $sformatf("  PASS  %-38s 0x%08h", what, got), UVM_LOW)
        else begin
            errors++;
            `uvm_error("SMOKE", $sformatf("  FAIL  %-38s 0x%08h (expected 0x%08h)",
                                          what, got, exp))
        end
    endfunction

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        `uvm_info("SMOKE", "---- constants and reset values (spec §5) ----", UVM_LOW)
        read(`A_ID, d, r);
        check("ID reads 0xDEADBEEF",        d, 32'hDEAD_BEEF);
        check("ID response OKAY",  {30'b0, r}, 32'h0);

        read(`A_CONFIG, d, r);
        check("CONFIG reset 0x000000FF",    d, 32'h0000_00FF);

        `uvm_info("SMOKE", "---- write / readback, AW and W same cycle ----", UVM_LOW)
        write(`A_SCRATCH, 32'hDEAD_C0DE, 4'b1111, r, 0, 0);
        check("SCRATCH write OKAY", {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("SCRATCH reads back",         d, 32'hDEAD_C0DE);

        // The ordering a lockstep driver can never produce. If the two
        // fork threads are genuinely independent, this works and
        // c_w_before_aw is covered; if they are not, it deadlocks.
        `uvm_info("SMOKE", "---- W accepted 4 cycles BEFORE AW (F03) ----", UVM_LOW)
        write(`A_SCRATCH, 32'h1234_5678, 4'b1111, r, 4, 0);
        check("W-before-AW OKAY",   {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("W-before-AW landed",         d, 32'h1234_5678);

        `uvm_info("SMOKE", "---- AW accepted 4 cycles BEFORE W (F03) ----", UVM_LOW)
        write(`A_SCRATCH, 32'h0F0F_0F0F, 4'b1111, r, 0, 4);
        check("AW-before-W OKAY",   {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("AW-before-W landed",         d, 32'h0F0F_0F0F);

        `uvm_info("SMOKE", "---- reserved bits read 0 (F13) ----", UVM_LOW)
        write(`A_CONFIG, 32'hFFFF_FFFF, 4'b1111, r, 0, 0);
        read(`A_CONFIG, d, r);
        check("CONFIG masks to 0x000000FF", d, 32'h0000_00FF);

        `uvm_info("SMOKE", "---- partial-strobe register write (F16) ----", UVM_LOW)
        write(`A_SCRATCH, 32'hAAAA_AAAA, 4'b0011, r, 0, 0);
        check("partial strobe SLVERR", {30'b0, r}, 32'h2);
        read(`A_SCRATCH, d, r);
        check("register unchanged",         d, 32'h0F0F_0F0F);
        read(`A_INT_STATUS, d, r);
        check("INT_STATUS[2] set",          d, 32'h0000_0004);

        `uvm_info("SMOKE", "---- unimplemented offset 0x100 (F19) ----", UVM_LOW)
        write(32'h0000_0100, 32'hFFFF_FFFF, 4'b1111, r, 0, 0);
        check("offset 0x100 SLVERR",  {30'b0, r}, 32'h2);
        read(`A_CTRL, d, r);
        check("CTRL not aliased",           d, 32'h0000_0000);

        `uvm_info("SMOKE", "---- misaligned access (F20) ----", UVM_LOW)
        read(32'h0000_0006, d, r);
        check("misaligned read SLVERR", {30'b0, r}, 32'h2);
        check("RDATA zeroed on error",      d, 32'h0000_0000);

        if (errors == 0)
            `uvm_info("SMOKE", $sformatf("all %0d checks passed", checks), UVM_LOW)
        else
            `uvm_error("SMOKE", $sformatf("%0d of %0d checks FAILED", errors, checks))
    endtask

endclass : axi_smoke_seq
