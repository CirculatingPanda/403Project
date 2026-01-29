module ddr_mc #(
    parameter BANK_BITS = 3,
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 10,
    parameter DATA_WIDTH = 64,
    parameter BURST_LENGTH = 8,
    parameter CAS_LATENCY = 5,
    parameter PHY_LATENCY = 2
)(
    // Clock and reset
    input  logic        phy_clk,
    input  logic        phy_rst_n,

    // Command interface (to PHY)
    output logic        phy_cmd_valid,
    input  logic        phy_cmd_ready,
    output logic [3:0]  phy_cmd,
    output logic [2:0]  phy_bank,
    output logic [12:0] phy_addr,

    // Write data interface (to PHY)
    output logic        phy_wr_valid,
    input  logic        phy_wr_ready,
    output logic [DATA_WIDTH-1:0] phy_wr_data,
    output logic [(DATA_WIDTH/8)-1:0] phy_wr_dm,
    output logic        phy_wr_last,

    // Read data interface (from PHY)
    input  logic        phy_rd_valid,
    input  logic [DATA_WIDTH-1:0] phy_rd_data,
    input  logic        phy_rd_last,

    // ODT control
    output logic        phy_odt,

    // Initialization
    input  logic        phy_init_done,

    // Host interface (abstracted for this module)
    input  logic        host_req_valid,
    output logic        host_req_ready,
    input  logic        host_req_write,
    input  logic [2:0]  host_req_bank,
    input  logic [12:0] host_req_row,
    input  logic [9:0]  host_req_col,
    input  logic [DATA_WIDTH-1:0] host_wr_data,
    input  logic [(DATA_WIDTH/8)-1:0] host_wr_dm,
    output logic        host_rd_valid,
    output logic [DATA_WIDTH-1:0] host_rd_data,
    output logic        host_rd_last,

    // Refresh request (from refresh timer)
    input  logic        refresh_req,
    output logic        refresh_ack
);

import ddr2_timing_params::*;

// JEDEC DDR2 timing parameters (example values, must be set per speed grade)
localparam int T_RCD = tRCD_CYCLES; // Activate to read/write
localparam int T_RP  = tRP_CYCLES;  // Precharge period
localparam int T_RAS = tRAS_CYCLES; // Active to precharge
localparam int T_RC  = tRC_CYCLES;  // Activate to activate (same bank)
localparam int T_WR  = tWR_CYCLES;  // Write recovery
localparam int T_RRD = tRRD_CYCLES; // Activate to activate (different bank)
localparam int T_FAW = tFAW_CYCLES; // Four activate window

// Bank state encoding
typedef enum logic [2:0] {
    BANK_IDLE        = 3'd0,
    BANK_ACTIVATING  = 3'd1,
    BANK_ACTIVE      = 3'd2,
    BANK_PRECHARGING = 3'd3,
    BANK_REFRESHING  = 3'd4
} bank_state_e;

// Per-bank state
typedef struct packed {
    bank_state_e      state;
    logic [ROW_BITS-1:0] active_row;
    logic [$clog2(T_RAS+1)-1:0] ras_timer;
    logic [$clog2(T_RCD+1)-1:0] rcd_timer;
    logic [$clog2(T_RP+1)-1:0]  rp_timer;
    logic [$clog2(T_RC+1)-1:0]  rc_timer;
    logic                      pending_precharge;
    logic                      pending_activate;
} bank_ctrl_t;

// Bank state array
bank_ctrl_t bank_ctrl [0:(1<<BANK_BITS)-1];

// Four Activate Window (FAW) tracker
logic [$clog2(T_FAW+1)-1:0] faw_counter;
logic [3:0]                 faw_window; // Tracks last 4 activates

// Refresh FSM
typedef enum logic [1:0] {
    REF_IDLE   = 2'd0,
    REF_PRE    = 2'd1,
    REF_ISSUE  = 2'd2,
    REF_WAIT   = 2'd3
} refresh_state_e;

refresh_state_e refresh_state, refresh_state_next;
logic [BANK_BITS-1:0] ref_bank_idx;
logic                 refresh_pending;
logic                 refresh_in_progress;
logic                 all_banks_idle;

// Command scheduling
logic [2:0]           sched_bank;
logic [ROW_BITS-1:0]  sched_row;
logic [COL_BITS-1:0]  sched_col;
logic                 sched_write;
logic                 sched_valid;
logic                 sched_row_hit;
logic                 sched_row_miss;
logic                 sched_precharge_needed;
logic                 sched_activate_needed;
logic                 sched_issue_read;
logic                 sched_issue_write;
logic                 sched_issue_activate;
logic                 sched_issue_precharge;
logic                 sched_issue_refresh;
logic                 sched_auto_precharge;
logic                 sched_cmd_ready;

