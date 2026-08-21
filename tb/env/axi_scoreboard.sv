//======================================================================
// axi_scoreboard.sv
//
// Reference model + comparison. Receives from the monitor's analysis
// port, which reconstructs from pins only -- so the driver's intentions
// are nowhere in this loop. That is the whole reason the monitor was
// built the way it was.
//
// The model is derived from docs/dut_spec.md, NOT from the RTL. Every
// rule below cites the section it implements. A reference model written
// by reading the RTL agrees with the RTL by construction and checks
// nothing.
//
//----------------------------------------------------------------------
// SCOPE: this models the REGISTER SLAVE, because that is the only DUT
// tb_top instantiates today. The memory model (an associative array, per
// vplan section 4) and the address decode arrive in September with the
// interconnect. Modelling a slave that receives no traffic would be
// untested code pretending to be coverage.
//
// Note that standalone, the register slave sees ADDR[11:0] and therefore
// aliases 0x1000 onto CTRL exactly as it aliases 0x100 -- routing is the
// interconnect's job. The model reproduces that deliberately.
//----------------------------------------------------------------------
// WHAT CANNOT BE PREDICTED, and why it is skipped rather than fudged:
//
//   COUNTER   increments every clock while CTRL.enable (spec section 5).
//             A transaction-level model sees transactions, not cycles,
//             so it cannot know the value. Data comparison is skipped
//             entirely; the RESPONSE is still checked.
//
//   STATUS[0] busy is 1 while a write is in flight (spec section 5) --
//             cycle-level state. Masked.
//
//   INT_STATUS[3] is set by COUNTER overflow, so it inherits COUNTER's
//             unpredictability. Bits [2:0] come from events the
//             scoreboard can see in the transaction stream and ARE
//             checked. Bit 3 is masked.
//
// Skipping is recorded per transaction and reported at check_phase, so
// "not checked" can never be mistaken for "checked and passed".
//======================================================================

localparam bit [2:0] SB_CTRL       = 3'd0;
localparam bit [2:0] SB_STATUS     = 3'd1;
localparam bit [2:0] SB_CONFIG     = 3'd2;
localparam bit [2:0] SB_INT_ENABLE = 3'd3;
localparam bit [2:0] SB_INT_STATUS = 3'd4;
localparam bit [2:0] SB_SCRATCH    = 3'd5;
localparam bit [2:0] SB_COUNTER    = 3'd6;
localparam bit [2:0] SB_ID         = 3'd7;

localparam bit [1:0] SB_OKAY   = 2'b00;
localparam bit [1:0] SB_SLVERR = 2'b10;


