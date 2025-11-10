//==============================================================================
// DDR MEMORY CONTROLLER - MAIN CONTROLLER SKELETON
// This skeleton will be filled by LLM based on user specifications
//==============================================================================
// USER SPECIFICATIONS TO CONSIDER:
// - DDR Generation: {{DDR_GEN}} (DDR2/DDR3/DDR4/DDR5)
// - Data Width: {{DATA_WIDTH}} bits
// - Address Width: {{ADDR_WIDTH}} bits  
// - Number of Banks: {{NUM_BANKS}}
// - Burst Length: {{BURST_LENGTH}}
// - Host Interface Type: {{HOST_IF_TYPE}} (AXI4/AXI4-Lite/AHB/Custom)
// - PHY Interface Type: {{PHY_IF_TYPE}} (DFI/Custom)
// - Operating Frequency: {{FREQ_MHZ}} MHz
//==============================================================================

`include "{{PARAMS_FILE}}.svh"
`include "{{TIMESCALE_FILE}}.svh"

module {{MODULE_NAME}}_main_ctrl
{{PARAMETER_SECTION}}
(
    // System signals
    input  logic                        clk,
    input  logic                        rst_n,
    
    // Configuration Interface (APB/AXI-Lite/Custom)
    {{CONFIG_INTERFACE_PORTS}}
    
    // Host Interface (AXI/AHB/Custom)
    {{HOST_INTERFACE_PORTS}}
    
    // PHY Interface (DFI/Custom)  
    {{PHY_INTERFACE_PORTS}}
    
    // Optional: Debug/Status Interface
    {{DEBUG_INTERFACE_PORTS}}
);

    //==========================================================================
    // Internal Signals and Interfaces
    //==========================================================================
    
    // Timing parameters interface
    {{TIMING_IF_TYPE}} timing_if();
    
    // Bank request interfaces
    REQ_IF bank_req_if[{{NUM_BANKS}}](.clk(clk), .rst_n(rst_n));
    
    // Scheduler request signals
    logic [{{NUM_BANKS}}-1:0] act_req;
    logic [{{NUM_BANKS}}-1:0] rd_req;
    logic [{{NUM_BANKS}}-1:0] wr_req;
    logic [{{NUM_BANKS}}-1:0] pre_req;
    logic [{{NUM_BANKS}}-1:0] ref_req;
    
    // Scheduler grant signals
    logic [{{NUM_BANKS}}-1:0] act_gnt;
    logic [{{NUM_BANKS}}-1:0] rd_gnt;
    logic [{{NUM_BANKS}}-1:0] wr_gnt;
    logic [{{NUM_BANKS}}-1:0] pre_gnt;
    logic [{{NUM_BANKS}}-1:0] ref_gnt;
    
    // Address arrays for scheduler
    {{ROW_ADDR_TYPE}} row_addr[{{NUM_BANKS}}];
    {{COL_ADDR_TYPE}} col_addr[{{NUM_BANKS}}];
    {{ID_TYPE}}       req_id[{{NUM_BANKS}}];
    {{LEN_TYPE}}      req_len[{{NUM_BANKS}}];
    
    // Scheduler output interface
    SCHED_IF sched_if();
    
    // Internal buffering interfaces
    {{INTERNAL_BUFFER_INTERFACES}}
    
    //==========================================================================
    // Module: Configuration Manager
    // Purpose: Manage timing parameters and controller configuration
    //==========================================================================
    {{MODULE_NAME}}_cfg u_cfg (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Configuration interface
        {{CONFIG_IF_CONNECTION}},
        
        // Timing parameters output
        .timing_if              (timing_if)
        
        {{ADDITIONAL_CFG_PORTS}}
    );
    
    //==========================================================================
    // Module: Address Decoder
    // Purpose: Decode host addresses to bank/row/column
    //==========================================================================
    {{MODULE_NAME}}_addr_decoder u_decoder (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Host interface connections
        {{HOST_ADDR_CONNECTIONS}},
        
        // Bank request outputs
        .req_if_arr             (bank_req_if)
        
        {{ADDITIONAL_DECODER_PORTS}}
    );
    
    //==========================================================================
    // Module: Bank Controllers
    // Purpose: Per-bank state machines and request generation
    //==========================================================================
    genvar bank_idx;
    generate
        for (bank_idx = 0; bank_idx < {{NUM_BANKS}}; bank_idx = bank_idx + 1) begin : gen_bank_ctrl
            {{MODULE_NAME}}_bank_ctrl #(
                .BANK_ID        (bank_idx)
                {{BANK_CTRL_PARAMS}}
            ) u_bank_ctrl (
                .clk            (clk),
                .rst_n          (rst_n),
                
                // Timing interface
                .timing_if      (timing_if),
                
                // Request interface
                .req_if         (bank_req_if[bank_idx]),
                
                // Scheduler requests
                .act_req_o      (act_req[bank_idx]),
                .rd_req_o       (rd_req[bank_idx]),
                .wr_req_o       (wr_req[bank_idx]),
                .pre_req_o      (pre_req[bank_idx]),
                .ref_req_o      (ref_req[bank_idx]),
                
                // Address outputs
                .row_addr_o     (row_addr[bank_idx]),
                .col_addr_o     (col_addr[bank_idx]),
                .id_o           (req_id[bank_idx]),
                .len_o          (req_len[bank_idx]),
                
                // Scheduler grants
                .act_gnt_i      (act_gnt[bank_idx]),
                .rd_gnt_i       (rd_gnt[bank_idx]),
                .wr_gnt_i       (wr_gnt[bank_idx]),
                .pre_gnt_i      (pre_gnt[bank_idx]),
                .ref_gnt_i      (ref_gnt[bank_idx])
                
                {{ADDITIONAL_BANK_PORTS}}
            );
        end
    endgenerate
    
    //==========================================================================
    // Module: Command Scheduler
    // Purpose: Arbitrate between banks and enforce timing
    //==========================================================================
    {{MODULE_NAME}}_scheduler u_scheduler (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Bank requests
        .act_req_arr            (act_req),
        .rd_req_arr             (rd_req),
        .wr_req_arr             (wr_req),
        .pre_req_arr            (pre_req),
        .ref_req_arr            (ref_req),
        
        // Address inputs
        .row_addr_arr           (row_addr),
        .col_addr_arr           (col_addr),
        .id_arr                 (req_id),
        .len_arr                (req_len),
        
        // Grant outputs
        .act_gnt_arr            (act_gnt),
        .rd_gnt_arr             (rd_gnt),
        .wr_gnt_arr             (wr_gnt),
        .pre_gnt_arr            (pre_gnt),
        .ref_gnt_arr            (ref_gnt),
        
        // Scheduler output
        .sched_if               (sched_if)
        
        {{ADDITIONAL_SCHED_PORTS}}
    );
    
    //==========================================================================
    // Module: Command Encoder
    // Purpose: Convert scheduler output to PHY commands
    //==========================================================================
    {{MODULE_NAME}}_cmd_encoder u_encoder (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Scheduler interface
        .sched_if               (sched_if),
        
        // PHY control interface
        {{PHY_CTRL_CONNECTION}}
        
        {{ADDITIONAL_ENCODER_PORTS}}
    );
    
    //==========================================================================
    // Module: Write Data Controller
    // Purpose: Handle write data path and buffering
    //==========================================================================
    {{MODULE_NAME}}_wr_ctrl u_wr_ctrl (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Timing interface
        .timing_if              (timing_if),
        
        // Scheduler interface
        .sched_if               (sched_if),
        
        // Host write interface
        {{HOST_WRITE_CONNECTIONS}},
        
        // PHY write interface
        {{PHY_WRITE_CONNECTION}}
        
        {{ADDITIONAL_WR_CTRL_PORTS}}
    );
    
    //==========================================================================
    // Module: Read Data Controller
    // Purpose: Handle read data path and reordering
    //==========================================================================
    {{MODULE_NAME}}_rd_ctrl u_rd_ctrl (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        // Timing interface
        .timing_if              (timing_if),
        
        // Scheduler interface
        .sched_if               (sched_if),
        
        // PHY read interface
        {{PHY_READ_CONNECTION}},
        
        // Host read interface
        {{HOST_READ_CONNECTIONS}}
        
        {{ADDITIONAL_RD_CTRL_PORTS}}
    );
    
    //==========================================================================
    // Optional: Initialization Sequence Controller
    //==========================================================================
    {{INIT_CONTROLLER_SECTION}}
    
    //==========================================================================
    // Optional: Power Management Controller
    //==========================================================================
    {{POWER_MGMT_SECTION}}
    
    //==========================================================================
    // Optional: Error Correction/Detection
    //==========================================================================
    {{ECC_SECTION}}
    
    //==========================================================================
    // Assertions for Verification
    //==========================================================================
    // synthesis translate_off
    {{ASSERTION_SECTION}}
    // synthesis translate_on
    
endmodule : {{MODULE_NAME}}_main_ctrl