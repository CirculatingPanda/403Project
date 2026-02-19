//==============================================================================
// ROM Controller Skeleton
// High-accuracy template - read-only simplifies everything
//
// Parameters from spec.json:
//   {{MODULE_NAME}}, {{DATA_WIDTH}}, {{MEM_DEPTH}}, {{MEM_ADDR_BITS}},
//   {{ADDR_WIDTH}}, {{READ_LATENCY}}
//==============================================================================

`timescale 1ns / 1ps

module {{MODULE_NAME}}_rom_ctrl #(
    parameter int DATA_WIDTH    = {{DATA_WIDTH}},
    parameter int MEM_DEPTH     = {{MEM_DEPTH}},
    parameter int MEM_ADDR_BITS = {{MEM_ADDR_BITS}},
    parameter int ADDR_WIDTH    = {{ADDR_WIDTH}},
    parameter int READ_LATENCY  = {{READ_LATENCY}}
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // Host interface (read-only)
    input  logic                      req_valid,
    output logic                      req_ready,
    input  logic [ADDR_WIDTH-1:0]     req_addr,
    
    output logic                      rsp_valid,
    input  logic                      rsp_ready,
    output logic [DATA_WIDTH-1:0]     rsp_rdata,
    output logic                      rsp_err
);

    // ════════════════════════════════════════════════════════════════════
    // Local Parameters
    // ════════════════════════════════════════════════════════════════════
    localparam int ADDR_LSB = $clog2(DATA_WIDTH / 8);

    // ════════════════════════════════════════════════════════════════════
    // ROM Memory (initialized from file or synthesis attribute)
    // ════════════════════════════════════════════════════════════════════
    (* rom_style = "block" *)
    logic [DATA_WIDTH-1:0] rom [0:MEM_DEPTH-1];
    
    // Initialize ROM (uncomment one method):
    // Method 1: From hex file
    // initial $readmemh("rom_init.hex", rom);
    
    // Method 2: Synthesis will infer from usage

    // ════════════════════════════════════════════════════════════════════
    // FSM (simplified for read-only)
    // ════════════════════════════════════════════════════════════════════
    typedef enum logic [1:0] {
        ST_IDLE = 2'b00,
        ST_READ = 2'b01,
        ST_RESP = 2'b10
    } state_t;
    
    state_t state, state_next;
    
    // Latched address
    logic [MEM_ADDR_BITS-1:0] latched_addr;
    
    // Read data
    logic [DATA_WIDTH-1:0] rdata_reg;
    
    // Timer for latency
    logic [$clog2(READ_LATENCY+1)-1:0] timer;

    // ════════════════════════════════════════════════════════════════════
    // State Register
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= state_next;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Next State Logic
    // ════════════════════════════════════════════════════════════════════
    always_comb begin
        state_next = state;
        
        case (state)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    state_next = ST_READ;
                end
            end
            
            ST_READ: begin
                if (timer == 0) begin
                    state_next = ST_RESP;
                end
            end
            
            ST_RESP: begin
                if (rsp_valid && rsp_ready) begin
                    state_next = ST_IDLE;
                end
            end
            
            default: state_next = ST_IDLE;
        endcase
    end

    // ════════════════════════════════════════════════════════════════════
    // Address Latching
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched_addr <= '0;
        end else if (state == ST_IDLE && req_valid && req_ready) begin
            // Extract word address from byte address
            latched_addr <= req_addr[ADDR_LSB +: MEM_ADDR_BITS];
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Timer
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        timer <= READ_LATENCY - 1;
                    end
                end
                ST_READ: begin
                    if (timer > 0) begin
                        timer <= timer - 1'b1;
                    end
                end
                default: timer <= '0;
            endcase
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // ROM Read
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata_reg <= '0;
        end else if (state == ST_READ && timer == 0) begin
            rdata_reg <= rom[latched_addr];
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Output Assignments
    // ════════════════════════════════════════════════════════════════════
    assign req_ready = (state == ST_IDLE);
    assign rsp_valid = (state == ST_RESP);
    assign rsp_rdata = rdata_reg;
    assign rsp_err   = 1'b0;  // ROM never has errors

    // ════════════════════════════════════════════════════════════════════
    // Assertions
    // ════════════════════════════════════════════════════════════════════
`ifndef SYNTHESIS
    // Address in range
    assert property (@(posedge clk) disable iff (!rst_n)
        (req_valid && req_ready) |-> 
        (req_addr[ADDR_LSB +: MEM_ADDR_BITS] < MEM_DEPTH)
    ) else $error("ROM: Address out of range");
`endif

endmodule : {{MODULE_NAME}}_rom_ctrl
