// golden/rom_model.sv
// Simple asynchronous ROM behavioral model with preload capability.
// Read-only: contents are initialized from an external hex/mem file or pattern.

`timescale 1ns/1ps
module rom_model #(
  parameter int DATA_W = 16,
  parameter int ADDR_W = 18,
  parameter string INIT_FILE = ""    // optional hex file for preload
) (
  input  logic [ADDR_W-1:0] addr,
  input  logic              cs_n,
  input  logic              oe_n,
  output tri   [DATA_W-1:0] rdata
);

  // Memory array
  logic [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

  // ------------------------------
  // Initialization
  // ------------------------------
  initial begin
    if (INIT_FILE != "") begin
      $display("[rom_model] Loading contents from %s", INIT_FILE);
      $readmemh(INIT_FILE, mem);
    end else begin
      // Optional synthetic pattern if no file is provided
      for (int i = 0; i < (1<<ADDR_W); i++)
        mem[i] = i;   // simple incremental data
    end
  end

  // ------------------------------
  // Read behavior
  // ------------------------------
  assign rdata = (!cs_n && !oe_n) ? mem[addr] : 'z;

  // ------------------------------
  // Debug helper
  // ------------------------------
  always @(negedge cs_n)
    if (!oe_n)
      $display("[rom_model] READ  addr=0x%0h  data=0x%0h", addr, mem[addr]);

endmodule
