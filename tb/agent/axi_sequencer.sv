//======================================================================
// axi_sequencer.sv
//
// A typedef, and for now nothing more.
//
// Named explicitly rather than writing uvm_sequencer #(axi_transaction)
// inline at every use, so that if it ever needs arbitration, a lock or
// grant policy, or a response queue, there is already a place to put it
// and no call site has to change.
//======================================================================

typedef uvm_sequencer #(axi_transaction) axi_sequencer;
