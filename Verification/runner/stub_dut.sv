// runner/stub_dut.sv
`timescale 1ns/1ps
module dut(
  input  logic        clk,
  input  logic        rst,
  input  logic [31:0] addr,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  input  logic        we,
  input  logic        re,
  output logic        ready,
  output logic        valid
);
  // 4K x 32 simple memory, 1-cycle read latency
  localparam DEPTH = 4096;
  logic [31:0] mem [0:DEPTH-1];

  logic        re_d;
  logic [31:0] addr_d;

  assign ready = 1'b1;          // always ready for this stub
  assign valid = re_d;          // data valid one cycle after read

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      re_d  <= 1'b0;
      addr_d <= '0;
      rdata <= '0;
    end else begin
      // write
      if (we) begin
        mem[addr[15:2]] <= wdata; // word address (assuming 32-bit data)
      end
      // pipeline read
      re_d  <= re;
      addr_d <= addr;
      if (re_d) begin
        rdata <= mem[addr_d[15:2]];
      end
    end
  end
endmodule
