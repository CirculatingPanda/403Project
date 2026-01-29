// golden/fifo_model.sv
// Simple synchronous FIFO behavioral model with almost_full/empty flags.
// Default: non-FWFT (read data appears 1 cycle after a legal pop).

`timescale 1ns/1ps
module fifo_model #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 256,
  parameter int AF_LVL = (DEPTH-1),  // almost_full threshold
  parameter int AE_LVL = 1,          // almost_empty threshold
  parameter bit FWFT   = 1'b0        // 0 = registered output, 1 = first-word fall-through
) (
  input  logic              clk,
  input  logic              rstn,

  // DUT-facing synchronous FIFO pins
  input  logic              wr_en,
  input  logic              rd_en,
  input  logic [DATA_W-1:0] din,
  output logic [DATA_W-1:0] dout,
  output logic              full,
  output logic              empty,
  output logic              almost_full,
  output logic              almost_empty
);

  // --------- Storage & pointers ---------
  localparam int AW = (DEPTH <= 2) ? 1 : $clog2(DEPTH);
  logic [DATA_W-1:0] mem [0:DEPTH-1];
  logic [AW-1:0] wptr, rptr;
  int               count;           // 0..DEPTH

  // --------- Flags ---------
  always_comb begin
    full          = (count == DEPTH);
    empty         = (count == 0);
    almost_full   = (count >= AF_LVL);
    almost_empty  = (count <= AE_LVL);
  end

  // --------- Write path ---------
  logic do_write;
  assign do_write = wr_en && !full;

  // --------- Read path ---------
  logic do_read;
  assign do_read = rd_en && !empty;

  // Optional FWFT staging
  logic [DATA_W-1:0] stage_q;  // used for FWFT
  logic              stage_v;

  // --------- Sequential behavior ---------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      wptr   <= '0;
      rptr   <= '0;
      count  <= 0;
      stage_q <= '0;
      stage_v <= 1'b0;
      dout    <= '0;
    end else begin
      // concurrent read/write permitted
      if (do_write) begin
        mem[wptr] <= din;
        wptr      <= (wptr == DEPTH-1) ? '0 : (wptr + 1'b1);
      end
      if (do_read) begin
        // advance rptr and manage output based on FWFT mode
        if (FWFT) begin
          // In FWFT, dout shows current head immediately when data is present.
          // On pop, advance head; next cycle, dout updates to new head.
          rptr <= (rptr == DEPTH-1) ? '0 : (rptr + 1'b1);
        end else begin
          // Registered output: capture the popped element into dout.
          dout <= mem[rptr];
          rptr <= (rptr == DEPTH-1) ? '0 : (rptr + 1'b1);
        end
      end

      // Update count (simultaneous read/write keeps count constant)
      unique case ({do_write, do_read})
        2'b10: count <= count + 1;
        2'b01: count <= count - 1;
        default: /* no change */ ;
      endcase

      // FWFT output maintenance
      if (FWFT) begin
        // When not empty, present current head; else hold last value
        if (!empty) begin
          dout <= mem[rptr];
        end
      end
    end
  end

  // --------- Simple sanity warnings (non-fatal) ---------
  always_ff @(posedge clk) begin
    if (rstn) begin
      if (wr_en && full)  $warning("[fifo_model] Write while FULL ignored.");
      if (rd_en && empty) $warning("[fifo_model] Read  while EMPTY ignored.");
    end
  end

endmodule
