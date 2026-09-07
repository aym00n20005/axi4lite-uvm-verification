//======================================================================
// axi_reg_seqs.sv
////
// SPLIT ACROSS THREE FILES, and the reason is a hard tool limit rather
// than a design preference: EDA Playground caps a pane at 100,000
// characters, and the environment plus all thirteen scenarios is 133,000
// even with every comment stripped. So the scenarios are grouped by what
// they are ABOUT, which at least makes the split mean something:
//
//   axi_proto_seqs.sv  protocol and decode -- reset, ordering, byte
//                      enables, alignment, routing, backpressure,
//                      back-to-back
//   axi_reg_seqs.sv    register semantics -- the strobe rule, error
//                      precedence, INT_STATUS, STATUS, COUNTER
//   axi_ral_seq.sv     the RAL access-policy sequence
//
//
// The thirteen scenarios from verification_plan.md section 6 that had no
// sequence, written as SEQUENCES rather than as tests.
//
// WHY SEQUENCES AND NOT TESTS
//
// UVM runs exactly one uvm_test per simulation, and this environment's
// only simulator is Xcelium on EDA Playground -- reached by clearing two
// panes and pasting. One test per run therefore means one browser round
// trip per test, and sixteen tests means sixteen. That is the difference
// between a regression somebody runs and a regression somebody stops
// running.
//
// Written as sequences, each scenario is still a test of its own (the
// thin wrappers in axi_directed_tests.sv) AND can be run alongside the
// others inside a single simulation by axi_regression_test. Sixteen
// tests, three pastes.
//
// EVERY SEQUENCE HERE IS CHECKED TWICE, ON PURPOSE
//
// The sequence checks the specific claim it was written to demonstrate,
// in the words of the spec paragraph it came from. The scoreboard checks
// every transaction against a spec-derived reference model fed by the
// monitor, and has never heard of these sequences. When both are right
// they agree; the value is entirely in what happens when they do not.
//
// NOT independently compilable -- see tb/agent/axi_transaction.sv.
//======================================================================

// Addresses and response codes come from axi_base_seq.sv, which every
// bundle includes -- see the note there.


