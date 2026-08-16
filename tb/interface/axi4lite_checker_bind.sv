//======================================================================
// axi4lite_checker_bind.sv  —  v0.3
//
// Binds axi4lite_protocol_checker to the DUT modules.
//
// A separate file, and `bind` rather than instantiation, so no assertion
// code ever appears in rtl/.  The RTL stays synthesisable and readable,
// and the checker can be dropped from a build by simply not compiling
// this file.
//
// Binding to the MODULE (not to an instance) means every instance of
// that module is checked — including the two the interconnect will
// instantiate in September, with no edit to this file.
//
// CHECK_ALIGN is 1 for both slaves.  Spec §6 requires the memory slave to
// return SLVERR on a misaligned access exactly as the register slave
// does, so there is no instance where disabling it is correct.
// See dut_spec.md §10.
//======================================================================

bind axi4lite_reg_slave axi4lite_protocol_checker #(
    .ADDR_WIDTH  (32),
    .DATA_WIDTH  (32),
    .CHECK_ALIGN (1)
) u_chk (.*);
