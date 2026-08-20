//======================================================================
// axi4lite_reg_bind.sv
//
// Binds the protocol checker to the register slave.
//
// One file per slave, deliberately. A single combined bind file forces
// every build to contain BOTH slaves: Xcelium warns *W,SVBNOT and
// silently skips a bind whose target module is absent, and adding the
// absent module to make the warning go away elaborates it as a second,
// unconnected top-level with floating inputs and a checker bound to it.
// Splitting lets a build include exactly the binds it has DUTs for.
//
// Binding to the MODULE, not an instance, so every instance is checked --
// including the two the interconnect will create in September.
//
// CHECK_ALIGN is 1 for both slaves: spec section 6 requires the memory
// slave to return SLVERR on a misaligned access just as the register
// slave does. See dut_spec.md section 10.
//======================================================================

bind axi4lite_reg_slave axi4lite_protocol_checker #(
    .ADDR_WIDTH  (32),
    .DATA_WIDTH  (32),
    .CHECK_ALIGN (1)
) u_chk (.*);
