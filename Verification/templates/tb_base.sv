`timescale 1ns/1ps
module tb;
  // Clock/reset
  logic clk=0, rst=1;
  always #2.5 clk = ~clk; // 200 MHz default
  initial begin #25 rst = 0; end

  // DUT signals (simple SRAM-ish bus)
  logic [31:0] addr, wdata, rdata;
  logic we, re, ready, valid;

  // DUT
  dut u_dut(.clk, .rst, .addr, .wdata, .rdata, .we, .re, .ready, .valid);

  // @LLM_EDIT BEGIN TIMING_CYCLES
  // (LLM fills: localparams like T_AA_CYC, T_WC_CYC)
  // @LLM_EDIT END TIMING_CYCLES

  // @LLM_EDIT BEGIN TASKS
  // (LLM fills: task automatic do_write/do_read/check_read)
  // @LLM_EDIT END TASKS

  initial begin
    // @LLM_EDIT: STIMULUS
    // ??? sequence goes here
    $display("TEST PASSED");
    $finish;
  end
endmodule
