//======================================================================
// axi_reg_adapter.sv
//
// The two-way translation between a uvm_reg operation and an
// axi_transaction, plus the environment plumbing that decides where the
// RAL's mirror gets its truth from.
//
// NOT independently compilable -- see tb/agent/axi_transaction.sv.
//
//----------------------------------------------------------------------
// THE DECISION THAT MATTERS: EXPLICIT PREDICTION, NOT AUTO-PREDICT
//
// UVM offers two ways to keep the mirror current.
//
//   auto-predict    the reg model updates itself from the operation it
//                   just issued. Cheap, needs no predictor, and it
//                   believes whatever the sequence asked for.
//
//   explicit        a uvm_reg_predictor sits on the MONITOR's analysis
//                   port and updates the mirror from what actually
//                   happened on the pins.
//
// This environment uses explicit prediction, and the reason is the same
// one that shaped the monitor: a model fed by the stimulus agrees with
// the stimulus. If the driver dropped a write, auto-predict would update
// the mirror anyway and the next read would be compared against a value
// the DUT was never told to hold -- and the failure would be reported
// against the DUT.
//
// It costs a predictor and one connect_phase line. It buys a RAL whose
// mirror is evidence rather than an assumption.
//
//----------------------------------------------------------------------
// WSTRB
//
// reg2bus always sets 4'b1111 on a write, and that is not laziness.
// Spec section 5: any strobe other than all-ones on a register write is
// SLVERR with the register unchanged. A RAL frontdoor write is a request
// to change a register, so anything but full strobe would make every
// uvm_reg::write() fail by construction -- including bit_bash's, which
// would then report an access-policy defect on a correct DUT.
//
// Partial-strobe register writes are F16 and belong to a directed test
// that means them.
//======================================================================

class axi_reg_adapter extends uvm_reg_adapter;

    `uvm_object_utils(axi_reg_adapter)

    function new(string name = "axi_reg_adapter");
        super.new(name);
        // The RAL never needs byte-lane control on this bus (see the
        // header), and there is no separate response item: the driver
        // fills resp and rdata into the same object.
        supports_byte_enable = 0;
        provides_responses   = 0;
    endfunction

    //------------------------------------------------------------------
    // uvm_reg operation -> bus transaction
    //------------------------------------------------------------------
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
        axi_transaction t = axi_transaction::type_id::create("ral_item");

        t.kind = (rw.kind == UVM_WRITE) ? AXI_WRITE : AXI_READ;
        t.addr = rw.addr;
        t.data = rw.data;
        t.strb = 4'b1111;                    // see the header

        // Tells the driver to hold item_done until the bus has answered.
        // provides_responses is 0, so uvm_reg_map reads the status
        // straight out of this item the moment finish_item returns --
        // and this driver's item_done fires on acceptance. See
        // axi_driver::dispatch for the full reasoning.
        t.from_ral = 1'b1;

        // Timing knobs the RAL has no opinion about. Randomising them
        // rather than pinning them to zero keeps RAL traffic from being
        // the one part of the regression that never exercises a delay --
        // and cg_valid_delay and cg_backpressure sample RAL transactions
        // like any other.
        if (!t.randomize() with {
                kind == local::t.kind;
                addr == local::t.addr;
                data == local::t.data;
                strb == local::t.strb;
                misaligned == (local::t.addr[1:0] != 2'b00);
            })
            `uvm_error("RAL_ADAPTER",
                       $sformatf("could not randomise timing for a RAL access to 0x%08h", rw.addr))
        return t;
    endfunction

    //------------------------------------------------------------------
    // Observed bus transaction -> uvm_reg operation
    //
    // Fed by the MONITOR through uvm_reg_predictor, so `rw` describes
    // what the pins did. status is where a DUT error becomes a RAL
    // error: spec section 4's SLVERR and DECERR are both UVM_NOT_OK, and
    // reporting them as UVM_IS_OK would let a RAL sequence sail past an
    // access the DUT rejected.
    //------------------------------------------------------------------
    virtual function void bus2reg(uvm_sequence_item bus_item,
                                  ref uvm_reg_bus_op rw);
        axi_transaction t;

        if (!$cast(t, bus_item)) begin
            `uvm_fatal("RAL_ADAPTER", "bus2reg was handed something that is not an axi_transaction")
            return;
        end

        rw.kind   = (t.kind == AXI_WRITE) ? UVM_WRITE : UVM_READ;
        rw.addr   = t.addr;
        rw.data   = (t.kind == AXI_WRITE) ? t.data : t.rdata;
        rw.byte_en = '1;
        rw.status = (t.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;
    endfunction

endclass : axi_reg_adapter
