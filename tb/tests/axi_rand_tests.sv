//======================================================================
// axi_rand_tests.sv
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

`AXI_DIRECTED_TEST(axi_backpressure_test,   axi_backpressure_seq)    // F28

//======================================================================
// axi_multiseed_test -- one test, several seeds, one simulation
//
// EDA Playground's command line is fixed, so there is no way to pass a
// seed per run and no way to launch several runs. A multi-seed
// regression is therefore impossible from the outside -- which is why it
// is done from the inside, by re-seeding the sequence's process between
// iterations.
//
// Each pass gets base_seed + i and creates a fresh sequence object, so
// the streams are distinct and each one is reproducible on its own:
// `make playground PLAY=rand SEED=n` reruns pass 0 of that set exactly.
//======================================================================
class axi_multiseed_test extends axi_base_test;

    `uvm_component_utils(axi_multiseed_test)

    // Eight passes of ~120 transactions each. Enough to close the
    // coverage model; small enough that the run does not hit
    // Playground's job limit.
    int unsigned n_seeds = 8;

    axi_base_seq seqs [$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axi_random_seq       s;
        axi_mem_seq          mem;
        axi_backpressure_seq bp;
        phase.raise_objection(this, "multi-seed random");

        // Two directed sequences run once before the seeds. Both belong
        // with random traffic rather than with the protocol bundle:
        // F14 is the memory data path that the random stream exercises
        // continuously, and F28's two cover points are the ones only a
        // driver that overlaps transactions can reach.
        mem = axi_mem_seq::type_id::create("mem");
        mem.seed = base_seed;
        `uvm_info(get_type_name(), "================ F14  memory ================", UVM_LOW)
        mem.start(env.agent.sqr);
        note(mem);
        seqs.push_back(mem);
        #300ns;

        bp = axi_backpressure_seq::type_id::create("backpressure");
        bp.seed = base_seed;
        `uvm_info(get_type_name(), "================ F28  backpressure ================", UVM_LOW)
        bp.start(env.agent.sqr);
        note(bp);
        seqs.push_back(bp);
        #300ns;

        for (int i = 0; i < n_seeds; i++) begin
            s = axi_random_seq::type_id::create($sformatf("random_%0d", i));
            s.seed = base_seed + i;
            `uvm_info(get_type_name(),
                $sformatf("================ pass %0d, seed %0d ================",
                          i, s.seed), UVM_LOW)
            s.start(env.agent.sqr);
            note(s);
            seqs.push_back(s);
            #300ns;
        end

        #500ns;
        phase.drop_objection(this, "multi-seed random done");
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_type_name(),
            $sformatf("%0d passes, seeds %0d..%0d", seqs.size(),
                      base_seed, base_seed + n_seeds - 1), UVM_LOW)
    endfunction

endclass : axi_multiseed_test
