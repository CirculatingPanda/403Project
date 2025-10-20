// tb_ddr2.sv — skeleton testbench for DDR2 SDRAM (adds ODT, posted CAS via AL, stricter timings)
// Guarded with @LLM_EDIT blocks; app-side requests, DUT drives DDR2 pins.

`timescale 1ns/1ps
module tb;

  // ---------------- Params (filled by generator) ----------------
  localparam int  DATA_W   = {{DATA_WIDTH}};
  localparam int  ADDR_W   = {{APP_ADDR_WIDTH}};
  localparam int  DQM_W    = (DATA_W/8>0)?(DATA_W/8):1;
  localparam int  ROW_W    = {{ROW_WIDTH}};
  localparam int  COL_W    = {{COL_WIDTH}};
  localparam int  BANK_W   = {{BANK_WIDTH}};
  localparam int  BL       = {{BURST_LENGTH}};             // 4 or 8 typical
  localparam int  CL       = {{CAS_LATENCY}};              // CKs
  localparam int  AL       = {{ADDITIVE_LATENCY}};         // posted CAS (0..CL)
  localparam real CK_MHZ   = {{CK_MHZ}};                   // e.g., 200
  localparam real CK_NS    = (1000.0/CK_MHZ);
  int NUM_TXNS = {{NUM_TRANSACTIONS}};

  // ------------- Derived timing in cycles (LLM uses provided ints) -------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
  // int T_RCD_CYC;   // ACT -> RD/WR
  // int T_RP_CYC;    // PRE -> ACT
  // int T_RAS_CYC;   // ACT -> PRE min
  // int T_RC_CYC;    // ACT -> ACT same bank
  // int T_RRD_CYC;   // ACT to ACT diff banks
  // int T_WR_CYC;    // WRITE recovery before PRE
  // int T_WTR_CYC;   // WRITE-to-READ turn
  // int T_RTW_CYC;   // READ-to-WRITE turn
  // int T_RFC_CYC;   // REFRESH
  // int T_CCD_CYC;   // RD/RD or WR/WR spacing
  // int T_RTP_CYC;   // READ to PRECHARGE
  // int T_ODT_ON_CYC;  // ODT enable/setup before WR
  // int T_ODT_OFF_CYC; // ODT hold/off after WR
  // // CL, AL, BL provided above
  // @LLM_EDIT END TIMING_CYCLES

  // ---------------- Clocks / Reset ----------------
  logic ck = 1'b0; logic rstn = 1'b0;
  always #(CK_NS/2.0) ck = ~ck;

  // ---------------- App-side interface ----------------
  logic                 app_req, app_we;
  logic [ADDR_W-1:0]    app_addr;
  logic [DATA_W-1:0]    app_wdata;
  logic [DQM_W-1:0]     app_dqm;
  wire  [DATA_W-1:0]    app_rdata;
  wire                  app_rvalid;

  // ---------------- DDR2 device pins ----------------
  wire                  cke;
  wire                  cs_n, ras_n, cas_n, we_n;
  wire [BANK_W-1:0]     ba;
  wire [ROW_W-1:0]      a_row;
  wire [COL_W-1:0]      a_col;
  wire [DQM_W-1:0]      dqm;
  wire                  odt;                 // **DDR2 adds ODT**

  // Data bus & strobes
  wire [DATA_W-1:0]     dq_out, dq_in; wire dq_oe;
  wire                  dqs_out, dqs_in;  wire dqs_oe;

  // ---------------- DUT ----------------
  ddr2_ctrl #(
    .DATA_W(DATA_W), .APP_AW(ADDR_W), .ROW_W(ROW_W), .COL_W(COL_W), .BANK_W(BANK_W),
    .BL(BL), .CL(CL), .AL(AL)
  ) dut (
    .ck(ck), .rstn(rstn),
    // app
    .app_req(app_req), .app_we(app_we), .app_addr(app_addr),
    .app_wdata(app_wdata), .app_dqm(app_dqm), .app_rdata(app_rdata), .app_rvalid(app_rvalid),
    // device
    .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a_row(a_row), .a_col(a_col), .dqm(dqm),
    .odt(odt),
    .dq_out(dq_out), .dq_in(dq_in), .dq_oe(dq_oe),
    .dqs_out(dqs_out), .dqs_in(dqs_in), .dqs_oe(dqs_oe)
  );

  // ---------------- Golden DDR2 model ----------------
  // Enforce DDR2 nuances:
  //  - Posted CAS via AL (effective read latency = AL+CL)
  //  - ODT behavior required during WR (tODTon/tODToff windows)
  //  - Command legality & timing as in DDR, with DDR2-specific constraints
  //  - DQS/DQ alignment on both edges; burst BL; mask via DQM
  {{INCLUDE_GOLDEN_DDR2}}

  // ---------------- Optional assertions ----------------
  // `include "libraries/svassert/ddr2_protocol.svh"
  // ddr2_protocol_asrt #(.ROW_W(ROW_W), .COL_W(COL_W), .BANK_W(BANK_W)) chk (.*);

  // ---------------- Preload content ----------------
  {{PRELOAD_SNIPPET}}

  // ---------------- Driver tasks (LLM fills) ----------------
  // @LLM_EDIT BEGIN TASK_APP_WRITE
  // task automatic app_write(input logic [ADDR_W-1:0] a, input logic [DATA_W-1:0] d, input logic [DQM_W-1:0] m);
  //   // Assert app_req/app_we; ensure ODT is enabled sufficiently early (T_ODT_ON_CYC),
  //   // respect controller pacing; provide app_dqm=m; allow write recovery (T_WR_CYC) before precharge.
  // endtask
  // @LLM_EDIT END TASK_APP_WRITE

  // @LLM_EDIT BEGIN TASK_APP_READ
  // task automatic app_read(input logic [ADDR_W-1:0] a, output logic [DATA_W-1:0] q);
  //   // Issue read; wait for app_rvalid after (AL+CL); capture first beat of app_rdata.
  //   // Respect tWTR/tRTW when mixing operations.
  // endtask
  // @LLM_EDIT END TASK_APP_READ

  // ---------------- Scoreboard ----------------
  int err_count=0, txn_count=0; logic [DATA_W-1:0] got_q, exp_q;
  task automatic check_eq(input [DATA_W-1:0] e, input [DATA_W-1:0] g, input [ADDR_W-1:0] a);
    if (e !== g) begin $error("[TB][MISMATCH] a=0x%0h exp=0x%0h got=0x%0h", a, e, g); err_count++; end
  endtask

  // ---------------- Main scenario (LLM fills) ----------------
  // Cover: ODT windows on writes, posted CAS (AL), tWTR/tRTW, tRTP, bank conflicts, masks.
  // @LLM_EDIT BEGIN MAIN_SCENARIO
  // initial begin
  //   app_req=0; app_we=0; app_addr='0; app_wdata='0; app_dqm='0;
  //   repeat (10) @(posedge ck); rstn<=1;
  //   for (int i=0;i<NUM_TXNS;i++) begin
  //     logic [ADDR_W-1:0] a = $urandom;
  //     logic [DATA_W-1:0] d = $urandom;
  //     logic [DQM_W-1:0]  m = '0;
  //     app_write(a,d,m);
  //     app_read(a,got_q);
  //     exp_q = d; check_eq(exp_q,got_q,a);
  //     txn_count++;
  //   end
  // end
  // @LLM_EDIT END MAIN_SCENARIO

  // ---------------- Emit results ----------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
  // final begin
  //   if (err_count==0 && txn_count>=NUM_TXNS) $display("RESULT: PASS");
  //   else begin $display("RESULT: FAIL"); $fatal(1); end
  // end
  // @LLM_EDIT END EMIT_RESULTS

  // Waves (optional)
  initial if ($test$plusargs("dumpon")) begin $dumpfile("tb.vcd"); $dumpvars(0,tb); end

endmodule
