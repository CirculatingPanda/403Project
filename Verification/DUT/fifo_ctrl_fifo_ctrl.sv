//==============================================================================
// FIFO Controller
// High-accuracy template with complete implementation
//
// Parameters from spec.json:
//   fifo_ctrl, 32, 1024, 10
//   896, 128
//==============================================================================

`timescale 1ns / 1ps

module fifo_ctrl_fifo_ctrl #(
    parameter int DATA_WIDTH   = 32,
    parameter int DEPTH        = 1024,
    parameter int ADDR_BITS    = 10,
    parameter int ALMOST_FULL  = 896,
    parameter int ALMOST_EMPTY = 128
) (
    input  logic                  clk,
    input  logic                  rst_n,
    
    // Write interface
    input  logic                  wr_valid,
    output logic                  wr_ready,
    input  logic [DATA_WIDTH-1:0] wr_data,
    
    // Read interface
    output logic                  rd_valid,
    input  logic                  rd_ready,
    output logic [DATA_WIDTH-1:0] rd_data,
    
    // Status
    output logic                  empty,
    output logic                  full,
    output logic                  almost_empty,
    output logic                  almost_full,
    output logic [ADDR_BITS:0]    fill_count
);

    // ════════════════════════════════════════════════════════════════════
    // Memory Array
    // ════════════════════════════════════════════════════════════════════
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ════════════════════════════════════════════════════════════════════
    // Pointers (one extra bit for full/empty detection)
    // ════════════════════════════════════════════════════════════════════
    logic [ADDR_BITS:0] wr_ptr;
    logic [ADDR_BITS:0] rd_ptr;
    
    // Address portion (drop MSB)
    logic [ADDR_BITS-1:0] wr_addr;
    logic [ADDR_BITS-1:0] rd_addr;
    
    assign wr_addr = wr_ptr[ADDR_BITS-1:0];
    assign rd_addr = rd_ptr[ADDR_BITS-1:0];

    // ════════════════════════════════════════════════════════════════════
    // Control Signals
    // ════════════════════════════════════════════════════════════════════
    logic do_write;
    logic do_read;
    
    assign do_write = wr_valid && wr_ready;
    assign do_read  = rd_valid && rd_ready;
    
    // Flow control
    assign wr_ready = !full;
    assign rd_valid = !empty;

    // ════════════════════════════════════════════════════════════════════
    // Write Pointer
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (do_write) begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Read Pointer
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0;
        end else if (do_read) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Memory Write
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk) begin
        if (do_write) begin
            mem[wr_addr] <= wr_data;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Memory Read (registered output for timing)
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data <= '0;
        end else if (!empty) begin
            rd_data <= mem[rd_addr];
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Status Flags
    // ════════════════════════════════════════════════════════════════════
    
    // Fill count
    assign fill_count = wr_ptr - rd_ptr;
    
    // Empty: pointers equal (including MSB)
    assign empty = (wr_ptr == rd_ptr);
    
    // Full: pointers equal except MSB
    assign full = (wr_ptr[ADDR_BITS-1:0] == rd_ptr[ADDR_BITS-1:0]) &&
                  (wr_ptr[ADDR_BITS] != rd_ptr[ADDR_BITS]);
    
    // Threshold flags
    assign almost_full  = (fill_count >= ALMOST_FULL);
    assign almost_empty = (fill_count <= ALMOST_EMPTY);

    // ════════════════════════════════════════════════════════════════════
    // Assertions
    // ════════════════════════════════════════════════════════════════════
`ifndef SYNTHESIS
    // No write when full
    assert property (@(posedge clk) disable iff (!rst_n)
        full |-> !do_write
    ) else $error("FIFO: Write when full!");
    
    // No read when empty
    assert property (@(posedge clk) disable iff (!rst_n)
        empty |-> !do_read
    ) else $error("FIFO: Read when empty!");
    
    // Fill count in range
    assert property (@(posedge clk) disable iff (!rst_n)
        fill_count <= DEPTH
    ) else $error("FIFO: Fill count overflow!");
`endif

endmodule : fifo_ctrl_fifo_ctrl
