// tb_ddr_lite.sv — skeleton testbench for a simplified DDR (DDR-lite) controller
// Guarded with @LLM_EDIT blocks for localized LLM edits. Source-synchronous DQS, single-ended CK.

`timescale 1ns/1ps
module tb;

  // ------------------------------
  // Parameters (filled by your generator)
  // ------------------------------
  localparam int  DATA_W   = {{DATA_WIDTH}};               // e.g., 16 (per DQS group)
  localparam int  ADDR_W   = {{APP_ADDR_WIDTH}};           // app-side linear address
  localparam int  DQM_W    = (DATA_W/8>0)?(DATA_W/8):1;    // byte masks
  localparam int  ROW_W    = {{ROW_WIDTH}};
  localparam int  COL_W    = {{COL_WIDTH}};
  localparam int  BANK_W   = {{BANK_WIDTH}};
  localparam int  BL       = {{BURST_LENGTH}};             // 4 or 8 typical
  localparam int  CL       = {{CAS_LATENCY}};              // in cycles (CK)
  localparam int  AL       = {{ADDITIVE_LATENCY}};         // 0 if unused
  localparam real CK_MHZ   = {{CK_MHZ}};                   // memory clock (e.g., 100)
  localparam real CK_NS    = (1000.0 / CK_MHZ);

  int NUM_TXNS = {{NUM_TRANSACTIONS}};

  // ------------------------------
  // Derived timing (cycles). LLM uses precomputed values from context.timing_cycles
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_RCD_CYC;   // ACT -> RD/WR
  // int T_RP_CYC;    // PRE -> ACT
  // int T_RAS_CYC;   // ACT -> PRE min
  // int T_RC_CYC;    // ACT -> ACT (same bank)
  // int T_RRD_CYC;   // ACT to ACT (diff banks)
  // int T_WTR_CYC;   // WRITE-to-READ turnaround
  // int T_RTW_CYC;   // READ-to-WRITE turnaround
  // int T_WR_CYC;    // WRITE recovery before PRE
  // int T_RFC_CYC;   // REFRESH time
  // // CL, AL, BL provided as parameters
  // @LLM_EDIT END TIMING_CYCLES

  // ------------------------------
  // Clocks / Reset
  // ------------------------------
  logic ck   = 1'b0;
  logic rstn = 1'b0;
  always #(CK_NS/2.0) ck = ~ck;

  // ------------------------------
  // App-side interface (to DUT)
  // ------------------------------
  logic                 app_req;
  logic                 app_we;           // 1=write, 0=read
  logic [ADDR_W-1:0]    app_addr;
  logic [DATA_W-1:0]    app_wdata;
  logic [DQM_W-1:0]     app_dqm;          // per-byte write mask
  wire  [DATA_W-1:0]    app_rdata;
  wire                  app_rvalid;

  // ------------------------------
  // DDR device pins (DUT -> golden model)
  // ------------------------------
  wire                  cke;
  wire                  cs_n, ras_n, cas_n, we_n;
  wire [BANK_W-1:0]     ba;
  wire [ROW_W-1:0]      a_row;
  wire [COL_W-1:0]      a_col;
  wire [DQM_W-1:0]      dqm;

  // Data bus & strobes (source-synchronous)
  wire  [DATA_W-1:0]    dq_out;     // DUT drives during WR
  wire  [DATA_W-1:0]    dq_in;      // Device drives during RD
  wire                   dq_oe;      // output-enable for dq_out
  wire                   dqs_out;    // DUT drives DQS during WR
  wire                   dqs_in;     // Device drives DQS during RD
  wire                   dqs_oe;     // output-enable for dqs_out

  // ------------------------------
  // Instantiate DUT
  // ------------------------------
  ddr_lite_ctrl #(
    .DATA_W (DATA_W),
    .APP_AW (ADDR_W),
    .ROW_W  (ROW_W),
    .COL_W  (COL_W),
    .BANK_W (BANK_W),
    .BL     (BL),
    .CL     (CL),
    .AL     (AL)
  ) dut (
    .ck       (ck),
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
    .dq_oe    (dq_oe),
    .dqs_out  (dqs_out),
    .dqs_in   (dqs_in),
    .dqs_oe   (dqs_oe)
  );

  // ------------------------------
  // Golden DDR-lite model (device behavior incl. burst + DQS)
  // ------------------------------
  // Your generator injects a compact DDR-lite model that:
  //  * models bank/row state machine and command legality
  //  * enforces tRCD/tRP/tRAS/tRC/tRRD/tWTR/tRTW/tRFC
  //  * handles CL/AL/BL
  //  * uses dq_oe/dqs_oe to arbitrate bus ownership
  //  * drives dq_in/dqs_in on READs; samples dq_out on WRITEs at DQS edges
  {{INCLUDE_GOLDEN_DDR_LITE}}

  // ------------------------------
  // Optional assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/ddr_lite_protocol.svh"
  // ddr_lite_protocol_asrt #(.ROW_W(ROW_W), .COL_W(COL_W), .BANK_W(BANK_W)) chk (.*);

  // ------------------------------
  // Preload content (expand deterministically)
  // ------------------------------
  {{PRELOAD_SNIPPET}}

  // ------------------------------
  // Helpers
  // ------------------------------
  function automatic [ADDR_W-1:0] clamp_addr(input [ADDR_W-1:0] a);
    clamp_addr = a; // optionally constrain to spec.address_map
  endfunction

  // ------------------------------
  // Driver tasks (LLM fills app-level sequences)
  // ------------------------------

  // @LLM_EDIT BEGIN TASK_APP_WRITE
  // task automatic app_write(
  //   input  logic [ADDR_W-1:0] a,
  //   input  logic [DATA_W-1:0] d,
  //   input  logic [DQM_W-1:0]  m
  // );
  //   // Issue write request(s) at app interface.
  //   // Respect controller's documented req pacing; supply app_dqm for byte masks.
  // endtask
  // @LLM_EDIT END TASK_APP_WRITE

  // @LLM_EDIT BEGIN TASK_APP_READ
  // task automatic app_read(
  //   input  logic [ADDR_W-1:0] a,
  //   output logic [DATA_W-1:0] q
  // );
  //   // Issue read request(s); wait for app_rvalid after (AL + CL) cycles (controller-dependent).
  //   // Capture first beat of app_rdata into q.
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
  //  - bank/row conflicts (tRCD/tRP/tRAS)
  //  - W->R and R->W turnarounds (tWTR/tRTW)
  //  - bursts across boundaries (BL), masks via DQM
  // ------------------------------
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   app_req=0; app_we=0; app_addr='0; app_wdata='0; app_dqm='0;
  //   repeat (8) @(posedge ck);
  //   rstn <= 1;
  //
  //   for (int i=0; i<NUM_TXNS; i++) begin
  //     logic [ADDR_W-1:0] a = clamp_addr($urandom);
  //     logic [DATA_W-1:0] d = $urandom;
  //     logic [DQM_W-1:0]  m = '0; // vary masks
  //     app_write(a, d, m);
  //     app_read(a, got_q);
  //     exp_q = d; // golden model should mirror masked writes
  //     check_eq(exp_q, got_q, a);
  //     txn_count++;
  //   end
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // EMIT_RESULTS
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
