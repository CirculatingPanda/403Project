// tb_fifo_sync.sv — skeleton testbench for a simple synchronous FIFO controller
// Guarded with @LLM_EDIT blocks for the LLM to fill localized logic.

`timescale 1ns/1ps
module tb;

  // ------------------------------
  // Params (filled by your generator)
  // ------------------------------
  localparam int  DATA_W   = 32;     // e.g., 32
  localparam int  DEPTH    = 1024;          // e.g., 256
  localparam int  AF_LEVEL = 896;    // optional, else set == DEPTH-1
  localparam int  AE_LEVEL = 128;   // optional, else set == 1
  localparam real CLK_MHZ  = 200;        // e.g., 100
  localparam real CLK_NS   = (1000.0/CLK_MHZ);

  localparam int NUM_TXNS = 200; // total push+pop ops target

  // ------------------------------
  // Timing in cycles (LLM fills if you model setup/hold/gaps)
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
localparam int T_PUSH_GAP_CYC = 0;
localparam int T_POP_GAP_CYC  = 0;
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
  /* golden FIFO model omitted for this config */

  // ------------------------------
  // Optional assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/fifo_protocol.svh"
  // fifo_protocol_asrt #(.DATA_W(DATA_W), .DEPTH(DEPTH)) chk (.*);

  // ------------------------------
  // Driver tasks (LLM fills legal sequences that respect full/empty)
  // ------------------------------
  // @LLM_EDIT BEGIN TASK_PUSH
task automatic do_push(input logic [DATA_W-1:0] d);
  int i;
  // Ensure enables are deasserted by default
  wr_en = 1'b0;
  // Wait for reset deassertion and a safe clock edge
  if (!rstn) begin
    @(posedge rstn);
    @(posedge clk);
  end
  // Respect push gap cycles before issuing a new push
  if (T_PUSH_GAP_CYC > 0) begin
    for (i = 0; i < T_PUSH_GAP_CYC; i = i + 1) begin
      @(posedge clk);
    end
  end
  // Wait until FIFO is not full, align to a negedge to avoid races
  while (full) begin
    @(posedge clk);
  end
  @(negedge clk);
  din = d;
  wr_en = 1'b1;
  // One cycle pulse on wr_en
  @(posedge clk);
  @(negedge clk);
  wr_en = 1'b0;
endtask
  // @LLM_EDIT END TASK_PUSH

  // @LLM_EDIT BEGIN TASK_POP
task automatic do_pop(output logic [DATA_W-1:0] q);
  int i;
  // Ensure enables are deasserted by default
  rd_en = 1'b0;
  // Wait for reset deassertion and a safe clock edge
  if (!rstn) begin
    @(posedge rstn);
    @(posedge clk);
  end
  // Respect pop gap cycles before issuing a new pop
  if (T_POP_GAP_CYC > 0) begin
    for (i = 0; i < T_POP_GAP_CYC; i = i + 1) begin
      @(posedge clk);
    end
  end
  // Wait until FIFO is not empty, align to a negedge to avoid races
  while (empty) begin
    @(posedge clk);
  end
  @(negedge clk);
  rd_en = 1'b1;
  // One cycle pulse on rd_en
  @(posedge clk);
  @(negedge clk);
  rd_en = 1'b0;
  // Sample dout on the next posedge to avoid races
  @(posedge clk);
  q = dout;
endtask
  // @LLM_EDIT END TASK_POP

  // ------------------------------
  // Scoreboard (avoid SV queues; use fixed arrays / ring buffer)
  // ------------------------------
  int                err_count = 0;
  int                pushes = 0;
  int                pops = 0;
  int                ops = 0;
  logic              done = 1'b0;
  logic [DATA_W-1:0] got_q, exp_q;
  logic [DATA_W-1:0] model_mem [0:DEPTH-1];
  int                model_wptr = 0;
  int                model_rptr = 0;
  int                model_count = 0;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got);
    if (exp !== got) begin
      $display("[TB][MISMATCH] exp=0x%0h got=0x%0h", exp, got);
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
  //   done = 1'b0;
  //   ops = 0;
  //   repeat (5) @(posedge clk);
  //   rstn <= 1;
  //
  //   // Example skeleton (LLM may replace/refine inside this region):
  //   while (ops < NUM_TXNS) begin
  //     // Randomly choose to push or pop; bias away from illegal ops.
  //     if (!full && ($urandom%2==0)) begin
  //       do_push($urandom);
  //       pushes++;
  //     
end
  //     else if (!empty) begin
  //       do_pop(got_q);
  //       // Use model_mem/model_wptr/model_rptr for expected data.
  //       pops++;
  //     end
  //     ops++;
  //   end
  //   done = 1'b1;
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // EMIT_RESULTS
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
  // initial begin
  //   wait (done);
  //   if (err_count == 0 && pops > 0 && pushes > 0) $display("RESULT: PASS");
  //   else begin
  //     $display("RESULT: FAIL");
  //     $fatal(1);
  //   
end
  //   $finish;
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
