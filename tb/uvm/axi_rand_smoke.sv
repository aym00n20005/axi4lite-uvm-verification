//======================================================================
// axi_rand_smoke.sv
//
// Validates axi_transaction's constraints BEFORE anything depends on
// them. No DUT, no driver, no pins -- just randomisation.
//
// Constraints that quietly fail to reach a bin are invisible until
// coverage closure in October, by which point the stimulus has been
// wrong for six weeks. Checking the distribution the day the constraints
// are written is far cheaper.
//
// It is a real pass/fail test: every property the constraints promise is
// asserted on every item, and every coverage bin the plan depends on
// must be reached at least once.
//
//----------------------------------------------------------------------
// Two things here are shaped by what Xcelium rejected on 19 Aug:
//
//   1. ONE flat tally keyed "group|bin", rather than several associative
//      arrays passed to helper functions. Passing a class-member
//      associative array by `ref` is an error -- *E,BADRFA, "actual
//      argument is not a variable". Passing by value would copy the
//      array on every call. Keeping one member and never passing it
//      avoids the question.
//
//   2. Index keys are built into a local before use. Writing
//      tally[f(x)]++ warns *W,LVLFNC: ++ reads and writes the element,
//      so the index expression may be evaluated twice in unspecified
//      order. name() is pure, but the tool cannot know that.
//======================================================================

