//======================================================================
// axi4lite_sys_bind.sv
//
// Binds the protocol checker to the interconnect's MASTER-FACING port --
// the one the UVM agent drives.
//
// Together with axi4lite_reg_bind.sv and axi4lite_mem_bind.sv, which
// bind to the slave MODULES and therefore reach every instance the
// system top creates, this gives three checker instances on a system
// build:
//
//   u_chk_m   the interconnect AS A SLAVE, seen from the master
//   u_chk     inside axi4lite_reg_slave -- the interconnect as a MASTER
//   u_chk     inside axi4lite_mem_slave -- likewise
//
// So the interconnect is checked from both sides. Every protocol rule
// it must obey towards the master, and every rule it must obey towards
// each slave, is a bound assertion rather than a review comment.
//
// Explicit port map, not (.*): the interconnect's signals are S_/M0_/M1_
// prefixed because it has three ports, so there is nothing for a
// wildcard to match. Only the S_ port is bound here -- the M_ ports are
// the same wires as the slaves' pins, already checked by the two
// per-slave binds, and binding them again would double every message.
//
// CHECK_ALIGN is 0 on this instance, and that is the only parameter
// difference anywhere in the project. The checker's alignment property
// asserts that a misaligned access returns a non-OKAY response -- true
// of a SLAVE. At the master port a misaligned UNMAPPED address returns
// DECERR, which is also non-OKAY, so the property would still hold; but
// alignment is a slave-side obligation under spec section 4's precedence
// (unmapped outranks misaligned), and asserting it here would state a
// requirement the interconnect does not own. The two slave-port
// instances check it where it belongs.
//======================================================================

bind axi4lite_interconnect axi4lite_protocol_checker #(
    .ADDR_WIDTH  (32),
    .DATA_WIDTH  (32),
    .CHECK_ALIGN (0)
) u_chk_m (
    .ACLK    (ACLK),      .ARESETn (ARESETn),
    .AWADDR  (S_AWADDR),  .AWVALID (S_AWVALID), .AWREADY (S_AWREADY),
    .WDATA   (S_WDATA),   .WSTRB   (S_WSTRB),   .WVALID  (S_WVALID),  .WREADY (S_WREADY),
    .BRESP   (S_BRESP),   .BVALID  (S_BVALID),  .BREADY  (S_BREADY),
    .ARADDR  (S_ARADDR),  .ARVALID (S_ARVALID), .ARREADY (S_ARREADY),
    .RDATA   (S_RDATA),   .RRESP   (S_RRESP),   .RVALID  (S_RVALID),  .RREADY (S_RREADY)
);
