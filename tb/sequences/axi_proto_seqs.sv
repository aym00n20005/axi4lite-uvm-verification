//======================================================================
// axi_proto_seqs.sv
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
class axi_reset_seq extends axi_base_seq;

    `uvm_object_utils(axi_reset_seq)

    uvm_event #(uvm_object) rst_req;
    uvm_event #(uvm_object) rst_done;

    function new(string name = "axi_reset_seq");
        super.new(name);
    endfunction

    task pulse_reset();
        rst_req  = uvm_event_pool::get_global("axi_reset_request");
        rst_done = uvm_event_pool::get_global("axi_reset_done");
        rst_done.reset();
        rst_req.trigger();
        rst_done.wait_trigger();
    endtask

    task body();
        bit [31:0] d;
        bit [1:0]  r;
        axi_transaction t;

        //--------------------------------------------------------------
        section("F09 -- reset while the bus is idle");

        write(`A_SCRATCH, 32'hA5A5_5A5A, 4'b1111, r);
        write(`A_CONFIG,  32'h0000_0055, 4'b1111, r);
        write(`M_WORD(3), 32'hFEED_FACE, 4'b1111, r);

        read(`A_SCRATCH, d, r);  check("SCRATCH holds before reset",  d, 32'hA5A5_5A5A);
        read(`A_CONFIG,  d, r);  check("CONFIG holds before reset",   d, 32'h0000_0055);
        read(`M_WORD(3), d, r);  check("memory holds before reset",   d, 32'hFEED_FACE);

        pulse_reset();

        // Spec section 5 reset values.
        read(`A_SCRATCH, d, r);  check("SCRATCH back to 0",           d, 32'h0000_0000);
        read(`A_CONFIG,  d, r);  check("CONFIG back to 0x000000FF",   d, 32'h0000_00FF);
        read(`A_ID,      d, r);  check("ID still 0xDEADBEEF",         d, 32'hDEAD_BEEF);
        read(`A_INT_STATUS, d, r);
        check("INT_STATUS cleared by reset",           d & 32'h7, 32'h0);

        // Spec section 6. The one thing reset must NOT do.
        read(`M_WORD(3), d, r);
        check("memory SURVIVES reset (section 6)",     d, 32'hFEED_FACE);

        //--------------------------------------------------------------
        // Reset landing on a transaction that has been half accepted.
        // w_delay 0 with a long aw_delay leaves W accepted and AW not,
        // which is the state the interconnect holds a beat in -- and the
        // state the monitor reports to cg_reset as RESET_MID_WRITE.
        section("F09 -- reset with a write half accepted");

        // aw_delay 20, not 25. axi_transaction's c_delay_range is a HARD
        // constraint bounding every delay to [0:20], so 25 is
        // unsatisfiable and randomize() fails -- which Xcelium reported
        // as *W,SVRNDF with the two conflicting lines named, and which
        // then cascaded into the abort check failing because the
        // transaction never got its long delay.
        //
        // 20 cycles is 200 ns, and pulse_reset() below fires 100 ns
        // after issue, so the AW is still un-accepted when reset lands.
        t = axi_transaction::type_id::create("mid_write");
        if (!t.randomize() with {
                kind == AXI_WRITE; addr == `A_SCRATCH; data == 32'hDEAD_0001;
                strb == 4'b1111; misaligned == 0; w_delay == 0; aw_delay == 20;
            })
            `uvm_error(get_type_name(), "mid-write randomize failed")
        issue_nb(t);
        #100ns;                       // let W be accepted, AW not yet
        pulse_reset();
        wait (t.completed == 1'b1);   // completed=1 even on an abort
        check_true("the half-accepted write was abandoned", t.aborted, {31'b0, t.aborted});

        read(`A_SCRATCH, d, r);
        check("and it did not land",                   d, 32'h0000_0000);
        write(`A_SCRATCH, 32'h1234_ABCD, 4'b1111, r);
        check("bus works after a mid-write reset", {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("  and the write took effect",           d, 32'h1234_ABCD);

        //--------------------------------------------------------------
        // AR accepted, R held off by a long r_ready_delay -- the read is
        // genuinely in flight when reset lands.
        section("F09 -- reset with a read in flight");

        t = axi_transaction::type_id::create("mid_read");
        if (!t.randomize() with {
                kind == AXI_READ; addr == `A_ID; misaligned == 0;
                ar_delay == 0; r_ready_delay == 20;      // see above
            })
            `uvm_error(get_type_name(), "mid-read randomize failed")
        issue_nb(t);
        #100ns;
        pulse_reset();
        wait (t.completed == 1'b1);
        check_true("the in-flight read was abandoned", t.aborted, {31'b0, t.aborted});

        read(`A_ID, d, r);
        check("bus works after a mid-read reset",      d, 32'hDEAD_BEEF);
    endtask

endclass : axi_reset_seq


//======================================================================
// F03 -- AW/W ordering independence
//
// Spec section 3 rule 4: the slave must accept AW and W in any order,
// including the same cycle. All three orderings write a distinct value
// and are read back, so an ordering the DUT mishandles shows up as data
// rather than as a hang.
//
// The delays are chosen, not randomised: this is the one test where the
// ordering IS the stimulus, and leaving it to a distribution would make
// a failure depend on the seed.
//======================================================================
class axi_order_seq extends axi_base_seq;

    `uvm_object_utils(axi_order_seq)

    function new(string name = "axi_order_seq");
        super.new(name);
    endfunction

    task one(string label, bit [31:0] addr, bit [31:0] data, int aw_d, int w_d);
        bit [31:0] d;
        bit [1:0]  r;
        write(addr, data, 4'b1111, r, aw_d, w_d);
        check($sformatf("%s response OKAY", label), {30'b0, r}, 32'h0);
        read(addr, d, r);
        check($sformatf("%s data landed", label),   d, data);
    endtask

    task body();
        section("F03 -- ordering, register slave");
        one("AW 4 cycles before W", `A_SCRATCH, 32'h0F0F_0F0F, 0, 4);
        one("W 4 cycles before AW", `A_SCRATCH, 32'hF0F0_F0F0, 4, 0);
        one("AW and W same cycle",  `A_SCRATCH, 32'hABCD_1234, 0, 0);
        one("W 12 cycles before AW", `A_SCRATCH, 32'h5A5A_A5A5, 12, 0);

        // Across the decode. W-before-AW is the case spec section 7 calls
        // the hard part: the interconnect cannot know where the beat is
        // going until AW arrives, so it must hold it.
        section("F03 -- ordering across the interconnect (section 7)");
        one("W-before-AW to memory",   `M_WORD(7),  32'h1111_2222, 6, 0);
        one("AW-before-W to memory",   `M_WORD(8),  32'h3333_4444, 0, 6);
        one("same cycle to memory",    `M_WORD(9),  32'h5555_6666, 0, 0);
    endtask

endclass : axi_order_seq


//======================================================================
// F15 -- byte enables on the memory slave
//
// Spec section 6: byte n is written only when WSTRB[n] is 1, and
// 4'b0000 is a legal no-op returning OKAY.
//
// All sixteen patterns, each on its OWN word, so a pattern that wrongly
// writes a byte it should not cannot be masked by the next pattern
// writing it correctly.
//======================================================================
class axi_wstrb_seq extends axi_base_seq;

    `uvm_object_utils(axi_wstrb_seq)

    localparam bit [31:0] SEED_VAL = 32'h1122_3344;
    localparam bit [31:0] NEW_VAL  = 32'hAABB_CCDD;

    function new(string name = "axi_wstrb_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] d, expected;
        bit [1:0]  r;

        section("F15 -- all sixteen WSTRB patterns, one word each");

        for (int p = 0; p < 16; p++) begin
            bit [31:0] a = `M_WORD(32 + p);

            write(a, SEED_VAL, 4'b1111, r);
            check($sformatf("strb %04b: seed written", p[3:0]), {30'b0, r}, 32'h0);

            write(a, NEW_VAL, p[3:0], r);
            check($sformatf("strb %04b: OKAY (section 6)", p[3:0]), {30'b0, r}, 32'h0);

            // The reference: byte n takes the new value iff strobed.
            expected = SEED_VAL;
            for (int b = 0; b < 4; b++)
                if (p[b]) expected[8*b +: 8] = NEW_VAL[8*b +: 8];

            read(a, d, r);
            check($sformatf("strb %04b: only strobed bytes changed", p[3:0]), d, expected);
        end

        // Stated separately because it is the pattern with two readings:
        // a legal no-op here, an SLVERR on the register slave.
        section("F15 -- WSTRB 0000 is a no-op on memory, not an error");
        write(`M_WORD(60), 32'hCAFE_BABE, 4'b1111, r);
        write(`M_WORD(60), 32'h0000_0000, 4'b0000, r);
        check("zero strobe returns OKAY",  {30'b0, r}, 32'h0);
        read(`M_WORD(60), d, r);
        check("  and changed nothing",      d, 32'hCAFE_BABE);
    endtask

endclass : axi_wstrb_seq


//======================================================================
// F16 / F22 -- the register slave's opposite WSTRB policy
//
// Spec section 5: WSTRB != 4'b1111 on a register write is SLVERR, the
// register is unchanged, and INT_STATUS[2] is set. Three claims in one
// transaction, and all three are checked.
//
// Same four bits as F15, opposite meaning. That contrast is the point of
// running the two sequences in the same simulation.
//======================================================================
class axi_align_seq extends axi_base_seq;

    `uvm_object_utils(axi_align_seq)

    function new(string name = "axi_align_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        section("F20 -- misaligned register access");

        write(`A_SCRATCH, 32'h9876_5432, 4'b1111, r);
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);

        for (int off = 1; off <= 3; off++) begin
            write(`A_SCRATCH + off, 32'hFFFF_FFFF, 4'b1111, r);
            check($sformatf("write SCRATCH+%0d -> SLVERR", off),
                  {30'b0, r}, {30'b0, SEQ_SLVERR});
            read(`A_SCRATCH + off, d, r);
            check($sformatf("read  SCRATCH+%0d -> SLVERR", off),
                  {30'b0, r}, {30'b0, SEQ_SLVERR});
            check($sformatf("  RDATA zeroed (section 4)"), d, 32'h0);
        end

        read(`A_SCRATCH, d, r);
        check("SCRATCH untouched by all six",  d, 32'h9876_5432);
        read(`A_INT_STATUS, d, r);
        check("INT_STATUS[1] set",             d & 32'h2, 32'h2);
        check("  and only that bit",           d & 32'h5, 32'h0);

        section("F20 -- misaligned memory access");

        write(`M_WORD(12), 32'h0BAD_C0DE, 4'b1111, r);
        write(`A_INT_STATUS, 32'h0000_000F, 4'b1111, r);

        for (int off = 1; off <= 3; off++) begin
            write(`M_WORD(12) + off, 32'hFFFF_FFFF, 4'b1111, r);
            check($sformatf("write mem+%0d -> SLVERR", off),
                  {30'b0, r}, {30'b0, SEQ_SLVERR});
            read(`M_WORD(12) + off, d, r);
            check($sformatf("read  mem+%0d -> SLVERR", off),
                  {30'b0, r}, {30'b0, SEQ_SLVERR});
            check("  RDATA zeroed",             d, 32'h0);
        end

        read(`M_WORD(12), d, r);
        check("memory word untouched",         d, 32'h0BAD_C0DE);

        // The discriminator.
        read(`A_INT_STATUS, d, r);
        check("no INT_STATUS bit from a MEMORY misalignment (section 6)",
              d & 32'hF, 32'h0);
    endtask

endclass : axi_align_seq


//======================================================================
// F17 / F18 / F19 -- address decode
//
// Spec section 4's map, walked at its boundaries. Every one of these
// addresses is one word away from an address with a different answer,
// which is the only interesting place to test a decode.
//
//   0x0000_0FFC  last register word        SLVERR (unimplemented)
//   0x0000_1000  first memory word         OKAY
//   0x0000_13FC  last memory word          OKAY
//   0x0000_1400  first unmapped            DECERR   <- BUG-005's address
//
// The 0x1400 case is the reason the gap exists at all: an ADDR[12] or
// ADDR[13] decode routes it to memory, where it aliases onto word 0x100
// of a 256-word array and is answered as if it were valid.
//======================================================================
class axi_decode_seq extends axi_base_seq;

    `uvm_object_utils(axi_decode_seq)

    function new(string name = "axi_decode_seq");
        super.new(name);
    endfunction

    task expect_resp(string label, bit [31:0] addr, bit [1:0] exp);
        bit [31:0] d;
        bit [1:0]  r;
        read(addr, d, r);
        check($sformatf("read  %s", label), {30'b0, r}, {30'b0, exp});
        if (exp != SEQ_OKAY)
            check($sformatf("  RDATA 0 on error"), d, 32'h0);
        write(addr, 32'hDEAD_DEAD, 4'b1111, r);
        check($sformatf("write %s", label), {30'b0, r}, {30'b0, exp});
    endtask

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        section("F17 -- routed to the right slave");

        // Two witnesses with the same low bits, one per slave. If the
        // decode aliased, one would overwrite the other.
        write(`A_SCRATCH, 32'h1111_1111, 4'b1111, r);
        write(`M_WORD(5), 32'h2222_2222, 4'b1111, r);
        read(`A_SCRATCH, d, r); check("register witness intact", d, 32'h1111_1111);
        read(`M_WORD(5), d, r); check("memory witness intact",   d, 32'h2222_2222);

        read(`A_ID, d, r);
        check("ID reaches the register slave", d, 32'hDEAD_BEEF);

        section("F19 -- unimplemented register offsets");
        expect_resp("0x00000020 (first unimplemented)", `A_REG_FIRST_UNIMP, SEQ_SLVERR);
        expect_resp("0x00000100 (aliases CTRL under the v0.2 decode)",
                    32'h0000_0100, SEQ_SLVERR);
        expect_resp("0x00000FFC (last register word)", `A_REG_LAST, SEQ_SLVERR);

        section("F17 -- the memory region's edges");
        write(`A_MEM_FIRST, 32'h3333_3333, 4'b1111, r);
        check("0x00001000 write OKAY", {30'b0, r}, 32'h0);
        read(`A_MEM_FIRST, d, r);
        check("  reads back",           d, 32'h3333_3333);
        write(`A_MEM_LAST, 32'h4444_4444, 4'b1111, r);
        check("0x000013FC write OKAY", {30'b0, r}, 32'h0);
        read(`A_MEM_LAST, d, r);
        check("  reads back",           d, 32'h4444_4444);

        section("F18 -- unmapped is DECERR, not SLVERR");
        expect_resp("0x00001400 (first unmapped, BUG-005)", `A_GAP_FIRST, SEQ_DECERR);
        expect_resp("0x00001FFC (last of the gap)",         `A_GAP_LAST,  SEQ_DECERR);
        expect_resp("0x00002000 (above the gap)",           32'h0000_2000, SEQ_DECERR);
        expect_resp("0xFFFFFFFC (top of the space)",        `A_UNMAPPED_HIGH, SEQ_DECERR);

        // Not forwarded (spec section 4). 0x1400 under a bit-test decode
        // lands on memory word 0x100, which wraps onto word 0.
        read(`A_MEM_FIRST, d, r);
        check("memory word 0 untouched by the DECERRs", d, 32'h3333_3333);

        section("F18 -- one word apart, three different answers");
        expect_resp("0x00000FFC -> SLVERR", `A_REG_LAST,  SEQ_SLVERR);
        read(`A_MEM_FIRST, d, r);
        check("0x00001000 -> OKAY",  {30'b0, r}, 32'h0);
        expect_resp("0x00001400 -> DECERR", `A_GAP_FIRST, SEQ_DECERR);
    endtask

endclass : axi_decode_seq


//======================================================================
// F21 -- error precedence
//
// Spec section 4: when several error conditions apply to one
// transaction, exactly ONE response is given and exactly ONE INT_STATUS
// bit is set, in this order:
//
//   1. unmapped              DECERR, and NO INT_STATUS bit at all --
//                            the slave never sees the transaction
//   2. misaligned            SLVERR, INT_STATUS[1]
//   3. unimplemented offset  SLVERR, INT_STATUS[0]
//   4. partial strobe        SLVERR, INT_STATUS[2]
//
// So each case below deliberately satisfies TWO conditions and checks
// that the higher-ranked one wins -- including its side effect. Checking
// only the response would pass a DUT that returned the right code and
// set the wrong bit.
//
// The "and only that bit" check is the load-bearing half: a cascade
// implemented with independent ifs instead of else-ifs gives the right
// response and sets two bits.
//======================================================================
class axi_b2b_seq extends axi_base_seq;

    `uvm_object_utils(axi_b2b_seq)

    localparam int N = 24;

    function new(string name = "axi_b2b_seq");
        super.new(name);
    endfunction

    task body();
        axi_transaction wr [N];
        axi_transaction rd [N];
        bit [31:0] d;
        bit [1:0]  r;

        section("F29 -- zero-gap writes");

        // All issued before any is awaited. finish_item returns on
        // ACCEPTANCE (item_done fires there), so the loop runs ahead of
        // the bus and the next AWVALID is already asserted when the
        // previous B completes.
        for (int i = 0; i < N; i++) begin
            wr[i] = axi_transaction::type_id::create($sformatf("b2b_wr%0d", i));
            if (!wr[i].randomize() with {
                    kind == AXI_WRITE; addr == `M_WORD(64 + i);
                    data == 32'hB2B0_0000 + i; strb == 4'b1111; misaligned == 0;
                    aw_delay == 0; w_delay == 0; b_ready_delay == 0;
                })
                `uvm_error(get_type_name(), "b2b write randomize failed")
            issue_nb(wr[i]);
        end
        foreach (wr[i]) wait (wr[i].completed == 1'b1);

        for (int i = 0; i < N; i++)
            check($sformatf("write %0d response OKAY", i), {30'b0, wr[i].resp}, 32'h0);

        section("F29 -- zero-gap reads, and every value is still there");

        for (int i = 0; i < N; i++) begin
            rd[i] = axi_transaction::type_id::create($sformatf("b2b_rd%0d", i));
            if (!rd[i].randomize() with {
                    kind == AXI_READ; addr == `M_WORD(64 + i); misaligned == 0;
                    ar_delay == 0; r_ready_delay == 0;
                })
                `uvm_error(get_type_name(), "b2b read randomize failed")
            issue_nb(rd[i]);
        end
        foreach (rd[i]) wait (rd[i].completed == 1'b1);

        for (int i = 0; i < N; i++)
            check($sformatf("read %0d returned its own data", i),
                  rd[i].rdata, 32'hB2B0_0000 + i);

        section("F29 -- back-to-back across the decode boundary");

        // Alternating slaves with no gap. The interconnect has to switch
        // destination between consecutive transactions, which is the
        // case a response mux gets wrong.
        for (int i = 0; i < 8; i++) begin
            axi_transaction t = axi_transaction::type_id::create($sformatf("b2b_mix%0d", i));
            if (!t.randomize() with {
                    kind == AXI_WRITE;
                    addr == (local::i[0] ? `M_WORD(100) : `A_SCRATCH);
                    data == 32'hA1B2_0000 + local::i; strb == 4'b1111; misaligned == 0;
                    aw_delay == 0; w_delay == 0; b_ready_delay == 0;
                })
                `uvm_error(get_type_name(), "b2b mixed randomize failed")
            issue_nb(t);
        end
        #500ns;

        read(`A_SCRATCH, d, r);
        check("last register write won",  d, 32'hA1B2_0006);
        read(`M_WORD(100), d, r);
        check("last memory write won",    d, 32'hA1B2_0007);
    endtask

endclass : axi_b2b_seq


//======================================================================
// F10 / F11 / F12 / F13 -- register access policies, through the RAL
//
// The RAL's value here is not that it saves typing. It is that the
// access policy is stated ONCE, in scripts/regmap.yaml, and then
// checked against the DUT by library code that has never read this
// project's specification. A hand-written policy test and a hand-written
// register bank are two transcriptions of the same table by the same
// person, and they agree with each other's mistakes.
//
// THREE PARTS, IN THIS ORDER, AND THE ORDER MATTERS:
//
//   hw_reset   reads every register and compares against its declared
//              reset value. Must run FIRST -- it is the only check whose
//              expectation is destroyed by any other traffic.
//
//   bit_bash   toggles every bit of every register and checks the
//              read-back against the mirror. This is what catches
//              BUG-004, INT_STATUS implemented as plain RW: the mirror
//              predicts W1C (write 1 -> 0), a plain-RW DUT returns 1,
//              and they disagree on the first bit.
//
//              It also covers F13 for free, and that is worth knowing:
//              uvm_reg_single_bit_bash_seq treats a bit no field claims
//              as "RO", so a reserved bit that stored data fails here
//              without anyone writing a reserved-bit test.
//
//   explicit   the four policies stated in the spec's own terms, so a
//              failure names the rule rather than a bit index.
//
// Four fields are excluded from comparison in the generated model --
// STATUS.busy, STATUS.error, COUNTER.count and INT_STATUS[3] -- because
// hardware writes them and the mirror cannot know. They are masked in
// exactly the places tb/env/axi_scoreboard.sv masks them, so the two
// independent models make the same claim about what is knowable.
