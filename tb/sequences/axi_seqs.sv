//======================================================================
// axi_seqs.sv  --  random, memory and backpressure sequences
//
// Split from axi_base_seq.sv because EDA Playground caps a pane at
// 100,000 characters and the whole environment does not fit in one.
// Every bundle needs the base class; only some need these.
//
// axi_backpressure_seq lives here rather than with the protocol
// sequences for the same reason, and it is not an unnatural home:
// backpressure is a stress property, it is what sanity_rand_tb exists
// to generate locally, and the two cover points it owns
// (c_write_backpressure, c_read_backpressure) are random-traffic ones.
//
// NOT independently compilable -- see tb/agent/axi_transaction.sv.
//======================================================================



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

    function new(string name = "axi_mem_seq");
        super.new(name);
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

//======================================================================
class axi_backpressure_seq extends axi_base_seq;

    `uvm_object_utils(axi_backpressure_seq)

    function new(string name = "axi_backpressure_seq");
        super.new(name);
    endfunction

    task slow_write(bit [31:0] addr, bit [31:0] data, int b_delay);
        axi_transaction t = axi_transaction::type_id::create("bp_wr");
        if (!t.randomize() with {
                kind == AXI_WRITE; addr == local::addr; data == local::data;
                strb == 4'b1111; misaligned == 0;
                aw_delay == 0; w_delay == 0; b_ready_delay == local::b_delay;
            })
            `uvm_error(get_type_name(), "backpressure write randomize failed")
        issue_nb(t);
        wait (t.completed == 1'b1);
    endtask

    task slow_read(bit [31:0] addr, int r_delay, output bit [31:0] data, output bit [1:0] resp);
        axi_transaction t = axi_transaction::type_id::create("bp_rd");
        if (!t.randomize() with {
                kind == AXI_READ; addr == local::addr; misaligned == 0;
                ar_delay == 0; r_ready_delay == local::r_delay;
            })
            `uvm_error(get_type_name(), "backpressure read randomize failed")
        issue_nb(t);
        wait (t.completed == 1'b1);
        data = t.rdata;
        resp = t.resp;
    endtask

    // vplan section 5's bin edges again: 0, 1-3, 4-10, >10. Declared
    // ahead of body(), which uses it -- a class property referenced
    // above its own declaration is accepted by some tools and rejected
    // by a conformant front end.
    int delays [6] = '{0, 2, 5, 9, 14, 20};

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        section("F28 -- responses held for a long time, register slave");

        foreach (delays[i]) begin
            slow_write(`A_SCRATCH, 32'hBEEF_0000 + i, delays[i]);
            slow_read(`A_SCRATCH, delays[i], d, r);
            check($sformatf("BREADY/RREADY held %0d cycles", delays[i]),
                  d, 32'hBEEF_0000 + i);
        end

        section("F28 -- and through the interconnect to memory");

        foreach (delays[i]) begin
            slow_write(`M_WORD(20 + i), 32'hFACE_0000 + i, delays[i]);
            slow_read(`M_WORD(20 + i), delays[i], d, r);
            check($sformatf("memory, READY held %0d cycles", delays[i]),
                  d, 32'hFACE_0000 + i);
        end

        section("F28 -- an error response is held just as long");

        // The response the master is slow to take is a DECERR this time.
        // The interconnect must hold it exactly as a slave holds a
        // normal one -- it is a slave to the master here.
        slow_read(`A_GAP_FIRST, 18, d, r);
        check("DECERR survived 18 cycles of RREADY low", {30'b0, r}, {30'b0, SEQ_DECERR});
        check("  RDATA still 0",                          d, 32'h0);
    endtask

endclass : axi_backpressure_seq


//======================================================================
// F29 / F08 -- back-to-back transactions
//
// Zero gap between consecutive transactions, which is the only stimulus
// that reaches c_b2b_write and c_b2b_read: they cover an accept landing
// on the cycle AFTER a response handshake completes, and a sequence that
// waits for each transaction before issuing the next can never produce
// one.
//
// F08, single-outstanding, is checked at the same time and by the same
// stimulus: this is exactly the traffic that would break it, and
// a_single_outstanding_write and a_single_outstanding_read are bound and
// watching. The sequence's own job is to confirm nothing was lost or
// reordered.
