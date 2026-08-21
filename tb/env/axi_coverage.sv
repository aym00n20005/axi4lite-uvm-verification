//======================================================================
// axi_coverage.sv
//
// Functional coverage, sampled from the MONITOR's analysis port.
//
// Sampled from observation, never from stimulus. A coverage model fed by
// the sequence measures what the testbench intended; fed by the monitor
// it measures what the DUT actually experienced. When those differ --
// a driver that drops a transaction, a delay that does not take effect --
// only the second one notices.
//
// TWO parallel mechanisms, and the reason is measured, not theoretical.
//
// The covergroups below are the real artifact. They are also inert on
// EDA Playground: Xcelium requires coverage to be enabled at elaboration
// (-coverage functional), the Playground command line is fixed and does
// not pass it, and the result is not an error --
//
//   *N,COVNSM: Sampling of covergroup type "axi_coverage::cg_..." is not
//   enabled. As a result, get_inst_coverage() will return 0 coverage.
//
// -- it is a silent 0.00%. A less explicit tool would simply have shown
// zero and left us believing coverage was genuinely zero.
//
// So every bin is ALSO tallied by hand into an associative array, which
// no tool switch can disable. The two must agree wherever both are live;
// where only one is, it is the one that still produces a number.
//
// The hand tally reports MISSING bins by name, not just a percentage.
// "cg_wstrb 19%" tells you to write more tests; "cg_wstrb missing 0000,
// 0001, 0010 ..." tells you which ones.
//
// Covers the eight groups from vplan section 5 that a transaction-level
// observer can see. The remainder -- cg_valid_delay, cg_backpressure,
// cg_reset -- need per-cycle timing the monitor does not currently
// record, and are listed as outstanding rather than faked.
//======================================================================

typedef enum { ERR_NONE, ERR_UNIMPL, ERR_MISALIGN, ERR_STROBE } axi_err_src_e;


