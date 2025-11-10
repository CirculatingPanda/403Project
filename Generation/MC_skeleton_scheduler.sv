//==============================================================================
// DDR MEMORY CONTROLLER - COMMAND SCHEDULER SKELETON
// This skeleton arbitrates between banks and enforces inter-bank timing
//==============================================================================
// SCHEDULER SPECIFICATIONS:
// - Scheduling Algorithm: {{SCHED_ALGO}} (FCFS/FR-FCFS/Priority/Custom)
// - Command Queue Depth: {{CMD_QUEUE_DEPTH}}
// - Read/Write Turnaround: {{RW_TURNAROUND}}
// - Support for QoS: {{QOS_SUPPORT}}
//==============================================================================

`include "{{PARAMS_FILE}}.svh"
`include "{{TIMESCALE_FILE}}.svh"

module {{MODULE_NAME}}_scheduler
{{PARAMETER_SECTION}}
(
    // System signals
    input  logic                        clk,
    input  logic                        rst_n,
    
    // Bank request inputs
    input  logic [{{NUM_BANKS}}-1:0]   act_req_arr,
    input  logic [{{NUM_BANKS}}-1:0]   rd_req_arr,
    input  logic [{{NUM_BANKS}}-1:0]   wr_req_arr,
    input  logic [{{NUM_BANKS}}-1:0]   pre_req_arr,
    input  logic [{{NUM_BANKS}}-1:0]   ref_req_arr,
    
    // Address inputs from banks
    input  {{ROW_ADDR_TYPE}}           row_addr_arr [{{NUM_BANKS}}],
    input  {{COL_ADDR_TYPE}}           col_addr_arr [{{NUM_BANKS}}],
    input  {{ID_TYPE}}                 id_arr [{{NUM_BANKS}}],
    input  {{LEN_TYPE}}                 len_arr [{{NUM_BANKS}}],
    
    // Grant outputs to banks
    output logic [{{NUM_BANKS}}-1:0]   act_gnt_arr,
    output logic [{{NUM_BANKS}}-1:0]   rd_gnt_arr,
    output logic [{{NUM_BANKS}}-1:0]   wr_gnt_arr,
    output logic [{{NUM_BANKS}}-1:0]   pre_gnt_arr,
    output logic [{{NUM_BANKS}}-1:0]   ref_gnt_arr,
    
    // Scheduler output interface
    SCHED_IF.SRC                        sched_if
    
    {{ADDITIONAL_PORTS}}
);

    //==========================================================================
    // Command Types
    //==========================================================================
    typedef enum logic [2:0] {
        CMD_NOP     = 3'b000,
        CMD_ACT     = 3'b001,
        CMD_READ    = 3'b010,
        CMD_WRITE   = 3'b011,
        CMD_PRE     = 3'b100,
        CMD_REF     = 3'b101,
        CMD_PREA    = 3'b110,
        CMD_REFA    = 3'b111
    } cmd_type_t;
    
    //==========================================================================
    // Scheduler State Machine
    //==========================================================================
    typedef enum logic [{{SCHED_STATE_WIDTH}}-1:0] {
        SCHED_IDLE          = {{SCHED_IDLE_VAL}},
        SCHED_ARBITRATE     = {{SCHED_ARB_VAL}},
        SCHED_ISSUE         = {{SCHED_ISSUE_VAL}}
        {{ADDITIONAL_SCHED_STATES}}
    } sched_state_t;
    
    //==========================================================================
    // Internal Signals
    //==========================================================================
    sched_state_t               sched_state, sched_state_nxt;
    
    // Selected command and bank
    cmd_type_t                  selected_cmd, selected_cmd_nxt;
    logic [{{BANK_WIDTH}}-1:0] selected_bank, selected_bank_nxt;
    logic                       cmd_valid, cmd_valid_nxt;
    
    // Inter-bank timing trackers
    logic [{{TIMING_WIDTH}}-1:0] t_rrd_cnt;  // ACT to ACT delay
    logic [{{TIMING_WIDTH}}-1:0] t_ccd_cnt;  // CAS to CAS delay
    logic [{{TIMING_WIDTH}}-1:0] t_wtr_cnt;  // Write to Read delay
    logic [{{TIMING_WIDTH}}-1:0] t_rtw_cnt;  // Read to Write delay
    {{ADDITIONAL_TIMING_COUNTERS}}
    
    // FAW (Four Activate Window) tracker for {{DDR_GEN}}
    logic [3:0]                 faw_window [{{FAW_WINDOW_SIZE}}];
    logic [{{FAW_CNT_WIDTH}}-1:0] faw_cnt;
    
    // Read/Write mode tracking
    logic                       read_mode, read_mode_nxt;
    logic                       write_mode, write_mode_nxt;
    logic [{{BURST_CNT_WIDTH}}-1:0] burst_cnt, burst_cnt_nxt;
    
    // Command queue (optional)
    {{COMMAND_QUEUE_SIGNALS}}
    
    // Priority/QoS signals (optional)
    {{QOS_SIGNALS}}
    
    //==========================================================================
    // Sequential Logic
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sched_state     <= SCHED_IDLE;
            selected_cmd    <= CMD_NOP;
            selected_bank   <= '0;
            cmd_valid       <= 1'b0;
            read_mode       <= 1'b0;
            write_mode      <= 1'b0;
            burst_cnt       <= '0;
            
            // Reset timing counters
            t_rrd_cnt       <= '0;
            t_ccd_cnt       <= '0;
            t_wtr_cnt       <= '0;
            t_rtw_cnt       <= '0;
            faw_cnt         <= '0;
            
            {{RESET_ADDITIONAL_SIGNALS}}
            
        end else begin
            sched_state     <= sched_state_nxt;
            selected_cmd    <= selected_cmd_nxt;
            selected_bank   <= selected_bank_nxt;
            cmd_valid       <= cmd_valid_nxt;
            read_mode       <= read_mode_nxt;
            write_mode      <= write_mode_nxt;
            burst_cnt       <= burst_cnt_nxt;
            
            // Update timing counters
            t_rrd_cnt       <= (t_rrd_cnt > 0) ? t_rrd_cnt - 1'b1 : '0;
            t_ccd_cnt       <= (t_ccd_cnt > 0) ? t_ccd_cnt - 1'b1 : '0;
            t_wtr_cnt       <= (t_wtr_cnt > 0) ? t_wtr_cnt - 1'b1 : '0;
            t_rtw_cnt       <= (t_rtw_cnt > 0) ? t_rtw_cnt - 1'b1 : '0;
            
            {{UPDATE_ADDITIONAL_SIGNALS}}
        end
    end
    
    //==========================================================================
    // FAW Window Management
    //==========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < {{FAW_WINDOW_SIZE}}; i++) begin
                faw_window[i] <= '0;
            end
        end else begin
            // Shift window and track activates
            {{FAW_WINDOW_LOGIC}}
        end
    end
    
    //==========================================================================
    // Arbitration Logic - Select next command
    //==========================================================================
    logic can_issue_act;
    logic can_issue_read;
    logic can_issue_write;
    logic can_issue_pre;
    logic can_issue_ref;
    
    always_comb begin
        // Check timing constraints
        can_issue_act   = (t_rrd_cnt == '0) && (faw_cnt < {{MAX_FAW_ACTS}});
        can_issue_read  = (t_ccd_cnt == '0) && (t_rtw_cnt == '0);
        can_issue_write = (t_ccd_cnt == '0) && (t_wtr_cnt == '0);
        can_issue_pre   = 1'b1;  // Usually no inter-bank constraint
        can_issue_ref   = 1'b1;  // Check all banks idle
        
        {{ADDITIONAL_TIMING_CHECKS}}
    end
    
    //==========================================================================
    // Priority Encoder / Arbitration
    //==========================================================================
    logic [{{BANK_WIDTH}}-1:0] next_act_bank;
    logic [{{BANK_WIDTH}}-1:0] next_rd_bank;
    logic [{{BANK_WIDTH}}-1:0] next_wr_bank;
    logic [{{BANK_WIDTH}}-1:0] next_pre_bank;
    logic [{{BANK_WIDTH}}-1:0] next_ref_bank;
    logic                       act_pending;
    logic                       rd_pending;
    logic                       wr_pending;
    logic                       pre_pending;
    logic                       ref_pending;
    
    always_comb begin
        // Find next requesting bank for each command type
        {{ARBITRATION_LOGIC}}
        
        // Default: Simple priority encoder
        act_pending = |act_req_arr;
        rd_pending  = |rd_req_arr;
        wr_pending  = |wr_req_arr;
        pre_pending = |pre_req_arr;
        ref_pending = |ref_req_arr;
        
        // Priority encode to find bank
        next_act_bank = '0;
        next_rd_bank  = '0;
        next_wr_bank  = '0;
        next_pre_bank = '0;
        next_ref_bank = '0;
        
        for (int i = 0; i < {{NUM_BANKS}}; i++) begin
            if (act_req_arr[i] && (next_act_bank == '0)) next_act_bank = i;
            if (rd_req_arr[i]  && (next_rd_bank == '0))  next_rd_bank = i;
            if (wr_req_arr[i]  && (next_wr_bank == '0))  next_wr_bank = i;
            if (pre_req_arr[i] && (next_pre_bank == '0)) next_pre_bank = i;
            if (ref_req_arr[i] && (next_ref_bank == '0)) next_ref_bank = i;
        end
    end
    
    //==========================================================================
    // Main Scheduler State Machine
    //==========================================================================
    always_comb begin
        // Default assignments
        sched_state_nxt     = sched_state;
        selected_cmd_nxt    = selected_cmd;
        selected_bank_nxt   = selected_bank;
        cmd_valid_nxt       = cmd_valid;
        read_mode_nxt       = read_mode;
        write_mode_nxt      = write_mode;
        burst_cnt_nxt       = burst_cnt;
        
        // Clear all grants by default
        act_gnt_arr         = '0;
        rd_gnt_arr          = '0;
        wr_gnt_arr          = '0;
        pre_gnt_arr         = '0;
        ref_gnt_arr         = '0;
        
        {{DEFAULT_SCHED_OUTPUTS}}
        
        case (sched_state)
            //==================================================================
            // IDLE/ARBITRATE - Select next command
            //==================================================================
            SCHED_IDLE, SCHED_ARBITRATE: begin
                cmd_valid_nxt = 1'b0;
                
                // Priority-based command selection
                if ({{SCHEDULING_ALGORITHM}}) begin
                    // Custom scheduling algorithm
                    {{CUSTOM_SCHEDULING_LOGIC}}
                    
                end else begin
                    // Default FR-FCFS style scheduling
                    if (read_mode && rd_pending && can_issue_read) begin
                        // Continue reading
                        selected_cmd_nxt = CMD_READ;
                        selected_bank_nxt = next_rd_bank;
                        cmd_valid_nxt = 1'b1;
                        
                    end else if (write_mode && wr_pending && can_issue_write) begin
                        // Continue writing
                        selected_cmd_nxt = CMD_WRITE;
                        selected_bank_nxt = next_wr_bank;
                        cmd_valid_nxt = 1'b1;
                        
                    end else if (rd_pending && can_issue_read && !write_mode) begin
                        // Switch to read mode
                        selected_cmd_nxt = CMD_READ;
                        selected_bank_nxt = next_rd_bank;
                        cmd_valid_nxt = 1'b1;
                        read_mode_nxt = 1'b1;
                        write_mode_nxt = 1'b0;
                        
                    end else if (wr_pending && can_issue_write && !read_mode) begin
                        // Switch to write mode
                        selected_cmd_nxt = CMD_WRITE;
                        selected_bank_nxt = next_wr_bank;
                        cmd_valid_nxt = 1'b1;
                        read_mode_nxt = 1'b0;
                        write_mode_nxt = 1'b1;
                        
                    end else if (act_pending && can_issue_act) begin
                        // Issue activate
                        selected_cmd_nxt = CMD_ACT;
                        selected_bank_nxt = next_act_bank;
                        cmd_valid_nxt = 1'b1;
                        
                    end else if (pre_pending && can_issue_pre) begin
                        // Issue precharge
                        selected_cmd_nxt = CMD_PRE;
                        selected_bank_nxt = next_pre_bank;
                        cmd_valid_nxt = 1'b1;
                        
                    end else if (ref_pending && can_issue_ref) begin
                        // Issue refresh
                        selected_cmd_nxt = CMD_REF;
                        selected_bank_nxt = next_ref_bank;
                        cmd_valid_nxt = 1'b1;
                    end
                end
                
                if (cmd_valid_nxt) begin
                    sched_state_nxt = SCHED_ISSUE;
                end
            end
            
            //==================================================================
            // ISSUE - Send command and update timing
            //==================================================================
            SCHED_ISSUE: begin
                // Issue grants
                case (selected_cmd)
                    CMD_ACT: begin
                        act_gnt_arr[selected_bank] = 1'b1;
                        // Update timing counters
                        {{UPDATE_ACT_TIMING}}
                    end
                    
                    CMD_READ: begin
                        rd_gnt_arr[selected_bank] = 1'b1;
                        burst_cnt_nxt = {{BURST_LENGTH}};
                        {{UPDATE_READ_TIMING}}
                    end
                    
                    CMD_WRITE: begin
                        wr_gnt_arr[selected_bank] = 1'b1;
                        burst_cnt_nxt = {{BURST_LENGTH}};
                        {{UPDATE_WRITE_TIMING}}
                    end
                    
                    CMD_PRE: begin
                        pre_gnt_arr[selected_bank] = 1'b1;
                        {{UPDATE_PRE_TIMING}}
                    end
                    
                    CMD_REF: begin
                        ref_gnt_arr[selected_bank] = 1'b1;
                        {{UPDATE_REF_TIMING}}
                    end
                endcase
                
                // Prepare scheduler output
                {{PREPARE_SCHED_OUTPUT}}
                
                sched_state_nxt = SCHED_IDLE;
            end
            
            {{ADDITIONAL_SCHED_STATES_LOGIC}}
            
            default: begin
                sched_state_nxt = SCHED_IDLE;
            end
        endcase
    end
    
    //==========================================================================
    // Scheduler Output Interface Assignment
    //==========================================================================
    always_comb begin
        sched_if.cmd_valid = cmd_valid;
        sched_if.cmd_type  = selected_cmd;
        sched_if.bank_sel  = selected_bank;
        
        // Address and data assignments
        sched_if.row_addr  = row_addr_arr[selected_bank];
        sched_if.col_addr  = col_addr_arr[selected_bank];
        sched_if.req_id    = id_arr[selected_bank];
        sched_if.req_len   = len_arr[selected_bank];
        
        {{ADDITIONAL_SCHED_IF_ASSIGNS}}
    end
    
    //==========================================================================
    // Optional: Performance Monitoring
    //==========================================================================
    {{PERFORMANCE_MONITORING}}
    
    //==========================================================================
    // Optional: QoS/Priority Management
    //==========================================================================
    {{QOS_MANAGEMENT}}
    
    //==========================================================================
    // Assertions for Verification
    //==========================================================================
    // synthesis translate_off
    {{SCHEDULER_ASSERTIONS}}
    // synthesis translate_on
    
endmodule : {{MODULE_NAME}}_scheduler
