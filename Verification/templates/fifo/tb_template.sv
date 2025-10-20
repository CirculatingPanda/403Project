// tb_fifo_sync.sv — skeleton testbench for a simple synchronous FIFO controller
// Guarded with @LLM_EDIT blocks for the LLM to fill localized logic.

`timescale 1ns/1ps
module tb;

  // ------------------------------
  // Params (filled by your generator)
  // ------------------------------
  localparam int  DATA_W   = {{DATA_WIDTH}};     // e.g., 32
  localparam int  DEPTH    = {{DEPTH}};          // e.g., 256
  localparam int  AF_LEVEL = {{ALMOST_FULL}};    // optional, else set == DEPTH-1
  localparam int  AE_LEVEL = {{ALMOST_EMPTY}};   // optional, else set == 1
  localparam real CLK_MHZ  = {{CLK_MHZ}};        // e.g., 100
  localparam real CLK_NS   = (1000.0/CLK_MHZ);

  int NUM_TXNS = {{NUM_TRANSACTIONS}};          // total push+pop ops target

  // ------------------------------
  // Timing in cycles (LLM fills if you model setup/hold/gaps)
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_PUSH_GAP_CYC; // min cycles between pushes
  // int T_POP_GAP_CYC;  // min cycles between pops
  // @LLM_EDIT END TIMING_CYCLES

  // ------------------------------
  // Clk/Reset
  // ------------------------------
  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #(CLK_NS/2.0) clk = ~clk;

  // ------------------------------
  // DUT I/O (typical simple FIFO)
  // ------------------------------
  logic                 wr_en;
  logic                 rd_en;
  logic [DATA_W-1:0]    din;
  wire  [DATA_W-1:0]    dout;
  wire                  full;
  wire                  empty;
  wire                  almost_full;
  wire                  almost_empty;

  // ------------------------------
  // Instantiate DUT (teammate’s FIFO)
  // ------------------------------
  fifo_ctrl #(
    .DATA_W (DATA_W),
    .DEPTH  (DEPTH),
    .AF_LVL (AF_LEVEL),
    .AE_LVL (AE_LEVEL)
  ) dut (
    .clk          (clk),
    .rstn         (rstn),
    .wr_en        (wr_en),
    .rd_en        (rd_en),
    .din          (din),
    .dout         (dout),
    .full         (full),
    .empty        (empty),
    .almost_full  (almost_full),
    .almost_empty (almost_empty)
  );

  // ------------------------------
  // Golden FIFO model (behavioral, same interface semantics)
  // ------------------------------
  {{INCLUDE_GOLDEN_FIFO}}

  // ------------------------------
  // Optional assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/fifo_protocol.svh"
  // fifo_protocol_asrt #(.DATA_W(DATA_W), .DEPTH(DEPTH)) chk (.*);

  // ------------------------------
  // Driver tasks (LLM fills legal sequences that respect full/empty)
  // ------------------------------
  // @LLM_EDIT BEGIN TASK_PUSH
  // task automatic do_push(input logic [DATA_W-1:0] d);
  //   // Wait until !full, assert wr_en for one cycle with din=d,
  //   // respect T_PUSH_GAP_CYC between pushes.
  // endtask
  // @LLM_EDIT END TASK_PUSH

  // @LLM_EDIT BEGIN TASK_POP
  // task automatic do_pop(output logic [DATA_W-1:0] q);
  //   // Wait until !empty, assert rd_en for one cycle,
  //   // capture dout after the DUT's documented latency (usually same cycle or next).
  //   // Respect T_POP_GAP_CYC between pops.
  // endtask
  // @LLM_EDIT END TASK_POP

  // ------------------------------
  // Scoreboard
  // ------------------------------
  int                err_count = 0;
  int                pushes = 0, pops = 0;
  logic [DATA_W-1:0] got_q, exp_q;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got);
    if (exp !== got) begin
      $error("[TB][MISMATCH] exp=0x%0h got=0x%0h", exp, got);
      err_count++;
    end
  endtask

  // ------------------------------
  // MAIN_SCENARIO (LLM composes mixed traffic)
  // ------------------------------
  // LLM goals:
  //  * Generate bursts of pushes until almost_full, then pop some,
  //  * Exercise boundaries: go to full, drain to empty,
  //  * Cover almost_full/almost_empty transitions,
  //  * Keep scoreboard aligned with golden model.
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   wr_en = 0; rd_en = 0; din = '0;
  //   repeat (5) @(posedge clk);
  //   rstn <= 1;
  //
  //   // Example skeleton (LLM may replace/refine inside this region):
  //   automatic int ops = 0;
  //   while (ops < NUM_TXNS) begin
  //     // Randomly choose to push or pop; bias away from illegal ops.
  //     if (!full && ($urandom%2==0)) begin
  //       do_push($urandom);
  //       pushes++;
  //     end
  //     else if (!empty) begin
  //       do_pop(got_q);
  //       // Set exp_q from golden model (implicitly advanced by same pins) or mirror queue
  //       // check_eq(exp_q, got_q);
  //       pops++;
  //     end
  //     ops++;
  //   end
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // EMIT_RESULTS
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
  // final begin
  //   if (err_count == 0 && pops > 0 && pushes > 0) $display("RESULT: PASS");
  //   else begin
  //     $display("RESULT: FAIL");
  //     $fatal(1);
  //   end
  // end
  // @LLM_EDIT END EMIT_RESULTS

  // ------------------------------
  // Waves (optional)
  // ------------------------------
  initial begin
    if ($test$plusargs("dumpon")) begin
      $dumpfile("tb.vcd");
      $dumpvars(0, tb);
    end
  end

endmodule
