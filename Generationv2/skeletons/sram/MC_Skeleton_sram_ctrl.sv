//==============================================================================
// SRAM Controller Skeleton v2
// High-accuracy template - nearly complete, minimal AI completion needed
//
// Parameters from spec.json:
//   {{MODULE_NAME}}, {{DATA_WIDTH}}, {{ADDR_WIDTH}}, {{MEM_DEPTH}},
//   {{MEM_ADDR_BITS}}, {{READ_LATENCY}}, {{STROBE_WIDTH}},
//   {{HAS_WRITE_MASK}}, {{HAS_ECC}}
//==============================================================================

`timescale 1ns / 1ps

module {{MODULE_NAME}}_sram_ctrl #(
    parameter int DATA_WIDTH    = {{DATA_WIDTH}},
    parameter int ADDR_WIDTH    = {{ADDR_WIDTH}},
    parameter int MEM_DEPTH     = {{MEM_DEPTH}},
    parameter int MEM_ADDR_BITS = {{MEM_ADDR_BITS}},
    parameter int READ_LATENCY  = {{READ_LATENCY}},
    parameter int STROBE_WIDTH  = {{STROBE_WIDTH}},
    parameter bit HAS_WRITE_MASK = {{HAS_WRITE_MASK}},
    parameter bit HAS_ECC       = {{HAS_ECC}}
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    // ── Host Interface (Ready/Valid) ──────────────────────────────────
    input  logic                      req_valid,
    output logic                      req_ready,
    input  logic                      req_write,
    input  logic [ADDR_WIDTH-1:0]     req_addr,
    input  logic [DATA_WIDTH-1:0]     req_wdata,
    input  logic [STROBE_WIDTH-1:0]   req_wstrb,
    
    output logic                      rsp_valid,
    input  logic                      rsp_ready,
    output logic                      rsp_err,
    output logic [DATA_WIDTH-1:0]     rsp_rdata,
    
    // ── Memory Interface ──────────────────────────────────────────────
    output logic                      mem_en,
    output logic                      mem_we,
    output logic [MEM_ADDR_BITS-1:0]  mem_addr,
    output logic [DATA_WIDTH-1:0]     mem_wdata,
    output logic [STROBE_WIDTH-1:0]   mem_wstrb,
    input  logic [DATA_WIDTH-1:0]     mem_rdata
);

    // ════════════════════════════════════════════════════════════════════
    // Local Parameters
    // ════════════════════════════════════════════════════════════════════
    localparam int ADDR_LSB = $clog2(DATA_WIDTH / 8);
    localparam int TIMER_BITS = (READ_LATENCY > 1) ? $clog2(READ_LATENCY) : 1;

    // ════════════════════════════════════════════════════════════════════
    // FSM States
    // ════════════════════════════════════════════════════════════════════
    typedef enum logic [1:0] {
        ST_IDLE  = 2'b00,
        ST_ISSUE = 2'b01,
        ST_WAIT  = 2'b10,
        ST_RESP  = 2'b11
    } state_t;
    
    state_t state, state_next;

    // ════════════════════════════════════════════════════════════════════
    // Internal Signals
    // ════════════════════════════════════════════════════════════════════
    logic [ADDR_WIDTH-1:0]     latched_addr;
    logic [DATA_WIDTH-1:0]     latched_wdata;
    logic [STROBE_WIDTH-1:0]   latched_wstrb;
    logic                      latched_write;
    logic [DATA_WIDTH-1:0]     rdata_reg;
    logic [TIMER_BITS-1:0]     timer;
    logic                      timer_done;

    // ════════════════════════════════════════════════════════════════════
    // FSM: State Register
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= state_next;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // FSM: Next State Logic
    // ════════════════════════════════════════════════════════════════════
    always_comb begin
        state_next = state;
        
        case (state)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    state_next = ST_ISSUE;
                end
            end
            
            ST_ISSUE: begin
                // For single-cycle writes, can skip WAIT
                if (READ_LATENCY == 1 && latched_write) begin
                    state_next = ST_RESP;
                end else begin
                    state_next = ST_WAIT;
                end
            end
            
            ST_WAIT: begin
                if (timer_done) begin
                    state_next = ST_RESP;
                end
            end
            
            ST_RESP: begin
                if (rsp_valid && rsp_ready) begin
                    state_next = ST_IDLE;
                end
            end
            
            default: begin
                state_next = ST_IDLE;
            end
        endcase
    end

    // ════════════════════════════════════════════════════════════════════
    // Request Latching
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched_addr  <= '0;
            latched_wdata <= '0;
            latched_wstrb <= '0;
            latched_write <= 1'b0;
        end else if (state == ST_IDLE && req_valid && req_ready) begin
            latched_addr  <= req_addr;
            latched_wdata <= req_wdata;
            latched_wstrb <= req_wstrb;
            latched_write <= req_write;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Latency Timer
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= '0;
        end else begin
            case (state)
                ST_ISSUE: begin
                    timer <= TIMER_BITS'(READ_LATENCY - 1);
                end
                ST_WAIT: begin
                    if (timer > 0) begin
                        timer <= timer - 1'b1;
                    end
                end
                default: begin
                    timer <= '0;
                end
            endcase
        end
    end
    
    assign timer_done = (timer == '0);

    // ════════════════════════════════════════════════════════════════════
    // Read Data Capture
    // ════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata_reg <= '0;
        end else if (state == ST_WAIT && timer_done && !latched_write) begin
            rdata_reg <= mem_rdata;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // Memory Interface
    // ════════════════════════════════════════════════════════════════════
    assign mem_en    = (state == ST_ISSUE);
    assign mem_we    = (state == ST_ISSUE) && latched_write;
    assign mem_addr  = latched_addr[ADDR_LSB +: MEM_ADDR_BITS];
    assign mem_wdata = latched_wdata;
    
    generate
        if (HAS_WRITE_MASK) begin : gen_wstrb
            assign mem_wstrb = latched_wstrb;
        end else begin : gen_no_wstrb
            assign mem_wstrb = {STROBE_WIDTH{1'b1}};
        end
    endgenerate

    // ════════════════════════════════════════════════════════════════════
    // Host Interface
    // ════════════════════════════════════════════════════════════════════
    assign req_ready = (state == ST_IDLE);
    assign rsp_valid = (state == ST_RESP);
    assign rsp_rdata = latched_write ? '0 : rdata_reg;
    assign rsp_err   = 1'b0;

    // ════════════════════════════════════════════════════════════════════
    // Assertions
    // ════════════════════════════════════════════════════════════════════
`ifndef SYNTHESIS
    // Request stable while waiting
    property p_req_stable;
        @(posedge clk) disable iff (!rst_n)
        (req_valid && !req_ready) |=> $stable(req_addr) && $stable(req_write);
    endproperty
    assert property (p_req_stable);
    
    // Response held until accepted
    property p_rsp_held;
        @(posedge clk) disable iff (!rst_n)
        (rsp_valid && !rsp_ready) |=> rsp_valid;
    endproperty
    assert property (p_rsp_held);
    
    // Address in range
    property p_addr_range;
        @(posedge clk) disable iff (!rst_n)
        (req_valid && req_ready) |-> 
            (req_addr[ADDR_LSB +: MEM_ADDR_BITS] < MEM_DEPTH);
    endproperty
    assert property (p_addr_range);
    
    // Coverage
    covergroup cg_ops @(posedge clk);
        cp_state: coverpoint state;
        cp_rw: coverpoint latched_write iff (state != ST_IDLE);
        cp_trans: cross cp_state, state_next;
    endgroup
    cg_ops cg_inst = new();