class axi_scoreboard extends uvm_component;

    `uvm_component_utils(axi_scoreboard)

    uvm_analysis_imp #(axi_transaction, axi_scoreboard) analysis_export;

    //------------------------------------------------------------------
    // Reference model -- spec section 5 reset values
    //------------------------------------------------------------------
    bit        m_ctrl_enable  = 1'b0;
    bit [7:0]  m_config       = 8'hFF;      // CONFIG resets to 0x0000_00FF
    bit [3:0]  m_int_enable   = 4'h0;
    bit [3:0]  m_int_status   = 4'h0;
    bit [31:0] m_scratch      = 32'h0;
    bit        m_status_error = 1'b0;

    //------------------------------------------------------------------
    int unsigned n_writes        = 0;
    int unsigned n_reads         = 0;
    int unsigned n_resp_checked  = 0;
    int unsigned n_data_checked  = 0;
    int unsigned n_data_skipped  = 0;
    int unsigned n_errors        = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_export = new("analysis_export", this);
    endfunction

    //==================================================================
    // Decode -- spec section 4 and section 5, as revised in v0.3.
    // Implemented iff ADDR[11:5] == 0; register selected by ADDR[4:2].
    //==================================================================
    function bit       is_misaligned(bit [31:0] a); return a[1:0] != 2'b00;       endfunction
    function bit       is_implemented(bit [31:0] a); return a[11:5] == 7'b0;      endfunction
    function bit [2:0] reg_index(bit [31:0] a);      return a[4:2];               endfunction

    //==================================================================
    function void write(axi_transaction t);
        if (t.kind == AXI_WRITE) begin n_writes++; check_write(t); end
        else                     begin n_reads++;  check_read(t);  end
    endfunction

    function void report_mismatch(string what, axi_transaction t,
                                  bit [31:0] got, bit [31:0] exp);
        n_errors++;
        `uvm_error("SB", $sformatf("%s mismatch on %s : got 0x%08h expected 0x%08h",
                                   what, t.convert2string(), got, exp))
    endfunction

    //==================================================================
    // Writes -- spec section 4 error precedence, strictly ordered, so
    // exactly one error applies and exactly one INT_STATUS bit is set.
    //==================================================================
    function void check_write(axi_transaction t);
        bit [1:0] exp_resp;
        bit [2:0] idx;
        bit       err_misalign, err_unimpl, err_strobe;

        err_misalign = is_misaligned(t.addr);
        err_unimpl   = !err_misalign && !is_implemented(t.addr);
        err_strobe   = !err_misalign && is_implemented(t.addr) && (t.strb != 4'b1111);

        exp_resp = (err_misalign || err_unimpl || err_strobe) ? SB_SLVERR : SB_OKAY;

        n_resp_checked++;
        if (t.resp !== exp_resp)
            report_mismatch("BRESP", t, {30'b0, t.resp}, {30'b0, exp_resp});

        // INT_STATUS event sources, spec section 5
        if      (err_misalign) m_int_status[1] = 1'b1;
        else if (err_unimpl)   m_int_status[0] = 1'b1;
        else if (err_strobe)   m_int_status[2] = 1'b1;

        // Spec section 4: no error condition modifies any state.
        if (exp_resp == SB_OKAY) begin
            idx = reg_index(t.addr);
            case (idx)
                SB_CTRL       : m_ctrl_enable = t.data[0];   // [1] self-clearing
                SB_CONFIG     : m_config      = t.data[7:0];
                SB_INT_ENABLE : m_int_enable  = t.data[3:0];
                SB_SCRATCH    : m_scratch     = t.data;
                SB_INT_STATUS : begin
                    // W1C: bit n clears iff WDATA[n] == 1 (spec section 5)
                    for (int i = 0; i < 4; i++)
                        if (t.data[i]) m_int_status[i] = 1'b0;
                end
                default : ; // STATUS, COUNTER, ID are RO -- OKAY, discarded
            endcase
        end

        // STATUS.error tracks the last completed register transaction.
        m_status_error = (exp_resp != SB_OKAY);
    endfunction

    //==================================================================
    // Reads
    //==================================================================
    function void check_read(axi_transaction t);
        bit [1:0]  exp_resp;
        bit [31:0] exp_data;
        bit [31:0] mask;              // 1 = compare this bit
        bit [2:0]  idx;
        bit        err_misalign, err_unimpl;
        bit        is_status_read;

        err_misalign = is_misaligned(t.addr);
        err_unimpl   = !err_misalign && !is_implemented(t.addr);
        exp_resp     = (err_misalign || err_unimpl) ? SB_SLVERR : SB_OKAY;

        n_resp_checked++;
        if (t.resp !== exp_resp)
            report_mismatch("RRESP", t, {30'b0, t.resp}, {30'b0, exp_resp});

        if      (err_misalign) m_int_status[1] = 1'b1;
        else if (err_unimpl)   m_int_status[0] = 1'b1;

        idx            = reg_index(t.addr);
        is_status_read = (exp_resp == SB_OKAY) && (idx == SB_STATUS);

        if (exp_resp != SB_OKAY) begin
            exp_data = 32'h0;         // spec section 4: RDATA is 0 on error
            mask     = 32'hFFFF_FFFF;
        end
        else begin
            mask = 32'hFFFF_FFFF;
            case (idx)
                SB_CTRL       : exp_data = {30'b0, 1'b0, m_ctrl_enable};
                SB_CONFIG     : exp_data = {24'b0, m_config};
                SB_INT_ENABLE : exp_data = {28'b0, m_int_enable};
                SB_SCRATCH    : exp_data = m_scratch;
                SB_ID         : exp_data = 32'hDEAD_BEEF;

                SB_STATUS     : begin
                    exp_data = {30'b0, m_status_error, 1'b0};
                    mask     = 32'hFFFF_FFFE;    // [0] busy is cycle-level
                end
                SB_INT_STATUS : begin
                    exp_data = {28'b0, m_int_status};
                    mask     = 32'hFFFF_FFF7;    // [3] follows COUNTER
                end
                SB_COUNTER    : begin
                    exp_data = 32'h0;
                    mask     = 32'h0;            // free-running: unpredictable
                end
                default : begin exp_data = 32'h0; mask = 32'h0; end
            endcase
        end

        if (mask == 32'h0) n_data_skipped++;
        else begin
            n_data_checked++;
            if ((t.rdata & mask) !== (exp_data & mask))
                report_mismatch("RDATA", t, t.rdata & mask, exp_data & mask);
        end

        // Spec section 5, clarified in v0.3: a read of STATUS is
        // transparent and does not update STATUS.error.
        if (!is_status_read)
            m_status_error = (exp_resp != SB_OKAY);
    endfunction

    //==================================================================
    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("SB", $sformatf(
            "%0d writes, %0d reads | %0d responses checked | %0d read-data checked, %0d skipped as unpredictable | %0d mismatches",
            n_writes, n_reads, n_resp_checked, n_data_checked, n_data_skipped, n_errors), UVM_LOW)
        if (n_resp_checked == 0)
            `uvm_error("SB", "scoreboard saw no transactions at all")
    endfunction

endclass : axi_scoreboard
