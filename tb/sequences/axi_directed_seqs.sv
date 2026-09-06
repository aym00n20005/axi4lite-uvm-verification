//======================================================================
// axi_directed_seqs.sv
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

// Memory words, spec section 6. Base 0x0000_1000, word = ADDR[9:2].
`define M_WORD(n)  (32'h0000_1000 + ((n) << 2))

// Spec section 4's boundaries. These five addresses are the map.
`define A_REG_LAST_IMPL   32'h0000_001C   // ID, last implemented register
`define A_REG_FIRST_UNIMP 32'h0000_0020   // first unimplemented offset
`define A_REG_LAST        32'h0000_0FFC   // last word of the register region
`define A_MEM_FIRST       32'h0000_1000   // memory word 0
`define A_MEM_LAST        32'h0000_13FC   // memory word 255
`define A_GAP_FIRST       32'h0000_1400   // first unmapped -- BUG-005's address
`define A_GAP_LAST        32'h0000_1FFC   // last of the deliberate gap
`define A_UNMAPPED_HIGH   32'hFFFF_FFFC   // top of the address space

localparam bit [1:0] SEQ_OKAY   = 2'b00;
localparam bit [1:0] SEQ_SLVERR = 2'b10;
localparam bit [1:0] SEQ_DECERR = 2'b11;


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

        t = axi_transaction::type_id::create("mid_write");
        if (!t.randomize() with {
                kind == AXI_WRITE; addr == `A_SCRATCH; data == 32'hDEAD_0001;
                strb == 4'b1111; misaligned == 0; w_delay == 0; aw_delay == 25;
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
                ar_delay == 0; r_ready_delay == 25;
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
//======================================================================
class axi_ral_seq extends axi_base_seq;

    `uvm_object_utils(axi_ral_seq)

    axi_reg_block regmodel;

    function new(string name = "axi_ral_seq");
        super.new(name);
    endfunction

    task body();
        uvm_reg_hw_reset_seq  hw_reset;
        uvm_reg_bit_bash_seq  bit_bash;
        uvm_status_e          status;
        uvm_reg_data_t        value;
        bit [31:0]            d;
        bit [1:0]             r;

        if (regmodel == null) begin
            `uvm_fatal(get_type_name(), "no register model -- the test must set seq.regmodel")
        end

        //--------------------------------------------------------------
        section("F10-F13 -- uvm_reg_hw_reset_seq (reset values)");

        hw_reset = uvm_reg_hw_reset_seq::type_id::create("hw_reset");
        hw_reset.model = regmodel;
        hw_reset.start(null);
        checks++;
        `uvm_info(get_type_name(), "  hw_reset complete -- any mismatch above is a UVM_ERROR", UVM_LOW)

        //--------------------------------------------------------------
        section("F10-F13 -- uvm_reg_bit_bash_seq (access policies, and BUG-004)");

        bit_bash = uvm_reg_bit_bash_seq::type_id::create("bit_bash");
        bit_bash.model = regmodel;
        bit_bash.start(null);
        checks++;
        `uvm_info(get_type_name(), "  bit_bash complete", UVM_LOW)

        //--------------------------------------------------------------
        section("F10 -- RW registers hold what is written");

        regmodel.SCRATCH.write(status, 32'hC0DE_F00D);
        check("SCRATCH write status OK", {30'b0, status == UVM_IS_OK}, 32'h1);
        regmodel.SCRATCH.read(status, value);
        check("SCRATCH reads back",      value[31:0], 32'hC0DE_F00D);

        regmodel.CONFIG.write(status, 32'h0000_00A5);
        regmodel.CONFIG.read(status, value);
        check("CONFIG reads back",       value[31:0], 32'h0000_00A5);

        regmodel.INT_ENABLE.write(status, 32'h0000_0009);
        regmodel.INT_ENABLE.read(status, value);
        check("INT_ENABLE reads back",   value[31:0], 32'h0000_0009);

        //--------------------------------------------------------------
        section("F13 -- reserved bits read 0 and cannot store data");

        regmodel.CONFIG.write(status, 32'hFFFF_FFFF);
        regmodel.CONFIG.read(status, value);
        check("CONFIG masks [31:8]",     value[31:0], 32'h0000_00FF);

        regmodel.INT_ENABLE.write(status, 32'hFFFF_FFFF);
        regmodel.INT_ENABLE.read(status, value);
        check("INT_ENABLE masks [31:4]", value[31:0], 32'h0000_000F);

        // CTRL[1] is a command bit, not storage -- spec section 5,
        // clarified in v0.3, and modelled WC rather than RW for exactly
        // this reason. Writing all-ones sets enable and pulses
        // reset_stats; the read-back shows only enable.
        regmodel.CTRL.write(status, 32'hFFFF_FFFF);
        regmodel.CTRL.read(status, value);
        check("CTRL: enable set, reset_stats reads 0", value[31:0], 32'h0000_0001);
        regmodel.CTRL.write(status, 32'h0000_0000);

        //--------------------------------------------------------------
        section("F11 -- RO registers accept writes with OKAY and ignore them");

        regmodel.ID.write(status, 32'h0000_0000);
        check("write to ID returns OK",  {30'b0, status == UVM_IS_OK}, 32'h1);
        regmodel.ID.read(status, value);
        check("  ID still 0xDEADBEEF",   value[31:0], 32'hDEAD_BEEF);

        regmodel.STATUS.write(status, 32'hFFFF_FFFF);
        check("write to STATUS returns OK", {30'b0, status == UVM_IS_OK}, 32'h1);

        regmodel.COUNTER.write(status, 32'hFFFF_FFFF);
        check("write to COUNTER returns OK", {30'b0, status == UVM_IS_OK}, 32'h1);

        //--------------------------------------------------------------
        section("F12 -- INT_STATUS is W1C, not RW (BUG-004's check)");

        // Clear, then make hardware set bit 0 with a real event, then
        // clear only that bit. A plain-RW implementation fails the
        // middle step -- the bit would not set at all -- and a
        // clear-on-any-write implementation fails the last.
        regmodel.INT_STATUS.write(status, 32'h0000_000F);
        read(`A_REG_FIRST_UNIMP, d, r);                 // -> INT_STATUS[0]
        regmodel.INT_STATUS.read(status, value);
        check("hardware set [0]",        value[31:0] & 32'h1, 32'h1);

        regmodel.INT_STATUS.write(status, 32'h0000_0000);
        regmodel.INT_STATUS.read(status, value);
        check("writing 0 does NOT clear it", value[31:0] & 32'h1, 32'h1);

        regmodel.INT_STATUS.write(status, 32'h0000_0001);
        regmodel.INT_STATUS.read(status, value);
        check("writing 1 clears it",     value[31:0] & 32'h1, 32'h0);

        //--------------------------------------------------------------
        section("mirror agreement -- the predictor is fed by the monitor");

        // The mirror was updated by uvm_reg_predictor from what the
        // MONITOR saw on the pins, not from what these calls asked for
        // (axi_map.set_auto_predict(0) -- see axi_env.sv). Comparing it
        // against a fresh read therefore compares two independent paths.
        regmodel.SCRATCH.write(status, 32'h5EED_1234);
        check("mirror matches after a write",
              regmodel.SCRATCH.get()[31:0], 32'h5EED_1234);
        read(`A_SCRATCH, d, r);
        check("  and so does a raw bus read", d, 32'h5EED_1234);
    endtask

endclass : axi_ral_seq
