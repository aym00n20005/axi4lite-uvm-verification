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
// SCOPE: three modes, chosen by the slave_kind config.
//
//   SLAVE_REG   the register slave alone, driven directly
//   SLAVE_MEM   the memory slave alone, driven directly
//   SLAVE_SYS   interconnect + both slaves -- a real address decode
//
// The first two exist because a slave driven standalone aliases the
// whole address space onto its own decode: the register slave sees
// ADDR[11:0], so 0x1000 lands on CTRL, and the memory slave sees
// ADDR[9:2], so 0x0000 lands on word 0. Both are correct -- routing is
// the interconnect's job -- and the model cannot guess which aliasing
// applies, so it is told.
//
// SLAVE_SYS is the one this file was written in anticipation of, and it
// changes nothing below it: the register model and the memory model are
// unchanged and now run side by side, with a decode in front deciding
// which of them owns each transaction and answering DECERR itself for
// the addresses that belong to neither.
//
// The decode is derived from spec section 4 HERE, independently, and not
// imported from the interconnect's localparams or from
// axi4lite_reg_pkg. A reference model that shares constants with the
// design agrees with the design by construction, which is exactly the
// class of defect BUG-007 was.
//----------------------------------------------------------------------
// WHAT CANNOT BE PREDICTED, and why it is skipped rather than fudged:
//
//   COUNTER   increments every clock while CTRL.enable (spec section 5).
//             A transaction-level model sees transactions, not cycles,
//             so it usually cannot know the value.
//
//             EXCEPT in one state. After a reset_stats write with enable
//             clear, COUNTER is 0 and frozen there, and every read must
//             return exactly 0 until enable is set again. That state is
//             fully predictable and IS checked -- it is what catches
//             BUG-006, a COUNTER that reset_stats fails to clear.
//
//             "Unpredictable" was too coarse. The honest model is
//             "unpredictable except when it isn't", and the difference is
//             an entire section 9 obligation.
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
localparam bit [1:0] SB_DECERR = 2'b11;

// Spec section 4's map. Written from the specification, not read off the
// interconnect.
localparam bit [31:0] SB_REG_LIMIT = 32'h0000_0FFF;
localparam bit [31:0] SB_MEM_BASE  = 32'h0000_1000;
localparam bit [31:0] SB_MEM_LIMIT = 32'h0000_13FF;

