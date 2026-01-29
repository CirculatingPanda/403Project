module ddr_mc #(
    // Controller configuration parameters
    parameter int BANK_BITS    = 3,
    parameter int ROW_BITS     = 13,
    parameter int COL_BITS     = 10,
    parameter int DATA_WIDTH   = 64,
    parameter int BURST_LENGTH = 8,
    parameter int CAS_LATENCY  = 5
)(
    input  logic clk,
    input  logic rst_n,

    // DDR2 interface (Micron MT47H64M16 pinmap, canonical names)
    output logic        ck,
    output logic        ck_n,
    output logic [0:0]  cke,
    output logic [0:0]  cs_n,
    output logic        ras_n,
    output logic        cas_n,
    output logic        we_n,
    output logic [2:0]  ba,
    output logic [12:0] a,
    output logic [0:0]  odt,
    output logic [1:0]  dm,
    inout  wire  [15:0] dq,
    inout  wire  [1:0]  dqs_p,
    inout  wire  [1:0]  dqs_n,

    // Initialization done signal
    output logic        init_done
);

    // Import timing parameters from external package
    import ddr2_timing_params::*;

    // State machine encoding
    typedef enum logic [3:0] {
        ST_IDLE                = 4'd0,
        ST_POWER_UP_INIT       = 4'd1,
        ST_ASSERT_CKE          = 4'd2,
        ST_PRECHARGE_ALL_1     = 4'd3,
        ST_LOAD_EMR2           = 4'd4,
        ST_LOAD_EMR3           = 4'd5,
        ST_LOAD_EMR1_ENABLE    = 4'd6,
        ST_LOAD_MR_DLL_RESET   = 4'd7,
        ST_PRECHARGE_ALL_2     = 4'd8,
        ST_AUTO_REFRESH_1      = 4'd9,
        ST_AUTO_REFRESH_2      = 4'd10,
        ST_LOAD_MR_DLL_CLEAR   = 4'd11,
        ST_WAIT_DLL_LOCK       = 4'd12,
        ST_LOAD_EMR1_OCD_DEF   = 4'd13,
        ST_LOAD_EMR1_OCD_EXIT  = 4'd14,
        ST_INIT_COMPLETE       = 4'd15
    } init_state_e;

    // Internal signals
    init_state_e state, state_n;
    logic [$clog2(T_INIT+1)-1:0]      wait_cnt;
    logic [$clog2(256)-1:0]           dll_lock_cnt; // 200 cycles min, 256 for safety

    // Output register signals
    logic        ck_r, ck_n_r;
    logic [0:0]  cke_r, cs_n_r, odt_r;
    logic        ras_n_r, cas_n_r, we_n_r;
    logic [2:0]  ba_r;
    logic [12:0] a_r;
    logic [1:0]  dm_r;
    logic        init_done_r;

    // Assign outputs
    assign ck      = ck_r;
    assign ck_n    = ck_n_r;
    assign cke     = cke_r;
    assign cs_n    = cs_n_r;
    assign ras_n   = ras_n_r;
    assign cas_n   = cas_n_r;
    assign we_n    = we_n_r;
    assign ba      = ba_r;
    assign a       = a_r;
    assign odt     = odt_r;
    assign dm      = dm_r;
    assign init_done = init_done_r;

    // DDR2 clock outputs (simple toggling for initialization)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ck_r   <= 1'b0;
            ck_n_r <= 1'b1;
        end else begin
            ck_r   <= ~ck_r;
            ck_n_r <= ~ck_n_r;
        end
    end

    // Main FSM and wait counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= ST_IDLE;
            wait_cnt      <= '0;
            dll_lock_cnt  <= '0;
            // Outputs default
            cke_r         <= 1'b0;
            cs_n_r        <= 1'b1;
            ras_n_r       <= 1'b1;
            cas_n_r       <= 1'b1;
            we_n_r        <= 1'b1;
            ba_r          <= 3'b000;
            a_r           <= 13'b0;
            odt_r         <= 1'b0;
            dm_r          <= 2'b00;
            init_done_r   <= 1'b0;
        end else begin
            // Default outputs for NOP
            cs_n_r        <= 1'b0;
            ras_n_r       <= 1'b1;
            cas_n_r       <= 1'b1;
            we_n_r        <= 1'b1;
            ba_r          <= 3'b000;
            a_r           <= 13'b0;
            odt_r         <= 1'b0;
            dm_r          <= 2'b00;
            init_done_r   <= 1'b0;

            case (state)
                // IDLE: Wait for reset release
                ST_IDLE: begin
                    cke_r    <= 1'b0;
                    cs_n_r   <= 1'b1;
                    ras_n_r  <= 1'b1;
                    cas_n_r  <= 1'b1;
                    we_n_r   <= 1'b1;
                    wait_cnt <= '0;
                    state    <= ST_POWER_UP_INIT;
                end

                // POWER_UP_INIT: Wait T_INIT cycles with CKE low
                ST_POWER_UP_INIT: begin
                    cke_r    <= 1'b0;
                    cs_n_r   <= 1'b1;
                    ras_n_r  <= 1'b1;
                    cas_n_r  <= 1'b1;
                    we_n_r   <= 1'b1;
                    if (wait_cnt < T_INIT-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        state    <= ST_ASSERT_CKE;
                    end
                end

                // ASSERT_CKE: Bring CKE high, issue NOP, wait T_XPR
                ST_ASSERT_CKE: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b1;
                    cas_n_r  <= 1'b1;
                    we_n_r   <= 1'b1;
                    if (wait_cnt < T_XPR-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        state    <= ST_PRECHARGE_ALL_1;
                    end
                end

                // PRECHARGE_ALL_1: Issue PRECHARGE ALL, wait T_RP
                ST_PRECHARGE_ALL_1: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b1;
                    we_n_r   <= 1'b0;
                    // A10 high for precharge all
                    a_r[10]  <= 1'b1;
                    a_r[12:0] <= 13'b0 | (1 << 10);
                    if (wait_cnt < T_RP-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        a_r      <= 13'b0;
                        state    <= ST_LOAD_EMR2;
                    end
                end

                // LOAD_EMR2: BA=010, all address bits 0, wait T_MRD
                ST_LOAD_EMR2: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b010;
                    a_r      <= 13'b0;
                    if (wait_cnt < T_MRD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        ba_r     <= 3'b000;
                        state    <= ST_LOAD_EMR3;
                    end
                end

                // LOAD_EMR3: BA=011, all address bits 0, wait T_MRD
                ST_LOAD_EMR3: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b011;
                    a_r      <= 13'b0;
                    if (wait_cnt < T_MRD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        ba_r     <= 3'b000;
                        state    <= ST_LOAD_EMR1_ENABLE;
                    end
                end

                // LOAD_EMR1_ENABLE: BA=001, DLL enable, ODT disabled, OCD exit, wait T_MRD
                ST_LOAD_EMR1_ENABLE: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b001;
                    // EMR1: DLL enable, ODT disabled, OCD exit
                    // A0=0 (DLL enable), A1=0 (full strength), A2=0 (ODT off), A5:3=0 (additive latency), A6=0 (output buffer enabled)
                    // A9:7=000 (OCD exit), A10=0 (RDQS off), A11=0 (DQS# enabled), A12=0 (output enabled)
                    a_r      <= 13'b0;
                    if (wait_cnt < T_MRD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        ba_r     <= 3'b000;
                        state    <= ST_LOAD_MR_DLL_RESET;
                    end
                end

                // LOAD_MR_DLL_RESET: BA=000, DLL reset (A8=1), BL=8, CL=5, wait T_MRD
                ST_LOAD_MR_DLL_RESET: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b000;
                    // MR: BL=8 (A2:0=011), BT=0 (A3=0), CL=5 (A6:4=101), DLL reset (A8=1), WR=010 (A11:9), PD=0 (A12=0)
                    a_r      <= {1'b0, 3'b010, 1'b1, 1'b0, 3'b101, 1'b0, 3'b010};
                    // A12=0, A11:9=010 (WR=3 cycles), A8=1, A7=0, A6:4=101 (CL=5), A3=0, A2:0=011 (BL=8)
                    if (wait_cnt < T_MRD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        a_r      <= 13'b0;
                        state    <= ST_PRECHARGE_ALL_2;
                    end
                end

                // PRECHARGE_ALL_2: Issue PRECHARGE ALL, wait T_RP
                ST_PRECHARGE_ALL_2: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b1;
                    we_n_r   <= 1'b0;
                    a_r[10]  <= 1'b1;
                    a_r[12:0] <= 13'b0 | (1 << 10);
                    if (wait_cnt < T_RP-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        a_r      <= 13'b0;
                        state    <= ST_AUTO_REFRESH_1;
                    end
                end

                // AUTO_REFRESH_1: Issue AUTO REFRESH, wait T_RFC
                ST_AUTO_REFRESH_1: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b1;
                    if (wait_cnt < T_RFC-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        state    <= ST_AUTO_REFRESH_2;
                    end
                end

                // AUTO_REFRESH_2: Issue AUTO REFRESH, wait T_RFC
                ST_AUTO_REFRESH_2: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b1;
                    if (wait_cnt < T_RFC-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        state    <= ST_LOAD_MR_DLL_CLEAR;
                    end
                end

                // LOAD_MR_DLL_CLEAR: BA=000, DLL reset cleared (A8=0), BL=8, CL=5, wait T_MRD
                ST_LOAD_MR_DLL_CLEAR: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b000;
                    // MR: BL=8 (A2:0=011), BT=0 (A3=0), CL=5 (A6:4=101), DLL reset (A8=0), WR=010 (A11:9), PD=0 (A12=0)
                    a_r      <= {1'b0, 3'b010, 1'b0, 1'b0, 3'b101, 1'b0, 3'b010};
                    if (wait_cnt < T_MRD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        a_r      <= 13'b0;
                        state    <= ST_WAIT_DLL_LOCK;
                        dll_lock_cnt <= '0;
                    end
                end

                // WAIT_DLL_LOCK: Issue NOPs for 200 cycles minimum
                ST_WAIT_DLL_LOCK: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b1;
                    cas_n_r  <= 1'b1;
                    we_n_r   <= 1'b1;
                    if (dll_lock_cnt < 200-1) begin
                        dll_lock_cnt <= dll_lock_cnt + 1;
                    end else begin
                        dll_lock_cnt <= '0;
                        state        <= ST_LOAD_EMR1_OCD_DEF;
                    end
                end

                // LOAD_EMR1_OCD_DEF: BA=001, OCD default (A9:7=111), wait T_MOD
                ST_LOAD_EMR1_OCD_DEF: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b001;
                    // EMR1: OCD default (A9:7=111), rest as before
                    a_r      <= 13'b000_000_111_000_0000;
                    if (wait_cnt < T_MOD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        ba_r     <= 3'b000;
                        state    <= ST_LOAD_EMR1_OCD_EXIT;
                    end
                end

                // LOAD_EMR1_OCD_EXIT: BA=001, OCD exit (A9:7=000), wait T_MOD
                ST_LOAD_EMR1_OCD_EXIT: begin
                    cke_r    <= 1'b1;
                    cs_n_r   <= 1'b0;
                    ras_n_r  <= 1'b0;
                    cas_n_r  <= 1'b0;
                    we_n_r   <= 1'b0;
                    ba_r     <= 3'b001;
                    // EMR1: OCD exit (A9:7=000), rest as before
                    a_r      <= 13'b000_000_000_000_0000;
                    if (wait_cnt < T_MOD-1) begin
                        wait_cnt <= wait_cnt + 1;
                    end else begin
                        wait_cnt <= '0;
                        ba_r     <= 3'b000;
                        state    <= ST_INIT_COMPLETE;
                    end
                end

                // INIT_COMPLETE: Assert init_done, ready for normal operation
                ST_INIT_COMPLETE: begin
                    cke_r        <= 1'b1;
                    cs_n_r       <= 1'b0;
                    ras_n_r      <= 1'b1;
                    cas_n_r      <= 1'b1;
                    we_n_r       <= 1'b1;
                    init_done_r  <= 1'b1;
                    // Remain in this state
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // Safety: ensure wait_cnt never overflows
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wait_cnt <= '0;
        end else if (wait_cnt > T_INIT) begin
            wait_cnt <= '0;
        end
    end

endmodule
