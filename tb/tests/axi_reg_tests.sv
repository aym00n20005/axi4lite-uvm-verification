//======================================================================
// axi_reg_tests.sv
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

`AXI_DIRECTED_TEST(axi_reg_strobe_test,     axi_reg_strobe_seq)      // F16, F22
`AXI_DIRECTED_TEST(axi_error_priority_test, axi_error_priority_seq)  // F21
`AXI_DIRECTED_TEST(axi_int_status_test,     axi_int_status_seq)      // F22, F23
`AXI_DIRECTED_TEST(axi_status_test,         axi_status_seq)          // F24, F25
`AXI_DIRECTED_TEST(axi_counter_test,        axi_counter_seq)         // F26, F27


//======================================================================
// axi_register_test -- every register semantics sequence, one simulation
//
// The test this bundle runs, and the reason those scenarios were
// written as sequences rather than as tests: UVM runs one uvm_test
// per simulation, and this environment's only simulator is reached
// by pasting into a browser.
//
// ORDER IS NOT ARBITRARY. COUNTER runs LAST: it is the only sequence
// that spends 655 us of simulated time, and putting it at the end
// means a failure anywhere else is reported before that wait rather
// than after it. Each sequence before it clears INT_STATUS first.
//
//======================================================================
class axi_register_test extends axi_base_test;

    `uvm_component_utils(axi_register_test)

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
        phase.raise_objection(this, "register semantics");

        run_one(axi_reg_strobe_seq::type_id::create("reg_strobe"), "F16/F22  register strobe rule");
        run_one(axi_error_priority_seq::type_id::create("error_priority"), "F21  error precedence");
        run_one(axi_int_status_seq::type_id::create("int_status"), "F22/F23  INT_STATUS");
        run_one(axi_status_seq::type_id::create("status"), "F24/F25  STATUS");
        run_one(axi_counter_seq::type_id::create("counter"), "F26/F27  COUNTER");

        #500ns;
        phase.drop_objection(this, "register semantics done");
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

endclass : axi_register_test