class axi_rand_smoke extends uvm_test;

    `uvm_component_utils(axi_rand_smoke)

    int unsigned N = 500;

    int unsigned tally [string];        // key: "group|bin"

    int unsigned n_misaligned = 0;
    int unsigned n_error      = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    //------------------------------------------------------------------
    // Tally helpers
    //------------------------------------------------------------------
    function void bump(string group, string bin);
        string k;
        k = {group, "|", bin};
        if (!tally.exists(k)) tally[k] = 0;
        tally[k] = tally[k] + 1;
    endfunction

    function int unsigned get_count(string group, string bin);
        string k;
        k = {group, "|", bin};
        if (tally.exists(k)) return tally[k];
        return 0;
    endfunction

    function int unsigned group_total(string group);
        string prefix;
        int unsigned total;
        prefix = {group, "|"};
        total  = 0;
        foreach (tally[k])
            if (k.len() > prefix.len() && k.substr(0, prefix.len()-1) == prefix)
                total = total + tally[k];
        return total;
    endfunction

    // Percentages are against the GROUP's own total, not N.
    //
    // The first version divided by N, so cg_aw_w_order -- which is only
    // tallied for writes -- summed to 52% and looked broken. A percentage
    // against the wrong denominator is how you talk yourself into
    // debugging a distribution that was fine.
    function void print_group(string group);
        string prefix;
        string bin;
        int unsigned total;
        prefix = {group, "|"};
        total  = group_total(group);
        `uvm_info("SMOKE", $sformatf("  %s   (n=%0d)", group, total), UVM_LOW)
        if (total == 0) return;
        foreach (tally[k]) begin
            if (k.len() > prefix.len() && k.substr(0, prefix.len()-1) == prefix) begin
                bin = k.substr(prefix.len(), k.len()-1);
                `uvm_info("SMOKE",
                          $sformatf("      %-20s %4d  (%5.1f%%)",
                                    bin, tally[k], real'(tally[k])*100.0/real'(total)),
                          UVM_LOW)
            end
        end
    endfunction

    // An empty bin is a constraint bug, found now instead of in October.
    function void require_bin(string group, string bin);
        if (get_count(group, bin) == 0)
            `uvm_error("BIN",
                       $sformatf("%s bin '%s' never reached in %0d items", group, bin, N))
    endfunction

    //------------------------------------------------------------------
    // Bin edges match cg_valid_delay / cg_backpressure in vplan section 5
    //------------------------------------------------------------------
    function string delay_bin(int unsigned d);
        if      (d == 0)  return "0";
        else if (d <= 3)  return "1-3";
        else if (d <= 10) return "4-10";
        else              return ">10";
    endfunction

    function string strb_bin(axi_transaction t);
        if (t.kind == AXI_READ) return "n/a (read)";
        if (t.strb == 4'b1111)  return "1111 (full)";
        if (t.strb == 4'b0000)  return "0000 (zero)";
        return "partial";
    endfunction

    //------------------------------------------------------------------
    // Every constraint the plan relies on, checked on every item
    //------------------------------------------------------------------
    function void check_item(axi_transaction t, int idx);

        if (!t.misaligned && t.addr[1:0] != 2'b00)
            `uvm_error("ALIGN", $sformatf("[%0d] misaligned==0 but addr=0x%08h", idx, t.addr))

        if (t.misaligned && t.addr[1:0] == 2'b00)
            `uvm_error("ALIGN", $sformatf("[%0d] misaligned==1 but addr=0x%08h", idx, t.addr))

        if (t.kind == AXI_READ && t.strb !== 4'b1111)
            `uvm_error("STRB", $sformatf("[%0d] read with strb=%04b", idx, t.strb))

        case (t.region)
            REGION_REG_IMPL:
                if (!(t.addr <= 32'h0000_001F))
                    `uvm_error("REGION", $sformatf("[%0d] REG_IMPL addr=0x%08h", idx, t.addr))
            REGION_REG_UNIMPL:
                if (!(t.addr >= 32'h0000_0020 && t.addr <= 32'h0000_0FFF))
                    `uvm_error("REGION", $sformatf("[%0d] REG_UNIMPL addr=0x%08h", idx, t.addr))
            REGION_MEM:
                if (!(t.addr >= 32'h0000_1000 && t.addr <= 32'h0000_13FF))
                    `uvm_error("REGION", $sformatf("[%0d] MEM addr=0x%08h", idx, t.addr))
            REGION_UNMAPPED_LOW:
                if (!(t.addr >= 32'h0000_1400 && t.addr <= 32'h0000_1FFF))
                    `uvm_error("REGION", $sformatf("[%0d] UNMAPPED_LOW addr=0x%08h", idx, t.addr))
            REGION_UNMAPPED_HIGH:
                if (!(t.addr >= 32'h0000_2000))
                    `uvm_error("REGION", $sformatf("[%0d] UNMAPPED_HIGH addr=0x%08h", idx, t.addr))
        endcase
    endfunction

    //------------------------------------------------------------------
    task run_phase(uvm_phase phase);
        axi_transaction t;
        string          key;

        phase.raise_objection(this, "randomisation smoke");

        `uvm_info("SMOKE", $sformatf("randomising %0d transactions", N), UVM_LOW)

        for (int i = 0; i < N; i++) begin
            t = axi_transaction::type_id::create($sformatf("t%0d", i));

            if (!t.randomize())
                `uvm_fatal("SMOKE", $sformatf("randomize() failed on item %0d", i))

            check_item(t, i);

            // Keys into locals first -- see the LVLFNC note in the header.
            key = t.region.name();  bump("cg_address_region", key);
            key = t.kind.name();    bump("kind",              key);
            key = strb_bin(t);      bump("cg_wstrb",          key);
            key = delay_bin(t.aw_delay); bump("cg_valid_delay (aw)", key);
            key = delay_bin(t.b_ready_delay); bump("cg_backpressure (b)", key);

            if (t.kind == AXI_WRITE) begin
                key = t.get_order().name();
                bump("cg_aw_w_order", key);
            end

            if (t.misaligned)      n_misaligned++;
            if (t.expects_error()) n_error++;

            if (i < 5)
                `uvm_info("SMOKE", $sformatf("  sample: %s", t.convert2string()), UVM_LOW)
        end

        `uvm_info("SMOKE", "---------------- distributions ----------------", UVM_LOW)
        print_group("kind");
        print_group("cg_address_region");
        print_group("cg_aw_w_order");
        print_group("cg_wstrb");
        print_group("cg_valid_delay (aw)");
        print_group("cg_backpressure (b)");
        `uvm_info("SMOKE", $sformatf("  misaligned           %4d  (%5.1f%%)",
                  n_misaligned, real'(n_misaligned)*100.0/real'(N)), UVM_LOW)
        `uvm_info("SMOKE", $sformatf("  expects error        %4d  (%5.1f%%)",
                  n_error, real'(n_error)*100.0/real'(N)), UVM_LOW)

        // The default weights aim at roughly a quarter error traffic, so
        // axi_random_test actually reaches the register and memory data
        // paths. Directed error tests raise the weights themselves. This
        // is a warning, not an error -- a sequence is entitled to steer
        // the distribution, and does so through the soft constraints.
        if (real'(n_error)*100.0/real'(N) > 35.0)
            `uvm_warning("DIST",
                $sformatf("error traffic is %0.1f%% of stimulus -- high for random mixed traffic",
                          real'(n_error)*100.0/real'(N)))

        //--------------------------------------------------------------
        // Every bin the verification plan depends on
        //--------------------------------------------------------------
        require_bin("cg_address_region", "REGION_REG_IMPL");
        require_bin("cg_address_region", "REGION_REG_UNIMPL");
        require_bin("cg_address_region", "REGION_MEM");
        require_bin("cg_address_region", "REGION_UNMAPPED_LOW");
        require_bin("cg_address_region", "REGION_UNMAPPED_HIGH");

        require_bin("cg_aw_w_order", "ORDER_AW_FIRST");
        require_bin("cg_aw_w_order", "ORDER_W_FIRST");
        require_bin("cg_aw_w_order", "ORDER_SAME_CYCLE");

        require_bin("cg_wstrb", "1111 (full)");
        require_bin("cg_wstrb", "0000 (zero)");
        require_bin("cg_wstrb", "partial");

        require_bin("cg_valid_delay (aw)", "0");
        require_bin("cg_valid_delay (aw)", "1-3");
        require_bin("cg_valid_delay (aw)", "4-10");
        require_bin("cg_valid_delay (aw)", ">10");

        require_bin("cg_backpressure (b)", "0");
        require_bin("cg_backpressure (b)", ">10");

        if (n_misaligned == 0)
            `uvm_error("BIN", "cg_alignment: no misaligned items generated")

        phase.drop_objection(this, "randomisation smoke done");
    endtask

endclass : axi_rand_smoke


module tb_top;
    initial run_test("axi_rand_smoke");
endmodule