//======================================================================
// F09 -- reset behaviour
//
// Three claims, and the third is the one that is easy to get wrong:
//
//   registers return to their reset values (spec section 5);
//   MEMORY DOES NOT (spec section 6, "reset does not clear memory
//     contents. This matches real RAM and is stated explicitly so it
//     isn't mistaken for a bug during scoreboard bring-up");
//   the bus works afterwards.
//
// Reset is requested through a uvm_event rather than driven from here --
// ARESETn has exactly one driver, and the section 1 reset contract lives
// with it. See tb_top_sys.sv.
//======================================================================
class axi_reg_strobe_seq extends axi_base_seq;

    `uvm_object_utils(axi_reg_strobe_seq)

    function new(string name = "axi_reg_strobe_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        section("F16 -- partial-strobe register write");

        write(`A_SCRATCH, 32'h1234_5678, 4'b1111, r);
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);      // clear all, W1C

        write(`A_SCRATCH, 32'hFFFF_FFFF, 4'b0011, r);
        check("partial strobe -> SLVERR", {30'b0, r}, {30'b0, SEQ_SLVERR});
        read(`A_SCRATCH, d, r);
        check("  register unchanged",      d, 32'h1234_5678);
        read(`A_INT_STATUS, d, r);
        check("  INT_STATUS[2] set (F22)", d & 32'h4, 32'h4);

        // Zero strobe is included in "anything but all-ones".
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);
        write(`A_SCRATCH, 32'hFFFF_FFFF, 4'b0000, r);
        check("zero strobe -> SLVERR too", {30'b0, r}, {30'b0, SEQ_SLVERR});
        read(`A_SCRATCH, d, r);
        check("  register still unchanged", d, 32'h1234_5678);
        read(`A_INT_STATUS, d, r);
        check("  INT_STATUS[2] set again",  d & 32'h4, 32'h4);

        // Every single-byte pattern, because "not all ones" is a range
        // and checking one member of it is not checking the rule.
        section("F16 -- each single-byte strobe is rejected");
        for (int b = 0; b < 4; b++) begin
            bit [3:0] p = 4'b0001 << b;
            write(`A_SCRATCH, 32'hFFFF_FFFF, p, r);
            check($sformatf("strb %04b -> SLVERR", p), {30'b0, r}, {30'b0, SEQ_SLVERR});
        end
        read(`A_SCRATCH, d, r);
        check("SCRATCH survived all of them", d, 32'h1234_5678);
    endtask

endclass : axi_reg_strobe_seq


//======================================================================
// F20 -- alignment
//
// Spec section 4: ADDR[1:0] != 0 is SLVERR with no state change, and
// RDATA is a deterministic zero on any error response.
//
// The discriminating check is the last one. A misaligned REGISTER access
// sets INT_STATUS[1]; a misaligned MEMORY access does not, because the
// memory slave has no INT_STATUS and spec section 6 reports its errors on
// the bus only. Same offence, two slaves, two different side effects --
// which is only visible with both slaves in the design.
//======================================================================
class axi_error_priority_seq extends axi_base_seq;

    `uvm_object_utils(axi_error_priority_seq)

    function new(string name = "axi_error_priority_seq");
        super.new(name);
    endfunction

    task clear_int();
        bit [1:0] r;
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);
    endtask

    // exp_bits is the exact expected value of INT_STATUS[2:0].
    task one(string label, bit [31:0] addr, bit [3:0] strb,
             bit [1:0] exp_resp, bit [2:0] exp_bits);
        bit [31:0] d;
        bit [1:0]  r;
        clear_int();
        write(addr, 32'hFFFF_FFFF, strb, r);
        check($sformatf("%s -> %s", label,
                        exp_resp == SEQ_DECERR ? "DECERR" :
                        exp_resp == SEQ_SLVERR ? "SLVERR" : "OKAY"),
              {30'b0, r}, {30'b0, exp_resp});
        read(`A_INT_STATUS, d, r);
        check($sformatf("  INT_STATUS[2:0] is exactly %03b", exp_bits),
              d & 32'h7, {29'b0, exp_bits});
    endtask

    task body();
        section("F21 -- two conditions at once, the higher one wins");

        // misaligned (rank 2) beats unimplemented (rank 3)
        one("misaligned AND unimplemented (0x21)",
            `A_REG_FIRST_UNIMP + 1, 4'b1111, SEQ_SLVERR, 3'b010);

        // misaligned (rank 2) beats partial strobe (rank 4)
        one("misaligned AND partial strobe (0x15)",
            `A_SCRATCH + 1, 4'b0011, SEQ_SLVERR, 3'b010);

        // unimplemented (rank 3) beats partial strobe (rank 4)
        one("unimplemented AND partial strobe (0x20)",
            `A_REG_FIRST_UNIMP, 4'b0011, SEQ_SLVERR, 3'b001);

        // All three at once. Still one response, still one bit.
        one("misaligned AND unimplemented AND partial strobe",
            `A_REG_FIRST_UNIMP + 2, 4'b0001, SEQ_SLVERR, 3'b010);

        section("F21 -- unmapped outranks everything and sets NOTHING");

        // Rank 1. The interconnect answers; no slave sees it; spec
        // section 4's parenthesis says "no INT_STATUS bit, since the
        // slave never sees the transaction". Zero bits is the check.
        one("unmapped alone (0x1400)",              `A_GAP_FIRST,     4'b1111, SEQ_DECERR, 3'b000);
        one("unmapped AND misaligned (0x1401)",     `A_GAP_FIRST + 1, 4'b1111, SEQ_DECERR, 3'b000);
        one("unmapped AND partial strobe (0x1400)", `A_GAP_FIRST,     4'b0011, SEQ_DECERR, 3'b000);
        one("unmapped, misaligned AND partial",     `A_GAP_FIRST + 3, 4'b0100, SEQ_DECERR, 3'b000);

        section("F21 -- and a clean access still sets nothing");
        one("aligned, implemented, full strobe", `A_SCRATCH, 4'b1111, SEQ_OKAY, 3'b000);
    endtask

endclass : axi_error_priority_seq


//======================================================================
// F22 / F23 -- INT_STATUS event sources and W1C semantics
//
// Spec section 5. Each of bits [2:0] has a real hardware event source,
// which is what makes a W1C register testable at all -- a
// write-1-to-clear register that nothing ever sets cannot be
// distinguished from a register that reads 0.
//
// F23, SET-VS-CLEAR COLLISION, IS NOT FULLY DECIDABLE HERE, and saying
// so is better than a check that looks like it covers it.
//
// The spec rule is: "if an event sets bit n on the same cycle a write
// would clear it, set wins". That is a SAME-CYCLE property. This
// sequence sees transactions, not cycles, and cannot place two events on
// one clock edge on purpose. What it CAN prove is the half that is
// reachable -- an event arriving after a clear is not lost -- and it
// does that below.
//
// The same-cycle half is proved by bounded model check instead, in
// formal/axi4lite_reg_slave_formal.sv. That is the honest division of
// labour and it is the reason the formal experiment is in this project
// rather than being a milestone that got quietly dropped.
//======================================================================
class axi_int_status_seq extends axi_base_seq;

    `uvm_object_utils(axi_int_status_seq)

    function new(string name = "axi_int_status_seq");
        super.new(name);
    endfunction

    task clear_all();
        bit [1:0] r;
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);
    endtask

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        section("F22 -- each event source sets its own bit");

        clear_all();
        read(`A_REG_FIRST_UNIMP, d, r);
        read(`A_INT_STATUS, d, r);
        check("unimplemented access sets [0]", d & 32'h7, 32'h1);

        clear_all();
        read(`A_SCRATCH + 2, d, r);
        read(`A_INT_STATUS, d, r);
        check("misaligned access sets [1]",    d & 32'h7, 32'h2);

        clear_all();
        write(`A_SCRATCH, 32'hFFFF_FFFF, 4'b0110, r);
        read(`A_INT_STATUS, d, r);
        check("partial strobe sets [2]",       d & 32'h7, 32'h4);

        section("F22 -- W1C clears only the bits written as 1");

        // Set [0] and [1] together.
        clear_all();
        read(`A_REG_FIRST_UNIMP, d, r);      // -> [0]
        read(`A_SCRATCH + 1, d, r);          // -> [1]
        read(`A_INT_STATUS, d, r);
        check("both [0] and [1] set",          d & 32'h7, 32'h3);

        write(`A_INT_STATUS, 32'h0000_0001, 4'b1111, r);
        read(`A_INT_STATUS, d, r);
        check("writing 1 clears [0] only",     d & 32'h7, 32'h2);

        write(`A_INT_STATUS, 32'h0000_0000, 4'b1111, r);
        read(`A_INT_STATUS, d, r);
        check("writing 0 clears nothing",      d & 32'h7, 32'h2);

        write(`A_INT_STATUS, 32'h0000_0002, 4'b1111, r);
        read(`A_INT_STATUS, d, r);
        check("writing 1 clears [1]",          d & 32'h7, 32'h0);

        section("F23 -- an event after a clear is not lost");

        // The reachable half of the set-vs-clear rule. If the RTL
        // cleared unconditionally on a W1C write rather than letting set
        // win, an event landing in the same neighbourhood would be
        // swallowed; this at least pins the ordering that transactions
        // can express.
        clear_all();
        read(`A_INT_STATUS, d, r);
        check("clear leaves [2:0] at 0",       d & 32'h7, 32'h0);
        write(`A_SCRATCH, 32'hFFFF_FFFF, 4'b0001, r);
        read(`A_INT_STATUS, d, r);
        check("event after the clear still sets [2]", d & 32'h4, 32'h4);

        `uvm_info(get_type_name(),
            "F23's same-cycle half is a cycle-level property and is proved by bounded model check, not here -- see docs/formal_notes.md",
            UVM_LOW)

        section("F13 -- INT_STATUS reserved bits read 0");
        clear_all();
        write(`A_INT_STATUS, 32'hFFFF_FFF0, 4'b1111, r);
        read(`A_INT_STATUS, d, r);
        check("bits [31:4] read 0",            d & 32'hFFFF_FFF0, 32'h0);
    endtask

endclass : axi_int_status_seq


//======================================================================
// F24 / F25 -- STATUS
//
// F25, STATUS.error, is straightforward and its v0.3 clarification is
// the interesting part: a read of STATUS is TRANSPARENT and does not
// update the bit. Under the v0.2 wording the read that observes error==1
// would itself be an OKAY register transaction and would clear it,
// making the bit read-once. A status bit destroyed by observing it is
// not a status bit, and the second read below is what distinguishes the
// two readings.
//
// F24, STATUS.busy, is the harder one and the answer changed when the
// interconnect arrived. verification_plan.md section 9 asked: "Is
// STATUS.busy observable often enough to close its coverage bin, given
// single-outstanding? If not, an explicit concurrent read+write sequence
// is needed." It is needed, and it is here.
//
// Why it got harder: busy tracks the REGISTER SLAVE's write path -- AW
// or W accepted, B not yet done. Driving the slave directly, a slow
// BREADY from the master holds the slave's BVALID high and keeps busy
// asserted for as long as you like. Through the interconnect it does
// not: the interconnect raises its own BREADY the cycle the slave
// responds, so the slave's busy window is two or three cycles wide
// regardless of what the master does. The master's b_ready_delay stalls
// the INTERCONNECT, not the slave.
//
// So the window is swept rather than aimed at: a non-blocking write is
// issued and a STATUS read follows it at every delay from 0 to 15, on
// the reasoning that a two-cycle window inside a sixteen-cycle sweep is
// hit several times. Observing it once is the claim; the sweep is how.
//======================================================================
class axi_status_seq extends axi_base_seq;

    `uvm_object_utils(axi_status_seq)

    int unsigned busy_seen = 0;

    function new(string name = "axi_status_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] d;
        bit [1:0]  r;
        axi_transaction wr, rd;

        section("F25 -- STATUS.error tracks the last completed register transaction");

        write(`A_SCRATCH, 32'h0000_0001, 4'b1111, r);       // OKAY
        read(`A_STATUS, d, r);
        check("error clear after an OKAY write", d & 32'h2, 32'h0);

        read(`A_REG_FIRST_UNIMP, d, r);                      // SLVERR
        read(`A_STATUS, d, r);
        check("error set after a SLVERR",        d & 32'h2, 32'h2);

        // The v0.3 clarification. Under the v0.2 wording this second
        // read returns 0, because the first read was itself an OKAY
        // register transaction.
        read(`A_STATUS, d, r);
        check("error SURVIVES being read (v0.3)", d & 32'h2, 32'h2);
        read(`A_STATUS, d, r);
        check("  and being read again",           d & 32'h2, 32'h2);

        write(`A_SCRATCH, 32'h0000_0002, 4'b1111, r);        // OKAY
        read(`A_STATUS, d, r);
        check("a later OKAY clears it",           d & 32'h2, 32'h0);

        // A misaligned access that DECODES to the STATUS offset is not a
        // read of STATUS -- it errors, and it sets the bit. Spec section 5.
        read(`A_STATUS + 2, d, r);
        check("misaligned read at STATUS+2 -> SLVERR", {30'b0, r}, {30'b0, SEQ_SLVERR});
        read(`A_STATUS, d, r);
        check("  and it DID set error",           d & 32'h2, 32'h2);

        section("F24 -- STATUS.busy during an in-flight write");

        for (int k = 0; k < 16; k++) begin
            wr = axi_transaction::type_id::create("busy_wr");
            if (!wr.randomize() with {
                    kind == AXI_WRITE; addr == `A_SCRATCH; data == 32'hB0B0_0000;
                    strb == 4'b1111; misaligned == 0;
                    aw_delay == 0; w_delay == 0; b_ready_delay == 0;
                })
                `uvm_error(get_type_name(), "busy write randomize failed")

            rd = axi_transaction::type_id::create("busy_rd");
            if (!rd.randomize() with {
                    kind == AXI_READ; addr == `A_STATUS; misaligned == 0;
                    ar_delay == local::k; r_ready_delay == 0;
                })
                `uvm_error(get_type_name(), "busy read randomize failed")

            // Both non-blocking, so the read is issued while the write is
            // still on the bus. Spec section 1 permits exactly this: one
            // write and one read in flight at once.
            issue_nb(wr);
            issue_nb(rd);
            wait (wr.completed == 1'b1);
            wait (rd.completed == 1'b1);

            if (rd.resp == SEQ_OKAY && rd.rdata[0] === 1'b1) busy_seen++;
        end

        check_true($sformatf("busy observed as 1 at least once (%0d of 16 offsets)", busy_seen),
                   busy_seen > 0, busy_seen);

        // The other half of the bit: it must also be observable as 0, or
        // it is not a status bit either.
        read(`A_STATUS, d, r);
        check("busy reads 0 with the bus idle",   d & 32'h1, 32'h0);
    endtask

endclass : axi_status_seq


//======================================================================
// F26 / F27 -- COUNTER and its overflow event
//
// Spec section 5. Three rules, and the second is the one a plausible
// RTL defect gets wrong:
//
//   increments every clock while CTRL.enable;
//   reset_stats clears it WITH PRIORITY over increment -- if both apply
//     on the same cycle the result is 0;
//   wrapping 0xFFFF -> 0x0000 sets INT_STATUS[3].
//
// The reset_stats check is BUG-006's, and it works because of the one
// state a transaction-level model can predict COUNTER in: cleared by
// reset_stats with enable low, it is 0 and frozen there, so every read
// must return exactly 0. Outside that state the value depends on how
// many clocks have passed, which no transaction can tell you.
//
// F27 IS WHY COUNTER IS 16 BITS. Spec section 5: a 32-bit counter takes
// ~4.3 billion cycles to wrap -- 43 seconds of simulated time -- so
// INT_STATUS[3] would be dead code and its coverage bin would never
// close. 16 bits wraps in 65,536 cycles, which is 655 us here and is
// reached below by polling rather than by one long delay: the watchdog
// watches for INACTIVITY, and 655 us of silence would correctly look
// like a hang.
//======================================================================
class axi_counter_seq extends axi_base_seq;

    `uvm_object_utils(axi_counter_seq)

    // 65,536 cycles at 10 ns is 655 us. Poll every 10 us and allow
    // generous headroom: the point is to reach the wrap, not to measure
    // how long it takes.
    localparam int POLL_LIMIT = 100;

    function new(string name = "axi_counter_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] d, first, second;
        bit [1:0]  r;
        bit        overflowed;
        int        polls;

        section("F26 -- reset_stats clears COUNTER (BUG-006)");

        // enable = 0, reset_stats = 1. After this the counter is 0 and
        // frozen there, which is the only state a read can be checked in.
        write(`A_CTRL, 32'h0000_0002, 4'b1111, r);
        check("CTRL write OKAY",              {30'b0, r}, 32'h0);
        read(`A_COUNTER, d, r);
        check("COUNTER reads exactly 0",       d, 32'h0000_0000);
        read(`A_COUNTER, d, r);
        check("  and stays 0 while disabled",  d, 32'h0000_0000);

        // reset_stats is a command bit and always reads 0 (v0.3).
        read(`A_CTRL, d, r);
        check("reset_stats reads back 0",      d, 32'h0000_0000);

        section("F26 -- COUNTER runs when enabled");

        write(`A_CTRL, 32'h0000_0001, 4'b1111, r);   // enable
        read(`A_CTRL, d, r);
        check("enable reads back 1",           d, 32'h0000_0001);

        read(`A_COUNTER, first, r);
        #1us;
        read(`A_COUNTER, second, r);
        check_true("COUNTER advanced while enabled", second !== first, second);
        check("  and stays inside 16 bits (F13)", second & 32'hFFFF_0000, 32'h0);

        section("F26 -- reset_stats has priority over increment");

        // Both bits at once. Spec section 5: "if enable and reset_stats
        // both apply on the same cycle, the result is 0". enable stays
        // set afterwards, so the counter restarts from 0 immediately and
        // the value cannot be predicted again -- the check that IS
        // available is that reset_stats did not disturb enable.
        write(`A_CTRL, 32'h0000_0003, 4'b1111, r);
        read(`A_CTRL, d, r);
        check("reset_stats did not clear enable", d, 32'h0000_0001);

        // Back to the predictable state to prove the clear really landed.
        write(`A_CTRL, 32'h0000_0002, 4'b1111, r);
        read(`A_COUNTER, d, r);
        check("COUNTER cleared and frozen again", d, 32'h0000_0000);

        section("F27 -- overflow sets INT_STATUS[3]");

        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);
        read(`A_INT_STATUS, d, r);
        check("INT_STATUS[3] clear before the wrap", d & 32'h8, 32'h0);

        // Clear the counter and start it. 65,536 cycles from here.
        write(`A_CTRL, 32'h0000_0002, 4'b1111, r);
        write(`A_CTRL, 32'h0000_0001, 4'b1111, r);

        overflowed = 1'b0;
        for (polls = 0; polls < POLL_LIMIT && !overflowed; polls++) begin
            #10us;
            // The poll is also what feeds the watchdog. A single #660us
            // delay would look exactly like a stalled handshake.
            read(`A_INT_STATUS, d, r);
            if (d[3]) overflowed = 1'b1;
        end

        check_true($sformatf("COUNTER wrapped and set INT_STATUS[3] after %0d polls", polls),
                   overflowed, {31'b0, overflowed});

        // Stop it, so the following sequences in a regression run are not
        // sharing the simulation with a free-running counter that keeps
        // setting bit 3 under them.
        write(`A_CTRL, 32'h0000_0002, 4'b1111, r);
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);
        read(`A_COUNTER, d, r);
        check("COUNTER stopped and cleared",   d, 32'h0000_0000);
    endtask

endclass : axi_counter_seq


//======================================================================
// F28 -- backpressure
//
// Spec section 3 rule 7: BVALID and RVALID must not wait for their
// READY. The DUT has to produce the response whether or not the master
// is listening, and then hold it.
//
// This sequence holds BREADY and RREADY low for a long time on every
// transaction. Two independent mechanisms then check the DUT:
//
//   a_b_not_stalled / a_r_not_stalled fire if the response failed to
//     appear within the bounded window after the accepts;
//   a_bvalid_stable / a_rvalid_stable fire if the response appeared and
//     was then withdrawn before the master accepted it.
//
// Both are bound assertions, so this sequence's own job is only to
// create the condition and confirm the data survived it.
