// tb_rom_async.sv — skeleton testbench for a basic async ROM controller
// Reuses GuardedEditEngine @LLM_EDIT regions like the SRAM template, but read-only.

`timescale 1ns/1ps

module tb;

  // ------------------------------
  // Parameters (filled deterministically by your generator)
  // ------------------------------
  localparam int  DATA_W = {{DATA_WIDTH}};             // e.g., 16
  localparam int  ADDR_W = {{ADDR_WIDTH}};             // e.g., 18
  localparam bit  LITTLE_ENDIAN = {{ENDIAN_IS_LITTLE}};// 1 for little, 0 for big
  localparam real CLK_MHZ = {{CLK_MHZ}};               // e.g., 100
  localparam real CLK_NS  = (1000.0 / CLK_MHZ);

  // Transactions
  int NUM_TXNS = {{NUM_TRANSACTIONS}};                 // e.g., 200

  // ------------------------------
  // Derived timing in cycles (LLM fills from context.timing_cycles)
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_AA_CYC; // address access time cycles (ns -> cycles)
  // int T_OE_CYC; // output enable access time cycles
  // @LLM_EDIT END TIMING_CYCLES

  // ------------------------------
  // Clk/Reset
  // ------------------------------
  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #(CLK_NS/2.0) clk = ~clk;

  // ------------------------------
  // DUT <-> ROM device pins (basic async read bus)
  // ------------------------------
  logic                  cs_n;
  logic                  oe_n;
  logic [ADDR_W-1:0]     addr;
  wire  [DATA_W-1:0]     rdata;

  // ------------------------------
  // Instantiate DUT (teammate’s ROM controller)
  // ------------------------------
  rom_ctrl #(
    .DATA_W (DATA_W),
    .ADDR_W (ADDR_W)
  ) dut (
    .clk   (clk),
    .rstn  (rstn),
    .cs_n  (cs_n),
    .oe_n  (oe_n),
    .addr  (addr),
    .rdata (rdata)
  );

  // ------------------------------
  // Golden ROM device model (connected to the same pins)
  // ------------------------------
  // Your generator substitutes a tiny read-only model here.
  // It should implement access latency per timing, drive rdata properly,
  // and support preloading content from the spec.
  {{INCLUDE_GOLDEN_ROM}}

  // ------------------------------
  // Optional monitors/assertions
  // ------------------------------
  // `include "libraries/svassert/rom_protocol.svh"
  // rom_protocol_asrt #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) chk (.*);

  // ------------------------------
  // Preload regions / init patterns (expanded deterministically)
  // ------------------------------
  // For ROM, this typically loads content into the golden model only.
  {{PRELOAD_SNIPPET}}

  // ------------------------------
  // Helper: endianness-aware pack (for assembling expected words from bytes)
  // ------------------------------
  function automatic [DATA_W-1:0] pack_bytes(input logic [7:0] B[(DATA_W/8>0)?(DATA_W/8):1]);
    const int BE_W = (DATA_W/8>0)?(DATA_W/8):1;
    int i;
    pack_bytes = '0;
    for (i = 0; i < BE_W; i++) begin
      if (LITTLE_ENDIAN) pack_bytes[i*8 +: 8] = B[i];
      else               pack_bytes[(BE_W-1-i)*8 +: 8] = B[i];
    end
  endfunction

  // ------------------------------
  // Driver task (LLM fills legal timing sequences for read)
  // ------------------------------
  // @LLM_EDIT BEGIN TASK_DO_READ
  // task automatic do_read(
  //   input  logic [ADDR_W-1:0] a,
  //   output logic [DATA_W-1:0] q
  // );
  //   // Drive legal async ROM read honoring T_AA_CYC/T_OE_CYC.
  //   // Sequence example:
  //   //   set addr, assert cs_n=0, optionally toggle oe_n, wait required cycles,
  //   //   sample rdata into q.
  // endtask
  // @LLM_EDIT END TASK_DO_READ

  // ------------------------------
  // Scoreboard / compare vs golden model
  // ------------------------------
  logic [DATA_W-1:0] got_q;
  logic [DATA_W-1:0] exp_q;
  int                err_count = 0;
  int                txn_count = 0;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got, input [ADDR_W-1:0] a);
    if (exp !== got) begin
      $error("[TB][MISMATCH] addr=0x%0h exp=0x%0h got=0x%0h", a, exp, got);
      err_count++;
    end
  endtask

  // ------------------------------
  // MAIN_SCENARIO (LLM fills constrained read stimulus)
  // ------------------------------
  // The LLM should:
  //  - iterate NUM_TXNS,
  //  - choose legal addresses within spec.address_map regions,
  //  - read from the ROM, compare with golden model's contents,
  //  - no writes, no modification of ROM state.
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   cs_n = 1; oe_n = 1; addr = '0;
  //   repeat (5) @(posedge clk);
  //   rstn <= 1;
  //
  //   for (int i = 0; i < NUM_TXNS; i++) begin
  //     logic [ADDR_W-1:0] a;
  //     // choose a within allowed address_map regions...
  //     do_read(a, got_q);
  //     // exp_q should be what the golden model provides at address 'a'
  //     // (either sample a mirrored output or recompute from preload pattern).
  //     // Compare:
  //     check_eq(exp_q, got_q, a);
  //     txn_count++;
  //   end
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // EMIT_RESULTS (machine-readable for runner)
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
  // final begin
  //   if (err_count == 0 && txn_count >= NUM_TXNS) $display("RESULT: PASS");
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
