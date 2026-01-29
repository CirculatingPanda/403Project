// tb_sram_sync.sv — skeleton testbench for a basic *synchronous* SRAM controller
// Guarded with @LLM_EDIT blocks for localized LLM edits.

`timescale 1ns/1ps
module tb;

  // ------------------------------
  // Parameters (filled by your generator)
  // ------------------------------
  localparam int  DATA_W = 32;              // e.g., 32
  localparam int  ADDR_W = 16;              // e.g., 18
  localparam int  BE_W   = (DATA_W/8>0)?(DATA_W/8):1;
  localparam bit  LITTLE_ENDIAN = 1; // 1 little, 0 big
  localparam real CLK_MHZ = 100;                // e.g., 100
  localparam real CLK_NS  = (1000.0/CLK_MHZ);
localparam int NUM_TXNS = 200;                  // e.g., 200

  // ------------------------------
  // Derived timing in cycles (LLM fills from context.timing_cycles)
  // Common sync knobs: read/write latency, min gaps, setup/hold in cycles, etc.
  // ------------------------------
  // @LLM_EDIT BEGIN TIMING_CYCLES
int T_RD_LAT_CYC = 1;  // cycles from read request to valid rdata (from timing_cycles.read_latency_cycles)
int T_WR_LAT_CYC = 0;  // not specified; assume immediate commit for writes
int T_SETUP_CYC  = 0;  // no extra setup cycles specified
int T_HOLD_CYC   = 0;  // no hold cycles specified
int T_GAP_CYC    = 0;  // no enforced inter-op gap specified
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
  /* golden SRAM sync model omitted for this config */

  // ------------------------------
  // Optional assertions/monitors
  // ------------------------------
  // `include "libraries/svassert/sram_sync_protocol.svh"
  // sram_sync_protocol_asrt #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) chk (.*);

  // ------------------------------
  // Preload / init content (deterministic expansion)
  // ------------------------------
  /* no preload */

  // ------------------------------
  // Endianness helpers
  // ------------------------------
  function automatic [DATA_W-1:0] pack_bytes(input logic [8*BE_W-1:0] B_flat);
  int i;
  pack_bytes = '0;
  for (i = 0; i < BE_W; i++) begin
    if (LITTLE_ENDIAN) begin
      pack_bytes[i*8 +: 8] = B_flat[i*8 +: 8];
    end else begin
      pack_bytes[(BE_W-1-i)*8 +: 8] = B_flat[i*8 +: 8];
    end
  end
endfunction

  // ------------------------------
  // Driver tasks (LLM fills legal synchronous sequences)
  // ------------------------------
  // @LLM_EDIT BEGIN TASK_DO_WRITE
task automatic do_write(
    input  logic [ADDR_W-1:0] a,
    input  logic [DATA_W-1:0] d,
    input  logic [BE_W-1:0]   ben
  );
    // Declarations first (Icarus quirk)
    wait (rstn);
    @(posedge clk);
    addr  <= a;
    wdata <= d;
    be    <= ben;
    we    <= 1'b1;
    req   <= 1'b1;
    repeat (T_SETUP_CYC) @(posedge clk);
    @(posedge clk);
    req   <= 1'b0;
    repeat (T_HOLD_CYC) @(posedge clk);
    we    <= 1'b0;
    if (T_WR_LAT_CYC > 0) repeat (T_WR_LAT_CYC) @(posedge clk);
    if (T_GAP_CYC    > 0) repeat (T_GAP_CYC)    @(posedge clk);
  endtask
  // @LLM_EDIT END TASK_DO_WRITE

  // @LLM_EDIT BEGIN TASK_DO_READ
