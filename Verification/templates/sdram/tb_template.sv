// tb_sdram.sv — skeleton testbench for a basic single-data-rate SDRAM controller
// Guarded with @LLM_EDIT blocks for localized LLM edits.
// App-side TB drives requests; DUT drives SDRAM device pins into a golden model.

`timescale 1ns/1ps
module tb;

  // ------------------------------
  // Parameters (filled by your generator)
  // ------------------------------
  localparam int  DATA_W = {{DATA_WIDTH}};                // e.g., 16
  localparam int  ADDR_W = {{APP_ADDR_WIDTH}};            // app-side linear address width
  localparam int  DQM_W  = (DATA_W/8>0)?(DATA_W/8):1;     // byte masks on device side
  localparam int  ROW_W  = {{ROW_WIDTH}};                 // device geometry
  localparam int  COL_W  = {{COL_WIDTH}};
  localparam int  BANK_W = {{BANK_WIDTH}};
  localparam int  BL     = {{BURST_LENGTH}};              // e.g., 4 or 8
  localparam int  CL     = {{CAS_LATENCY}};               // in cycles
  localparam real CLK_MHZ = {{CLK_MHZ}};                  // SDRAM clock (e.g., 100)
  localparam real CLK_NS  = (1000.0/CLK_MHZ);

  int NUM_TXNS = {{NUM_TRANSACTIONS}};                    // number of app-level ops

  // ------------------------------
  // Derived timing in cycles (LLM uses values already computed in context)
  // Typical SDRAM: tRCD, tRP, tRAS, tRC, tRFC, tMRD, tWR, CL, BL, tCCD, tRRD
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_RCD_CYC;  // ACT -> READ/WRITE
  // int T_RP_CYC;   // PRECHARGE -> next ACT
  // int T_RAS_CYC;  // ACT -> PRECHARGE min
  // int T_RC_CYC;   // ACT -> ACT same bank
  // int T_RFC_CYC;  // AUTO REFRESH cycle
  // int T_MRD_CYC;  // MODE REGISTER SET cycle
  // int T_WR_CYC;   // WRITE recovery before PRECHARGE
  // int T_CCD_CYC;  // READ/WRITE command spacing
  // int T_RRD_CYC;  // ACT to ACT different banks
  // // CL and BL are provided (CL, BL)
  // @LLM_EDIT END TIMING_CYCLES

  // ------------------------------
  // Clock / Reset
  // ------------------------------
  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #(CLK_NS/2.0) clk = ~clk;

  // ------------------------------
  // App-side interface (to DUT)
  // ------------------------------
  logic                 app_req;     // pulse or level, per DUT
  logic                 app_we;      // 1=write, 0=read
  logic [ADDR_W-1:0]    app_addr;    // linear address (controller maps to row/col/bank)
  logic [DATA_W-1:0]    app_wdata;
  logic [DQM_W-1:0]     app_dqm;     // optional: per-byte write mask
  wire  [DATA_W-1:0]    app_rdata;
  wire                  app_rvalid;  // asserted when read data is valid

  // ------------------------------
  // SDRAM device pins (driven by DUT to golden model)
  // ------------------------------
  wire                  cke;
  wire                  cs_n, ras_n, cas_n, we_n;
  wire [BANK_W-1:0]     ba;
  wire [ROW_W-1:0]      a_row;       // row/command/mode bits
  wire [COL_W-1:0]      a_col;       // column when used
  wire [DQM_W-1:0]      dqm;
  wire [DATA_W-1:0]     dq_out;      // from DUT to device (write)
  wire [DATA_W-1:0]     dq_in;       // from device to DUT (read)
  wire                  dq_oe;       // DUT drives dq when 1

  // ------------------------------
  // Instantiate DUT (controller under test)
  // ------------------------------
  sdram_ctrl #(
    .DATA_W (DATA_W),
    .APP_AW (ADDR_W),
    .ROW_W  (ROW_W),
    .COL_W  (COL_W),
    .BANK_W (BANK_W),
    .BL     (BL),
    .CL     (CL)
  ) dut (
    .clk      (clk),
    .rstn     (rstn),
    // app side
    .app_req  (app_req),
    .app_we   (app_we),
    .app_addr (app_addr),
    .app_wdata(app_wdata),
    .app_dqm  (app_dqm),
    .app_rdata(app_rdata),
    .app_rvalid(app_rvalid),
    // device side
    .cke      (cke),
    .cs_n     (cs_n),
    .ras_n    (ras_n),
    .cas_n    (cas_n),
    .we_n     (we_n),
    .ba       (ba),
    .a_row    (a_row),
    .a_col    (a_col),
    .dqm      (dqm),
    .dq_out   (dq_out),
    .dq_in    (dq_in),
    .dq_oe    (dq_oe)
  );

  // ------------------------------
  // Golden SDRAM device model (pin-accurate-ish, simplified timing)
  // ------------------------------
  // Your generator substitutes a compact SDRAM behavioral model and the dq bus hookup.
  // The model should:
  //  - Support INIT (CKE low, PRECHARGE ALL, MRS)
  //  - Enforce tRCD/tRP/tRAS/tRC/tRFC/tWR/tMRD/CL/BL
  //  - Provide dq_in data with CL latency on READ bursts and accept dq_out on WRITE bursts
  //  - Honor DQM byte masks
  {{INCLUDE_GOLDEN_SDRAM}}

  // ------------------------------
  // Optional protocol assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/sdram_protocol.svh"
  // sdram_protocol_asrt #(.ROW_W(ROW_W), .COL_W(COL_W), .BANK_W(BANK_W)) chk (.*);

  // ------------------------------
  // Preload content / address map helpers (deterministic expansion)
  // Typically preloads memory array inside the golden model.
  // ------------------------------
  {{PRELOAD_SNIPPET}}

  // ------------------------------
  // Helpers
  // ------------------------------
  function automatic [ADDR_W-1:0] clamp_addr(input [ADDR_W-1:0] a);
    // If you provide an address_map in the spec, your generator can constrain ranges.
    clamp_addr = a;
  endfunction

  // ------------------------------
  // Driver tasks (LLM fills legal app-level sequences)
  // The DUT handles bank/row/col timing; TB just issues app requests and checks data.
  // ------------------------------

  // @LLM_EDIT BEGIN TASK_APP_WRITE
  // task automatic app_write(
  //   input  logic [ADDR_W-1:0] a,
  //   input  logic [DATA_W-1:0] d,
  //   input  logic [DQM_W-1:0]  m
  // );
  //   // Drive a legal app-side write transaction (single-beat or one-burst),
  //   // respecting any documented gaps the controller needs between requests.
  //   // Apply 'app_dqm' for masked writes; the golden model must mirror masks.
  // endtask
  // @LLM_EDIT END TASK_APP_WRITE

  // @LLM_EDIT BEGIN TASK_APP_READ
  // task automatic app_read(
  //   input  logic [ADDR_W-1:0] a,
  //   output logic [DATA_W-1:0] q
  // );
  //   // Issue an app-side read; wait for app_rvalid according to controller latency.
  //   // Capture app_rdata into q. If the controller bursts, capture the first beat.
  // endtask
  // @LLM_EDIT END TASK_APP_READ

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
  // MAIN_SCENARIO (LLM composes constrained traffic)
  // Cover:
  //  - different banks/rows to exercise ACT/PRE/READ/WRITE scheduling
  //  - back-to-back reads (tCCD), write->precharge (tWR), refresh pauses (tRFC)
  //  - byte masks via DQM, burst boundaries, min/max addresses
  // ------------------------------
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   app_req=0; app_we=0; app_addr='0; app_wdata='0; app_dqm='0;
  //   repeat (8) @(posedge clk);
  //   rstn <= 1;
  //
  //   for (int i=0; i<NUM_TXNS; i++) begin
  //     logic [ADDR_W-1:0] a = clamp_addr($urandom);
  //     logic [DATA_W-1:0] d = $urandom;
  //     logic [DQM_W-1:0]  m = '0; // vary masks
  //     app_write(a, d, m);
  //     app_read(a, got_q);
  //     exp_q = d; // golden model should reflect masked writes if m!=0
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
