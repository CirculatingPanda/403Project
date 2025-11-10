//==============================================================================
// DDR MEMORY CONTROLLER - BANK CONTROLLER SKELETON
// This skeleton manages per-bank state machine and request generation
//==============================================================================
// BANK CONTROLLER SPECIFICATIONS:
// - Bank ID: {{BANK_ID}}
// - Page Policy: {{PAGE_POLICY}} (Open/Closed/Adaptive)
// - Row Buffer Size: {{ROW_BUFFER_SIZE}}
// - Queue Depth: {{QUEUE_DEPTH}}
//==============================================================================

`include "{{PARAMS_FILE}}.svh"
`include "{{TIMESCALE_FILE}}.svh"

module {{MODULE_NAME}}_bank_ctrl
#(
    parameter integer BANK_ID = 0
    {{ADDITIONAL_PARAMS}}
)
(
    // System signals
    input  logic                        clk,
    input  logic                        rst_n,
    
    // Timing parameters interface
    TIMING_IF.MON                       timing_if,
    
    // Request interface from address decoder
    REQ_IF.DST                          req_if,
    
    // Scheduler request outputs
    output logic                        act_req_o,
    output logic                        rd_req_o,
    output logic                        wr_req_o,
    output logic                        pre_req_o,
    output logic                        ref_req_o,
    
    // Address outputs to scheduler
    output {{ROW_ADDR_TYPE}}           row_addr_o,
    output {{COL_ADDR_TYPE}}           col_addr_o,
    output {{ID_TYPE}}                 id_o,
    output {{LEN_TYPE}}                 len_o,
    
    // Scheduler grant inputs
    input  logic                        act_gnt_i,
    input  logic                        rd_gnt_i,
    input  logic                        wr_gnt_i,
    input  logic                        pre_gnt_i,
    input  logic                        ref_gnt_i,
    
    // Optional: Per-bank refresh
    input  logic                        ref_req_i,
    output logic                        ref_gnt_o
    
    {{ADDITIONAL_PORTS}}
);

    //==========================================================================
    // Bank State Machine States
    //==========================================================================
    typedef enum logic [{{STATE_WIDTH}}-1:0] {
        IDLE            = {{STATE_IDLE_VAL}},
        ACTIVATING      = {{STATE_ACT_VAL}},
        ACTIVE          = {{STATE_ACTIVE_VAL}},
        READING         = {{STATE_READ_VAL}},
        WRITING         = {{STATE_WRITE_VAL}},
        PRECHARGING     = {{STATE_PRE_VAL}},
        REFRESHING      = {{STATE_REF_VAL}}
        {{ADDITIONAL_STATES}}
    } bank_state_t;
    
    //==========================================================================
    // Internal Signals
    //==========================================================================
    bank_state_t                state, state_nxt;
    
    // Current row tracking
    {{ROW_ADDR_TYPE}}          current_row, current_row_nxt;
    logic                       row_valid, row_valid_nxt;
    
    // Timing counters
    logic [{{COUNTER_WIDTH}}-1:0] timing_cnt, timing_cnt_nxt;
    
    // Row open counter for page policy
    logic [{{ROW_OPEN_CNT_WIDTH}}-1:0] row_open_cnt, row_open_cnt_nxt;
    
    // Request queue (optional based on QUEUE_DEPTH)
    {{REQUEST_QUEUE_SIGNALS}}
    
    // Hit/miss detection
    logic row_hit;
    logic row_conflict;
    
    //==========================================================================
    // Timing Check Signals
    //==========================================================================
    logic t_rc_met;     // Row cycle time met
    logic t_ras_met;    // Row active time met
    logic t_rcd_met;    // RAS to CAS delay met
    logic t_rp_met;     // Row precharge time met
    logic t_rtp_met;    // Read to precharge time met
    logic t_wtp_met;    // Write to precharge time met
    logic t_rfc_met;    // Refresh cycle time met
    {{ADDITIONAL_TIMING_CHECKS}}
    
    //==========================================================================
    // Sequential Logic
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= IDLE;
            current_row     <= '0;
            row_valid       <= 1'b0;
            timing_cnt      <= '0;
            row_open_cnt    <= '0;
            {{RESET_ADDITIONAL_REGS}}
        end else begin
            state           <= state_nxt;
            current_row     <= current_row_nxt;
            row_valid       <= row_valid_nxt;
            timing_cnt      <= timing_cnt_nxt;
            row_open_cnt    <= row_open_cnt_nxt;
            {{UPDATE_ADDITIONAL_REGS}}
        end
    end
    
    //==========================================================================
    // Hit/Miss Detection Logic
    //==========================================================================
    always_comb begin
        row_hit = 1'b0;
        row_conflict = 1'b0;
        
        if (req_if.valid && row_valid) begin
            if (req_if.row_addr == current_row) begin
                row_hit = 1'b1;
            end else begin
                row_conflict = 1'b1;
            end
        end
    end
    
    //==========================================================================
    // Timing Check Logic
    //==========================================================================
    always_comb begin
        // Check if timing constraints are met
        t_rc_met  = (timing_cnt == '0) || (timing_cnt <= {{T_RC_CHECK}});
        t_ras_met = (timing_cnt >= {{T_RAS_CHECK}});
        t_rcd_met = (timing_cnt >= {{T_RCD_CHECK}});
        t_rp_met  = (timing_cnt >= {{T_RP_CHECK}});
        t_rtp_met = (timing_cnt >= {{T_RTP_CHECK}});
        t_wtp_met = (timing_cnt >= {{T_WTP_CHECK}});
        t_rfc_met = (timing_cnt >= {{T_RFC_CHECK}});
        {{ADDITIONAL_TIMING_CHECK_LOGIC}}
    end
    
    //==========================================================================
    // Main State Machine Logic
    //==========================================================================
    always_comb begin
        // Default assignments
        state_nxt        = state;
        current_row_nxt  = current_row;
        row_valid_nxt    = row_valid;
        timing_cnt_nxt   = (timing_cnt > 0) ? timing_cnt - 1'b1 : '0;
        row_open_cnt_nxt = row_open_cnt;
        
        // Default outputs
        req_if.ready     = 1'b0;
        act_req_o        = 1'b0;
        rd_req_o         = 1'b0;
        wr_req_o         = 1'b0;
        pre_req_o        = 1'b0;
        ref_req_o        = 1'b0;
        ref_gnt_o        = 1'b0;
        
        row_addr_o       = 'x;
        col_addr_o       = 'x;
        id_o             = 'x;
        len_o            = 'x;
        
        {{DEFAULT_ADDITIONAL_OUTPUTS}}
        
        case (state)
            //==================================================================
            // IDLE State - Wait for requests
            //==================================================================
            IDLE: begin
                if (req_if.valid) begin
                    // New request - need to activate
                    if (t_rc_met) begin
                        act_req_o = 1'b1;
                        row_addr_o = req_if.row_addr;
                        
                        if (act_gnt_i) begin
                            current_row_nxt = req_if.row_addr;
                            row_valid_nxt = 1'b1;
                            timing_cnt_nxt = {{T_RCD_CYCLES}};
                            state_nxt = ACTIVATING;
                        end
                    end
                end else if (ref_req_i) begin
                    // Refresh request
                    if (t_rc_met) begin
                        ref_req_o = 1'b1;
                        
                        if (ref_gnt_i) begin
                            ref_gnt_o = 1'b1;
                            timing_cnt_nxt = {{T_RFC_CYCLES}};
                            state_nxt = REFRESHING;
                        end
                    end
                end
            end
            
            //==================================================================
            // ACTIVATING State - Wait for tRCD
            //==================================================================
            ACTIVATING: begin
                if (timing_cnt == '0) begin
                    row_open_cnt_nxt = {{ROW_OPEN_CYCLES}};
                    state_nxt = ACTIVE;
                end
            end
            
            //==================================================================
            // ACTIVE State - Row is open, can issue RD/WR
            //==================================================================
            ACTIVE: begin
                if (req_if.valid) begin
                    if (row_hit) begin
                        // Row hit - can issue command
                        col_addr_o = req_if.col_addr;
                        id_o = req_if.id;
                        len_o = req_if.len;
                        
                        if (req_if.is_write) begin
                            // Write request
                            wr_req_o = 1'b1;
                            
                            if (wr_gnt_i) begin
                                req_if.ready = 1'b1;
                                timing_cnt_nxt = {{BURST_CYCLES}};
                                row_open_cnt_nxt = {{ROW_OPEN_CYCLES}};
                                state_nxt = WRITING;
                            end
                        end else begin
                            // Read request
                            rd_req_o = 1'b1;
                            
                            if (rd_gnt_i) begin
                                req_if.ready = 1'b1;
                                timing_cnt_nxt = {{BURST_CYCLES}};
                                row_open_cnt_nxt = {{ROW_OPEN_CYCLES}};
                                state_nxt = READING;
                            end
                        end
                    end else if (row_conflict) begin
                        // Row miss - need to precharge first
                        if (t_ras_met) begin
                            pre_req_o = 1'b1;
                            
                            if (pre_gnt_i) begin
                                row_valid_nxt = 1'b0;
                                timing_cnt_nxt = {{T_RP_CYCLES}};
                                state_nxt = PRECHARGING;
                            end
                        end
                    end
                end else if (row_open_cnt == '0) begin
                    // Auto-precharge after timeout
                    if (t_ras_met) begin
                        pre_req_o = 1'b1;
                        
                        if (pre_gnt_i) begin
                            row_valid_nxt = 1'b0;
                            timing_cnt_nxt = {{T_RP_CYCLES}};
                            state_nxt = PRECHARGING;
                        end
                    end
                end else begin
                    // Decrement row open counter
                    row_open_cnt_nxt = row_open_cnt - 1'b1;
                end
                
                {{ACTIVE_STATE_ADDITIONAL_LOGIC}}
            end
            
            //==================================================================
            // READING State - Wait for read to complete
            //==================================================================
            READING: begin
                if (timing_cnt == '0) begin
                    state_nxt = ACTIVE;
                end
                {{READING_STATE_ADDITIONAL_LOGIC}}
            end
            
            //==================================================================
            // WRITING State - Wait for write to complete
            //==================================================================
            WRITING: begin
                if (timing_cnt == '0) begin
                    state_nxt = ACTIVE;
                end
                {{WRITING_STATE_ADDITIONAL_LOGIC}}
            end
            
            //==================================================================
            // PRECHARGING State - Wait for tRP
            //==================================================================
            PRECHARGING: begin
                if (timing_cnt == '0) begin
                    state_nxt = IDLE;
                end
            end
            
            //==================================================================
            // REFRESHING State - Wait for tRFC
            //==================================================================
            REFRESHING: begin
                if (timing_cnt == '0) begin
                    state_nxt = IDLE;
                end
            end
            
            {{ADDITIONAL_STATE_LOGIC}}
            
            default: begin
                state_nxt = IDLE;
            end
        endcase
    end
    
    //==========================================================================
    // Optional: Request Queue Management
    //==========================================================================
    {{REQUEST_QUEUE_LOGIC}}
    
    //==========================================================================
    // Optional: Performance Counters
    //==========================================================================
    {{PERFORMANCE_COUNTER_LOGIC}}
    
    //==========================================================================
    // Assertions for Verification
    //==========================================================================
    // synthesis translate_off
    {{BANK_ASSERTIONS}}
    // synthesis translate_on
    
endmodule : {{MODULE_NAME}}_bank_ctrl