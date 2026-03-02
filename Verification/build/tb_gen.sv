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
localparam int NUM_TXNS = 200;          // total push+pop ops target

  // ------------------------------
  // Timing in cycles (LLM fills if you model setup/hold/gaps)
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
int T_PUSH_GAP_CYC = 0; // min cycles between pushes
int T_POP_GAP_CYC  = 0;  // min cycles between pops
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
  // Wait for space in FIFO synchronized to clk
  while (full) @(posedge clk);
  // Issue push on next clock edge
  @(posedge clk);
  din   <= d;
  wr_en <= 1'b1;
  // Hold for exactly one cycle
  @(posedge clk);
  wr_en <= 1'b0;
  din   <= '0;
  // Respect inter-push gap cycles
  for (i = 0; i < T_PUSH_GAP_CYC; i = i + 1) @(posedge clk);
endtask
  // @LLM_EDIT END TASK_PUSH

  // @LLM_EDIT BEGIN TASK_POP
task automatic do_pop(output logic [DATA_W-1:0] q);
  int i;
  logic [DATA_W-1:0] tmp;
  // Wait for data available synchronized to clk
  while (empty) @(posedge clk);
  // Issue pop on next clock edge
  @(posedge clk);
  rd_en <= 1'b1;
  // Sample data on the following clock edge to avoid races
  @(posedge clk);
  tmp   = dout;
  rd_en <= 1'b0;
  q = tmp;
  // Respect inter-pop gap cycles
  for (i = 0; i < T_POP_GAP_CYC; i = i + 1) @(posedge clk);
