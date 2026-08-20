//======================================================================
// axi_observer.sv  --  TEMPORARY
//
// Counts what arrives on the monitor's analysis port. Exists so the
// analysis path is exercised end to end before the scoreboard is written,
// and so the env has something real connected to mon.ap.
//
// Replaced by axi_scoreboard on 26 Aug. It checks nothing; counting is
// all it does.
//======================================================================

class axi_observer extends uvm_subscriber #(axi_transaction);

    `uvm_component_utils(axi_observer)

    int unsigned n_writes = 0;
    int unsigned n_reads  = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // uvm_subscriber supplies the analysis_export and requires this name.
    function void write(axi_transaction t);
        if (t.kind == AXI_WRITE) n_writes++;
        else                     n_reads++;
    endfunction

endclass : axi_observer
