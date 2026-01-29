// golden/sram_model.sv
// Minimal async SRAM behavioral model with byte-enable support.
// Drives rdata during reads; updates memory on writes. No explicit timing
// delays inside the model — your TB tasks should wait the required cycles.

`timescale 1ns/1ps

module sram_model #(
  parameter int DATA_W = 16,
  parameter int ADDR_W = 18
) (
  input  logic                  clk,    // used to sequence writes cleanly
  input  logic                  rstn,

  // Async SRAM-like pins
  input  logic                  cs_n,   // chip select, active low
  input  logic                  we_n,   // write enable, active low
  input  logic                  oe_n,   // output enable, active low
  input  logic [ADDR_W-1:0]     addr,
  input  logic [DATA_W-1:0]     wdata,
  input  logic [(DATA_W/8>0)?(DATA_W/8):1-1:0] be, // byte enables, 1=write that byte
  output tri   [DATA_W-1:0]     rdata
);

  localparam int BE_W = (DATA_W/8>0) ? (DATA_W/8) : 1;

  // Memory array
  logic [DATA_W-1:0] mem [0:(1<<ADDR_W)-1];

  // Optional: clear memory on reset (cheap, for small ADDR_W; comment out if huge)
  // generate
  //   if (ADDR_W <= 12) begin : g_small_init
  //     integer i;
  //     always_ff @(negedge rstn) begin
  //       for (i = 0; i < (1<<ADDR_W); i++) mem[i] <= '0;
  //     end
  //   end
  // endgenerate

  // ----------------------------
  // Write behavior (masked by byte enables)
  // ----------------------------
  // We commit writes synchronously on clk when CS is active and WE is low.
  // Your TB should honor tWP/tWC/tDW/tDH via waits; the model itself is ideal.
  always_ff @(posedge clk) begin
    if (!rstn) begin
      // no op (keep contents)
    end else if (!cs_n && !we_n) begin
      for (int b = 0; b < BE_W; b++) begin
        if (be[b]) begin
          mem[addr][8*b +: 8] <= wdata[8*b +: 8];
        end
      end
    end
  end

  // ----------------------------
  // Read behavior
  // ----------------------------
  // Drive rdata only during a read cycle (CS low, OE low, WE high).
  // Otherwise high-Z to emulate a real device bus.
  assign rdata = (!cs_n && !oe_n && we_n) ? mem[addr] : 'z;

  // ----------------------------
  // (Optional) Simple protocol sanity checks (non-fatal)
  // ----------------------------
  // Warn if read/write both asserted (illegal for async SRAM).
  always @(posedge clk) begin
    if (!rstn) begin
      // no-op
    end else if (!cs_n && !we_n && !oe_n) begin
      $warning("[sram_model] we_n==0 and oe_n==0 simultaneously (illegal).");
    end
  end

endmodule
