//======================================================================
// axi_transaction.sv
//
// One AXI4-Lite transaction: a write (AW + W + B) or a read (AR + R).
//
// NOT independently compilable. `uvm_macros.svh` and `import uvm_pkg::*`
// are emitted once by `make playground`, which concatenates the agent
// sources into a single file for the EDA Playground testbench pane.
//
// Design rationale: docs/uvm_agent_design.md
//======================================================================

typedef enum bit { AXI_READ, AXI_WRITE } axi_kind_e;

// The five values are exactly cg_address_region's five bins (vplan section 5),
// so coverage samples this field rather than re-deriving the decode.
typedef enum {
    REGION_REG_IMPL,        // 0x0000_0000 - 0x0000_001F  implemented registers
    REGION_REG_UNIMPL,      // 0x0000_0020 - 0x0000_0FFF  decoded, unimplemented
    REGION_MEM,             // 0x0000_1000 - 0x0000_13FF  memory
    REGION_UNMAPPED_LOW,    // 0x0000_1400 - 0x0000_1FFF  the deliberate gap
    REGION_UNMAPPED_HIGH    // 0x0000_2000 - 0xFFFF_FFFF
} axi_region_e;

typedef enum { ORDER_AW_FIRST, ORDER_W_FIRST, ORDER_SAME_CYCLE } axi_order_e;


