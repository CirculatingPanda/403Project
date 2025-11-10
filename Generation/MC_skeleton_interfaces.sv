//==============================================================================
// DDR MEMORY CONTROLLER - INTERFACE DEFINITIONS SKELETON
// This file defines all SystemVerilog interfaces used in the controller
//==============================================================================

`include "{{PARAMS_FILE}}.svh"
`include "{{TIMESCALE_FILE}}.svh"

//==============================================================================
// AXI4 Address Channel Interface
//==============================================================================
{{#IF_AXI}}
interface AXI_ADDR_IF (
    input logic clk,
    input logic rst_n
);
    logic                       valid;
    logic                       ready;
    axi_id_t                    id;
    axi_addr_t                  addr;
    axi_len_t                   len;
    axi_size_t                  size;
    axi_burst_t                 burst;
    logic [1:0]                 lock;
    logic [3:0]                 cache;
    logic [2:0]                 prot;
    logic [3:0]                 qos;
    logic [3:0]                 region;
    logic                       user;
    
    // Master modport
    modport MASTER (
        output valid, id, addr, len, size, burst, lock, cache, prot, qos, region, user,
        input  ready
    );
    
    // Slave modport
    modport SLAVE (
        input  valid, id, addr, len, size, burst, lock, cache, prot, qos, region, user,
        output ready
    );
    
    // Monitor modport
    modport MONITOR (
        input valid, ready, id, addr, len, size, burst
    );
    
    {{AXI_ADDR_TASKS}}
    
endinterface : AXI_ADDR_IF

//==============================================================================
// AXI4 Write Data Channel Interface
//==============================================================================
interface AXI_WDATA_IF (
    input logic clk,
    input logic rst_n
);
    logic                       valid;
    logic                       ready;
    axi_data_t                  data;
    axi_strb_t                  strb;
    logic                       last;
    logic                       user;
    
    modport MASTER (
        output valid, data, strb, last, user,
        input  ready
    );
    
    modport SLAVE (
        input  valid, data, strb, last, user,
        output ready
    );
    
    {{AXI_WDATA_TASKS}}
    
endinterface : AXI_WDATA_IF

//==============================================================================
// AXI4 Write Response Channel Interface
//==============================================================================
interface AXI_WRESP_IF (
    input logic clk,
    input logic rst_n
);
    logic                       valid;
    logic                       ready;
    axi_id_t                    id;
    axi_resp_t                  resp;
    logic                       user;
    
    modport MASTER (
        output ready,
        input  valid, id, resp, user
    );
    
    modport SLAVE (
        output valid, id, resp, user,
        input  ready
    );
    
    {{AXI_WRESP_TASKS}}
    
endinterface : AXI_WRESP_IF

//==============================================================================
// AXI4 Read Data Channel Interface
//==============================================================================
interface AXI_RDATA_IF (
    input logic clk,
    input logic rst_n
);
    logic                       valid;
    logic                       ready;
    axi_id_t                    id;
    axi_data_t                  data;
    axi_resp_t                  resp;
    logic                       last;
    logic                       user;
    
    modport MASTER (
        output ready,
        input  valid, id, data, resp, last, user
    );
    
    modport SLAVE (
        output valid, id, data, resp, last, user,
        input  ready
    );
    
    {{AXI_RDATA_TASKS}}
    
endinterface : AXI_RDATA_IF
{{/IF_AXI}}

//==============================================================================
// APB Configuration Interface
//==============================================================================
{{#IF_APB_CONFIG}}
interface APB_IF (
    input logic clk,
    input logic rst_n
);
    logic                       psel;
    logic                       penable;
    logic                       pwrite;
    logic [31:0]                paddr;
    logic [31:0]                pwdata;
    logic [31:0]                prdata;
    logic                       pready;
    logic                       pslverr;
    
    modport MASTER (
        output psel, penable, pwrite, paddr, pwdata,
        input  prdata, pready, pslverr
    );
    
    modport SLAVE (
        input  psel, penable, pwrite, paddr, pwdata,
        output prdata, pready, pslverr
    );
    
endinterface : APB_IF
{{/IF_APB_CONFIG}}

//==============================================================================
// Request Interface (Internal)
//==============================================================================
interface REQ_IF (
    input logic clk,
    input logic rst_n
);
    logic                       valid;
    logic                       ready;
    logic                       is_write;
    row_addr_t                  row_addr;
    col_addr_t                  col_addr;
    bank_addr_t                 bank_addr;
    {{ID_TYPE}}                 id;
    {{LEN_TYPE}}                len;
    logic [1:0]                 size;
    logic                       auto_precharge;
    
    modport SRC (
        output valid, is_write, row_addr, col_addr, bank_addr, id, len, size, auto_precharge,
        input  ready
    );
    
    modport DST (
        input  valid, is_write, row_addr, col_addr, bank_addr, id, len, size, auto_precharge,
        output ready
    );
    
    // Clear/reset task
    task automatic clear();
        valid <= 1'b0;
        is_write <= 1'b0;
        row_addr <= '0;
        col_addr <= '0;
        bank_addr <= '0;
        id <= '0;
        len <= '0;
        size <= '0;
        auto_precharge <= 1'b0;
    endtask
    
endinterface : REQ_IF

//==============================================================================
// Scheduler Interface (Internal)
//==============================================================================
interface SCHED_IF (
    input logic clk,
    input logic rst_n
);
    logic                       cmd_valid;
    logic [2:0]                 cmd_type;    // NOP, ACT, RD, WR, PRE, REF
    bank_addr_t                 bank_sel;
    row_addr_t                  row_addr;
    col_addr_t                  col_addr;
    {{ID_TYPE}}                 req_id;
    {{LEN_TYPE}}                req_len;
    logic                       auto_precharge;
    logic                       burst_end;
    
    modport SRC (
        output cmd_valid, cmd_type, bank_sel, row_addr, col_addr, 
               req_id, req_len, auto_precharge, burst_end
    );
    
    modport DST (
        input  cmd_valid, cmd_type, bank_sel, row_addr, col_addr,
               req_id, req_len, auto_precharge, burst_end
    );
    
    modport MONITOR (
        input  cmd_valid, cmd_type, bank_sel, row_addr, col_addr
    );
    
endinterface : SCHED_IF

//==============================================================================
// Timing Parameters Interface (Internal)
//==============================================================================
interface TIMING_IF;
    // Core timing parameters (configurable)
    logic [7:0]                 t_rcd;
    logic [7:0]                 t_rp;
    logic [7:0]                 t_ras_min;
    logic [15:0]                t_ras_max;
    logic [7:0]                 t_rc;
    logic [7:0]                 t_rtp;
    logic [7:0]                 t_wr;
    logic [7:0]                 t_wtp;
    
    // Inter-bank timing
    logic [7:0]                 t_rrd;
    logic [7:0]                 t_ccd;
    logic [7:0]                 t_wtr;
    logic [7:0]                 t_rtw;
    logic [7:0]                 t_faw;
    
    // Refresh timing
    logic [15:0]                t_rfc;
    logic [15:0]                t_refi;
    
    // CAS latencies
    logic [4:0]                 cas_latency;
    logic [4:0]                 write_latency;
    logic [4:0]                 additive_latency;
    
    // Burst configuration
    logic [3:0]                 burst_length;
    
    // Helper values (pre-calculated)
    logic [7:0]                 t_rcd_m1;    // t_rcd - 1
    logic [7:0]                 t_rcd_m2;    // t_rcd - 2
    logic [7:0]                 t_rp_m1;
    logic [7:0]                 t_rp_m2;
    logic [7:0]                 t_ras_min_m1;
    logic [7:0]                 t_rc_m1;
    logic [15:0]                t_rfc_m1;
    logic [15:0]                t_rfc_m2;
    logic [3:0]                 burst_cycles;
    logic [3:0]                 burst_cycles_m2;
    
    modport CFG (
        output t_rcd, t_rp, t_ras_min, t_ras_max, t_rc, t_rtp, t_wr, t_wtp,
               t_rrd, t_ccd, t_wtr, t_rtw, t_faw,
               t_rfc, t_refi,
               cas_latency, write_latency, additive_latency,
               burst_length,
               t_rcd_m1, t_rcd_m2, t_rp_m1, t_rp_m2, t_ras_min_m1, 
               t_rc_m1, t_rfc_m1, t_rfc_m2,
               burst_cycles, burst_cycles_m2
    );
    
    modport MON (
        input  t_rcd, t_rp, t_ras_min, t_ras_max, t_rc, t_rtp, t_wr, t_wtp,
               t_rrd, t_ccd, t_wtr, t_rtw, t_faw,
               t_rfc, t_refi,
               cas_latency, write_latency, additive_latency,
               burst_length,
               t_rcd_m1, t_rcd_m2, t_rp_m1, t_rp_m2, t_ras_min_m1,
               t_rc_m1, t_rfc_m1, t_rfc_m2,
               burst_cycles, burst_cycles_m2
    );
    
endinterface : TIMING_IF

//==============================================================================
// DFI (DDR PHY Interface) Control Interface
//==============================================================================
{{#IF_DFI}}
interface DFI_CTRL_IF (
    input logic clk,
    input logic rst_n
);
    logic                       cke;
    logic [`DFI_CS_WIDTH-1:0]  cs_n;
    logic                       ras_n;
    logic                       cas_n;
    logic                       we_n;
    logic [`DFI_BANK_WIDTH-1:0] bank;
    logic [`DFI_ADDR_WIDTH-1:0] address;
    logic                       odt;
    logic                       reset_n;
    
    modport MC (
        output cke, cs_n, ras_n, cas_n, we_n, bank, address, odt, reset_n
    );
    
    modport PHY (
        input  cke, cs_n, ras_n, cas_n, we_n, bank, address, odt, reset_n
    );
    
endinterface : DFI_CTRL_IF

//==============================================================================
// DFI Write Data Interface
//==============================================================================
interface DFI_WRDATA_IF (
    input logic clk,
    input logic rst_n
);
    logic                       wrdata_en;
    logic [`DFI_DATA_WIDTH-1:0] wrdata;
    logic [`DFI_DATA_WIDTH/8-1:0] wrdata_mask;
    logic                       wrdata_cs_n;
    
    modport MC (
        output wrdata_en, wrdata, wrdata_mask, wrdata_cs_n
    );
    
    modport PHY (
        input  wrdata_en, wrdata, wrdata_mask, wrdata_cs_n
    );
    
endinterface : DFI_WRDATA_IF

//==============================================================================
// DFI Read Data Interface
//==============================================================================
interface DFI_RDDATA_IF (
    input logic clk,
    input logic rst_n
);
    logic                       rddata_en;
    logic [`DFI_DATA_WIDTH-1:0] rddata;
    logic                       rddata_valid;
    logic [`DFI_DATA_WIDTH/8-1:0] rddata_dnv;  // Data Not Valid
    logic                       rddata_cs_n;
    
    modport MC (
        output rddata_en,
        input  rddata, rddata_valid, rddata_dnv, rddata_cs_n
    );
    
    modport PHY (
        input  rddata_en,
        output rddata, rddata_valid, rddata_dnv, rddata_cs_n
    );
    
endinterface : DFI_RDDATA_IF
{{/IF_DFI}}

//==============================================================================
// Custom PHY Interface (if not using DFI)
//==============================================================================
{{#IF_CUSTOM_PHY}}
interface CUSTOM_PHY_IF (
    input logic clk,
    input logic rst_n
);
    {{CUSTOM_PHY_SIGNALS}}
    
    modport MC (
        {{CUSTOM_PHY_MC_PORTS}}
    );
    
    modport PHY (
        {{CUSTOM_PHY_PHY_PORTS}}
    );
    
endinterface : CUSTOM_PHY_IF
{{/IF_CUSTOM_PHY}}

//==============================================================================
// Optional: Debug/Monitor Interface
//==============================================================================
interface DEBUG_IF;
    // Performance counters
    logic [31:0]                total_reads;
    logic [31:0]                total_writes;
    logic [31:0]                row_hits;
    logic [31:0]                row_misses;
    logic [31:0]                row_conflicts;
    logic [31:0]                refresh_count;
    logic [31:0]                cmd_queue_full;
    
    // Current state monitors
    logic [{{NUM_BANKS}}-1:0]  bank_active;
    logic [15:0]                active_cmds;
    logic [15:0]                pending_reads;
    logic [15:0]                pending_writes;
    
    // Error flags
    logic                       timing_violation;
    logic                       protocol_error;
    logic                       data_error;
    
    modport CTRL (
        output total_reads, total_writes, row_hits, row_misses, row_conflicts,
               refresh_count, cmd_queue_full,
               bank_active, active_cmds, pending_reads, pending_writes,
               timing_violation, protocol_error, data_error
    );
    
    modport MON (
        input  total_reads, total_writes, row_hits, row_misses, row_conflicts,
               refresh_count, cmd_queue_full,
               bank_active, active_cmds, pending_reads, pending_writes,
               timing_violation, protocol_error, data_error
    );
    
endinterface : DEBUG_IF

//==============================================================================
// Verification Support - Interface Assertions
//==============================================================================
// synthesis translate_off
{{INTERFACE_ASSERTIONS}}
// synthesis translate_on