`endif

endmodule : {{MODULE_NAME}}_sram_ctrl


//==============================================================================
// SRAM Memory Block (instantiate alongside controller)
//==============================================================================
module {{MODULE_NAME}}_sram_mem #(
    parameter int DATA_WIDTH   = {{DATA_WIDTH}},
    parameter int DEPTH        = {{MEM_DEPTH}},
    parameter int ADDR_BITS    = {{MEM_ADDR_BITS}},
    parameter int STROBE_WIDTH = {{STROBE_WIDTH}}
) (
    input  logic                    clk,
    input  logic                    en,
    input  logic                    we,
    input  logic [ADDR_BITS-1:0]    addr,
    input  logic [DATA_WIDTH-1:0]   wdata,
    input  logic [STROBE_WIDTH-1:0] wstrb,
    output logic [DATA_WIDTH-1:0]   rdata
);

    // Memory array
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    
    // Synchronous read
    always_ff @(posedge clk) begin
        if (en && !we) begin
            rdata <= mem[addr];
        end
    end
    
    // Write with byte strobes
    always_ff @(posedge clk) begin
        if (en && we) begin
            for (int i = 0; i < STROBE_WIDTH; i++) begin
                if (wstrb[i]) begin
                    mem[addr][i*8 +: 8] <= wdata[i*8 +: 8];
                end
            end
        end
    end

endmodule : {{MODULE_NAME}}_sram_mem


//==============================================================================
// Top-level Wrapper
//==============================================================================
module {{MODULE_NAME}}_sram_top #(
    parameter int DATA_WIDTH    = {{DATA_WIDTH}},
    parameter int ADDR_WIDTH    = {{ADDR_WIDTH}},
    parameter int MEM_DEPTH     = {{MEM_DEPTH}},
    parameter int READ_LATENCY  = {{READ_LATENCY}}
) (
    input  logic                      clk,
    input  logic                      rst_n,
    
    input  logic                      req_valid,
    output logic                      req_ready,
    input  logic                      req_write,
    input  logic [ADDR_WIDTH-1:0]     req_addr,
    input  logic [DATA_WIDTH-1:0]     req_wdata,
    input  logic [DATA_WIDTH/8-1:0]   req_wstrb,
    
    output logic                      rsp_valid,
    input  logic                      rsp_ready,
    output logic                      rsp_err,
    output logic [DATA_WIDTH-1:0]     rsp_rdata
);

    localparam int MEM_ADDR_BITS = $clog2(MEM_DEPTH);
    localparam int STROBE_WIDTH  = DATA_WIDTH / 8;

    // Internal wires
    logic                      mem_en;
    logic                      mem_we;
    logic [MEM_ADDR_BITS-1:0]  mem_addr;
    logic [DATA_WIDTH-1:0]     mem_wdata;
    logic [STROBE_WIDTH-1:0]   mem_wstrb;
    logic [DATA_WIDTH-1:0]     mem_rdata;

    // Controller
    {{MODULE_NAME}}_sram_ctrl #(
        .DATA_WIDTH    (DATA_WIDTH),
        .ADDR_WIDTH    (ADDR_WIDTH),
        .MEM_DEPTH     (MEM_DEPTH),
        .MEM_ADDR_BITS (MEM_ADDR_BITS),
        .READ_LATENCY  (READ_LATENCY),
        .STROBE_WIDTH  (STROBE_WIDTH),
        .HAS_WRITE_MASK(1),
        .HAS_ECC       (0)
    ) u_ctrl (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (req_valid),
        .req_ready (req_ready),
        .req_write (req_write),
        .req_addr  (req_addr),
        .req_wdata (req_wdata),
        .req_wstrb (req_wstrb),
        .rsp_valid (rsp_valid),
        .rsp_ready (rsp_ready),
        .rsp_err   (rsp_err),
        .rsp_rdata (rsp_rdata),
        .mem_en    (mem_en),
        .mem_we    (mem_we),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata)
    );

    // Memory
    {{MODULE_NAME}}_sram_mem #(
        .DATA_WIDTH   (DATA_WIDTH),
        .DEPTH        (MEM_DEPTH),
        .ADDR_BITS    (MEM_ADDR_BITS),
        .STROBE_WIDTH (STROBE_WIDTH)
    ) u_mem (
        .clk   (clk),
        .en    (mem_en),
        .we    (mem_we),
        .addr  (mem_addr),
        .wdata (mem_wdata),
        .wstrb (mem_wstrb),
        .rdata (mem_rdata)
    );

endmodule : {{MODULE_NAME}}_sram_top
