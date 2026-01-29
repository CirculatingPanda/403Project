// Auto-generated stub DUT: synchronous SRAM controller
// Note: simple model for compilation & basic TB checks; not cycle-accurate to any real core.
module sram_sync_ctrl #(
  parameter int DATA_W = 32,
  parameter int ADDR_W = 16
) (
  input  logic                 clk,
  input  logic                 rstn,
  input  logic                 req,
  input  logic                 we,
  input  logic [ADDR_W-1:0]    addr,
  input  logic [DATA_W-1:0]    wdata,
  input  logic [4-1:0]    be,
  output logic [DATA_W-1:0]    rdata,
  output logic                 rvalid
);
  localparam int BE_W = (DATA_W/8>0)?(DATA_W/8):1;
  localparam int DEPTH = (1 << ADDR_W);

  logic [DATA_W-1:0] mem [0:DEPTH-1];

  // one-cycle read latency
  logic                 rd_pipe;
  logic [ADDR_W-1:0]    addr_d;

  integer i;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      rdata   <= '0;
      rvalid  <= 1'b0;
      rd_pipe <= 1'b0;
      addr_d  <= '0;
    end else begin
      rvalid  <= rd_pipe;
      rd_pipe <= 1'b0;

      // write on req & we
      if (req && we) begin
        if (BE_W == 1) begin
          if (be[0]) mem[addr] <= wdata;
        end else begin
          logic [DATA_W-1:0] cur;
          cur = mem[addr];
          for (i = 0; i < BE_W; i++) begin
            if (be[i]) begin
              cur[i*8 +: 8] = wdata[i*8 +: 8];
            end
          end
          mem[addr] <= cur;
        end
      end

      // schedule read on req & !we
      if (req && !we) begin
        addr_d  <= addr;
        rd_pipe <= 1'b1;
      end

      if (rd_pipe) begin
        rdata <= mem[addr_d];
      end
    end
  end
endmodule
