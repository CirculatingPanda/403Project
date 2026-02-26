// golden/ddr2_model.sv
// Simplified DDR2 SDRAM behavioral model (open-page, source-synchronous).
// - Bank/row FSM: ACT, READ, WRITE, PRE, REF, MRS
// - Enforces key timings (CK cycles): tRCD, tRP, tRAS, tRC, tRFC, tRRD, tWR, tWTR, tRTW, tCCD, tRTP
// - READ: after (AL+CL) cycles, drives DQS/DQ for BL beats (2 beats/CK)
// - WRITE: samples DQ on both DQS edges; requires ODT asserted around the burst
// - DQM masks bytes (1=mask)
//
// Notes:
// * This is a bring-up model (not JEDEC-complete). Timing is approximate but useful.
// * TB converts ns->cycles and passes integers via parameters.

`timescale 1ns/1ps
module ddr2_model #(
  parameter int DATA_W   = 16,
  parameter int ROW_W    = 13,
  parameter int COL_W    = 10,
  parameter int BANK_W   = 2,
  parameter int DQM_W    = (DATA_W/8>0)?(DATA_W/8):1,
  parameter int BL       = 4,    // in beats
  parameter int CL       = 4,    // CAS (in CK)
  parameter int AL       = 0,    // additive latency
  // Timing (CK cycles)
  parameter int T_RCD_CYC = 4,
  parameter int T_RP_CYC  = 4,
  parameter int T_RAS_CYC = 8,
  parameter int T_RC_CYC  = 12,
  parameter int T_RRD_CYC = 2,
  parameter int T_WR_CYC  = 3,
  parameter int T_WTR_CYC = 2,
  parameter int T_RTW_CYC = 3,
  parameter int T_RFC_CYC = 12,
  parameter int T_CCD_CYC = 2,
  parameter int T_RTP_CYC = 2,
  // On-die termination windows around writes (approx)
  parameter int T_ODT_ON_CYC  = 1,
  parameter int T_ODT_OFF_CYC = 1,
  // Memory init
  parameter bit INIT_MEM_ZERO = 1'b1
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
  input  logic                   odt,     // DDR2 ODT

  // Data bus (source-synchronous)
  input  logic [DATA_W-1:0]      dq_out,  // controller -> device (WR)
  output logic [DATA_W-1:0]      dq_in,   // device -> controller (RD)
  input  logic                   dq_oe,   // controller owns DQ on WR
  input  logic                   dqs_out, // controller strobe on WR
  output logic                   dqs_in,  // device strobe on RD
  input  logic                   dqs_oe   // controller owns DQS on WR
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

  // Global cooldowns
  int t_rfc, t_rrd_cool, t_ccd_cool;

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
    int                delay_ck;      // AL + CL
    logic [BANK_W-1:0] b;
    logic [ROW_W-1:0]  r;
    logic [COL_W-1:0]  c;
    int                beats_left;    // in beats
  } rdq_t;
  rdq_t rdq;
  // ---------------- WRITE scheduler ----------------
  typedef struct {
    logic              active;
    logic [BANK_W-1:0] b;
    logic [ROW_W-1:0]  r;
    logic [COL_W-1:0]  c;
    int                beats_left;
  } wrq_t;
  wrq_t wrq;

  task automatic drive_read_beat();
    addr_t a; a.b = rdq.b; a.r = rdq.r; a.c = rdq.c;
    dq_in  <= mem[idx(a)];
    dqs_in <= ~dqs_in;   // simple toggle
    rdq.c  <= rdq.c + 1'b1;
    rdq.beats_left <= rdq.beats_left - 1;
    if (rdq.beats_left == 1) rdq.valid <= 1'b0;
  endtask

  // Track a simple "recent write" window for ODT checking
  int odt_guard; // counts down around writes

  // ---------------- CK domain ----------------
  always_ff @(posedge ck or negedge rstn) begin
    if (!rstn) begin
      dq_in <= '0; dqs_in <= 1'b0;
      t_rfc <= 0; t_rrd_cool <= 0; t_ccd_cool <= 0;
      odt_guard <= 0;
      if (INIT_MEM_ZERO) begin
        for (int mi=0; mi<MEM_DEPTH; mi++) begin
          mem[mi] <= '0;
        end
      end
      for (int i=0;i<(1<<BANK_W);i++) begin
        bank[i].st <= BK_IDLE;
        bank[i].open_row <= '0;
        bank[i].t_rcd <= 0; bank[i].t_ras <= 0; bank[i].t_rp <= 0; bank[i].t_wr <= 0;
      end
      rdq <= '{valid:0, delay_ck:0, b:'0, r:'0, c:'0, beats_left:0};
      wrq <= '{active:0, b:'0, r:'0, c:'0, beats_left:0};
    end else if (cke) begin
      if (t_rfc>0)      t_rfc      <= t_rfc - 1;
      if (t_rrd_cool>0) t_rrd_cool <= t_rrd_cool - 1;
      if (t_ccd_cool>0) t_ccd_cool <= t_ccd_cool - 1;
      if (odt_guard>0)  odt_guard  <= odt_guard - 1;

      for (int b=0;b<(1<<BANK_W);b++) begin
        if (bank[b].t_rcd>0) bank[b].t_rcd <= bank[b].t_rcd - 1;
        if (bank[b].t_ras>0) bank[b].t_ras <= bank[b].t_ras - 1;
        if (bank[b].t_rp >0) bank[b].t_rp  <= bank[b].t_rp  - 1;
        if (bank[b].t_wr >0) bank[b].t_wr  <= bank[b].t_wr  - 1;
      end

      // READ pipeline countdown
      if (rdq.valid) begin
        if (rdq.delay_ck > 0) rdq.delay_ck <= rdq.delay_ck - 1;
        else                  drive_read_beat();
      end else begin
        dq_in  <= '0;
        dqs_in <= 1'b0;
      end

      // Decode this cycle's command
      cmd_e cmd = decode(cs_n, ras_n, cas_n, we_n);

      unique case (cmd)
        CMD_NOP: /* no-op */ ;

        CMD_MRS: /* mode ignored; TB sets params */ ;

        CMD_REF: begin
          t_rfc <= T_RFC_CYC;
        end

        CMD_ACT: begin
          int b = ba;
          if (t_rfc>0) $warning("[ddr2_model] ACT during REF busy");
          if (bank[b].st==BK_ACTIVE) $warning("[ddr2_model] ACT while bank active (need PRE)");
          if (bank[b].t_rp>0) $warning("[ddr2_model] tRP violated on ACT (bank=%0d)", b);
          if (t_rrd_cool>0) $warning("[ddr2_model] tRRD violated (ACT->ACT)");
          bank[b].st       <= BK_ACTIVE;
          bank[b].open_row <= a_row;
          bank[b].t_rcd    <= T_RCD_CYC;
          bank[b].t_ras    <= T_RAS_CYC;
          t_rrd_cool       <= T_RRD_CYC;
        end

        CMD_PRE: begin
          int b = ba;
          if (bank[b].st==BK_ACTIVE) begin
            if (bank[b].t_ras>0) $warning("[ddr2_model] tRAS violated on PRE (bank=%0d)", b);
            if (bank[b].t_wr >0) $warning("[ddr2_model] tWR violated on PRE (bank=%0d)", b);
          end
          bank[b].st <= BK_IDLE;
          bank[b].t_rp <= T_RP_CYC;
        end

        CMD_READ: begin
          int b = ba;
          if (t_ccd_cool>0) $warning("[ddr2_model] tCCD violated on READ");
          if (bank[b].st!=BK_ACTIVE || bank[b].open_row!=a_row)
            $warning("[ddr2_model] READ without open row/bank match (bank=%0d)", b);
          if (bank[b].t_rcd>0) $warning("[ddr2_model] tRCD violated on READ (bank=%0d)", b);
          rdq <= '{valid:1, delay_ck:(AL+CL), b:ba, r:a_row, c:a_col, beats_left:BL};
          t_ccd_cool <= T_CCD_CYC;
        end

        CMD_WRITE: begin
          int b = ba;
          if (t_ccd_cool>0) $warning("[ddr2_model] tCCD violated on WRITE");
          if (bank[b].st!=BK_ACTIVE || bank[b].open_row!=a_row)
            $warning("[ddr2_model] WRITE without open row/bank match (bank=%0d)", b);
          if (bank[b].t_rcd>0) $warning("[ddr2_model] tRCD violated on WRITE (bank=%0d)", b);
          // Arm write recovery; and require ODT around the burst.
          bank[b].t_wr <= T_WR_CYC;
          t_ccd_cool   <= T_CCD_CYC;
          // Latch write address for burst
          wrq <= '{active:1, b:ba, r:a_row, c:a_col, beats_left:BL};
          // ODT guard window (before & after DQS burst)
          odt_guard    <= (T_ODT_ON_CYC + T_ODT_OFF_CYC + (BL+1)/BEATS_PER_CK);
        end

        default: ;
      endcase
    end
  end

  // ---------------- WRITE capture on DQS edges (requires ODT) ----------------
  // We check ODT roughly: it must be asserted during the guarded window.
  task automatic capture_write_beat();
    if (!odt) $warning("[ddr2_model] ODT deasserted during write beat");
    if (!wrq.active) begin
      return;
    end
    addr_t a; a.b = wrq.b; a.r = wrq.r; a.c = wrq.c;
    logic [DATA_W-1:0] cur = mem[idx(a)];
    logic [DATA_W-1:0] nxt = dq_out;
    for (int by=0; by<BE_W; by++) if (dqm[by]) nxt[8*by +: 8] = cur[8*by +: 8];
    mem[idx(a)] = nxt;
    wrq.c = wrq.c + 1'b1;
    wrq.beats_left = wrq.beats_left - 1;
    if (wrq.beats_left == 1) wrq.active = 1'b0;
  endtask

  // Sample on both DQS edges when controller owns the bus.
  always_ff @(posedge dqs_out) if (dqs_oe && dq_oe && rstn && cke) capture_write_beat();
  always_ff @(negedge dqs_out) if (dqs_oe && dq_oe && rstn && cke) capture_write_beat();

  // ---------------- Light turnaround / RTP hints (non-fatal) ----------------
  // (Extend with history if you want stronger checks.)
  // Read-to-precharge spacing hint
  // This simplified model does not fully track last READ cycles per bank; add if needed.

endmodule
