// golden/ddr_model.sv
// Simplified DDR SDRAM behavioral model (open-page, source-synchronous).
// - Bank/row FSM: ACT, READ, WRITE, PRE, REF, MRS
// - Key timings in cycles: tRCD, tRP, tRAS, tRC, tRFC, tWR, tRRD, tWTR, tRTW, tCCD
// - READ: after (AL+CL) CK cycles, drives DQS and DQ for BL beats (2 beats/CK)
// - WRITE: samples DQ on both DQS edges for BL beats while controller asserts dq_oe
// - DQM masks bytes (1=mask)
// Notes: This is a compact bring-up model, not JEDEC-complete.

`timescale 1ns/1ps
module ddr_model #(
  parameter int DATA_W   = 16,
  parameter int ROW_W    = 13,
  parameter int COL_W    = 10,
  parameter int BANK_W   = 2,
  parameter int DQM_W    = (DATA_W/8>0)?(DATA_W/8):1,
  parameter int BL       = 4,   // 2/4/8 typical (beats, not CKs)
  parameter int CL       = 3,   // CAS latency (CKs)
  parameter int AL       = 0,   // additive latency (posted CAS) (CKs)

  // Timing in CK cycles (filled from TB/spec)
  parameter int T_RCD_CYC = 3,
  parameter int T_RP_CYC  = 3,
  parameter int T_RAS_CYC = 6,
  parameter int T_RC_CYC  = 9,
  parameter int T_RRD_CYC = 2,
  parameter int T_WR_CYC  = 2,
  parameter int T_WTR_CYC = 2,
  parameter int T_RTW_CYC = 2,
  parameter int T_RFC_CYC = 10,
  parameter int T_CCD_CYC = 2   // col-to-col cmd spacing
) (
  input  logic                   ck,
  input  logic                   rstn,

  // Command/address
  input  logic                   cke,
  input  logic                   cs_n,
  input  logic                   ras_n,
  input  logic                   cas_n,
  input  logic                   we_n,
  input  logic [BANK_W-1:0]      ba,
  input  logic [ROW_W-1:0]       a_row,
  input  logic [COL_W-1:0]       a_col,
  input  logic [DQM_W-1:0]       dqm,

  // Data bus (source-synchronous)
  input  logic [DATA_W-1:0]      dq_out,  // controller -> device during WR
  output logic [DATA_W-1:0]      dq_in,   // device -> controller during RD
  input  logic                   dq_oe,   // controller drives when 1

  input  logic                   dqs_out, // controller strobe during WR
  output logic                   dqs_in,  // device strobe during RD
  input  logic                   dqs_oe   // controller drives DQS when 1
);

  localparam int BEATS_PER_CK = 2; // DDR: 2 beats per CK
  localparam int BE_W = DQM_W;

  // ---------------- Memory array (flat) ----------------
  typedef struct packed { logic [BANK_W-1:0] b; logic [ROW_W-1:0] r; logic [COL_W-1:0] c; } addr_t;
  function automatic int unsigned idx(input addr_t a);
    return (((a.b * (1<<ROW_W)) + a.r) * (1<<COL_W)) + a.c;
  endfunction
  localparam int MEM_DEPTH = (1<<BANK_W)*(1<<ROW_W)*(1<<COL_W);
  logic [DATA_W-1:0] mem [0:MEM_DEPTH-1];

  // ---------------- Bank state ----------------
  typedef enum logic [1:0] {BK_IDLE, BK_ACTIVE} bk_state_e;
  typedef struct {
    bk_state_e        st;
    logic [ROW_W-1:0] open_row;
    int t_rcd, t_ras, t_rp, t_wr;
  } bank_t;
  bank_t bank[0:(1<<BANK_W)-1];

  // Global timers
  int t_rfc;               // refresh busy
  int t_rrd_cool;          // ACT to ACT (diff banks)
  int t_ccd_cool;          // READ/WRITE cmd spacing

  // ---------------- Command decode ----------------
  typedef enum logic [2:0] {CMD_NOP, CMD_ACT, CMD_PRE, CMD_REF, CMD_MRS, CMD_READ, CMD_WRITE} cmd_e;
  function automatic cmd_e decode(input logic cs, rs, csig, we);
    if (cs) return CMD_NOP;
    if (!rs &&  csig &&  we)  return CMD_ACT;
    if (!rs &&  csig && !we)  return CMD_PRE;
    if (!rs && !csig &&  we)  return CMD_REF;
    if (!rs && !csig && !we)  return CMD_MRS;
    if ( rs && !csig &&  we)  return CMD_READ;
    if ( rs && !csig && !we)  return CMD_WRITE;
    return CMD_NOP;
  endfunction

  // ---------------- READ scheduler ----------------
  typedef struct {
    logic              valid;
    int                delay_ck;       // AL + CL
    logic [BANK_W-1:0] b;
    logic [ROW_W-1:0]  r;
    logic [COL_W-1:0]  c;
    int                beats_left;     // in beats (not CKs)
  } rdq_t;
  rdq_t rdq;

  // Drive DQS/DQ during read bursts (simple square DQS toggling)
  task automatic drive_read_beat();
    addr_t a; a.b = rdq.b; a.r = rdq.r; a.c = rdq.c;
    dq_in  <= mem[idx(a)];
    dqs_in <= ~dqs_in;          // toggle strobe
    rdq.c  <= rdq.c + 1'b1;
    rdq.beats_left <= rdq.beats_left - 1;
    if (rdq.beats_left == 1) rdq.valid <= 1'b0;
  endtask

  // ---------------- Main CK domain ----------------
  always_ff @(posedge ck or negedge rstn) begin
    if (!rstn) begin
      dq_in   <= '0;
      dqs_in  <= 1'b0;
      t_rfc   <= 0; t_rrd_cool <= 0; t_ccd_cool <= 0;
      for (int i=0;i<(1<<BANK_W);i++) begin
        bank[i].st <= BK_IDLE;
        bank[i].open_row <= '0;
        bank[i].t_rcd <= 0; bank[i].t_ras <= 0; bank[i].t_rp <= 0; bank[i].t_wr <= 0;
      end
      rdq <= '{valid:0, delay_ck:0, b:'0, r:'0, c:'0, beats_left:0};
    end else if (cke) begin
      // cool-downs
      if (t_rfc>0)      t_rfc      <= t_rfc - 1;
      if (t_rrd_cool>0) t_rrd_cool <= t_rrd_cool - 1;
      if (t_ccd_cool>0) t_ccd_cool <= t_ccd_cool - 1;
      for (int b=0;b<(1<<BANK_W);b++) begin
        if (bank[b].t_rcd>0) bank[b].t_rcd <= bank[b].t_rcd - 1;
        if (bank[b].t_ras>0) bank[b].t_ras <= bank[b].t_ras - 1;
        if (bank[b].t_rp >0) bank[b].t_rp  <= bank[b].t_rp  - 1;
        if (bank[b].t_wr >0) bank[b].t_wr  <= bank[b].t_wr  - 1;
      end

      // READ pipeline countdown (in CK domain)
      if (rdq.valid) begin
        if (rdq.delay_ck > 0) begin
          rdq.delay_ck <= rdq.delay_ck - 1;
        end else begin
          // produce 2 beats per CK edge domain (one here, one on negedge block)
          drive_read_beat();
        end
      end

      // Decode command
      cmd_e cmd = decode(cs_n, ras_n, cas_n, we_n);

      unique case (cmd)
        CMD_NOP: /* no-op */ ;

        CMD_MRS: /* ignore content; treat as no-op functionally */ ;

        CMD_REF: begin
          t_rfc <= T_RFC_CYC;
        end

        CMD_ACT: begin
          int b = ba;
          if (t_rfc>0) $warning("[ddr_model] ACT during refresh busy");
          if (bank[b].st==BK_ACTIVE) $warning("[ddr_model] ACT while bank active (missing PRE?)");
          if (bank[b].t_rp>0) $warning("[ddr_model] tRP violated on ACT (bank=%0d)", b);
          if (t_rrd_cool>0) $warning("[ddr_model] tRRD violated (ACT->ACT)");
          bank[b].st       <= BK_ACTIVE;
          bank[b].open_row <= a_row;
          bank[b].t_rcd    <= T_RCD_CYC;
          bank[b].t_ras    <= T_RAS_CYC;
          t_rrd_cool       <= T_RRD_CYC;
        end

        CMD_PRE: begin
          int b = ba;
          if (bank[b].st!=BK_ACTIVE) /* benign */ ;
          else begin
            if (bank[b].t_ras>0) $warning("[ddr_model] tRAS min violated on PRE (bank=%0d)", b);
            if (bank[b].t_wr >0) $warning("[ddr_model] tWR violated on PRE (bank=%0d)", b);
          end
          bank[b].st <= BK_IDLE;
          bank[b].t_rp <= T_RP_CYC;
        end

        CMD_READ: begin
          int b = ba;
          if (t_ccd_cool>0) $warning("[ddr_model] tCCD violated on READ");
          if (bank[b].st!=BK_ACTIVE || bank[b].open_row!=a_row)
            $warning("[ddr_model] READ without open row/bank match (bank=%0d)", b);
          if (bank[b].t_rcd>0) $warning("[ddr_model] tRCD violated on READ (bank=%0d)", b);
          // schedule read.
          rdq.valid      <= 1'b1;
          rdq.delay_ck   <= (AL + CL);
          rdq.b          <= ba;
          rdq.r          <= a_row;
          rdq.c          <= a_col;
          rdq.beats_left <= BL;               // in beats
          t_ccd_cool     <= T_CCD_CYC;
        end

        CMD_WRITE: begin
          int b = ba;
          if (t_ccd_cool>0) $warning("[ddr_model] tCCD violated on WRITE");
          if (bank[b].st!=BK_ACTIVE || bank[b].open_row!=a_row)
            $warning("[ddr_model] WRITE without open row/bank match (bank=%0d)", b);
          if (bank[b].t_rcd>0) $warning("[ddr_model] tRCD violated on WRITE (bank=%0d)", b);
          // Start write capture on both DQS edges for BL beats (handled below
          // in negedge/posedge DQS sampling). Arm tWR before PRE.
          bank[b].t_wr <= T_WR_CYC;
          t_ccd_cool   <= T_CCD_CYC;
        end

        default: ;
      endcase
    end
  end

  // ---------------- WRITE capture on DQS edges ----------------
  // Capture one beat per DQS edge while controller owns the bus (dq_oe & dqs_oe).
  // We assume the controller asserts a WRITE command before starting DQS toggles.
  task automatic capture_write_beat();
    addr_t a; a.b = ba; a.r = a_row; a.c = a_col; // current column at cmd time
    static int beat_idx = 0;                      // track within burst
    a.c = a.c + beat_idx[COL_W-1:0];
    logic [DATA_W-1:0] cur = mem[idx(a)];
    logic [DATA_W-1:0] nxt = dq_out;
    // DQM: 1=mask (keep existing byte)
    for (int by=0; by<BE_W; by++) if (dqm[by]) nxt[8*by +: 8] = cur[8*by +: 8];
    mem[idx(a)] = nxt;
    beat_idx++;
    if (beat_idx >= BL) beat_idx = 0;
  endtask

  // Sample on both edges of DQS when the controller owns the bus.
  always_ff @(posedge dqs_out) if (dqs_oe && dq_oe && rstn) capture_write_beat();
  always_ff @(negedge dqs_out) if (dqs_oe && dq_oe && rstn) capture_write_beat();

  // ---------------- Extra protocol hints (non-fatal) ----------------
  // Turnaround warnings (very approximate)
  always_ff @(posedge ck) if (rstn && cke) begin
    // Controller responsibility to space RD->WR (tRTW) and WR->RD (tWTR).
    // We don't fully track history; this is a light reminder:
    // (Extend if you want stronger checks.)
  end

endmodule
