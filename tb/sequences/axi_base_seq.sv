//======================================================================
// axi_base_seq.sv  --  the sequence base class, and the register
//                     offsets every sequence uses
//
// item_done() fires on acceptance, so finish_item() returns BEFORE the
// transaction has completed on the bus. A sequence that needs the result
// waits on the handle it already owns:
//
//     finish_item(t);
//     wait (t.completed == 1'b1);
//
// That is deliberate. Blocking inside finish_item would serialise reads
// behind writes and make F24 unobservable -- see docs/uvm_agent_design.md section 2.
// The formal alternative (put_response / get_response) arrives with the
// scoreboard; this is the same information with less plumbing.
//======================================================================

// Register offsets, spec section 5
`define A_CTRL       32'h0000_0000
`define A_STATUS     32'h0000_0004
`define A_INT_ENABLE 32'h0000_000C
`define A_CONFIG     32'h0000_0008
`define A_INT_STATUS 32'h0000_0010
`define A_COUNTER    32'h0000_0018
`define A_SCRATCH    32'h0000_0014
`define A_ID         32'h0000_001C

//----------------------------------------------------------------------
// Addresses and response codes, in ONE place.
//
// Every sequence file needs these and every bundle includes this file,
// which is the whole reason they live here rather than beside the
// sequences that use them: the environment is split across four
// bundles to fit EDA Playground's 100,000-character pane limit, and a
// define that lives in one of the four is missing from the other three.
//
// Written from the SPECIFICATION's address map (section 4), not from the
// interconnect's localparams. A sequence that imports the DUT's own
// constants agrees with the DUT by construction.
//----------------------------------------------------------------------

