// tb_sram_async.sv — skeleton testbench for a basic async SRAM controller
// Compatible with Verilator/Icarus and the GuardedEditEngine (@LLM_EDIT regions)

`timescale 1ns/1ps

module tb;

  // ------------------------------
  // Parameters (filled deterministically by your generator)
  // ------------------------------
  localparam int  DATA_W = {{DATA_WIDTH}};          // e.g., 16
  localparam int  ADDR_W = {{ADDR_WIDTH}};          // e.g., 18
  localparam bit  LITTLE_ENDIAN = {{ENDIAN_IS_LITTLE}}; // 1 for little, 0 for big
  localparam real CLK_MHZ = {{CLK_MHZ}};            // e.g., 100
  localparam real CLK_NS  = (1000.0 / CLK_MHZ);

  // Transaction knobs
  int NUM_TXNS = {{NUM_TRANSACTIONS}};              // e.g., 200
  localparam int BE_W = (DATA_W/8 > 0) ? (DATA_W/8) : 1;

  // ------------------------------
  // Derived timing in cycles (LLM fills ints using 'timing_cycles' from context)
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_AA_CYC; // address access time cycles
  // int T_OE_CYC; // output enable access time cycles
  // int T_WC_CYC; // write cycle time cycles
  // int T_WP_CYC; // write pulse width cycles
  // int T_DW_CYC; // data valid to end of write cycles
  // int T_DH_CYC; // data hold from end of write cycles
  // @LLM_EDIT END TIMING_CYCLES

  // ------------------------------
  // Clk/Reset
  // ------------------------------
  logic clk = 1'b0;
  logic rstn = 1'b0;

  always #(CLK_NS/2.0) clk = ~clk;

  // ------------------------------
  // DUT <-> SRAM device pins (basic async bus)
  // ------------------------------
  logic                  cs_n;
  logic                  we_n;
  logic                  oe_n;
  logic [ADDR_W-1:0]     addr;
  logic [DATA_W-1:0]     wdata;
  wire  [DATA_W-1:0]     rdata;
  logic [BE_W-1:0]       be;

  // ------------------------------
  // Instantiate DUT (teammate’s controller)
  // ------------------------------
  // Adjust module name/params to your controller under test.
  sram_ctrl #(
    .DATA_W (DATA_W),
    .ADDR_W (ADDR_W)
  ) dut (
    .clk   (clk),
    .rstn  (rstn),
    .cs_n  (cs_n),
    .we_n  (we_n),
    .oe_n  (oe_n),
    .addr  (addr),
    .wdata (wdata),
    .rdata (rdata),
    .be    (be)
  );

  // ------------------------------
  // Golden SRAM device model (connected to same pins)
  // ------------------------------
  // Your generator substitutes a small behavioral model here.
  // It should implement byte-enable aware storage and rdata driving.
  {{INCLUDE_GOLDEN_SRAM}}

  // ------------------------------
  // Optional monitors/assertions (can be empty at first)
  // ------------------------------
  // `include "libraries/svassert/sram_protocol.svh"
  // sram_protocol_asrt #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) chk (.*);

  // ------------------------------
  // Preload regions / init patterns (expanded deterministically)
  // ------------------------------
  {{PRELOAD_SNIPPET}}

  // ------------------------------
  // Helper: byte-pack/unpack respecting endianness
  // ------------------------------
  function automatic [DATA_W-1:0] pack_bytes(input logic [7:0] B[BE_W]);
    int i;
    pack_bytes = '0;
    for (i = 0; i < BE_W; i++) begin
      if (LITTLE_ENDIAN) begin
        pack_bytes[i*8 +: 8] = B[i];
      end else begin
        pack_bytes[(BE_W-1-i)*8 +: 8] = B[i];
      end
    end
  endfunction

  // ------------------------------
  // Driver tasks (LLM fills legal timing sequences)
  // ------------------------------

  // @LLM_EDIT BEGIN TASK_DO_WRITE
  // task automatic do_write(
  //   input  logic [ADDR_W-1:0] a,
  //   input  logic [DATA_W-1:0] d,
  //   input  logic [BE_W-1:0]   ben
  // );
  //   // Drive a legal async SRAM write honoring T_WP_CYC/T_WC_CYC/T_DW_CYC/T_DH_CYC.
  //   // Use 'be' to mask bytes; wdata holds full DATA_W.
  // endtask
  // @LLM_EDIT END TASK_DO_WRITE

  // @LLM_EDIT BEGIN TASK_DO_READ
  // task automatic do_read(
  //   input  logic [ADDR_W-1:0] a,
  //   output logic [DATA_W-1:0] q
  // );
  //   // Drive a legal async SRAM read honoring T_AA_CYC/T_OE_CYC.
  //   // Capture 'rdata' into q after required latency.
  // endtask
  // @LLM_EDIT END TASK_DO_READ

  // ------------------------------
  // Scoreboard / simple reference compare
  // ------------------------------
  logic [DATA_W-1:0] exp_q;
  logic [DATA_W-1:0] got_q;
  int                err_count = 0;
  int                txn_count = 0;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got, input [ADDR_W-1:0] a);
    if (exp !== got) begin
      $error("[TB][MISMATCH] addr=0x%0h exp=0x%0h got=0x%0h", a, exp, got);
      err_count++;
    end
  endtask

  // ------------------------------
  // Main scenario (LLM fills constrained stimulus over address_map/BE patterns)
  // ------------------------------
  // The LLM should:
  //  - iterate NUM_TXNS,
  //  - choose legal addresses within spec.address_map regions,
  //  - exercise various 'be' masks,
  //  - perform write then read-after-write,
  //  - update/read from the golden model implicitly via shared pins,
  //  - compare 'got_q' vs 'exp_q' using check_eq.
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   cs_n  = 1; we_n = 1; oe_n = 1;
  //   be    = '0; addr = '0; wdata = '0;
  //   repeat (5) @(posedge clk);
  //   rstn <= 1;
  //
  //   // Example skeleton loop (LLM may replace/refine content inside this region):
  //   for (int i = 0; i < NUM_TXNS; i++) begin
  //     logic [ADDR_W-1:0] a;
  //     logic [DATA_W-1:0] d;
  //     logic [BE_W-1:0]   ben;
  //     // choose a, d, ben within constraints...
  //     do_write(a, d, ben);
  //     do_read(a, got_q);
  //     exp_q = d; // For a simple behavioral memory w/o wait states.
  //     check_eq(exp_q, got_q, a);
  //     txn_count++;
  //   end
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // Result emission (machine-readable for runner)
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
  // final begin
  //   if (err_count == 0 && txn_count >= NUM_TXNS) begin
  //     $display("RESULT: PASS");
  //   end else begin
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