class axi_coverage extends uvm_subscriber #(axi_transaction);

    `uvm_component_utils(axi_coverage)

    // Sampled values. Computed in write() before sampling, so every
    // coverpoint is a plain variable reference.
    axi_kind_e    c_kind;
    axi_region_e  c_region;
    bit [2:0]     c_offset;
    bit           c_offset_valid;
    bit [1:0]     c_align;
    bit [3:0]     c_strb;
    bit           c_is_write;
    bit [1:0]     c_resp;
    axi_err_src_e c_err;
    axi_order_e   c_order;
    bit           c_order_valid;

    int unsigned n_sampled = 0;

    // Hand tally: key is "group|bin". Every expected bin is declared at
    // construction with a count of 0, so a bin that is never hit is
    // reported as missing rather than being absent from the report.
    int unsigned hits [string];
    string       groups [$];

    //------------------------------------------------------------------
    covergroup cg_transaction_type;
        option.per_instance = 1;
        type_cp : coverpoint c_kind;
    endgroup

    covergroup cg_address_region;
        option.per_instance = 1;
        region_cp : coverpoint c_region;
    endgroup

    // Only meaningful for an implemented offset; `iff` keeps unimplemented
    // and unmapped traffic from landing in a register bin.
    covergroup cg_register_offset;
        option.per_instance = 1;
        offset_cp : coverpoint c_offset iff (c_offset_valid) {
            bins ctrl       = {3'd0};
            bins status     = {3'd1};
            bins config_reg = {3'd2};
            bins int_enable = {3'd3};
            bins int_status = {3'd4};
            bins scratch    = {3'd5};
            bins counter    = {3'd6};
            bins id         = {3'd7};
        }
    endgroup

    covergroup cg_alignment;
        option.per_instance = 1;
        align_cp : coverpoint c_align {
            bins aligned     = {2'b00};
            bins offset_by_1 = {2'b01};
            bins offset_by_2 = {2'b10};
            bins offset_by_3 = {2'b11};
        }
    endgroup

    // All sixteen patterns, writes only. Spec section 5 makes anything
    // other than 4'b1111 an error on the register slave, so several bins
    // are only reachable as error stimulus -- which is the point.
    covergroup cg_wstrb;
        option.per_instance = 1;
        strb_cp : coverpoint c_strb iff (c_is_write);
    endgroup

    covergroup cg_response;
        option.per_instance = 1;
        resp_cp : coverpoint c_resp {
            bins okay   = {2'b00};
            bins slverr = {2'b10};
            bins decerr = {2'b11};
        }
    endgroup

    covergroup cg_error_source;
        option.per_instance = 1;
        err_cp : coverpoint c_err;
    endgroup

    // Observed on the bus, not requested by the sequence.
    covergroup cg_aw_w_order;
        option.per_instance = 1;
        order_cp : coverpoint c_order iff (c_order_valid);
    endgroup

    //------------------------------------------------------------------
    // Crosses, vplan section 5
    //------------------------------------------------------------------
    covergroup cg_type_x_region;
        option.per_instance = 1;
        t  : coverpoint c_kind;
        r  : coverpoint c_region;
        tr : cross t, r;
    endgroup

    covergroup cg_wstrb_x_align;
        option.per_instance = 1;
        s  : coverpoint c_strb iff (c_is_write);
        a  : coverpoint c_align;
        sa : cross s, a;
    endgroup

    covergroup cg_type_x_response;
        option.per_instance = 1;
        t  : coverpoint c_kind;
        p  : coverpoint c_resp { bins okay = {2'b00}; bins slverr = {2'b10}; bins decerr = {2'b11}; }
        tp : cross t, p;
    endgroup

    //------------------------------------------------------------------
    //------------------------------------------------------------------
    // Hand-tally plumbing
    //------------------------------------------------------------------
    function void declare_group(string g);
        groups.push_back(g);
    endfunction

    function void declare_bin(string g, string b);
        string k;
        k = {g, "|", b};
        if (!hits.exists(k)) hits[k] = 0;
    endfunction

    function void hit(string g, string b);
        string k;
        k = {g, "|", b};
        if (!hits.exists(k)) hits[k] = 0;   // an undeclared bin still counts
        hits[k] = hits[k] + 1;
    endfunction

    function void declare_all();
        string nm;

        declare_group("cg_transaction_type");
        declare_bin("cg_transaction_type", "AXI_READ");
        declare_bin("cg_transaction_type", "AXI_WRITE");

        declare_group("cg_address_region");
        declare_bin("cg_address_region", "REGION_REG_IMPL");
        declare_bin("cg_address_region", "REGION_REG_UNIMPL");
        declare_bin("cg_address_region", "REGION_MEM");
        declare_bin("cg_address_region", "REGION_UNMAPPED_LOW");
        declare_bin("cg_address_region", "REGION_UNMAPPED_HIGH");

        declare_group("cg_register_offset");
        declare_bin("cg_register_offset", "CTRL");
        declare_bin("cg_register_offset", "STATUS");
        declare_bin("cg_register_offset", "CONFIG");
        declare_bin("cg_register_offset", "INT_ENABLE");
        declare_bin("cg_register_offset", "INT_STATUS");
        declare_bin("cg_register_offset", "SCRATCH");
        declare_bin("cg_register_offset", "COUNTER");
        declare_bin("cg_register_offset", "ID");

        declare_group("cg_alignment");
        declare_bin("cg_alignment", "aligned");
        declare_bin("cg_alignment", "offset_1");
        declare_bin("cg_alignment", "offset_2");
        declare_bin("cg_alignment", "offset_3");

        // All sixteen patterns, per vplan section 5.
        declare_group("cg_wstrb");
        for (int i = 0; i < 16; i++) begin
            nm = $sformatf("%04b", i[3:0]);
            declare_bin("cg_wstrb", nm);
        end

        declare_group("cg_response");
        declare_bin("cg_response", "OKAY");
        declare_bin("cg_response", "SLVERR");
        declare_bin("cg_response", "DECERR");

        declare_group("cg_error_source");
        declare_bin("cg_error_source", "ERR_NONE");
        declare_bin("cg_error_source", "ERR_UNIMPL");
        declare_bin("cg_error_source", "ERR_MISALIGN");
        declare_bin("cg_error_source", "ERR_STROBE");

        declare_group("cg_aw_w_order");
        declare_bin("cg_aw_w_order", "ORDER_AW_FIRST");
        declare_bin("cg_aw_w_order", "ORDER_W_FIRST");
        declare_bin("cg_aw_w_order", "ORDER_SAME_CYCLE");
    endfunction

    function new(string name, uvm_component parent);
        super.new(name, parent);
        declare_all();
        cg_transaction_type = new();
        cg_address_region   = new();
        cg_register_offset  = new();
        cg_alignment        = new();
        cg_wstrb            = new();
        cg_response         = new();
        cg_error_source     = new();
        cg_aw_w_order       = new();
        cg_type_x_region    = new();
        cg_wstrb_x_align    = new();
        cg_type_x_response  = new();
    endfunction

    //------------------------------------------------------------------
    // Region decode, spec section 4. Derived from the observed address so
    // it stays true when the interconnect arrives.
    //------------------------------------------------------------------
    function axi_region_e region_of(bit [31:0] a);
        if (a <= 32'h0000_001F) return REGION_REG_IMPL;
        if (a <= 32'h0000_0FFF) return REGION_REG_UNIMPL;
        if (a <= 32'h0000_13FF) return REGION_MEM;
        if (a <= 32'h0000_1FFF) return REGION_UNMAPPED_LOW;
        return REGION_UNMAPPED_HIGH;
    endfunction

    // Spec section 4 precedence, strictly ordered.
    function axi_err_src_e err_of(axi_transaction t);
        if (t.addr[1:0] != 2'b00)                            return ERR_MISALIGN;
        if (t.addr[11:5] != 7'b0)                            return ERR_UNIMPL;
        if (t.kind == AXI_WRITE && t.strb != 4'b1111)        return ERR_STROBE;
        return ERR_NONE;
    endfunction

    function void write(axi_transaction t);
        c_kind         = t.kind;
        c_region       = region_of(t.addr);
        c_offset       = t.addr[4:2];
        c_offset_valid = (c_region == REGION_REG_IMPL) && (t.addr[1:0] == 2'b00);
        c_align        = t.addr[1:0];
        c_strb         = t.strb;
        c_is_write     = (t.kind == AXI_WRITE);
        c_resp         = t.resp;
        c_err          = err_of(t);
        c_order        = t.obs_order;
        c_order_valid  = t.obs_order_valid;

        cg_transaction_type.sample();
        cg_address_region  .sample();
        cg_register_offset .sample();
        cg_alignment       .sample();
        cg_wstrb           .sample();
        cg_response        .sample();
        cg_error_source    .sample();
        cg_aw_w_order      .sample();
        cg_type_x_region   .sample();
        cg_wstrb_x_align   .sample();
        cg_type_x_response .sample();

        // ...and the tally, which no tool switch can disable.
        hit("cg_transaction_type", c_kind.name());
        hit("cg_address_region",   c_region.name());
        hit("cg_response",         (c_resp == 2'b00) ? "OKAY" :
                                   (c_resp == 2'b10) ? "SLVERR" : "DECERR");
        hit("cg_error_source",     c_err.name());
        hit("cg_alignment",        (c_align == 2'b00) ? "aligned" :
                                   (c_align == 2'b01) ? "offset_1" :
                                   (c_align == 2'b10) ? "offset_2" : "offset_3");
        if (c_offset_valid)
            hit("cg_register_offset",
                (c_offset == 3'd0) ? "CTRL"       : (c_offset == 3'd1) ? "STATUS"     :
                (c_offset == 3'd2) ? "CONFIG"     : (c_offset == 3'd3) ? "INT_ENABLE" :
                (c_offset == 3'd4) ? "INT_STATUS" : (c_offset == 3'd5) ? "SCRATCH"    :
                (c_offset == 3'd6) ? "COUNTER"    : "ID");
        if (c_is_write)
            hit("cg_wstrb", $sformatf("%04b", c_strb));
        if (c_order_valid)
            hit("cg_aw_w_order", c_order.name());

        n_sampled++;
    endfunction

    //------------------------------------------------------------------
    function void report_line(string name, real pct, string goal);
        `uvm_info("COV", $sformatf("    %-22s %6.2f%%   goal %s", name, pct, goal), UVM_LOW)
    endfunction

    //------------------------------------------------------------------
    // Hand-tally report. Names the MISSING bins, because a percentage
    // says how far there is to go and a bin name says what to write.
    //------------------------------------------------------------------
    function void report_tally();
        string prefix, bin, missing;
        int unsigned total, covered;

        `uvm_info("COV", "---- bin tally (independent of tool coverage) ----", UVM_LOW)
        foreach (groups[i]) begin
            prefix  = {groups[i], "|"};
            total   = 0;
            covered = 0;
            missing = "";
            foreach (hits[k]) begin
                if (k.len() > prefix.len() && k.substr(0, prefix.len()-1) == prefix) begin
                    total++;
                    if (hits[k] > 0) covered++;
                    else begin
                        bin     = k.substr(prefix.len(), k.len()-1);
                        missing = (missing == "") ? bin : {missing, " ", bin};
                    end
                end
            end
            `uvm_info("COV", $sformatf("    %-22s %2d/%2d  %6.2f%%",
                      groups[i], covered, total,
                      (total == 0) ? 0.0 : real'(covered)*100.0/real'(total)), UVM_LOW)
            if (missing != "")
                `uvm_info("COV", $sformatf("        missing: %s", missing), UVM_LOW)
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COV", $sformatf("functional coverage over %0d observed transactions", n_sampled), UVM_LOW)
        report_line("cg_transaction_type", cg_transaction_type.get_inst_coverage(), "100%");
        report_line("cg_address_region",   cg_address_region  .get_inst_coverage(), "100%");
        report_line("cg_register_offset",  cg_register_offset .get_inst_coverage(), "100%");
        report_line("cg_alignment",        cg_alignment       .get_inst_coverage(), "100%");
        report_line("cg_wstrb",            cg_wstrb           .get_inst_coverage(), ">=90%");
        report_line("cg_response",         cg_response        .get_inst_coverage(), "100%");
        report_line("cg_error_source",     cg_error_source    .get_inst_coverage(), "100%");
        report_line("cg_aw_w_order",       cg_aw_w_order      .get_inst_coverage(), "100%");
        report_line("cross type x region", cg_type_x_region   .get_inst_coverage(), "100%");
        report_line("cross wstrb x align", cg_wstrb_x_align   .get_inst_coverage(), "100%");
        report_line("cross type x resp",   cg_type_x_response .get_inst_coverage(), "100%");
        `uvm_info("COV",
            "the percentages above are 0.00 unless the simulator was invoked with coverage enabled (Xcelium: -coverage functional). The tally below does not depend on that.",
            UVM_LOW)
        report_tally();
        `uvm_info("COV",
            "not modelled here: cg_valid_delay, cg_backpressure, cg_reset -- these need per-cycle timing the monitor does not record",
            UVM_LOW)
    endfunction

endclass : axi_coverage
