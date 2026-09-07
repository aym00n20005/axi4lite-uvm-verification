//======================================================================
// axi_proto_tests.sv
////
// SPLIT ACROSS FOUR FILES to match tb/sequences/, because EDA Playground
// caps a pane at 100,000 characters and the environment plus all
// thirteen scenarios does not fit in one. See axi_proto_seqs.sv.
//
//
// The thirteen directed tests from verification_plan.md section 6, plus
// the three that make a regression affordable.
//
// Each directed test is four lines, because the scenario lives in a
// SEQUENCE (axi_directed_seqs.sv) and the test only chooses which one to
// run. That is not a style preference -- it is what lets
// axi_regression_test run all of them inside ONE simulation, which is
// what turns sixteen EDA Playground pastes into three.
//
// The end-of-test count check lives in axi_base_test and is inherited by
// every test here.
//
// NOT independently compilable -- see tb/agent/axi_transaction.sv.
//======================================================================

//----------------------------------------------------------------------
// A test that runs exactly one sequence. Every directed test below is
// one of these with a different type.
//----------------------------------------------------------------------
virtual class axi_one_seq_test extends axi_base_test;

    axi_base_seq the_seq;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // Subclasses build their own sequence type here.
    pure virtual function axi_base_seq make_seq();

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, get_type_name());
        the_seq = make_seq();
        the_seq.seed = base_seed;
        the_seq.start(env.agent.sqr);
        note(the_seq);
        #500ns;                          // let the last responses drain
        report_seq(the_seq);
        phase.drop_objection(this, get_type_name());
    endtask

    function void report_seq(axi_base_seq s);
        `uvm_info(get_type_name(),
                  $sformatf("%s: %0d checks, %0d failures",
                            s.get_type_name(), s.checks, s.errors), UVM_LOW)
    endfunction

endclass


`define AXI_DIRECTED_TEST(TESTNAME, SEQTYPE)                                  \
class TESTNAME extends axi_one_seq_test;                                      \
    `uvm_component_utils(TESTNAME)                                            \
    function new(string name, uvm_component parent);                          \
        super.new(name, parent);                                              \
    endfunction                                                               \
    virtual function axi_base_seq make_seq();                                 \
        SEQTYPE s = SEQTYPE::type_id::create("seq");                          \
        return s;                                                             \
    endfunction                                                               \
endclass

`AXI_DIRECTED_TEST(axi_reset_test,          axi_reset_seq)           // F09
`AXI_DIRECTED_TEST(axi_order_test,          axi_order_seq)           // F03
`AXI_DIRECTED_TEST(axi_wstrb_test,          axi_wstrb_seq)           // F15
`AXI_DIRECTED_TEST(axi_align_test,          axi_align_seq)           // F20
`AXI_DIRECTED_TEST(axi_decode_test,         axi_decode_seq)          // F17, F18, F19
`AXI_DIRECTED_TEST(axi_b2b_test,            axi_b2b_seq)             // F29, F08


//======================================================================
// axi_protocol_test -- every protocol and decode sequence, one simulation
//
// The test this bundle runs, and the reason those scenarios were
// written as sequences rather than as tests: UVM runs one uvm_test
// per simulation, and this environment's only simulator is reached
// by pasting into a browser.
//
// ORDER IS NOT ARBITRARY. The reset sequence runs FIRST, while the
// DUT is still in its reset state, because half of what it checks is
// that the registers hold their spec section 5 reset values -- an
// expectation any earlier traffic destroys.
//
//======================================================================
class axi_protocol_test extends axi_base_test;

    `uvm_component_utils(axi_protocol_test)

    axi_base_seq seqs [$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_one(axi_base_seq s, string label);
        `uvm_info(get_type_name(),
            $sformatf("================ %s ================", label), UVM_LOW)
        s.seed = base_seed;
        s.start(env.agent.sqr);
        note(s);
        seqs.push_back(s);
        #300ns;                          // drain before the next one starts
    endtask

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "protocol and decode");

        run_one(axi_reset_seq::type_id::create("reset"), "F09  reset");
        run_one(axi_smoke_seq::type_id::create("smoke"), "F01/F02  smoke");
        run_one(axi_order_seq::type_id::create("order"), "F03  AW/W ordering");
        run_one(axi_decode_seq::type_id::create("decode"), "F17/F18/F19  decode");
        run_one(axi_align_seq::type_id::create("align"), "F20  alignment");
        run_one(axi_wstrb_seq::type_id::create("wstrb"), "F15  byte enables");
        run_one(axi_b2b_seq::type_id::create("b2b"), "F29/F08  back-to-back");

        #500ns;
        phase.drop_objection(this, "protocol and decode done");
    endtask

    function void report_phase(uvm_phase phase);
        int unsigned total_checks = 0;
        int unsigned total_errors = 0;
        super.report_phase(phase);

        `uvm_info(get_type_name(), "==== per-sequence totals ====", UVM_LOW)
        foreach (seqs[i]) begin
            `uvm_info(get_type_name(),
                $sformatf("   %-24s %4d checks  %2d failures",
                          seqs[i].get_name(), seqs[i].checks, seqs[i].errors), UVM_LOW)
            total_checks += seqs[i].checks;
            total_errors += seqs[i].errors;
        end
        `uvm_info(get_type_name(),
            $sformatf("   %-24s %4d checks  %2d failures",
                      "TOTAL", total_checks, total_errors), UVM_LOW)
    endfunction

endclass : axi_protocol_test