// Host request queue (simple 1-deep for this example)
logic                 req_valid_q, req_write_q;
logic [2:0]           req_bank_q;
logic [ROW_BITS-1:0]  req_row_q;
logic [COL_BITS-1:0]  req_col_q;
logic [DATA_WIDTH-1:0] req_wr_data_q;
logic [(DATA_WIDTH/8)-1:0] req_wr_dm_q;

// Write data burst tracking
logic [3:0]           wr_burst_cnt;
logic                 wr_burst_active;

// Read data burst tracking
logic [3:0]           rd_burst_cnt;
logic                 rd_burst_active;

// ODT control
logic                 odt_on;

// Command output registers
logic        phy_cmd_valid_r;
logic [3:0]  phy_cmd_r;
logic [2:0]  phy_bank_r;
logic [12:0] phy_addr_r;

// Host ready/valid
assign host_req_ready = !req_valid_q && !refresh_in_progress;

// Host request queue logic
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        req_valid_q    <= 1'b0;
        req_write_q    <= 1'b0;
        req_bank_q     <= '0;
        req_row_q      <= '0;
        req_col_q      <= '0;
        req_wr_data_q  <= '0;
        req_wr_dm_q    <= '0;
    end else if (host_req_valid && host_req_ready) begin
        req_valid_q    <= 1'b1;
        req_write_q    <= host_req_write;
        req_bank_q     <= host_req_bank;
        req_row_q      <= host_req_row;
        req_col_q      <= host_req_col;
        req_wr_data_q  <= host_wr_data;
        req_wr_dm_q    <= host_wr_dm;
    end else if (sched_valid && sched_cmd_ready) begin
        req_valid_q    <= 1'b0;
    end
end

// Bank state machine and timing enforcement
genvar b;
generate
    for (b = 0; b < (1<<BANK_BITS); b = b + 1) begin : BANK_FSM
        always_ff @(posedge phy_clk or negedge phy_rst_n) begin
            if (!phy_rst_n) begin
                bank_ctrl[b].state           <= BANK_IDLE;
                bank_ctrl[b].active_row      <= '0;
                bank_ctrl[b].ras_timer       <= '0;
                bank_ctrl[b].rcd_timer       <= '0;
                bank_ctrl[b].rp_timer        <= '0;
                bank_ctrl[b].rc_timer        <= '0;
                bank_ctrl[b].pending_precharge <= 1'b0;
                bank_ctrl[b].pending_activate  <= 1'b0;
            end else begin
                // Default: decrement timers if nonzero
                if (bank_ctrl[b].ras_timer != 0)
                    bank_ctrl[b].ras_timer <= bank_ctrl[b].ras_timer - 1;
                if (bank_ctrl[b].rcd_timer != 0)
                    bank_ctrl[b].rcd_timer <= bank_ctrl[b].rcd_timer - 1;
                if (bank_ctrl[b].rp_timer != 0)
                    bank_ctrl[b].rp_timer <= bank_ctrl[b].rp_timer - 1;
                if (bank_ctrl[b].rc_timer != 0)
                    bank_ctrl[b].rc_timer <= bank_ctrl[b].rc_timer - 1;

                // State transitions
                case (bank_ctrl[b].state)
                    BANK_IDLE: begin
                        // Activate issued
                        if (sched_issue_activate && sched_bank == b && phy_cmd_valid && phy_cmd_ready) begin
                            bank_ctrl[b].state        <= BANK_ACTIVATING;
                            bank_ctrl[b].active_row   <= sched_row;
                            bank_ctrl[b].rcd_timer    <= T_RCD - 1;
                            bank_ctrl[b].rc_timer     <= T_RC - 1;
                        end
                        // Refresh issued (all banks)
                        else if (refresh_in_progress && refresh_state == REF_ISSUE) begin
                            bank_ctrl[b].state        <= BANK_REFRESHING;
                        end
                    end
                    BANK_ACTIVATING: begin
                        // Wait tRCD, then move to ACTIVE
                        if (bank_ctrl[b].rcd_timer == 0) begin
                            bank_ctrl[b].state      <= BANK_ACTIVE;
                            bank_ctrl[b].ras_timer  <= T_RAS - 1;
                        end
                    end
                    BANK_ACTIVE: begin
                        // Precharge issued
                        if (sched_issue_precharge && sched_bank == b && phy_cmd_valid && phy_cmd_ready) begin
                            bank_ctrl[b].state      <= BANK_PRECHARGING;
                            bank_ctrl[b].rp_timer   <= T_RP - 1;
                        end
                        // Refresh issued (all banks)
                        else if (refresh_in_progress && refresh_state == REF_PRE) begin
                            bank_ctrl[b].state      <= BANK_PRECHARGING;
                            bank_ctrl[b].rp_timer   <= T_RP - 1;
                        end
                    end
                    BANK_PRECHARGING: begin
                        // Wait tRP, then move to IDLE
                        if (bank_ctrl[b].rp_timer == 0) begin
                            bank_ctrl[b].state      <= BANK_IDLE;
                        end
                    end
                    BANK_REFRESHING: begin
                        // Wait for refresh to complete (handled by refresh FSM)
                        if (!refresh_in_progress) begin
                            bank_ctrl[b].state      <= BANK_IDLE;
                        end
                    end
                    default: bank_ctrl[b].state <= BANK_IDLE;
                endcase
            end
        end
    end