task automatic do_read(
    input  logic [ADDR_W-1:0] a,
    output logic [DATA_W-1:0] q
  );
    // Declarations first (Icarus quirk)
    int wait_cycles;
    wait (rstn);
    @(posedge clk);
    addr  <= a;
    we    <= 1'b0;
    be    <= '1;
    req   <= 1'b1;
    repeat (T_SETUP_CYC) @(posedge clk);
    @(posedge clk);
    req   <= 1'b0;
    if (T_RD_LAT_CYC > 0) repeat (T_RD_LAT_CYC) @(posedge clk);
    wait_cycles = 0;
    while (!rvalid && wait_cycles < (T_RD_LAT_CYC + 8)) begin
      wait_cycles++;
      @(posedge clk);
    end
    q = rdata;
    if (T_GAP_CYC > 0) repeat (T_GAP_CYC) @(posedge clk);
  endtask
  // @LLM_EDIT END TASK_DO_READ

  // ------------------------------
  // Scoreboard
  // ------------------------------
  int                err_count = 0;
  int                txn_count = 0;
  logic [DATA_W-1:0] got_q, exp_q;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got, input [ADDR_W-1:0] a);
    if (exp !== got) begin
      $display("[TB][MISMATCH] addr=0x%0h exp=0x%0h got=0x%0h", a, exp, got);
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
initial begin
    // Declarations first (Icarus quirk)
    int i;
    int j;
    int READ_LAT;
    int NUM_BYTES;
    int LIMIT;
    logic [ADDR_W-1:0] a;
    logic [DATA_W-1:0] d;
    logic [BE_W-1:0]   ben;
    logic [DATA_W-1:0] mask_bits;
    logic [DATA_W-1:0] expected_local;
    logic [BE_W-1:0]   one_hot;
    int                 seed_dummy;

    // init
    READ_LAT = 1; // timing_cycles.read_latency_cycles
    req = 1'b0; we = 1'b0; addr = '0; wdata = '0; be = '0;
    seed_dummy = $urandom(32'h1ACE_B00C); // deterministic seed
    repeat (5) @(posedge clk);
    rstn <= 1'b1;

    // compute byte count for mask expansion (assumes 8 bits/byte)
    NUM_BYTES = (DATA_W/8);
    LIMIT = (BE_W < NUM_BYTES) ? BE_W : NUM_BYTES;

    for (i = 0; i < NUM_TXNS; i++) begin
      // address selection: cover min/max, then unique sequential
      if (i == 0)               a = {ADDR_W{1'b0}};           // min address
      else if (i == 1)          a = {ADDR_W{1'b1}};           // max address
      else                      a = i[ADDR_W-1:0];            // unique low addresses

      // data pattern
      d = $urandom();

      // byte-enable patterns: all bytes, single byte, none, all except one
      if ((i % 4) == 0)       ben = {BE_W{1'b1}};
      else if ((i % 4) == 1) begin
        one_hot = '0;
        one_hot[i % BE_W] = 1'b1;
        ben = one_hot;
      end
      else if ((i % 4) == 2)  ben = {BE_W{1'b0}};
      else begin
        one_hot = '0;
        one_hot[i % BE_W] = 1'b1;
        ben = {BE_W{1'b1}} ^ one_hot;
      end

      // build bit mask from byte enables (8 bits per enable), clamp to DATA_W size
      mask_bits = '0;
      for (j = 0; j < LIMIT; j++) begin
        if (ben[j]) mask_bits[j*8 +: 8] = 8'hFF;
        else        mask_bits[j*8 +: 8] = 8'h00;
      end

      // write then read-after-write same address
      do_write(a, d, ben);
      // allow read latency/gap cycles between operations
      repeat (READ_LAT) @(posedge clk);
      do_read(a, got_q);

      // expected = (prev assumed 0 after reset) merged with write-data per byte-enable
      expected_local = (d & mask_bits);

      exp_q = expected_local; // golden model mirrors masked commit semantics
      check_eq(exp_q, got_q, a);
      txn_count++;

      // minimal inter-transaction gap
      @(posedge clk);
    end
  end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // Emit machine-readable result
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
initial begin
    // Declarations first (Icarus quirk)
    int cycles;
    int max_cycles;
    int rst_wait_max;
    cycles = 0;
    max_cycles = NUM_TXNS * 64 + 500;
    rst_wait_max = 1000;

    // Wait for reset deassertion with timeout
    while (!rstn && rst_wait_max > 0) begin
      rst_wait_max--;
      @(posedge clk);
    end
    if (!rstn) begin
      $display("RESULT: FAIL");
      $fatal(1);
    end

    while (txn_count < NUM_TXNS && cycles < max_cycles) begin
      cycles++;
      @(posedge clk);
    end

    if (err_count == 0 && txn_count >= NUM_TXNS) $display("RESULT: PASS");
    else begin
      $display("RESULT: FAIL");
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
