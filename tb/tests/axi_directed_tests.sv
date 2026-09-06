//======================================================================
// axi_directed_tests.sv
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
`AXI_DIRECTED_TEST(axi_reg_strobe_test,     axi_reg_strobe_seq)      // F16, F22
`AXI_DIRECTED_TEST(axi_align_test,          axi_align_seq)           // F20
`AXI_DIRECTED_TEST(axi_decode_test,         axi_decode_seq)          // F17, F18, F19
`AXI_DIRECTED_TEST(axi_error_priority_test, axi_error_priority_seq)  // F21
`AXI_DIRECTED_TEST(axi_int_status_test,     axi_int_status_seq)      // F22, F23
`AXI_DIRECTED_TEST(axi_status_test,         axi_status_seq)          // F24, F25
`AXI_DIRECTED_TEST(axi_counter_test,        axi_counter_seq)         // F26, F27
`AXI_DIRECTED_TEST(axi_backpressure_test,   axi_backpressure_seq)    // F28
`AXI_DIRECTED_TEST(axi_b2b_test,            axi_b2b_seq)             // F29, F08


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


//======================================================================
// axi_regression_test -- every directed scenario, one simulation
//
// This is the test the `sys` bundle runs, and it is the whole reason the
// scenarios were written as sequences.
//
// ORDER IS NOT ARBITRARY.
//
//   The reset sequence runs FIRST, while the DUT is still in its reset
//   state, because half of what it checks is that the reset values are
//   what spec section 5 says -- an expectation any earlier traffic
//   destroys.
//
//   The counter sequence runs LAST. It leaves the counter stopped and
//   INT_STATUS cleared, but it is also the only sequence that spends
//   655 us of simulated time, and putting it at the end means a failure
//   in any other sequence is reported before that wait rather than after
//   it.
//
//   Everything between is ordered so that a sequence which sets
//   INT_STATUS bits is followed by one that clears them first.
//======================================================================
class axi_regression_test extends axi_base_test;

    `uvm_component_utils(axi_regression_test)

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
        phase.raise_objection(this, "regression");

        run_one(axi_reset_seq         ::type_id::create("reset"),      "F09  reset");
        run_one(axi_smoke_seq         ::type_id::create("smoke"),      "F01/F02  smoke");
        run_one(axi_order_seq         ::type_id::create("order"),      "F03  AW/W ordering");
        run_one(axi_decode_seq        ::type_id::create("decode"),     "F17/F18/F19  decode");
        run_one(axi_align_seq         ::type_id::create("align"),      "F20  alignment");
        run_one(axi_wstrb_seq         ::type_id::create("wstrb"),      "F15  byte enables");
        run_one(axi_reg_strobe_seq    ::type_id::create("regstrb"),    "F16/F22  register strobe rule");
        run_one(axi_error_priority_seq::type_id::create("errprio"),    "F21  error precedence");
        run_one(axi_int_status_seq    ::type_id::create("intstat"),    "F22/F23  INT_STATUS");
        run_one(axi_status_seq        ::type_id::create("status"),     "F24/F25  STATUS");
        run_one(axi_backpressure_seq  ::type_id::create("backp"),      "F28  backpressure");
        run_one(axi_b2b_seq           ::type_id::create("b2b"),        "F29/F08  back-to-back");
        run_one(axi_mem_seq           ::type_id::create("mem"),        "F14  memory");
        run_one(axi_random_seq        ::type_id::create("random"),     "F01/F02/F14/F28  random");
        run_one(axi_counter_seq       ::type_id::create("counter"),    "F26/F27  COUNTER");

        #500ns;
        phase.drop_objection(this, "regression done");
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

endclass : axi_regression_test


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
        axi_random_seq s;
        phase.raise_objection(this, "multi-seed random");

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
