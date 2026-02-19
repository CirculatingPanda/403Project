//==============================================================================
// Register File Controller Skeleton
// High-accuracy template - nearly complete, minimal AI generation needed
//
// Parameters from spec.json:
//   {{MODULE_NAME}}, {{DATA_WIDTH}}, {{ENTRIES}}, {{ENTRY_BITS}}
//   {{READ_PORTS}}, {{WRITE_PORTS}}, {{HAS_BYPASS}}
//==============================================================================

`timescale 1ns / 1ps

module {{MODULE_NAME}}_regfile_ctrl #(
    parameter int DATA_WIDTH  = {{DATA_WIDTH}},
    parameter int ENTRIES     = {{ENTRIES}},
    parameter int ENTRY_BITS  = {{ENTRY_BITS}},
    parameter int READ_PORTS  = {{READ_PORTS}},
    parameter int WRITE_PORTS = {{WRITE_PORTS}},
    parameter bit HAS_BYPASS  = {{HAS_BYPASS}}
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Read ports
    input  logic [ENTRY_BITS-1:0]     rd_addr  [READ_PORTS],
    output logic [DATA_WIDTH-1:0]     rd_data  [READ_PORTS],
    
    // Write port(s)
    input  logic                      wr_en    [WRITE_PORTS],
    input  logic [ENTRY_BITS-1:0]     wr_addr  [WRITE_PORTS],
    input  logic [DATA_WIDTH-1:0]     wr_data  [WRITE_PORTS]
);

    // ════════════════════════════════════════════════════════════════════
    // Register Array
    // ════════════════════════════════════════════════════════════════════
    logic [DATA_WIDTH-1:0] regs [0:ENTRIES-1];

    // ════════════════════════════════════════════════════════════════════
    // Write Logic
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all registers to 0
            for (int i = 0; i < ENTRIES; i++) begin
                regs[i] <= '0;
            end
        end else begin
            // Handle writes (priority to lower-indexed port on conflict)
            for (int p = 0; p < WRITE_PORTS; p++) begin
                if (wr_en[p] && wr_addr[p] != '0) begin  // r0 often hardwired to 0
                    regs[wr_addr[p]] <= wr_data[p];
                end
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Read Logic with Optional Bypass
    // ════════════════════════════════════════════════════════════════════
    generate
        if (HAS_BYPASS) begin : gen_bypass
            // Combinational read with write bypass
            always_comb begin
                for (int rp = 0; rp < READ_PORTS; rp++) begin
                    // Default: read from register array
                    rd_data[rp] = regs[rd_addr[rp]];
                    
                    // Bypass: if writing to same address this cycle, forward data
                    for (int wp = 0; wp < WRITE_PORTS; wp++) begin
                        if (wr_en[wp] && (wr_addr[wp] == rd_addr[rp])) begin
                            rd_data[rp] = wr_data[wp];
                        end
                    end
                    
                    // Register 0 always reads as 0 (RISC convention)
                    if (rd_addr[rp] == '0) begin
                        rd_data[rp] = '0;
                    end
                end
            end
        end else begin : gen_no_bypass
            // Simple registered read (1-cycle latency)
            always_ff @(posedge clk) begin
                for (int rp = 0; rp < READ_PORTS; rp++) begin
                    if (rd_addr[rp] == '0) begin
                        rd_data[rp] <= '0;
                    end else begin
                        rd_data[rp] <= regs[rd_addr[rp]];
                    end
                end
            end
        end
    endgenerate

    // ════════════════════════════════════════════════════════════════════
    // Assertions
    // ════════════════════════════════════════════════════════════════════
`ifndef SYNTHESIS
    // Address in range
    generate
        for (genvar rp = 0; rp < READ_PORTS; rp++) begin : gen_rd_assert
            assert property (@(posedge clk) disable iff (!rst_n)
                rd_addr[rp] < ENTRIES
            ) else $error("RegFile: Read address out of range");
        end
        
        for (genvar wp = 0; wp < WRITE_PORTS; wp++) begin : gen_wr_assert
            assert property (@(posedge clk) disable iff (!rst_n)
                !wr_en[wp] || (wr_addr[wp] < ENTRIES)
            ) else $error("RegFile: Write address out of range");
        end
    endgenerate
`endif

endmodule : {{MODULE_NAME}}_regfile_ctrl