typedef enum { SLAVE_REG, SLAVE_MEM, SLAVE_SYS } axi_slave_kind_e;


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

    // True while COUNTER is known to be exactly 0: cleared by reset_stats
    // (or by reset) and not running because enable is clear. Spec section 5.
    // Starts true -- reset leaves COUNTER at 0 with enable clear.
    bit        m_counter_zero = 1'b1;

    //------------------------------------------------------------------
    // Memory model -- spec section 6. An associative array, per vplan
    // section 4, so only words that were written exist.
    //
    // m_mem_valid tracks which BYTES are defined. Spec section 6 says
    // reset does not clear the array, and nothing initialises it, so an
    // unwritten byte reads X in the DUT and is unpredictable here. A
    // partial write to a fresh word defines only the strobed lanes.
    //
    // The spec states the no-clear-on-reset rule explicitly "so it isn't
    // mistaken for a bug during scoreboard bring-up". This is that
    // bring-up, and per-byte validity is what the warning was about.
    //------------------------------------------------------------------
    bit [31:0] m_mem       [bit [7:0]];
    bit [3:0]  m_mem_valid [bit [7:0]];

    axi_slave_kind_e slave_kind = SLAVE_REG;

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
        if (!uvm_config_db #(axi_slave_kind_e)::get(this, "", "slave_kind", slave_kind))
            `uvm_info(get_type_name(),
                      "no slave_kind in config_db -- modelling the register slave", UVM_MEDIUM)
        `uvm_info(get_type_name(),
                  $sformatf("modelling %s", slave_kind.name()), UVM_LOW)
    endfunction

    //==================================================================
    // Decode -- spec section 4 and section 5, as revised in v0.3.
    // Implemented iff ADDR[11:5] == 0; register selected by ADDR[4:2].
    //==================================================================
    function bit       is_misaligned(bit [31:0] a); return a[1:0] != 2'b00;       endfunction
    function bit       is_implemented(bit [31:0] a); return a[11:5] == 7'b0;      endfunction
    function bit [2:0] reg_index(bit [31:0] a);      return a[4:2];               endfunction

    //==================================================================
    // System decode -- spec section 4. Only consulted in SLAVE_SYS.
    //
    // A range test, deliberately, and for the same reason the RTL uses
    // one: the unmapped gap at 0x1400-0x1FFF sits inside what a single
    // ADDR[12] test would call memory. If this model used a bit test it
    // would agree with a BUG-005-style decode and the scoreboard would
    // pass the very defect spec section 9 assigns to it.
    //==================================================================
    function bit is_reg_region(bit [31:0] a); return a <= SB_REG_LIMIT; endfunction
    function bit is_mem_region(bit [31:0] a);
        return (a >= SB_MEM_BASE) && (a <= SB_MEM_LIMIT);
    endfunction
    function bit is_unmapped(bit [31:0] a);   return a > SB_MEM_LIMIT;  endfunction

    //==================================================================
    function void write(axi_transaction t);
        bit to_mem, to_none;

        // SLAVE_SYS routes; the other two modes are told which model to
        // use and every address goes there.
        to_none = (slave_kind == SLAVE_SYS) && is_unmapped(t.addr);
        to_mem  = (slave_kind == SLAVE_MEM) ||
                  ((slave_kind == SLAVE_SYS) && is_mem_region(t.addr));

        if (t.kind == AXI_WRITE) begin
            n_writes++;
            if      (to_none) check_unmapped(t);
            else if (to_mem)  check_write_mem(t);
            else              check_write(t);
        end else begin
            n_reads++;
            if      (to_none) check_unmapped(t);
            else if (to_mem)  check_read_mem(t);
            else              check_read(t);
        end
    endfunction

    //==================================================================
    // Unmapped -- spec section 4.
    //
    // DECERR, and NOTHING ELSE HAPPENS. Three separate claims, and all
    // three are checked here rather than assumed:
    //
    //   the response is DECERR and not SLVERR -- the distinction is the
    //   difference between "no slave owns this" and "a slave owns it and
    //   said no";
    //
    //   RDATA is a deterministic zero on a read (section 4, added in
    //   v0.3 so the model can check it rather than mask it);
    //
    //   no INT_STATUS bit is set and STATUS.error does not move. The
    //   transaction is terminated by the interconnect and never reaches
    //   the register slave, so nothing in the register model may change.
    //   That last one is a silent claim -- there is no signal for it --
    //   and it is enforced by this function simply not touching the
    //   model. Any future edit that "helpfully" sets a bit here breaks
    //   spec section 4's parenthesis: "no INT_STATUS bit, since the slave
    //   never sees the transaction".
    //
    // Precedence matters too: unmapped OUTRANKS misaligned, so a
    // misaligned address above 0x13FF is DECERR, not SLVERR. That is why
    // this runs before any alignment test.
    //==================================================================
    function void check_unmapped(axi_transaction t);
        n_resp_checked++;
        if (t.resp !== SB_DECERR)
            report_mismatch(t.kind == AXI_WRITE ? "BRESP" : "RRESP",
                            t, {30'b0, t.resp}, {30'b0, SB_DECERR});

        if (t.kind == AXI_READ) begin
            n_data_checked++;
            if (t.rdata !== 32'h0)
                report_mismatch("RDATA", t, t.rdata, 32'h0);
        end
    endfunction

    //==================================================================
    // Memory slave -- spec section 6.
    //
    // Misalignment is the only error. WSTRB is HONOURED byte by byte,
    // and 4'b0000 is a legal no-op returning OKAY -- the exact opposite
    // of the register slave, where any strobe but 4'b1111 is SLVERR.
    // Same four bits, opposite policy; this is the model that has to
    // hold both readings at once.
    //==================================================================
    function void check_write_mem(axi_transaction t);
        bit [1:0] exp_resp;
        bit [7:0] word;

        exp_resp = is_misaligned(t.addr) ? SB_SLVERR : SB_OKAY;

        n_resp_checked++;
        if (t.resp !== exp_resp)
            report_mismatch("BRESP", t, {30'b0, t.resp}, {30'b0, exp_resp});

        // Spec section 6: a misaligned access changes no state.
        if (exp_resp != SB_OKAY) return;

        word = t.addr[9:2];
        if (!m_mem.exists(word)) begin
            m_mem[word]       = 32'h0;
            m_mem_valid[word] = 4'h0;
        end

        // WSTRB == 4'b0000 needs no special case here either: no lane is
        // enabled, nothing changes, and the response is already OKAY.
        for (int b = 0; b < 4; b++) begin
            if (t.strb[b]) begin
                m_mem[word][8*b +: 8] = t.data[8*b +: 8];
                m_mem_valid[word][b]  = 1'b1;
            end
        end
    endfunction

    function void check_read_mem(axi_transaction t);
        bit [1:0]  exp_resp;
        bit [31:0] exp_data;
        bit [31:0] mask;
        bit [7:0]  word;
        bit [3:0]  v;

        exp_resp = is_misaligned(t.addr) ? SB_SLVERR : SB_OKAY;

        n_resp_checked++;
        if (t.resp !== exp_resp)
            report_mismatch("RRESP", t, {30'b0, t.resp}, {30'b0, exp_resp});

        if (exp_resp != SB_OKAY) begin
            exp_data = 32'h0;               // spec section 4
            mask     = 32'hFFFF_FFFF;
        end
        else begin
            word = t.addr[9:2];
            if (!m_mem.exists(word)) begin
                // Never written. Spec section 6: reset does not clear the
                // array and nothing initialises it, so the DUT returns X.
                exp_data = 32'h0;
                mask     = 32'h0;
            end
            else begin
                v        = m_mem_valid[word];
                exp_data = m_mem[word];
                // Compare only the bytes some write has defined.
                mask     = {{8{v[3]}}, {8{v[2]}}, {8{v[1]}}, {8{v[0]}}};
            end
        end

        if (mask == 32'h0) n_data_skipped++;
        else begin
            n_data_checked++;
            if ((t.rdata & mask) !== (exp_data & mask))
                report_mismatch("RDATA", t, t.rdata & mask, exp_data & mask);
        end
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
                SB_CTRL       : begin
                    m_ctrl_enable = t.data[0];   // [1] is self-clearing
                    // Order matters and mirrors the RTL's branch order.
                    // reset_stats has priority over increment on its own
                    // cycle, but if enable is also set the counter starts
                    // running immediately afterwards and is unknown again.
                    if      (t.data[0]) m_counter_zero = 1'b0;  // enabled: runs
                    else if (t.data[1]) m_counter_zero = 1'b1;  // cleared, frozen
                    // else: frozen at whatever it was -- state unchanged
                end
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
                    // Checkable only in the cleared-and-frozen state.
                    mask     = m_counter_zero ? 32'hFFFF_FFFF : 32'h0;
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