// Memory words, spec section 6. Base 0x0000_1000, word = ADDR[9:2].
`define M_WORD(n)  (32'h0000_1000 + ((n) << 2))

// Spec section 4's boundaries. These addresses ARE the map, and each is
// one word away from an address with a different answer -- which is the
// only interesting place to test a decode.
`define A_REG_LAST_IMPL   32'h0000_001C   // ID, last implemented register
`define A_REG_FIRST_UNIMP 32'h0000_0020   // first unimplemented offset
`define A_REG_LAST        32'h0000_0FFC   // last word of the register region
`define A_MEM_FIRST       32'h0000_1000   // memory word 0
`define A_MEM_LAST        32'h0000_13FC   // memory word 255
`define A_GAP_FIRST       32'h0000_1400   // first unmapped -- BUG-005's address
`define A_GAP_LAST        32'h0000_1FFC   // last of the deliberate gap
`define A_UNMAPPED_HIGH   32'hFFFF_FFFC   // top of the address space

localparam bit [1:0] SEQ_OKAY   = 2'b00;
localparam bit [1:0] SEQ_SLVERR = 2'b10;
localparam bit [1:0] SEQ_DECERR = 2'b11;


virtual class axi_base_seq extends uvm_sequence #(axi_transaction);

    // What this sequence ISSUED. The monitor independently counts what it
    // SAW on the pins. Comparing the two is the check that the monitor is
    // reconstructing rather than echoing -- two counts with no shared path.
    int unsigned issued_writes = 0;
    int unsigned issued_reads  = 0;

    // Set by the test. 0 means "leave the stream alone".
    int unsigned seed = 0;

    function new(string name = "axi_base_seq");
        super.new(name);
    endfunction

    //------------------------------------------------------------------
    // Seeding.
    //
    // process::self().srandom(), not this.srandom(). IEEE 1800-2017
    // section 18.14.2: an object created with new() takes its RNG from
    // the THREAD that called new, not from the enclosing object. Every
    // transaction below is created inside body(), which runs in this
    // sequence's own process -- so seeding the process is what makes the
    // whole stream reproducible, and seeding the object would not.
    //
    // Xcelium reports "SVSEED default: 1" and Playground's fixed command
    // line cannot change it, so without this every run of a test is
    // byte-identical (docs/tooling_notes.md, 19 Aug). Excellent for
    // debugging a failure; useless for a regression, which is many seeds
    // of one test.
    //
    // pre_body rather than body so that no subclass has to remember: it
    // is called automatically by start() unless call_pre_post is 0.
    //------------------------------------------------------------------
    task pre_body();
        if (seed != 0) begin
            process::self().srandom(seed);
            `uvm_info(get_type_name(), $sformatf("seeded with %0d", seed), UVM_LOW)
        end
    endtask

    //------------------------------------------------------------------
    // Self-checking, in the base so every sequence counts the same way
    // and axi_regression_test can total them.
    //
    // These are the SEQUENCE's own expectations, and they are not the
    // scoreboard. The scoreboard checks every transaction against a
    // spec-derived model fed by the monitor; a directed sequence checks
    // the specific thing it was written to demonstrate, in the words of
    // the spec paragraph it came from. When both are right they agree;
    // when they disagree, having two independent statements is the whole
    // point.
    //------------------------------------------------------------------
    int unsigned checks = 0;
    int unsigned errors = 0;

    function void check(string what, bit [31:0] got, bit [31:0] exp);
        checks++;
        if (got === exp)
            `uvm_info(get_type_name(), $sformatf("  PASS  %-42s 0x%08h", what, got), UVM_LOW)
        else begin
            errors++;
            `uvm_error(get_type_name(), $sformatf("  FAIL  %-42s 0x%08h (expected 0x%08h)",
                                                  what, got, exp))
        end
    endfunction

    function void check_true(string what, bit ok, bit [31:0] got);
        checks++;
        if (ok)
            `uvm_info(get_type_name(), $sformatf("  PASS  %-42s 0x%08h", what, got), UVM_LOW)
        else begin
            errors++;
            `uvm_error(get_type_name(), $sformatf("  FAIL  %-42s 0x%08h", what, got))
        end
    endfunction

    function void section(string title);
        `uvm_info(get_type_name(), $sformatf("---- %s ----", title), UVM_LOW)
    endfunction

    // Blocking write. Returns the response once the B handshake is done.
    task write(input bit [31:0] addr, input bit [31:0] data,
               input bit [3:0] strb, output bit [1:0] resp,
               input int aw_d = -1, input int w_d = -1);
        axi_transaction t;
        t = axi_transaction::type_id::create("wr");
        start_item(t);
        // The distribution constraints are soft, so pinning fields here
        // steers the transaction instead of contradicting it.
        if (!t.randomize() with {
                kind       == AXI_WRITE;
                addr       == local::addr;
                data       == local::data;
                strb       == local::strb;
                misaligned == (local::addr[1:0] != 2'b00);
                (local::aw_d >= 0) -> aw_delay == local::aw_d;
                (local::w_d  >= 0) -> w_delay  == local::w_d;
            })
            `uvm_error(get_type_name(), $sformatf("write randomize failed addr=0x%08h", addr))
        `uvm_info(get_type_name(),
                  $sformatf("write  addr=0x%08h data=0x%08h strb=%04b -- issued",
                            addr, data, strb), UVM_HIGH)
        finish_item(t);
        // completed goes high on an abort too -- reset cannot produce the
        // B response this would otherwise wait forever for. See
        // axi_transaction::aborted.
        wait (t.completed == 1'b1);
        issued_writes++;
        resp = t.resp;
    endtask

    // Blocking read.
    task read(input bit [31:0] addr, output bit [31:0] data, output bit [1:0] resp);
        axi_transaction t;
        t = axi_transaction::type_id::create("rd");
        start_item(t);
        if (!t.randomize() with {
                kind       == AXI_READ;
                addr       == local::addr;
                misaligned == (local::addr[1:0] != 2'b00);
            })
            `uvm_error(get_type_name(), $sformatf("read randomize failed addr=0x%08h", addr))
        finish_item(t);
        wait (t.completed == 1'b1);
        issued_reads++;
        data = t.rdata;
        resp = t.resp;
    endtask

    //------------------------------------------------------------------
    // Non-blocking issue.
    //
    // finish_item() returns as soon as the DRIVER accepts the transaction
    // (item_done fires on acceptance -- docs/uvm_agent_design.md section 2),
    // so returning here without waiting on t.completed leaves the previous
    // transaction still on the bus. That is what produces back-to-back
    // traffic, and it is the only way c_b2b_write and c_b2b_read can ever
    // be covered.
    //
    // The caller keeps the handle and waits later.
    //------------------------------------------------------------------
    task issue_nb(axi_transaction t);
        start_item(t);
        finish_item(t);
        if (t.kind == AXI_WRITE) issued_writes++;
        else                     issued_reads++;
    endtask

endclass
