//======================================================================
// axi_ral_test.sv
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

//======================================================================
// axi_ral_test -- F10 to F13
//
// The one test that builds the register model. axi_env only constructs
// the RAL and its predictor when "use_ral" is set, because a locked reg
// block sitting unused in every other test is one more mirror that can
// silently be wrong.
//
// It also switches off the sequence-issued count check, and the reason
// is worth stating rather than hiding behind a flag: RAL accesses do not
// come from a sequence's write()/read(), they come from inside uvm_reg,
// so axi_base_seq's issued_writes cannot see them. The DRIVER's dispatch
// count does, and that comparison against the monitor is the one that
// carries the independence claim anyway -- the monitor has no handle to
// the driver either.
//======================================================================
class axi_ral_test extends axi_base_test;

    `uvm_component_utils(axi_ral_test)

    axi_ral_seq seq;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        uvm_config_db #(bit)::set(this, "env", "use_ral", 1);
        super.build_phase(phase);
        seq_counts_all = 0;              // see the header
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "RAL");
        seq = axi_ral_seq::type_id::create("seq");
        seq.seed     = base_seed;
        seq.regmodel = env.regmodel;
        seq.start(env.agent.sqr);
        note(seq);
        #500ns;
        `uvm_info(get_type_name(),
                  $sformatf("axi_ral_seq: %0d checks, %0d failures", seq.checks, seq.errors),
                  UVM_LOW)
        phase.drop_objection(this, "RAL done");
    endtask

endclass : axi_ral_test


