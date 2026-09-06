//======================================================================
// axi4lite_reg_slave_formal.svh
//
// Bounded model check of the register slave's safety properties.
// Included INSIDE axi4lite_reg_slave under `ifdef FORMAL, and compiled
// out everywhere else.
//
//   make formal
//
//----------------------------------------------------------------------
// WHY THIS EXISTS
//
// Two of the rules below cannot be proved any other way, and they are
// the reason the formal milestone was worth keeping rather than quietly
// dropping.
//
//   Spec section 5, INT_STATUS: "if an event sets bit n on the same
//   cycle a write would clear it, SET WINS. The event is real and must
//   not be lost."
//
//   Spec section 5, COUNTER: "reset_stats clears COUNTER WITH PRIORITY
//   over increment. If enable and reset_stats both apply on the same
//   cycle, the result is 0."
//
// Both are SAME-CYCLE rules. tb/sequences/axi_directed_seqs.sv says so
// and declines to claim them: a transaction-level sequence sees
// transactions, not clock edges, and cannot place two events on one
// edge on purpose. axi_int_status_seq proves the reachable half -- an
// event after a clear is not lost -- and leaves the collision here.
//
// A bounded model check does not have to CONSTRUCT the collision. It
// searches every reachable state within N cycles for one that violates
// the rule, and returns a counter_q-example if it finds one.
//
//----------------------------------------------------------------------
// WHY IT IS AN INCLUDE INSIDE THE DUT AND NOT A BOUND WRAPPER
//
// Because Yosys cannot read a wrapper. Each of these was tried:
//
//   a separate module with `dut.int_status_q`
//       ERROR: Identifier `\dut.int_status_q' is implicitly declared
//       -- the frontend does not resolve hierarchical references
//   bind ... : the frontend has no `bind` support either
//
// So the properties live where the state lives, guarded by `ifdef
// FORMAL. Verilator, slang and Xcelium never define it, so nothing they
// compile changes by one gate.
//
//----------------------------------------------------------------------
// WHAT YOSYS ACCEPTS, MEASURED
//
// Yosys's open-source frontend supports NO CONCURRENT SVA AT ALL. Every
// form below was tried and rejected:
//
//   default clocking @(posedge ACLK); endclocking
//                                     ERROR: unexpected TOK_DEFAULT
//   assert property (@(posedge ACLK) disable iff (!rst) a |=> b);
//                                     ERROR: unexpected '@'
//   assert (a |=> b);                 ERROR: unexpected TOK_BIT_OR_ASSIGN
//   property pr; ... endproperty      ERROR: unexpected TOK_PROPERTY
//   import pkg::*;  (inside a module) ERROR: unexpected TOK_IMPORT
//
// What it does accept in -formal mode is the IMMEDIATE assertion inside
// a clocked always block, plus $past. So every property here is written
// as `assert (consequent)` guarded by the antecedent held for one cycle
// in an explicit history register, rather than by an implication
// operator.
//
// This is why tb/interface/axi4lite_if.sv is NOT reused here. Its 23
// assertions are concurrent properties with ##[0:8] windows and
// $stable, none of which Yosys can read, and rewriting all of them in
// this subset would be a second checker to keep correct. The rules
// below are the ones worth the duplication: the ones no simulation can
// decide, and the ones a proof states more strongly than a run can.
//
// The full list of rejections is docs/formal_notes.md, and that half is
// a finding in the same register as "Riviera compiles UVM and cannot
// simulate it".
//
//----------------------------------------------------------------------
// SCOPE. Safety rules about this slave's internal state, proved over a
// bounded window. This is not a proof of the design. It is a proof of
// the rules that are hardest to reach from the bus.
//======================================================================

    //==================================================================
    // History. Where a concurrent property would have written |=>, this
    // holds the antecedent for one cycle so an immediate assertion can
    // check the consequent against it.
    //
    // Explicit registers rather than $past() throughout: $past works in
    // Yosys but reads badly when the antecedent is a three-term
    // expression, and a named register makes a counter-example trace
    // legible.
    //==================================================================
    // INITIAL VALUES, and an assumption that the first cycle is in
    // reset.
    //
    // Formal starts in an ARBITRARY state, not a reset one. Without
    // these two lines the solver begins with past_valid already 1 and
    // the history registers holding whatever it likes, then reports
    // counter-examples at step 0 in which a register "changed" from a
    // value it never held. Four of the six properties failed exactly
    // that way on the first run, and not one of the failures was about
    // the design.
    //
    // f_init is a separate register from past_valid because past_valid
    // is cleared BY reset -- using it to constrain reset would be
    // circular.
    reg        f_init     = 1'b0;
    reg        past_valid = 1'b0;
    reg [3:0]  int_set_q, int_status_prev;
    reg        w1c_write_q;
    reg [31:0] wr_data_q;
    reg        rst_pulse_q, ctrl_en_q;
    reg [15:0] counter_prev;
    reg        reg_write_q;
    reg [2:0]  wr_idx_q;
    reg [7:0]  config_prev;
    reg [3:0]  int_en_prev;
    reg [31:0] scratch_prev;

    // The register slave has no read-address latch: ARREADY is gated on
    // !rvalid_q, so the response is computed straight from ARADDR on the
    // accept cycle. rd_idx therefore follows the CURRENT ARADDR, not the
    // address of the read whose data is sitting in rdata_q. A property
    // about RDATA needs its own capture, or it correlates this cycle's
    // address with a previous cycle's data -- which is why
    // f_config_reserved failed on the first run.
    reg [2:0]  rd_idx_at_accept;

    always @(posedge ACLK) f_init <= 1'b1;

    always @(posedge ACLK) if (ar_hs) rd_idx_at_accept <= rd_idx;

    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            past_valid <= 1'b0;
        end else begin
            past_valid      <= 1'b1;
            int_set_q       <= int_set;
            int_status_prev <= int_status_q;
            w1c_write_q     <= w1c_write;
            wr_data_q       <= wr_data;
            rst_pulse_q     <= reset_stats_pulse;
            ctrl_en_q       <= ctrl_enable;
            counter_prev    <= counter_q;
            reg_write_q     <= reg_write;
            wr_idx_q        <= wr_idx;
            config_prev     <= config_q;
            int_en_prev     <= int_enable_q;
            scratch_prev    <= scratch_q;
        end
    end

    //==================================================================
    // The properties. All guarded by ARESETn and by past_valid, so none
    // of them fires on the first cycle out of reset, where the history
    // registers hold nothing.
    //==================================================================
    always @(posedge ACLK) begin
        // Start in reset, so every state the proof explores is one the
        // design can actually reach.
        if (!f_init) assume (!ARESETn);

        if (ARESETn && past_valid) begin

            //----------------------------------------------------------
            // 1. SET BEATS A SIMULTANEOUS CLEAR.  Spec section 5.
            //
            // THE PROPERTY THIS FILE EXISTS FOR. If an event asserted
            // last cycle, the bit is set this cycle -- whatever the
            // write on that same cycle was trying to do to it. Losing
            // the event loses an interrupt.
            //
            // Four separate assertions rather than a loop, so a
            // counter_q-example names the bit, and because the four bits
            // have four different event sources.
            //----------------------------------------------------------
            f_set_beats_clear_0 : assert (!int_set_q[0] || int_status_q[0]);
            f_set_beats_clear_1 : assert (!int_set_q[1] || int_status_q[1]);
            f_set_beats_clear_2 : assert (!int_set_q[2] || int_status_q[2]);
            f_set_beats_clear_3 : assert (!int_set_q[3] || int_status_q[3]);

            //----------------------------------------------------------
            // 2. W1C CLEARS ONLY WHERE WDATA IS 1.  Spec section 5.
            //
            // The other half of the rule. The spec's own example:
            // "INT_STATUS is 4'b1011, software writes 4'b0011 -> result
            // 4'b1000". This is that example generalised over every
            // reachable value rather than checked at one.
            //----------------------------------------------------------
            f_w1c_keeps_0 : assert (!(int_status_prev[0] && !int_set_q[0] &&
                                      !(w1c_write_q && wr_data_q[0])) || int_status_q[0]);
            f_w1c_keeps_1 : assert (!(int_status_prev[1] && !int_set_q[1] &&
                                      !(w1c_write_q && wr_data_q[1])) || int_status_q[1]);
            f_w1c_keeps_2 : assert (!(int_status_prev[2] && !int_set_q[2] &&
                                      !(w1c_write_q && wr_data_q[2])) || int_status_q[2]);
            f_w1c_keeps_3 : assert (!(int_status_prev[3] && !int_set_q[3] &&
                                      !(w1c_write_q && wr_data_q[3])) || int_status_q[3]);

            // ...and a bit that was clear, with no event, stays clear.
            // Without this, a register that sets bits spontaneously
            // would satisfy everything above.
            f_w1c_no_spurious_set : assert (
                ((~int_status_prev) & (~int_set_q) & int_status_q) == 4'b0);

            //----------------------------------------------------------
            // 3. reset_stats HAS PRIORITY OVER INCREMENT.  Spec section 5.
            //
            // The second same-cycle rule, and the second one no
            // transaction-level test can decide. axi_counter_seq can
            // only check that enable survived the write, because after
            // it the counter_q is running again and its value is
            // unpredictable by construction.
            //----------------------------------------------------------
            f_reset_stats_wins : assert (!rst_pulse_q || (counter_q == 16'h0));

            // The counter_q does not move on its own.
            f_counter_holds : assert (rst_pulse_q || ctrl_en_q ||
                                      (counter_q == counter_prev));

            // And when it does move, it moves by exactly one.
            f_counter_steps_by_one : assert (rst_pulse_q || !ctrl_en_q ||
                                             (counter_q == counter_prev + 16'd1));

            //----------------------------------------------------------
            // 4. RO REGISTERS ARE READ-ONLY.  Spec section 5.
            //
            // Writes to STATUS, COUNTER and ID are "accepted with OKAY,
            // data discarded, no state change". COUNTER is not in the
            // consequent -- it is read-only to the BUS and written by
            // hardware every cycle, which is the difference between
            // "read-only" and "constant" and the reason the RAL marks it
            // volatile.
            //----------------------------------------------------------
            f_ro_write_no_effect : assert (
                !(reg_write_q && (wr_idx_q == 3'd1 || wr_idx_q == 3'd6 || wr_idx_q == 3'd7))
                || ((config_q == config_prev) && (int_enable_q == int_en_prev)
                    && (scratch_q == scratch_prev)));

            //----------------------------------------------------------
            // 5. RESERVED BITS CANNOT STORE DATA.  Spec section 5, F13.
            //
            // Structural today -- the flops are declared at implemented
            // width, so a reserved bit has nothing behind it. Asserted
            // anyway, because "structurally impossible" is a statement
            // about this version of the code and this is a check on
            // every future one.
            //----------------------------------------------------------
            f_config_reserved : assert ((RDATA & 32'hFFFF_FF00) == 32'h0
                                        || !(RVALID && rd_idx_at_accept == R_CONFIG));
            f_int_en_reserved : assert ((RDATA & 32'hFFFF_FFF0) == 32'h0
                                        || !(RVALID && rd_idx_at_accept == R_INT_ENABLE));
            f_ctrl_reserved   : assert ((RDATA & 32'hFFFF_FFFC) == 32'h0
                                        || !(RVALID && rd_idx_at_accept == R_CTRL));

            // CTRL[1] is a command bit and reads 0 unconditionally --
            // spec section 5, clarified in v0.3. Not a reserved bit, but
            // the same claim about a read: it never returns 1.
            f_reset_stats_reads_0 : assert ((RDATA & 32'h2) == 32'h0
                                            || !(RVALID && rd_idx_at_accept == R_CTRL));

            //----------------------------------------------------------
            // 6. NO WRITE RESPONSE BEFORE BOTH HALVES.  Spec section 3
            //    rule 5.
            //
            // Also covered by the bound checker in simulation. Repeated
            // here because a proof says something much stronger about
            // it: simulation says "the stimulus we ran never violated
            // this", a bounded model check says "no reachable state
            // within N cycles violates it".
            //
            // BUG-002 is the injection this catches.
            //----------------------------------------------------------
            f_bvalid_needs_both : assert (!BVALID || $past(do_write) ||
                                          $past(BVALID));
        end
    end

    //==================================================================
    // Cover, so the proof is not vacuous.
    //
    // An assertion that is never reached passes trivially, and a set of
    // them can all pass on a design that does nothing at all. These say
    // the interesting states ARE reachable within the bound -- if a
    // cover fails, the proof above it proved nothing.
    //==================================================================
    always @(posedge ACLK) begin
        if (ARESETn && past_valid) begin
            // The collision itself: an event and a W1C write to the same
            // bit on the same cycle. If this is unreachable, property 1
            // is vacuous and the whole file is decoration.
            fc_collision : cover (int_set[0] && w1c_write && wr_data[0]);
            fc_set       : cover (|int_set);
            fc_w1c       : cover (w1c_write && |wr_data[3:0]);
            fc_rst_pulse : cover (reset_stats_pulse);
            fc_counting  : cover (ctrl_enable && counter_q != 16'h0);
            fc_bvalid    : cover (BVALID);
        end
    end
