//======================================================================
// axi_watchdog.sv
//
// One watchdog, instantiated by every testbench top.
//
// A hang is the one failure mode this environment could not report on
// its own. EDA Playground kills an over-running job with exit 137 and no
// message, so a stalled handshake used to produce no evidence at all --
// the log simply stopped. This turns that into a bus-state dump naming
// the channel that is stuck.
//
// INACTIVITY, NOT ELAPSED TIME, and that distinction is the reason this
// file exists rather than a `#50us` in each top.
//
// An absolute deadline cannot tell "stalled" from "still working".
// axi_counter_test has to run COUNTER from 0 to 0xFFFF to reach the
// overflow event that sets INT_STATUS[3] -- 65,536 cycles, 655 us at
// 100 MHz. Under a 50 us deadline that test fails for doing exactly what
// spec section 5 requires of it, and the failure looks like a hang.
//
// So the deadline resets on ANY handshake. It is progress being watched,
// not completion, and a test is free to take as long as it keeps making
// some.
//
// Every stall has a signature, which is why the dump prints all five
// channels rather than a message: VALID high with READY low means the
// slave is not accepting; both low on a channel that should be busy
// means the driver never issued.
//======================================================================

module axi_watchdog #(
    // Nanoseconds rather than a `time` parameter: `time` parameters are
    // supported unevenly and this has to elaborate on four tools.
    parameter int IDLE_NS = 20_000
) (
    input logic        ACLK,
    input logic        ARESETn,
    input logic [31:0] AWADDR,
    input logic        AWVALID,
    input logic        AWREADY,
    input logic [31:0] WDATA,
    input logic [3:0]  WSTRB,
    input logic        WVALID,
    input logic        WREADY,
    input logic [1:0]  BRESP,
    input logic        BVALID,
    input logic        BREADY,
    input logic [31:0] ARADDR,
    input logic        ARVALID,
    input logic        ARREADY,
    input logic [31:0] RDATA,
    input logic [1:0]  RRESP,
    input logic        RVALID,
    input logic        RREADY
);

    time last_activity = 0;

    // Reset counts as activity: a test that deliberately holds the bus
    // in reset (F09) is not hung.
    always @(posedge ACLK) begin
        if ((AWVALID && AWREADY) || (WVALID  && WREADY) ||
            (BVALID  && BREADY)  || (ARVALID && ARREADY) ||
            (RVALID  && RREADY)  || !ARESETn)
            last_activity = $time;
    end

    initial begin
        forever begin
            #(IDLE_NS * 1ns);
            if ($time - last_activity >= (IDLE_NS * 1ns)) begin
                $display("");
                $display("=================== WATCHDOG ===================");
                $display(" no bus activity for %0d ns. ARESETn=%b", IDLE_NS, ARESETn);
                $display("   AW  VALID=%b READY=%b  ADDR=0x%08h", AWVALID, AWREADY, AWADDR);
                $display("   W   VALID=%b READY=%b  DATA=0x%08h STRB=%04b",
                         WVALID, WREADY, WDATA, WSTRB);
                $display("   B   VALID=%b READY=%b  RESP=%02b", BVALID, BREADY, BRESP);
                $display("   AR  VALID=%b READY=%b  ADDR=0x%08h", ARVALID, ARREADY, ARADDR);
                $display("   R   VALID=%b READY=%b  DATA=0x%08h RESP=%02b",
                         RVALID, RREADY, RDATA, RRESP);
                $display("================================================");
                $fatal(1, "watchdog: no bus activity for %0d ns", IDLE_NS);
            end
        end
    end

endmodule : axi_watchdog
