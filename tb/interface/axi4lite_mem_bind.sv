//======================================================================
// axi4lite_mem_bind.sv
//
// Binds the protocol checker to the memory slave.
// See axi4lite_reg_bind.sv for why these are separate files.
//======================================================================

bind axi4lite_mem_slave axi4lite_protocol_checker #(
    .ADDR_WIDTH  (32),
    .DATA_WIDTH  (32),
    .CHECK_ALIGN (1)
) u_chk (.*);
