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
int T_PUSH_GAP_CYC = 1; // min cycles between pushes
int T_POP_GAP_CYC  = 1; // min cycles between pops
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
  wire                  rd_valid;
  wire                  wr_ready;
  wire                  full;
  wire                  empty;
  wire                  almost_full;
  wire                  almost_empty;

  // ------------------------------
  // fifo_ctrl_fifo_ctrl DUT (teammate’s FIFO)
  // ------------------------------
  fifo_ctrl #(
    .DATA_WIDTH (DATA_W),
    .DEPTH  (DEPTH),
    .ALMOST_FULL (AF_LEVEL),
    .ALMOST_EMPTY (AE_LEVEL)
  ) dut (
    .clk          (clk),
    .rst_n         (rstn),
    .wr_valid    (wr_en),
    .rd_ready    (rd_en),
    .wr_data     (din),
    .rd_data     (dout),
    .full         (full),
    .empty        (empty),
    .almost_full  (almost_full),
    .almost_empty (almost_empty),

    .wr_ready   (wr_ready),
    .rd_valid   (rd_valid)
  );

  // ------------------------------
  // Golden FIFO model (behavioral, same interface semantics)
  // ------------------------------
  /* golden FIFO model omitted for this config */

  // ------------------------------
  // Optional assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/fifo_protocol.svh"
  // fifo_protocol_asrt #(.DATA_WIDTH(DATA_W), .DEPTH(DEPTH)) chk (.*);

  // ------------------------------
  // Driver tasks (LLM fills legal sequences that respect full/empty)
  // ------------------------------
  // @LLM_EDIT BEGIN TASK_PUSH
task automatic do_push(input logic [DATA_W-1:0] d);
  int i;
  // Wait until FIFO is not full
  while (full) @(posedge clk);

  // Drive data and assert write enable prior to the sampling edge
  din = d;
  wr_en = 1'b1;
  @(posedge clk);
  wr_en = 1'b0;

  // Respect inter-push gap cycles
  for (i = 0; i < T_PUSH_GAP_CYC; i = i + 1) @(posedge clk);
endtask
  // @LLM_EDIT END TASK_PUSH

  // @LLM_EDIT BEGIN TASK_POP
task automatic do_pop(output logic [DATA_W-1:0] q);
  int i;
  // Wait until FIFO is not empty
  while (empty) @(posedge clk);

  // Assert read enable for one cycle
  rd_en = 1'b1;
  @(posedge clk);
  rd_en = 1'b0;

  // Sample data on the next posedge to avoid races
  @(posedge clk);
  q = dout;

  // Respect inter-pop gap cycles
  for (i = 0; i < T_POP_GAP_CYC; i = i + 1) @(posedge clk);
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
initial begin
  integer i;
  integer j;
  integer burst_len;
  integer cnt;

  wr_en = 0; rd_en = 0; din = '0;
  done = 1'b0;
  ops = 0;
  repeat (5) @(posedge clk);
  rstn <= 1;
  repeat (2) @(posedge clk);

  // Phase 1: Push until almost_full to cover transition
  while (ops < NUM_TXNS && !almost_full && !full) begin
    do_push($urandom);
    pushes++;
    ops++;
  end

  // Pop a few to move off almost_full boundary
  cnt = 0;
  while (ops < NUM_TXNS && !empty && cnt < 3) begin
    do_pop(got_q);
    pops++;
    ops++;
    cnt = cnt + 1;
  end

  // Phase 2: Go to full
  while (ops < NUM_TXNS && !full) begin
    do_push($urandom);
    pushes++;
    ops++;
  end

  // Drain to empty to cover full->empty path and almost_empty transition
  while (ops < NUM_TXNS && !empty) begin
    do_pop(got_q);
    pops++;
    ops++;
  end

  // Nudge almost_empty boundary: push a few from empty, then pop back
  cnt = 0;
  while (ops < NUM_TXNS && !full && cnt < 2) begin
    do_push($urandom);
    pushes++;
    ops++;
    cnt = cnt + 1;
  end
  cnt = 0;
  while (ops < NUM_TXNS && !empty && cnt < 2) begin
    do_pop(got_q);
    pops++;
    ops++;
    cnt = cnt + 1;
  end

  // Phase 3: Random bursts honoring boundaries
  while (ops < NUM_TXNS) begin
    burst_len = ($urandom % 4) + 1; // 1..4
    if (almost_full) begin
      // Prefer pops when near full
      for (j = 0; j < burst_len; j = j + 1) begin
        if (ops >= NUM_TXNS) ;
        if (!empty) begin
          do_pop(got_q);
          pops++;
          ops++;
        end else begin
          // If empty, push to continue activity
          if (!full) begin
            do_push($urandom);
            pushes++;
            ops++;
          end
        end
      end
    end else if (almost_empty) begin
      // Prefer pushes when near empty
      for (j = 0; j < burst_len; j = j + 1) begin
        if (ops >= NUM_TXNS) ;
        if (!full) begin
          do_push($urandom);
          pushes++;
          ops++;
        end else begin
          // If full, pop to continue activity
          if (!empty) begin
            do_pop(got_q);
            pops++;
            ops++;
          end
        end
      end
    end else begin
      // Middle range: random choice, but avoid illegal ops
      for (j = 0; j < burst_len; j = j + 1) begin
        if (ops >= NUM_TXNS) ;
        if (!full && !empty) begin
          if (($urandom % 2) == 0) begin
            do_push($urandom);
            pushes++;
            ops++;
          end else begin
            do_pop(got_q);
            pops++;
            ops++;
          end
        end else if (!full) begin
          do_push($urandom);
          pushes++;
          ops++;
        end else if (!empty) begin
          do_pop(got_q);
          pops++;
          ops++;
        end
      end
    end
  end

  done = 1'b1;
end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // EMIT_RESULTS
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
initial begin
  wait (done);
  if (err_count == 0 && pops > 0 && pushes > 0) begin
    $display("RESULT: PASS");
  end else begin
    $display("RESULT: FAIL err_count=%0d pushes=%0d pops=%0d", err_count, pushes, pops);
    $fatal(1);
  end
  $finish;
end
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
