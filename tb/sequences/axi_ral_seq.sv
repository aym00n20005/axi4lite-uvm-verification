//======================================================================
// axi_ral_seq.sv
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