endtask
  // @LLM_EDIT END TASK_POP

  // ------------------------------
  // Scoreboard
  // ------------------------------
  int                err_count = 0;
  int                pushes = 0, pops = 0;
  logic [DATA_W-1:0] got_q, exp_q;

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
    // Declarations first (Icarus requirement)
    int ops;
    int guard;
    logic [$bits(din)-1:0] val;
    logic [$bits(din)-1:0] exp;
    logic [$bits(din)-1:0] got;
    logic [$bits(din)-1:0] golden_q[$];

    // Reset/init
    wr_en = 0;
    rd_en = 0;
    din   = '0;
    val   = '0;

    repeat (5) @(posedge clk);
    rstn <= 1;
    repeat (2) @(posedge clk);

    // Phase A: Push until almost_full
    ops = 0;
    guard = 0;
    while (!almost_full && guard < 10000) begin
      if (!full) begin
        // Prepare next data deterministically
        val = val + 1;
        din <= val;
        wr_en <= 1;
        rd_en <= 0;
        @(posedge clk);
        wr_en <= 0;
        // Golden model accepts write when full was low at request
        golden_q.push_back(val);
        pushes++;
        ops++;
      end else begin
        wr_en <= 0;
        rd_en <= 0;
        @(posedge clk);
      end
      guard++;
    end

    // Continue pushes to reach full boundary
    guard = 0;
    while (!full && guard < 10000) begin
      if (!full) begin
        val = val + 1;
        din <= val;
        wr_en <= 1;
        rd_en <= 0;
        @(posedge clk);
        wr_en <= 0;
        golden_q.push_back(val);
        pushes++;
        ops++;
      end else begin
        wr_en <= 0;
        rd_en <= 0;
        @(posedge clk);
      end
      guard++;
    end
    wr_en <= 0;
    rd_en <= 0;

    // Phase B: Drain all to empty
    guard = 0;
    while (!empty && guard < 20000) begin
      if (!empty) begin
        wr_en <= 0;
        rd_en <= 1;
        // Issue pop request
        @(posedge clk);
        rd_en <= 0;
        // Sample data on the following posedge to avoid races
        @(posedge clk);
        if (golden_q.size() == 0) begin
          $display("Underflow: golden model empty during pop at t=%0t", $time);
          err_count++;
          $fatal(1, "Golden model underflow");
        end
        got = dout;
        exp = golden_q.pop_front();
        if (got !== exp) begin
          $display("Data mismatch: exp=%0h got=%0h t=%0t", exp, got, $time);
          err_count++;
          $fatal(1, "Data mismatch");
        end
        pops++;
        ops++;
      end else begin
        wr_en <= 0;
        rd_en <= 0;
        @(posedge clk);
      end
      guard++;
    end
    wr_en <= 0;
    rd_en <= 0;

    // Phase C: Mixed operations to cover almost_full/almost_empty transitions
    while (ops < NUM_TXNS) begin
      // Bias towards pushes when almost_empty, pops when almost_full
      if (!full && (almost_empty || (ops % 3 != 0))) begin
        val = val + 1;
        din <= val;
        wr_en <= 1;
        rd_en <= 0;
        @(posedge clk);
        wr_en <= 0;
        golden_q.push_back(val);
        pushes++;
        ops++;
      end else if (!empty) begin
        wr_en <= 0;
        rd_en <= 1;
        @(posedge clk);
        rd_en <= 0;
        @(posedge clk);
        if (golden_q.size() == 0) begin
          $display("Underflow during mixed pop at t=%0t", $time);
          err_count++;
          $fatal(1, "Underflow");
        end
        got = dout;
        exp = golden_q.pop_front();
        if (got !== exp) begin
          $display("Data mismatch (mixed): exp=%0h got=%0h t=%0t", exp, got, $time);
          err_count++;
          $fatal(1, "Data mismatch");
        end
        pops++;
        ops++;
      end else begin
        // Idle when neither legal push nor pop fits the bias
        wr_en <= 0;
        rd_en <= 0;
        @(posedge clk);
      end
    end

    // Phase D: Explicitly hit full and then drain to empty again
    guard = 0;
    while (!full && guard < 10000) begin
      if (!full) begin
        val = val + 1;
        din <= val;
        wr_en <= 1;
        rd_en <= 0;
        @(posedge clk);
        wr_en <= 0;
        golden_q.push_back(val);
        pushes++;
      end else begin
        wr_en <= 0;
        rd_en <= 0;
        @(posedge clk);
      end
      guard++;
    end
    wr_en <= 0;
    rd_en <= 0;

    guard = 0;
    while (!empty && guard < 20000) begin
      if (!empty) begin
        wr_en <= 0;
        rd_en <= 1;
        @(posedge clk);
        rd_en <= 0;
        @(posedge clk);
        if (golden_q.size() == 0) begin
          $display("Underflow during final drain at t=%0t", $time);
          err_count++;
          $fatal(1, "Underflow");
        end
        got = dout;
        exp = golden_q.pop_front();
        if (got !== exp) begin
          $display("Data mismatch (final drain): exp=%0h got=%0h t=%0t", exp, got, $time);
          err_count++;
          $fatal(1, "Data mismatch");
        end
        pops++;
      end else begin
        wr_en <= 0;
        rd_en <= 0;
        @(posedge clk);
      end
      guard++;
    end

    wr_en <= 0;
    rd_en <= 0;
    repeat (5) @(posedge clk);
    $finish;
  end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // EMIT_RESULTS
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
initial begin
    integer idle_cnt;
    idle_cnt = 0;
    // Wait for any activity before evaluating results
    wait (pushes > 0 || pops > 0);
    idle_cnt = 0;
    forever begin
      @(posedge clk);
      if (wr_en == 0 && rd_en == 0) begin
        idle_cnt = idle_cnt + 1;
        if (idle_cnt >= 5) begin
          if (err_count == 0 && pops > 0 && pushes > 0) begin
            $display("RESULT: PASS");            $finish;
          end else begin
            $display("RESULT: FAIL");
            $fatal(1);
          end
          ;
        end
      end else begin
        idle_cnt = 0;
      end
    end
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
