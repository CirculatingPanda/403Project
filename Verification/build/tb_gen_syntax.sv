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
int T_RD_LAT_CYC = 1;  // cycles from read request to valid rdata
int T_WR_LAT_CYC = 0;  // not specified, default 0
int T_SETUP_CYC  = 0;  // not specified, default 0
int T_HOLD_CYC   = 0;  // not specified, default 0
int T_GAP_CYC    = 0;  // not specified, default 0
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
  /* DUT instantiation elided for syntax check */
/* sram_sync_ctrl #(
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
  ); */

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
    int i;
    begin
      // Wait for reset deasserted and a couple cycles before starting
      wait (rstn === 1'b1);
      @(posedge clk);

      // Deassert controls between transactions
      req   <= 1'b0;
      we    <= 1'b0;

      // Drive address/data/byte-enables and respect setup time
      addr  <= a;
      wdata <= d;
      be    <= ben;

      if (T_SETUP_CYC > 0) begin
        repeat (T_SETUP_CYC) @(posedge clk);
      end else begin
        @(posedge clk);
      end

      // Assert write request for one cycle
      req <= 1'b1;
      we  <= 1'b1;
      @(posedge clk);

      // Deassert request and write-enable; hold addr/data/be stable one more cycle
      req <= 1'b0;
      we  <= 1'b0;
      @(posedge clk);

      // Wait for write latency and optional gap cycles
      if (T_WR_LAT_CYC > 0) begin
        repeat (T_WR_LAT_CYC) @(posedge clk);
      end
      if (T_GAP_CYC > 0) begin
        repeat (T_GAP_CYC) @(posedge clk);
      end
    end
  endtask
  // @LLM_EDIT END TASK_DO_WRITE

  // @LLM_EDIT BEGIN TASK_DO_READ
task automatic do_read(
    input  logic [ADDR_W-1:0] a,
    output logic [DATA_W-1:0] q
  );
    int i;
    begin
      // Wait for reset deasserted and a couple cycles before starting
      wait (rstn === 1'b1);
      @(posedge clk);

      // Ensure write is deasserted between transactions
      we   <= 1'b0;
      req  <= 1'b0;

      // Drive address and respect setup time before asserting request
      addr <= a;

      if (T_SETUP_CYC > 0) begin
        repeat (T_SETUP_CYC) @(posedge clk);
      end else begin
        @(posedge clk);
      end

      // Assert read request for one cycle (we=0 indicates read)
      req <= 1'b1;
      @(posedge clk);
      req <= 1'b0;

      // Wait the programmed read latency cycles, then for rvalid if present
      if (T_RD_LAT_CYC > 0) begin
        repeat (T_RD_LAT_CYC) @(posedge clk);
      end

      // If rvalid is present, wait until it is asserted
      while (rvalid !== 1'b1) begin
        @(posedge clk);
      end

      // Sample rdata on the next posedge to avoid races
      @(posedge clk);
      q = rdata;

      // Optional gap cycles before next transaction
      if (T_GAP_CYC > 0) begin
        repeat (T_GAP_CYC) @(posedge clk);
      end
    end
  endtask
  // @LLM_EDIT END TASK_DO_READ

  // ------------------------------
  // Scoreboard
  // ------------------------------
  int                err_count = 0;
  int                txn_count = 0;
  logic              done = 1'b0;
  int                TB_TIMEOUT_CYC = 1000;
  logic [DATA_W-1:0] got_q, exp_q;

  task automatic check_eq(input [DATA_W-1:0] exp, input [DATA_W-1:0] got, input logic [ADDR_W-1:0] a);
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
    int BYTES;
    int i, j, k;
    int seed_iter;
    logic [ADDR_W-1:0] a;
    logic [DATA_W-1:0] d;
    logic [DATA_W-1:0] exp_d;
    logic [DATA_W-1:0] read_d;
    logic [DATA_W-1:0] old_d;
    logic [DATA_W-1:0] mask;
    logic [BE_W-1:0]   ben;
    logic [ADDR_W-1:0] addrs [0:3];
    logic [7:0]        bval;
    logic [DATA_W-1:0] model [0:(1<<ADDR_W)-1];
    bit                 model_valid [0:(1<<ADDR_W)-1]; // validity flag per address

    // Reset/init
    req = 1'b0;
    we  = 1'b0;
    addr  = '0;
    wdata = '0;
    be    = '0;
    repeat (5) @(posedge clk);
    rstn <= 1'b1;
    repeat (2) @(posedge clk);
    // Initialize model_valid flags to 0 (Icarus-safe)
    for (i = 0; i < (1<<ADDR_W); i++) begin
      model_valid[i] = 1'b0;
    end


    // Setup helpers
    BYTES = (DATA_W + 7) / 8;

    // Deterministic set of addresses: min, max, a couple of low offsets
    addrs[0] = '0;
    addrs[1] = {ADDR_W{1'b1}};
    addrs[2] = 'h10;
    addrs[3] = 'h20;

    // Helper: functionally build data pattern based on address and seed (byte-wise)
    // (implemented inline per use to avoid nested function; using for-loop)

    // Core targeted scenarios on specific addresses
    for (i = 0; i < 4; i++) begin
      a = addrs[i];

      // 1) Write full word then read-after-write same address
      ben = {BE_W{1'b1}};
      d   = '0;
      for (j = 0; j < BYTES; j++) begin
        bval = (8'h11 * j) ^ a[7:0] ^ 8'hA5;
        d[8*j +: 8] = bval;
      end
      do_write(a, d, ben);
      do_read(a, read_d);
      exp_d = d;
      if (read_d !== exp_d) begin
        $display("Mismatch RAW full write @%0h exp=%0h got=%0h", a, exp_d, read_d);
        $fatal(1);
      end
      model[a] = exp_d; model_valid[a] = 1'b1;
      txn_count++;

      // 2) Corner: be=0 should not modify, read should remain previous
      ben = '0;
      d   = '0;
      for (j = 0; j < BYTES; j++) begin
        bval = (8'h3C ^ j[7:0]) ^ a[7:0];
        d[8*j +: 8] = bval;
      end
      do_write(a, d, ben);
      do_read(a, read_d);
      exp_d = model_valid[a] ? model[a] : '0;
      if (read_d !== exp_d) begin
        $display("Mismatch be=0 write @%0h exp=%0h got=%0h", a, exp_d, read_d);
        $fatal(1);
      end
      // model unchanged
      txn_count++;

      // 3) Corner: single-byte (or lane) updates; if BE_W==1 this degenerates to full-width
      for (j = 0; j < BE_W; j++) begin
        ben = '0;
        ben[j] = 1'b1;
        d = '0;
        for (k = 0; k < BYTES; k++) begin
          bval = (8'h5A ^ j[7:0]) ^ k[7:0] ^ a[7:0];
          d[8*k +: 8] = bval;
        end
        // Build byte mask from ben
        mask = '0;
        for (k = 0; k < BYTES; k++) begin
          if (BE_W == 1) begin
            if (ben[0]) mask[8*k +: 8] = {8{1'b1}};
          end else begin
            if (k < BE_W && ben[k]) mask[8*k +: 8] = {8{1'b1}};
          end
        end
        old_d = model_valid[a] ? model[a] : '0;
        exp_d = (d & mask) | (old_d & ~mask);
        do_write(a, d, ben);
        do_read(a, read_d);
        if (read_d !== exp_d) begin
          $display("Mismatch single-lane write @%0h lane=%0d exp=%0h got=%0h", a, j, exp_d, read_d);
          $fatal(1);
        end
        model[a] = exp_d;
        txn_count++;
      end

      // 4) Corner: all-bytes enabled
      ben = {BE_W{1'b1}};
      d   = '0;
      for (j = 0; j < BYTES; j++) begin
        bval = (8'hC3 ^ ((j*7) & 8'hFF)) ^ a[7:0];
        d[8*j +: 8] = bval;
      end
      do_write(a, d, ben);
      do_read(a, read_d);
      exp_d = d;
      if (read_d !== exp_d) begin
        $display("Mismatch all-bytes write @%0h exp=%0h got=%0h", a, exp_d, read_d);
        $fatal(1);
      end
      model[a] = exp_d;
      txn_count++;
    end

    // 5) Simple burst-like sequences with 1-cycle gap between operations
    //    Writes followed by reads on consecutive addresses
    a = 'h40;
    for (i = 0; i < 4; i++) begin
      ben = {BE_W{1'b1}};
      d   = '0;
      for (j = 0; j < BYTES; j++) begin
        bval = (8'h77 ^ i[7:0]) ^ j[7:0] ^ a[7:0];
        d[8*j +: 8] = bval;
      end
      do_write(a + ((i) & {ADDR_W{1'b1}}), d, ben);
      @(posedge clk);
      do_read(a + ((i) & {ADDR_W{1'b1}}), read_d);
      exp_d = d;
      if (read_d !== exp_d) begin
        $display("Mismatch burst idx=%0d @%0h exp=%0h got=%0h", i, (a + ((i) & {ADDR_W{1'b1}})), exp_d, read_d);
        $fatal(1);
      end
      model[a + ((i) & {ADDR_W{1'b1}})] = exp_d;
      txn_count++;
      @(posedge clk);
    end

    // 6) Deterministic broader coverage until reaching NUM_TXNS
    seed_iter = 0;
    while (txn_count < NUM_TXNS) begin
      // Deterministic address sequence
      a = (seed_iter * 32'h1F123BB5) ^ (seed_iter << 3);
      // If first time seeing address, initialize with full write
      if (!model_valid[a]) begin
        model_valid[a] = 1'b1;

        ben = {BE_W{1'b1}};
        d = '0;
        for (j = 0; j < BYTES; j++) begin
          bval = (8'hA0 ^ seed_iter[7:0]) ^ j[7:0] ^ a[7:0];
          d[8*j +: 8] = bval;
        end
        do_write(a, d, ben);
        do_read(a, read_d);
        exp_d = d;
        if (read_d !== exp_d) begin
          $display("Mismatch init write @%0h exp=%0h got=%0h", a, exp_d, read_d);
          $fatal(1);
        end
        model[a] = exp_d;
        txn_count++;
      end

      // Next, partial or full update depending on BE_W
      d = '0;
      for (j = 0; j < BYTES; j++) begin
        bval = (8'h5C ^ ((seed_iter + j) & 8'hFF)) ^ a[7:0];
        d[8*j +: 8] = bval;
      end

      if (BE_W == 1) begin
        ben = {BE_W{1'b1}};
      end else begin
        ben = '0;
        ben[seed_iter % BE_W] = 1'b1;
      end

      // Build mask and expected
      mask = '0;
      for (j = 0; j < BYTES; j++) begin
        if (BE_W == 1) begin
          if (ben[0]) mask[8*j +: 8] = {8{1'b1}};
        end else begin
          if (j < BE_W && ben[j]) mask[8*j +: 8] = {8{1'b1}};
        end
      end
      old_d = model[a];
      exp_d = ( (BE_W == 1) ? d : ((d & mask) | (old_d & ~mask)) );

      do_write(a, d, ben);
      do_read(a, read_d);
      if (read_d !== exp_d) begin
        $display("Mismatch iter=%0d @%0h ben=%0b exp=%0h got=%0h", seed_iter, a, ben, exp_d, read_d);
        $fatal(1);
      end
      model[a] = exp_d;
      txn_count++;

      // Small gap between transactions
      @(posedge clk);
      seed_iter++;
    end

    // Finish
    req = 1'b0;
    we  = 1'b0;
    done = 1'b1;
  end
  // @LLM_EDIT END MAIN_SCENARIO

  // ------------------------------
  // Emit machine-readable result
  // ------------------------------
  // @LLM_EDIT BEGIN EMIT_RESULTS
initial begin
  integer local_timeout_cyc;
  local_timeout_cyc = (NUM_TXNS > 0) ? (NUM_TXNS * 20) : 1000;
  fork
    begin
      repeat (local_timeout_cyc) @(posedge clk);
      $display("RESULT: FAIL");
      $fatal(1);
    end
    begin
      wait (done);
      if (err_count == 0 && txn_count >= NUM_TXNS) begin
        $display("RESULT: PASS");
        $finish;
      end else begin
        $display("RESULT: FAIL");
        $fatal(1);
      end
    end
  join_any
  disable fork;
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