class axi_transaction extends uvm_sequence_item;

    //------------------------------------------------------------------
    // Stimulus -- randomised
    //------------------------------------------------------------------
    rand axi_kind_e   kind;
    rand axi_region_e region;
    rand bit [31:0]   addr;
    rand bit [31:0]   data;      // write data (read data is filled in below)
    rand bit [3:0]    strb;
    rand bit          misaligned;

    // Timing knobs. aw_delay and w_delay are measured from the same
    // instant, so their RELATIVE values decide AW/W ordering -- which is
    // how cg_aw_w_order's three bins fall out of two random integers.
    rand int unsigned aw_delay;
    rand int unsigned w_delay;
    rand int unsigned ar_delay;
    rand int unsigned b_ready_delay;
    rand int unsigned r_ready_delay;

    //------------------------------------------------------------------
    // Results -- NOT rand, and excluded from compare.
    //
    // Filled in by the driver from the B/R channels, and independently
    // by the monitor from the pins. Randomising a field the DUT is meant
    // to produce is how a scoreboard ends up checking the testbench
    // against itself.
    //------------------------------------------------------------------
    bit [1:0]  resp;
    bit [31:0] rdata;
    bit        completed;

    `uvm_object_utils_begin(axi_transaction)
        `uvm_field_enum(axi_kind_e,   kind,       UVM_ALL_ON)
        `uvm_field_enum(axi_region_e, region,     UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_int (addr,       UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (data,       UVM_ALL_ON | UVM_HEX)
        `uvm_field_int (strb,       UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (misaligned, UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_int (aw_delay,   UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (w_delay,    UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (ar_delay,   UVM_ALL_ON | UVM_DEC | UVM_NOCOMPARE)
        `uvm_field_int (resp,       UVM_ALL_ON | UVM_BIN)
        `uvm_field_int (rdata,      UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    function new(string name = "axi_transaction");
        super.new(name);
    endfunction

    //==================================================================
    // Address constraints
    //
    // region picks the address, not the other way round. A freely
    // randomised 32-bit address lands in REGION_UNMAPPED_HIGH virtually
    // every time -- the mapped regions are 5 KB out of 4 GB.
    //==================================================================
    constraint c_region_addr {
        region == REGION_REG_IMPL     -> addr inside {[32'h0000_0000 : 32'h0000_001F]};
        region == REGION_REG_UNIMPL   -> addr inside {[32'h0000_0020 : 32'h0000_0FFF]};
        region == REGION_MEM          -> addr inside {[32'h0000_1000 : 32'h0000_13FF]};
        region == REGION_UNMAPPED_LOW -> addr inside {[32'h0000_1400 : 32'h0000_1FFF]};
        region == REGION_UNMAPPED_HIGH-> addr inside {[32'h0000_2000 : 32'hFFFF_FFFF]};
    }

    // Weighted so the interesting regions dominate but the error paths
    // are hit often enough to close their bins without a directed test.
    // SOFT, so a sequence can write `with { region == REGION_MEM; }` and
    // steer the traffic without producing a constraint contradiction.
    // Every distribution constraint below is soft for the same reason.
    //
    // Weights target roughly a quarter error traffic. Measured 19 Aug at
    // 48.8% with the first set of weights, which is wrong for
    // axi_random_test: that test exists to exercise the working data
    // paths (F01, F02, F14, F28), and at half errors it barely reaches
    // them. The error paths belong to the directed tests -- axi_decode_test,
    // axi_align_test, axi_error_priority_test -- which raise these weights
    // deliberately.
    constraint c_region_dist {
        soft region dist {
            REGION_REG_IMPL      := 42,
            REGION_MEM           := 42,
            REGION_REG_UNIMPL    :=  6,
            REGION_UNMAPPED_LOW  :=  5,
            REGION_UNMAPPED_HIGH :=  5
        };
    }

    // Alignment is a controlled knob, not luck. A random 32-bit address
    // is aligned one time in four, which is neither a useful nor a
    // steerable distribution.
    constraint c_align {
        misaligned == 1'b0 -> addr[1:0] == 2'b00;
        misaligned == 1'b1 -> addr[1:0] != 2'b00;
    }

    constraint c_align_dist {
        soft misaligned dist { 1'b0 := 92, 1'b1 := 8 };
    }

    //==================================================================
    // Strobe
    //
    // Reads carry no WSTRB. Pinning it to all-ones on reads keeps the
    // field deterministic so a scoreboard mismatch can never be blamed
    // on a don't-care.
    //==================================================================
    constraint c_strb_read {
        kind == AXI_READ -> strb == 4'b1111;
    }

    // 4'b0000 deserves its own weight: it is a legal OKAY no-op on the
    // memory slave (spec section 6) and an SLVERR on the register slave (section 5).
    // Same pattern, opposite meaning -- worth hitting often.
    constraint c_strb_dist {
        soft (kind == AXI_WRITE) -> strb dist {
            4'b1111              := 55,
            [4'b0001 : 4'b1110] :/ 35,
            4'b0000              := 10
        };
    }

    // A partial-strobe write to an implemented register is an ERROR
    // (spec section 5, F16) whereas on memory it is the normal case (section 6, F15).
    // Without this correlation, register writes are partial ~45% of the
    // time and F16 alone contributes ~8% of all traffic -- far more than
    // a corner case deserves. 20% of register writes still leaves ~20
    // hits per 500 items, which is ample.
    constraint c_strb_reg {
        soft (kind == AXI_WRITE && region == REGION_REG_IMPL) ->
            strb dist { 4'b1111 := 80, [4'b0000 : 4'b1110] :/ 20 };
    }

    constraint c_kind_dist {
        soft kind dist { AXI_WRITE := 50, AXI_READ := 50 };
    }

    //==================================================================
    // Timing
    //
    // Bin edges match cg_valid_delay and cg_backpressure exactly:
    // 0, 1-3, 4-10, >10. All four are reachable by construction rather
    // than by hoping the range happens to spread.
    //==================================================================
    constraint c_delay_range {
        aw_delay      inside {[0:20]};
        w_delay       inside {[0:20]};
        ar_delay      inside {[0:20]};
        b_ready_delay inside {[0:20]};
        r_ready_delay inside {[0:20]};
    }

    constraint c_delay_dist {
        soft aw_delay      dist { 0 := 35, [1:3] :/ 35, [4:10] :/ 20, [11:20] :/ 10 };
        soft w_delay       dist { 0 := 35, [1:3] :/ 35, [4:10] :/ 20, [11:20] :/ 10 };
        soft ar_delay      dist { 0 := 40, [1:3] :/ 35, [4:10] :/ 15, [11:20] :/ 10 };
        soft b_ready_delay dist { 0 := 40, [1:3] :/ 35, [4:10] :/ 15, [11:20] :/ 10 };
        soft r_ready_delay dist { 0 := 40, [1:3] :/ 35, [4:10] :/ 15, [11:20] :/ 10 };
    }

    //==================================================================
    // Helpers
    //==================================================================

    // cg_aw_w_order samples this. Writes only -- meaningless for reads.
    function axi_order_e get_order();
        if      (aw_delay <  w_delay) return ORDER_AW_FIRST;
        else if (w_delay  <  aw_delay) return ORDER_W_FIRST;
        else                           return ORDER_SAME_CYCLE;
    endfunction

    // True when the spec requires an error response for this access.
    // Used by the smoke test's tally; the scoreboard will derive its own
    // expectation from the spec rather than trusting this.
    function bit expects_error();
        if (region == REGION_UNMAPPED_LOW || region == REGION_UNMAPPED_HIGH) return 1;
        if (misaligned)                                                      return 1;
        if (region == REGION_REG_UNIMPL)                                     return 1;
        if (kind == AXI_WRITE && region == REGION_REG_IMPL && strb != 4'b1111) return 1;
        return 0;
    endfunction

    // Prints only the fields that mean something for this kind. A read
    // has no WSTRB and no AW/W ordering; showing them invites someone to
    // debug a number that was never used.
    function string convert2string();
        if (kind == AXI_WRITE)
            return $sformatf("WRITE %-20s addr=0x%08h data=0x%08h strb=%04b aw_d=%0d w_d=%0d %s%s",
                             region.name(), addr, data, strb, aw_delay, w_delay,
                             get_order().name(),
                             expects_error() ? "  [expects error]" : "");
        else
            return $sformatf("READ  %-20s addr=0x%08h                    ar_d=%0d%s",
                             region.name(), addr, ar_delay,
                             expects_error() ? "  [expects error]" : "");
    endfunction

endclass : axi_transaction
