//======================================================================
// axi_smoke_seq.sv
//
// Deliberately mirrors sanity_tb.sv, so a failure here can be compared
// against a bench known to pass on the same RTL. When the UVM
// environment first touches pins, "is it the DUT or is it me?" is the
// only question worth being able to answer quickly.
//
// In its own file because EDA Playground caps a pane at 100,000
// characters and the environment is split across four bundles to fit --
// see axi_proto_seqs.sv. Two of the four need this sequence.
//
// NOT independently compilable -- see tb/agent/axi_transaction.sv.
//======================================================================

//======================================================================
class axi_smoke_seq extends axi_base_seq;

    `uvm_object_utils(axi_smoke_seq)

    function new(string name = "axi_smoke_seq");
        super.new(name);
    endfunction

    task body();
        bit [31:0] d;
        bit [1:0]  r;

        `uvm_info("SMOKE", "---- constants and reset values (spec section 5) ----", UVM_LOW)
        read(`A_ID, d, r);
        check("ID reads 0xDEADBEEF",        d, 32'hDEAD_BEEF);
        check("ID response OKAY",  {30'b0, r}, 32'h0);

        read(`A_CONFIG, d, r);
        check("CONFIG reset 0x000000FF",    d, 32'h0000_00FF);

        `uvm_info("SMOKE", "---- write / readback, AW and W same cycle ----", UVM_LOW)
        write(`A_SCRATCH, 32'hDEAD_C0DE, 4'b1111, r, 0, 0);
        check("SCRATCH write OKAY", {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("SCRATCH reads back",         d, 32'hDEAD_C0DE);

        // The ordering a lockstep driver can never produce. If the two
        // fork threads are genuinely independent, this works and
        // c_w_before_aw is covered; if they are not, it deadlocks.
        `uvm_info("SMOKE", "---- W accepted 4 cycles BEFORE AW (F03) ----", UVM_LOW)
        write(`A_SCRATCH, 32'h1234_5678, 4'b1111, r, 4, 0);
        check("W-before-AW OKAY",   {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("W-before-AW landed",         d, 32'h1234_5678);

        `uvm_info("SMOKE", "---- AW accepted 4 cycles BEFORE W (F03) ----", UVM_LOW)
        write(`A_SCRATCH, 32'h0F0F_0F0F, 4'b1111, r, 0, 4);
        check("AW-before-W OKAY",   {30'b0, r}, 32'h0);
        read(`A_SCRATCH, d, r);
        check("AW-before-W landed",         d, 32'h0F0F_0F0F);

        `uvm_info("SMOKE", "---- reserved bits read 0 (F13) ----", UVM_LOW)
        write(`A_CONFIG, 32'hFFFF_FFFF, 4'b1111, r, 0, 0);
        read(`A_CONFIG, d, r);
        check("CONFIG masks to 0x000000FF", d, 32'h0000_00FF);

        `uvm_info("SMOKE", "---- partial-strobe register write (F16) ----", UVM_LOW)
        write(`A_SCRATCH, 32'hAAAA_AAAA, 4'b0011, r, 0, 0);
        check("partial strobe SLVERR", {30'b0, r}, 32'h2);
        read(`A_SCRATCH, d, r);
        check("register unchanged",         d, 32'h0F0F_0F0F);
        read(`A_INT_STATUS, d, r);
        check("INT_STATUS[2] set",          d, 32'h0000_0004);

        `uvm_info("SMOKE", "---- unimplemented offset 0x100 (F19) ----", UVM_LOW)
        write(32'h0000_0100, 32'hFFFF_FFFF, 4'b1111, r, 0, 0);
        check("offset 0x100 SLVERR",  {30'b0, r}, 32'h2);
        read(`A_CTRL, d, r);
        check("CTRL not aliased",           d, 32'h0000_0000);

        `uvm_info("SMOKE", "---- misaligned access (F20) ----", UVM_LOW)
        read(32'h0000_0006, d, r);
        check("misaligned read SLVERR", {30'b0, r}, 32'h2);
        check("RDATA zeroed on error",      d, 32'h0000_0000);

        //--------------------------------------------------------------
        // STATUS.error, and the v0.3 transparency rule (decision D1).
        //
        // Spec section 5 as clarified in v0.3: error is set by the last
        // completed register transaction, and a read of STATUS is
        // TRANSPARENT -- it does not update the bit. That clarification
        // was made by this project on 14 Aug to resolve a contradiction
        // in v0.2, has been implemented in RTL and in the scoreboard
        // since, and until now nothing has ever exercised it.
        //
        // The misaligned read above left error set. Only bit [1] is
        // checked: STATUS[0] is busy, which is cycle-level state.
        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- STATUS.error transparency (F25, spec v0.3 D1) ----", UVM_LOW)

        read(`A_STATUS, d, r);
        check("STATUS.error set after SLVERR", d & 32'h2, 32'h2);

        // The whole point of D1: reading it again must NOT have cleared it.
        // Under the literal v0.2 wording the first read would have cleared
        // the bit and this would return 0.
        read(`A_STATUS, d, r);
        check("STATUS read is transparent",    d & 32'h2, 32'h2);

        // Any other transaction completing with OKAY does clear it.
        write(`A_SCRATCH, 32'h5A5A_5A5A, 4'b1111, r, 0, 0);
        read(`A_STATUS, d, r);
        check("STATUS.error cleared by OKAY",  d & 32'h2, 32'h0);

        //--------------------------------------------------------------
        // COUNTER is free-running, so the scoreboard cannot predict its
        // value and skips the data comparison. Reading it here is what
        // exercises that skip path -- otherwise the mask logic is code
        // no test has ever executed. The RESPONSE is still checked.
        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- COUNTER read: response checked, data unpredictable ----", UVM_LOW)

        // Enable it first. Read with enable clear and COUNTER returns 0,
        // which is trivially predictable -- the skip would execute while
        // proving nothing. Spec section 5: COUNTER increments every clock
        // while CTRL.enable, so once running its value depends on cycles
        // the scoreboard cannot see.
        write(`A_CTRL, 32'h0000_0001, 4'b1111, r, 0, 0);
        check("CTRL enable write OKAY", {30'b0, r}, 32'h0);

        // CTRL[1] reset_stats always reads 0 (spec section 5, v0.3 D2),
        // so a CTRL read after enabling returns exactly 1.
        read(`A_CTRL, d, r);
        check("CTRL reads enable=1, reset_stats=0", d, 32'h0000_0001);

        read(`A_COUNTER, d, r);
        check("COUNTER read OKAY",      {30'b0, r}, 32'h0);
        `uvm_info("SMOKE",
                  $sformatf("  COUNTER read 0x%08h -- nonzero and cycle-dependent; scoreboard skips it", d),
                  UVM_LOW)

        //--------------------------------------------------------------
        // Coverage closure for the bins a directed test can reach.
        //
        // Added 21 Aug after the first real coverage measurement showed
        // cg_wstrb at 2/16, cg_alignment at 2/4 and cg_register_offset at
        // 7/8. None of those were design gaps -- they were transactions
        // nobody had written. The measurement is what turned them from
        // invisible into a work item.
        //
        // In September these become axi_wstrb_test and axi_align_test as
        // the verification plan's test list lays them out; one sequence
        // is right while there is one test.
        //--------------------------------------------------------------
        // F26, and the section 9 obligation BUG-006 sits on.
        //
        // COUNTER is free-running and normally unpredictable. In ONE
        // state it is not: after reset_stats with enable clear it is 0
        // and frozen, so every read must return exactly 0. That is the
        // only window in which this bug is visible, and it is why spec
        // section 9 assigns BUG-006 to a directed test.
        //
        // The scoreboard now models the same window, so the bug is caught
        // twice over -- by the check below and by the reference model.
        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- reset_stats clears COUNTER (F26, BUG-006) ----", UVM_LOW)

        // enable is still 1 from the section above, so the counter has
        // been running. Clear it AND stop it in one write: reset_stats
        // has priority over increment (spec section 5).
        write(`A_CTRL, 32'h0000_0002, 4'b1111, r, 0, 0);
        check("CTRL reset_stats write OKAY", {30'b0, r}, 32'h0);

        read(`A_COUNTER, d, r);
        check("reset_stats cleared COUNTER",      d, 32'h0000_0000);

        // Still 0 several transactions later: enable is clear, so it is
        // frozen rather than merely passing through zero.
        //
        // Note what the failure looks like -- the CTRL=0x2 write clears
        // enable too, so a COUNTER that reset_stats failed to clear
        // freezes at its old value rather than climbing. Measured under
        // BUG-006 on 27 Aug: 0x15 on both reads, not a rising count.
        read(`A_SCRATCH, d, r);
        read(`A_COUNTER, d, r);
        check("COUNTER frozen while disabled",    d, 32'h0000_0000);

        // enable and reset_stats together: result is 0 on that cycle, and
        // enable survives (spec section 5 -- the two bits are
        // independently testable).
        write(`A_CTRL, 32'h0000_0003, 4'b1111, r, 0, 0);
        read(`A_CTRL, d, r);
        check("reset_stats did not disturb enable", d, 32'h0000_0001);

        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- WSTRB sweep, all 16 patterns (F16, cg_wstrb) ----", UVM_LOW)

        // Spec section 5: only 4'b1111 is a legal register write. The
        // other fifteen must every one return SLVERR and change nothing,
        // which is fifteen checks of the same rule from fifteen angles.
        for (int unsigned i = 0; i < 16; i++) begin
            bit [3:0] sweep_strb = i[3:0];
            write(`A_SCRATCH, 32'hC0DE_0000 | i, sweep_strb, r, 0, 0);
            if (sweep_strb == 4'b1111)
                check($sformatf("WSTRB=%04b OKAY", sweep_strb),   {30'b0, r}, 32'h0);
            else
                check($sformatf("WSTRB=%04b SLVERR", sweep_strb), {30'b0, r}, 32'h2);
        end

        // 4'b1111 is the last pattern swept, so it is the one that landed.
        read(`A_SCRATCH, d, r);
        check("only the full-strobe write took effect", d, 32'hC0DE_000F);

        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- remaining alignment offsets (F20, cg_alignment) ----", UVM_LOW)

        // The misaligned read above used offset 2. Offsets 1 and 3 are
        // the same rule at different byte positions.
        read(32'h0000_0005, d, r);
        check("addr offset 1 -> SLVERR", {30'b0, r}, 32'h2);
        read(32'h0000_0007, d, r);
        check("addr offset 3 -> SLVERR", {30'b0, r}, 32'h2);

        //--------------------------------------------------------------
        `uvm_info("SMOKE", "---- INT_ENABLE, the last untouched register ----", UVM_LOW)

        // Implemented bits [3:0] (spec section 5), so the upper bits are
        // reserved and must read 0 -- F13 again, on the one register no
        // test had ever addressed.
        write(`A_INT_ENABLE, 32'hFFFF_FFFF, 4'b1111, r, 0, 0);
        check("INT_ENABLE write OKAY", {30'b0, r}, 32'h0);
        read(`A_INT_ENABLE, d, r);
        check("INT_ENABLE masks to 0xF", d, 32'h0000_000F);

        if (errors == 0)
            `uvm_info("SMOKE", $sformatf("all %0d checks passed", checks), UVM_LOW)
        else
            `uvm_error("SMOKE", $sformatf("%0d of %0d checks FAILED", errors, checks))
    endtask

endclass : axi_smoke_seq