endgenerate

// Four Activate Window (FAW) logic
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        faw_counter <= '0;
        faw_window  <= 4'b0;
    end else begin
        // Shift window on each ACTIVATE
        if (sched_issue_activate && phy_cmd_valid && phy_cmd_ready) begin
            faw_window  <= {faw_window[2:0], 1'b1};
            if (faw_counter < T_FAW)
                faw_counter <= faw_counter + 1;
        end else if (faw_counter != 0) begin
            faw_counter <= faw_counter - 1;
        end
    end
end

// Detect all banks idle (for refresh)
always_comb begin
    all_banks_idle = 1'b1;
    for (int i = 0; i < (1<<BANK_BITS); i++) begin
        if (bank_ctrl[i].state != BANK_IDLE)
            all_banks_idle = 1'b0;
    end
end

// Refresh FSM
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        refresh_state        <= REF_IDLE;
        refresh_pending      <= 1'b0;
        refresh_in_progress  <= 1'b0;
        refresh_ack          <= 1'b0;
    end else begin
        refresh_ack <= 1'b0;
        case (refresh_state)
            REF_IDLE: begin
                if (refresh_req) begin
                    refresh_pending <= 1'b1;
                end
                if (refresh_pending && all_banks_idle) begin
                    refresh_in_progress <= 1'b1;
                    refresh_state       <= REF_ISSUE;
                end
            end
            REF_ISSUE: begin
                // Issue REFRESH command
                if (phy_cmd_ready) begin
                    refresh_state       <= REF_WAIT;
                end
            end
            REF_WAIT: begin
                // Wait for tRFC (not modeled here, assume 1 cycle for simplicity)
                refresh_in_progress  <= 1'b0;
                refresh_pending      <= 1'b0;
                refresh_ack          <= 1'b1;
                refresh_state        <= REF_IDLE;
            end
            default: refresh_state <= REF_IDLE;
        endcase
    end
end

// Command scheduler
always_comb begin
    // Default outputs
    sched_valid            = 1'b0;
    sched_bank             = '0;
    sched_row              = '0;
    sched_col              = '0;
    sched_write            = 1'b0;
    sched_row_hit          = 1'b0;
    sched_row_miss         = 1'b0;
    sched_precharge_needed = 1'b0;
    sched_activate_needed  = 1'b0;
    sched_issue_read       = 1'b0;
    sched_issue_write      = 1'b0;
    sched_issue_activate   = 1'b0;
    sched_issue_precharge  = 1'b0;
    sched_issue_refresh    = 1'b0;
    sched_auto_precharge   = 1'b0;
    sched_cmd_ready        = phy_cmd_ready;

    // Priority: Refresh > Precharge > Activate > Read/Write
    if (refresh_in_progress && refresh_state == REF_ISSUE) begin
        sched_valid         = 1'b1;
        sched_issue_refresh = 1'b1;
    end else if (req_valid_q) begin
        sched_bank = req_bank_q;
        sched_row  = req_row_q;
        sched_col  = req_col_q;
        sched_write= req_write_q;

        // Bank state
        case (bank_ctrl[req_bank_q].state)
            BANK_IDLE: begin
                sched_activate_needed = 1'b1;
                sched_issue_activate  = 1'b1;
                sched_valid           = 1'b1;
            end
            BANK_ACTIVE: begin
                if (bank_ctrl[req_bank_q].active_row == req_row_q) begin
                    sched_row_hit = 1'b1;
                    if (req_write_q) begin
                        sched_issue_write = 1'b1;
                        sched_valid       = 1'b1;
                    end else begin
                        sched_issue_read  = 1'b1;
                        sched_valid       = 1'b1;
                    end
                end else begin
                    // Row miss: must precharge then activate
                    sched_precharge_needed = 1'b1;
                    sched_issue_precharge  = 1'b1;
                    sched_valid            = 1'b1;
                end
            end
            BANK_PRECHARGING, BANK_ACTIVATING, BANK_REFRESHING: begin
                // Wait for bank to become IDLE or ACTIVE
                sched_valid = 1'b0;
            end
            default: sched_valid = 1'b0;
        endcase
    end
end

// Command output logic
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        phy_cmd_valid_r <= 1'b0;
        phy_cmd_r       <= 4'b0000;
        phy_bank_r      <= '0;
        phy_addr_r      <= '0;
    end else begin
        phy_cmd_valid_r <= 1'b0;
        phy_cmd_r       <= 4'b0000;
        phy_bank_r      <= '0;
        phy_addr_r      <= '0;

        if (sched_valid && phy_cmd_ready) begin
            phy_cmd_valid_r <= 1'b1;
            if (sched_issue_refresh) begin
                phy_cmd_r   <= 4'b0101; // REFRESH
                phy_bank_r  <= 3'b000;
                phy_addr_r  <= 13'b0;
            end else if (sched_issue_precharge) begin
                phy_cmd_r   <= 4'b0100; // PRECHARGE
                phy_bank_r  <= sched_bank;
                phy_addr_r  <= 13'b100_0000_0000; // A10=1 for all banks, else 0 for single bank
            end else if (sched_issue_activate) begin
                phy_cmd_r   <= 4'b0001; // ACTIVATE
                phy_bank_r  <= sched_bank;
                phy_addr_r  <= sched_row;
            end else if (sched_issue_read) begin
                phy_cmd_r   <= 4'b0010; // READ
                phy_bank_r  <= sched_bank;
                phy_addr_r  <= {3'b0, sched_col}; // A10=0 for no auto-precharge
            end else if (sched_issue_write) begin
                phy_cmd_r   <= 4'b0011; // WRITE
                phy_bank_r  <= sched_bank;
                phy_addr_r  <= {3'b0, sched_col}; // A10=0 for no auto-precharge
            end else begin
                phy_cmd_r   <= 4'b0000; // NOP
            end
        end
    end
end

assign phy_cmd_valid = phy_cmd_valid_r;
assign phy_cmd       = phy_cmd_r;
assign phy_bank      = phy_bank_r;
assign phy_addr      = phy_addr_r;

// Write data path (simple: present data with WRITE command)
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        phy_wr_valid <= 1'b0;
        phy_wr_data  <= '0;
        phy_wr_dm    <= '0;
        phy_wr_last  <= 1'b0;
        wr_burst_cnt <= 4'd0;
        wr_burst_active <= 1'b0;
    end else begin
        if (sched_issue_write && phy_cmd_valid && phy_cmd_ready) begin
            phy_wr_valid <= 1'b1;
            phy_wr_data  <= req_wr_data_q;
            phy_wr_dm    <= req_wr_dm_q;
            phy_wr_last  <= (BURST_LENGTH == 1);
            wr_burst_cnt <= 1;
            wr_burst_active <= 1'b1;
        end else if (wr_burst_active && phy_wr_ready) begin
            if (wr_burst_cnt < BURST_LENGTH) begin
                phy_wr_valid <= 1'b1;
                phy_wr_data  <= req_wr_data_q; // For simplicity, repeat same data
                phy_wr_dm    <= req_wr_dm_q;
                phy_wr_last  <= (wr_burst_cnt == BURST_LENGTH-1);
                wr_burst_cnt <= wr_burst_cnt + 1;
            end else begin
                phy_wr_valid <= 1'b0;
                phy_wr_last  <= 1'b0;
                wr_burst_active <= 1'b0;
            end
        end else begin
            phy_wr_valid <= 1'b0;
            phy_wr_last  <= 1'b0;
        end
    end
end

// Read data path (pass-through)
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        host_rd_valid <= 1'b0;
        host_rd_data  <= '0;
        host_rd_last  <= 1'b0;
        rd_burst_cnt  <= 4'd0;
        rd_burst_active <= 1'b0;
    end else begin
        if (phy_rd_valid) begin
            host_rd_valid <= 1'b1;
            host_rd_data  <= phy_rd_data;
            host_rd_last  <= phy_rd_last;
            if (!rd_burst_active) begin
                rd_burst_cnt <= 1;
                rd_burst_active <= 1'b1;
            end else begin
                rd_burst_cnt <= rd_burst_cnt + 1;
                if (phy_rd_last)
                    rd_burst_active <= 1'b0;
            end
        end else begin
            host_rd_valid <= 1'b0;
            host_rd_last  <= 1'b0;
        end
    end
end

// ODT control: On during writes, off otherwise
always_ff @(posedge phy_clk or negedge phy_rst_n) begin
    if (!phy_rst_n) begin
        phy_odt <= 1'b0;
    end else begin
        if (sched_issue_write && phy_cmd_valid && phy_cmd_ready)
            phy_odt <= 1'b1;
        else if (wr_burst_active)
            phy_odt <= 1'b1;
        else
            phy_odt <= 1'b0;
    end
end

endmodule
