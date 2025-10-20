// tb_sram_sync.sv — skeleton testbench for a basic *synchronous* SRAM controller
// Guarded with @LLM_EDIT blocks for localized LLM edits.

`timescale 1ns/1ps
module tb;

  // ------------------------------
  // Parameters (filled by your generator)
  // ------------------------------
  localparam int  DATA_W = {{DATA_WIDTH}};              // e.g., 32
  localparam int  ADDR_W = {{ADDR_WIDTH}};              // e.g., 18
  localparam int  BE_W   = (DATA_W/8>0)?(DATA_W/8):1;
  localparam bit  LITTLE_ENDIAN = {{ENDIAN_IS_LITTLE}}; // 1 little, 0 big
  localparam real CLK_MHZ = {{CLK_MHZ}};                // e.g., 100
  localparam real CLK_NS  = (1000.0/CLK_MHZ);
  int NUM_TXNS = {{NUM_TRANSACTIONS}};                  // e.g., 200

  // ------------------------------
  // Derived timing in cycles (LLM fills from context.timing_cycles)
  // Common sync knobs: read/write latency, min gaps, setup/hold in cycles, etc.
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_RD_LAT_CYC;  // cycles from read request to valid rdata
  // int T_WR_LAT_CYC;  // cycles until write is committed (if modeled)
  // int T_SETUP_CYC;   // addr/data/setup cycles (if DUT requires explicit wait)
  // int T_HOLD_CYC;    // hold cycles after enable
  // int T_GAP_CYC;     // min idle cycles between ops
  // @LLM_EDIT END TIMING_CYCLES

  // ------------------------------
  // Clock / Reset
  // ------------------------------
  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #(CLK_NS/2.0) clk = ~clk;

  // ------------------------------
  // DUT I/O (typical sync SRAM bus)
  // ------------------------------
  logic                 req;     // request/enable
  logic                 we;      // 1=write, 0=read
  logic [ADDR_W-1:0]    addr;
  logic [DATA_W-1:0]    wdata;
  logic [BE_W-1:0]      be;
  wire  [DATA_W-1:0]    rdata;
  wire                  rvalid;  // read-data valid (or ready)

  // ------------------------------
  // Instantiate DUT (teammate’s controller)
  // ------------------------------
  sram_sync_ctrl #(
    .DATA_W (DATA_W),
    .ADDR_W (ADDR_W)
  ) dut (
    .clk    (clk),
    .rstn   (rstn),
    .req    (req),
    .we     (we),
    .addr   (addr),
    .wdata  (wdata),
    .be     (be),
    .rdata  (rdata),
    .rvalid (rvalid)
  );

  // ------------------------------
  // Golden model (synchronous, byte-enable aware, same latency)
  // ------------------------------
  {{INCLUDE_GOLDEN_SRAM_SYNC}}

  // ------------------------------
  // Optional assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/sram_sync_protocol.svh"
  // sram_sync_protocol_asrt #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) chk (.*);

  // ------------------------------
  // Preload / init content (deterministic expansion)
  // ------------------------------
  {{PRELOAD_SNIPPET}}

  // ------------------------------
  // Endianness helpers
  // ------------------------------
  function automatic [DATA_W-1:0] pack_bytes(input logic [7:0] B[BE_W]);
    int i; pack_bytes = '0;
    for (i=0;i<BE_W;i++) begin
      if (LITTLE_ENDIAN) pack_bytes[i*8 +: 8] = B[i];
      else               pack_bytes[(BE_W-1-i)*8 +: 8] = B[i];
    end
  endfunction

  // ------------------------------
  // Driver tasks (LLM fills legal synchronous sequences)
  // ------------------------------
  // @LLM_EDIT BEGIN TASK_DO_WRITE
  // task automatic do_write(
  //   input  logic [ADDR_W-1:0] a,
  //   input  logic [DATA_W-1:0] d,
  //   input  logic [BE_W-1:0]   ben
  // );
  //   // Example shape (refine per DUT):
  //   //   wait reset deasserted;
  //   //   apply addr/d/wdata/be; set we=1; pulse req respecting T_SETUP_CYC;
  //   //   hold as needed, then deassert; wait T_WR_LAT_CYC & optional T_GAP_CYC.
  // endtask
  // @LLM_EDIT END TASK_DO_WRITE

  // @LLM_EDIT BEGIN TASK_DO_READ
  // task automatic do_read(
  //   input  logic [ADDR_W-1:0] a,
  //   output logic [DATA_W-1:0] q
  // );
  //   // Example shape (refine per DUT):
  //   //   set we=0; drive addr; pulse req; wait T_RD_LAT_CYC;
  //   //   optionally wait for rvalid; sample rdata into q; respect T_GAP_CYC.
  // endtask
  // @LLM_EDIT END TASK_DO_READ

  // ------------------------------
  // Scoreboard
  // ------------------------------
  int                err_count = 0;
  int                txn_count = 0;
  logic [DATA_W-1:0] got_q, exp_q;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got, input [ADDR_W-1:0] a);
    if (exp !== got) begin
      $error("[TB][MISMATCH] addr=0x%0h exp=0x%0h got=0x%0h", a, exp, got);
      err_count++;
    end
  endtask

  // ------------------------------
  // Main scenario (LLM fills constrained traffic)
  // ------------------------------
  // Exercise:
  //  - write/read-after-write same address,
  //  - byte-enable patterns,
  //  - min/max addresses in address_map,
  //  - bursts with T_GAP_CYC spacing,
  //  - corner cases (be=0, single-byte, all-bytes).
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   req=0; we=0; addr='0; wdata='0; be='0;
  //   repeat (5) @(posedge clk);
  //   rstn <= 1;
  //
  //   for (int i=0; i<NUM_TXNS; i++) begin
  //     logic [ADDR_W-1:0] a;
  //     logic [DATA_W-1:0] d;
  //     logic [BE_W-1:0]   ben;
  //     // choose a/d/ben within spec.address_map ...
  //     do_write(a, d, ben);
  //     do_read(a, got_q);
  //     exp_q = d; // golden model mirrors the commit semantics
  //     check_eq(exp_q, got_q, a);
  //     txn_count++;
  //   end
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // Emit machine-readable result
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
