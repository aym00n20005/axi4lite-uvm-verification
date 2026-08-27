//======================================================================
// axi_seqs.sv  --  sequences
//
// item_done() fires on acceptance, so finish_item() returns BEFORE the
// transaction has completed on the bus. A sequence that needs the result
// waits on the handle it already owns:
//
//     finish_item(t);
//     wait (t.completed == 1'b1);
//
// That is deliberate. Blocking inside finish_item would serialise reads
// behind writes and make F24 unobservable -- see docs/uvm_agent_design.md section 2.
// The formal alternative (put_response / get_response) arrives with the
// scoreboard; this is the same information with less plumbing.
//======================================================================

// Register offsets, spec section 5
`define A_CTRL       32'h0000_0000
`define A_STATUS     32'h0000_0004
`define A_INT_ENABLE 32'h0000_000C
`define A_CONFIG     32'h0000_0008
`define A_INT_STATUS 32'h0000_0010
`define A_COUNTER    32'h0000_0018
`define A_SCRATCH    32'h0000_0014
`define A_ID         32'h0000_001C


virtual class axi_base_seq extends uvm_sequence #(axi_transaction);

    // What this sequence ISSUED. The monitor independently counts what it
    // SAW on the pins. Comparing the two is the check that the monitor is
    // reconstructing rather than echoing -- two counts with no shared path.
    int unsigned issued_writes = 0;
    int unsigned issued_reads  = 0;

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
        `uvm_info(get_type_name(),
                  $sformatf("write  addr=0x%08h data=0x%08h strb=%04b -- issued",
                            addr, data, strb), UVM_HIGH)
        finish_item(t);
        wait (t.completed == 1'b1);
        issued_writes++;
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
        issued_reads++;
        data = t.rdata;
        resp = t.resp;
    endtask

    //------------------------------------------------------------------
    // Non-blocking issue.
    //
    // finish_item() returns as soon as the DRIVER accepts the transaction
    // (item_done fires on acceptance -- docs/uvm_agent_design.md section 2),
    // so returning here without waiting on t.completed leaves the previous
    // transaction still on the bus. That is what produces back-to-back
    // traffic, and it is the only way c_b2b_write and c_b2b_read can ever
    // be covered.
    //
    // The caller keeps the handle and waits later.
    //------------------------------------------------------------------
    task issue_nb(axi_transaction t);
        start_item(t);
        finish_item(t);
        if (t.kind == AXI_WRITE) issued_writes++;
        else                     issued_reads++;
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

        `uvm_info("SMOKE", "---- constants and reset values (spec section 5) ----", UVM_LOW)
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

        //--------------------------------------------------------------
        // STATUS.error, and the v0.3 transparency rule (decision D1).
        //
        // Spec section 5 as clarified in v0.3: error is set by the last
        // completed register transaction, and a read of STATUS is
        // TRANSPARENT -- it does not update the bit. That clarification
        // was made by this project on 14 Aug to resolve a contradiction
        // in v0.2, has been implemented in RTL and in the scoreboard
        // since, and until now nothing has ever exercised it.
        //
        // The misaligned read above left error set. Only bit [1] is
        // checked: STATUS[0] is busy, which is cycle-level state.
        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- STATUS.error transparency (F25, spec v0.3 D1) ----", UVM_LOW)

        read(`A_STATUS, d, r);
        check("STATUS.error set after SLVERR", d & 32'h2, 32'h2);

        // The whole point of D1: reading it again must NOT have cleared it.
        // Under the literal v0.2 wording the first read would have cleared
        // the bit and this would return 0.
        read(`A_STATUS, d, r);
        check("STATUS read is transparent",    d & 32'h2, 32'h2);

        // Any other transaction completing with OKAY does clear it.
        write(`A_SCRATCH, 32'h5A5A_5A5A, 4'b1111, r, 0, 0);
        read(`A_STATUS, d, r);
        check("STATUS.error cleared by OKAY",  d & 32'h2, 32'h0);

        //--------------------------------------------------------------
        // COUNTER is free-running, so the scoreboard cannot predict its
        // value and skips the data comparison. Reading it here is what
        // exercises that skip path -- otherwise the mask logic is code
        // no test has ever executed. The RESPONSE is still checked.
        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- COUNTER read: response checked, data unpredictable ----", UVM_LOW)

        // Enable it first. Read with enable clear and COUNTER returns 0,
        // which is trivially predictable -- the skip would execute while
        // proving nothing. Spec section 5: COUNTER increments every clock
        // while CTRL.enable, so once running its value depends on cycles
        // the scoreboard cannot see.
        write(`A_CTRL, 32'h0000_0001, 4'b1111, r, 0, 0);
        check("CTRL enable write OKAY", {30'b0, r}, 32'h0);

        // CTRL[1] reset_stats always reads 0 (spec section 5, v0.3 D2),
        // so a CTRL read after enabling returns exactly 1.
        read(`A_CTRL, d, r);
        check("CTRL reads enable=1, reset_stats=0", d, 32'h0000_0001);

        read(`A_COUNTER, d, r);
        check("COUNTER read OKAY",      {30'b0, r}, 32'h0);
        `uvm_info("SMOKE",
                  $sformatf("  COUNTER read 0x%08h -- nonzero and cycle-dependent; scoreboard skips it", d),
                  UVM_LOW)

        //--------------------------------------------------------------
        // Coverage closure for the bins a directed test can reach.
        //
        // Added 21 Aug after the first real coverage measurement showed
        // cg_wstrb at 2/16, cg_alignment at 2/4 and cg_register_offset at
        // 7/8. None of those were design gaps -- they were transactions
        // nobody had written. The measurement is what turned them from
        // invisible into a work item.
        //
        // In September these become axi_wstrb_test and axi_align_test as
        // the verification plan's test list lays them out; one sequence
        // is right while there is one test.
        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- WSTRB sweep, all 16 patterns (F16, cg_wstrb) ----", UVM_LOW)

        // Spec section 5: only 4'b1111 is a legal register write. The
        // other fifteen must every one return SLVERR and change nothing,
        // which is fifteen checks of the same rule from fifteen angles.
        for (int unsigned i = 0; i < 16; i++) begin
            bit [3:0] sweep_strb = i[3:0];
            write(`A_SCRATCH, 32'hC0DE_0000 | i, sweep_strb, r, 0, 0);
            if (sweep_strb == 4'b1111)
                check($sformatf("WSTRB=%04b OKAY", sweep_strb),   {30'b0, r}, 32'h0);
            else
                check($sformatf("WSTRB=%04b SLVERR", sweep_strb), {30'b0, r}, 32'h2);
        end

        // 4'b1111 is the last pattern swept, so it is the one that landed.
        read(`A_SCRATCH, d, r);
        check("only the full-strobe write took effect", d, 32'hC0DE_000F);

        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- remaining alignment offsets (F20, cg_alignment) ----", UVM_LOW)

        // The misaligned read above used offset 2. Offsets 1 and 3 are
        // the same rule at different byte positions.
        read(32'h0000_0005, d, r);
        check("addr offset 1 -> SLVERR", {30'b0, r}, 32'h2);
        read(32'h0000_0007, d, r);
        check("addr offset 3 -> SLVERR", {30'b0, r}, 32'h2);

        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- INT_ENABLE, the last untouched register ----", UVM_LOW)

        // Implemented bits [3:0] (spec section 5), so the upper bits are
        // reserved and must read 0 -- F13 again, on the one register no
        // test had ever addressed.
        write(`A_INT_ENABLE, 32'hFFFF_FFFF, 4'b1111, r, 0, 0);
        check("INT_ENABLE write OKAY", {30'b0, r}, 32'h0);
        read(`A_INT_ENABLE, d, r);
        check("INT_ENABLE masks to 0xF", d, 32'h0000_000F);

        if (errors == 0)
            `uvm_info("SMOKE", $sformatf("all %0d checks passed", checks), UVM_LOW)
        else
            `uvm_error("SMOKE", $sformatf("%0d of %0d checks FAILED", errors, checks))
    endtask

endclass : axi_smoke_seq


//======================================================================
// axi_random_seq -- constrained-random traffic against the real DUT.
//
// The transaction class has had weighted region, alignment, strobe and
// delay distributions since 19 Aug, measured over 500 items by
// axi_rand_smoke. Until now none of that had ever driven a pin: the only
// test that touched the DUT issued hand-picked addresses.
//
// That gap matters because a directed test can only find bugs someone
// already thought of, and because the scoreboard had never disagreed with
// the DUT across 44 transactions that a human chose.
//
// Three phases, and the split is deliberate.
//
//   1. Serialised random traffic. Every field random, every transaction
//      waited on. Exercises the scoreboard hundreds of times and produces
//      read backpressure for free, since r_ready_delay is randomised and
//      the driver applies it before asserting RREADY.
//
//   2. A burst of writes issued WITHOUT waiting, so the next AW is offered
//      while the previous B is still completing -- c_b2b_write.
//
//   3. The same for reads -- c_b2b_read.
//
// Phases 2 and 3 are single-kind on purpose. Mixing un-waited reads and
// writes makes the completion ORDER depend on thread scheduling, and
// STATUS.error is defined by "the last completed register transaction"
// (spec section 5), so the scoreboard and the DUT could legitimately
// disagree about which was last. Writes alone complete in issue order
// through one slot, so the ordering stays defined. Mixed concurrent
// traffic needs that question answered first, and it is not answered yet.
//======================================================================
class axi_random_seq extends axi_base_seq;

    `uvm_object_utils(axi_random_seq)

    int unsigned n_random = 150;
    int unsigned n_burst  = 8;

    function new(string name = "axi_random_seq");
        super.new(name);
    endfunction

    task body();
        axi_transaction t;
        axi_transaction burst [$];

        //--------------------------------------------------------------
        `uvm_info("RAND", $sformatf("phase 1: %0d serialised random transactions", n_random), UVM_LOW)

        for (int i = 0; i < n_random; i++) begin
            t = axi_transaction::type_id::create($sformatf("rnd%0d", i));
            start_item(t);
            if (!t.randomize())
                `uvm_fatal("RAND", $sformatf("randomize failed on item %0d", i))
            finish_item(t);
            wait (t.completed == 1'b1);
            if (t.kind == AXI_WRITE) issued_writes++;
            else                     issued_reads++;
            if (i < 3)
                `uvm_info("RAND", $sformatf("  %s", t.convert2string()), UVM_LOW)
        end

        //--------------------------------------------------------------
        // Zero delays everywhere, so the next AW is offered on the cycle
        // after the previous B completes. Fixed address and full strobe:
        // the point of this phase is the TIMING, and leaving the payload
        // random would make a scoreboard mismatch ambiguous between the
        // two.
        `uvm_info("RAND", $sformatf("phase 2: %0d back-to-back writes, no waiting", n_burst), UVM_LOW)

        burst.delete();
        for (int i = 0; i < n_burst; i++) begin
            t = axi_transaction::type_id::create($sformatf("b2bw%0d", i));
            if (!t.randomize() with {
                    kind          == AXI_WRITE;
                    region        == REGION_REG_IMPL;
                    addr          == `A_SCRATCH;
                    strb          == 4'b1111;
                    misaligned    == 1'b0;
                    aw_delay      == 0;
                    w_delay       == 0;
                    b_ready_delay == 0;
                })
                `uvm_fatal("RAND", "b2b write randomize failed")
            issue_nb(t);
            burst.push_back(t);
        end
        foreach (burst[i]) wait (burst[i].completed == 1'b1);

        //--------------------------------------------------------------
        `uvm_info("RAND", $sformatf("phase 3: %0d back-to-back reads, no waiting", n_burst), UVM_LOW)

        burst.delete();
        for (int i = 0; i < n_burst; i++) begin
            t = axi_transaction::type_id::create($sformatf("b2br%0d", i));
            if (!t.randomize() with {
                    kind          == AXI_READ;
                    region        == REGION_REG_IMPL;
                    addr          == `A_SCRATCH;
                    misaligned    == 1'b0;
                    ar_delay      == 0;
                    r_ready_delay == 0;
                })
                `uvm_fatal("RAND", "b2b read randomize failed")
            issue_nb(t);
            burst.push_back(t);
        end
        foreach (burst[i]) wait (burst[i].completed == 1'b1);

        `uvm_info("RAND", $sformatf("issued %0d writes, %0d reads",
                                    issued_writes, issued_reads), UVM_LOW)
    endtask

endclass : axi_random_seq


//======================================================================
// axi_mem_seq -- directed sequence for the memory slave.
//
// Deliberately mirrors tb/sanity_mem_tb.sv, the same way axi_smoke_seq
// mirrors sanity_tb.sv: when a new DUT first meets the UVM environment,
// "is it the DUT or is it me" needs a bench known to pass on that exact
// RTL to compare against.
//
// What this is really for is the three places the memory slave behaves
// OPPOSITELY to the register slave, because those are where a scoreboard
// that quietly reuses the register model would agree with itself:
//
//   WSTRB is honoured byte by byte, not rejected
//   WSTRB == 4'b0000 is a legal OKAY no-op, not an SLVERR
//   there is no unimplemented-offset case at all
//======================================================================

`define M_BASE 32'h0000_1000
`define M_W000 32'h0000_1000
`define M_W005 32'h0000_1014
`define M_W255 32'h0000_13FC

class axi_mem_seq extends axi_base_seq;

    `uvm_object_utils(axi_mem_seq)

    int errors = 0;
    int checks = 0;

    function new(string name = "axi_mem_seq");
        super.new(name);
    endfunction

    function void check(string what, bit [31:0] got, bit [31:0] exp);
        checks++;
        if (got === exp)
            `uvm_info("MEM", $sformatf("  PASS  %-38s 0x%08h", what, got), UVM_LOW)
        else begin
            errors++;
            `uvm_error("MEM", $sformatf("  FAIL  %-38s 0x%08h (expected 0x%08h)",
                                        what, got, exp))
        end
    endfunction

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        `uvm_info("MEM", "---- full words at both ends of the region (F14) ----", UVM_LOW)
        write(`M_W000, 32'hCAFE_BABE, 4'b1111, r, 0, 0);
        check("word 0 write OKAY",   {30'b0, r}, 32'h0);
        read(`M_W000, d, r);
        check("word 0 reads back",           d, 32'hCAFE_BABE);

        write(`M_W255, 32'h5A5A_A5A5, 4'b1111, r, 0, 0);
        read(`M_W255, d, r);
        check("word 255 reads back",         d, 32'h5A5A_A5A5);
        read(`M_W000, d, r);
        check("word 0 undisturbed",          d, 32'hCAFE_BABE);

        // Cumulative: each lane must land on its own byte and disturb
        // nothing else. A reversed lane-to-byte mapping shows up here and
        // nowhere else -- and this is what BUG-003 breaks.
        `uvm_info("MEM", "---- byte lanes, one at a time (F15) ----", UVM_LOW)
        write(`M_W005, 32'h0000_0000, 4'b1111, r, 0, 0);
        write(`M_W005, 32'hAABB_CCDD, 4'b0001, r, 0, 0);
        read(`M_W005, d, r);
        check("WSTRB=0001 -> byte 0 only",    d, 32'h0000_00DD);
        write(`M_W005, 32'hAABB_CCDD, 4'b0010, r, 0, 0);
        read(`M_W005, d, r);
        check("WSTRB=0010 -> byte 1 only",    d, 32'h0000_CCDD);
        write(`M_W005, 32'hAABB_CCDD, 4'b0100, r, 0, 0);
        read(`M_W005, d, r);
        check("WSTRB=0100 -> byte 2 only",    d, 32'h00BB_CCDD);
        write(`M_W005, 32'hAABB_CCDD, 4'b1000, r, 0, 0);
        read(`M_W005, d, r);
        check("WSTRB=1000 -> byte 3 only",    d, 32'hAABB_CCDD);

        `uvm_info("MEM", "---- non-contiguous strobe ----", UVM_LOW)
        write(`M_W005, 32'h1122_3344, 4'b1010, r, 0, 0);
        read(`M_W005, d, r);
        check("only bytes 1 and 3 changed",   d, 32'h11BB_33DD);

        // The contrast. Identical stimulus on the register slave returns
        // SLVERR and sets INT_STATUS[2] (spec section 5).
        `uvm_info("MEM", "---- WSTRB=0000 is a legal no-op here (spec section 6) ----", UVM_LOW)
        write(`M_W005, 32'hFFFF_FFFF, 4'b0000, r, 0, 0);
        check("zero strobe returns OKAY", {30'b0, r}, 32'h0);
        read(`M_W005, d, r);
        check("memory unchanged",             d, 32'h11BB_33DD);

        `uvm_info("MEM", "---- misaligned, bus-error only (F20) ----", UVM_LOW)
        write(`M_BASE + 32'h016, 32'hDEAD_DEAD, 4'b1111, r, 0, 0);
        check("misaligned write SLVERR", {30'b0, r}, 32'h2);
        read(`M_W005, d, r);
        check("no state change",              d, 32'h11BB_33DD);
        read(`M_BASE + 32'h016, d, r);
        check("misaligned read SLVERR",  {30'b0, r}, 32'h2);
        check("RDATA zeroed on error",        d, 32'h0000_0000);

        `uvm_info("MEM", "---- AW/W ordering independence (F03) ----", UVM_LOW)
        write(`M_W005, 32'h0F0F_0F0F, 4'b1111, r, 4, 0);   // W first
        read(`M_W005, d, r);
        check("W-before-AW landed",           d, 32'h0F0F_0F0F);
        write(`M_W005, 32'hF0F0_F0F0, 4'b1111, r, 0, 4);   // AW first
        read(`M_W005, d, r);
        check("AW-before-W landed",           d, 32'hF0F0_F0F0);

        if (errors == 0)
            `uvm_info("MEM", $sformatf("all %0d checks passed", checks), UVM_LOW)
        else
            `uvm_error("MEM", $sformatf("%0d of %0d checks FAILED", errors, checks))
    endtask

endclass : axi_mem_seq
