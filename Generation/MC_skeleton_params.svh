//==============================================================================
// DDR MEMORY CONTROLLER - PARAMETERS SKELETON
// This file defines all timing parameters and configurations
//==============================================================================
// MEMORY SPECIFICATIONS FROM USER:
// - DDR Generation: {{DDR_GEN}}
// - Speed Grade: {{SPEED_GRADE}} (e.g., DDR2-800, DDR3-1600, DDR4-2400)
// - Memory Part: {{MEMORY_PART}} (e.g., Micron MT47H64M16)
// - Clock Period: {{CLK_PERIOD_PS}} ps
// - Data Width: {{DATA_WIDTH}} bits
// - Density: {{DENSITY_GB}} GB
//==============================================================================

`ifndef __{{MODULE_NAME}}_PARAMS_SVH__
`define __{{MODULE_NAME}}_PARAMS_SVH__

//==============================================================================
// Clock and System Parameters
//==============================================================================
`define CLK_PERIOD_NS               {{CLK_PERIOD_NS}}      // Clock period in ns
`define CLK_PERIOD_PS               {{CLK_PERIOD_PS}}      // Clock period in ps

//==============================================================================
// Host Interface Parameters ({{HOST_IF_TYPE}})
//==============================================================================
{{#IF_AXI}}
// AXI4 Interface Parameters
`define AXI_ID_WIDTH                {{AXI_ID_WIDTH}}       // Transaction ID width
`define AXI_ADDR_WIDTH              {{AXI_ADDR_WIDTH}}     // Address width
`define AXI_DATA_WIDTH              {{AXI_DATA_WIDTH}}     // Data width
`define AXI_STRB_WIDTH              (`AXI_DATA_WIDTH/8)    // Strobe width
`define AXI_LEN_WIDTH               {{AXI_LEN_WIDTH}}      // Burst length width
`define AXI_SIZE_WIDTH              3                      // Burst size width
`define AXI_BURST_WIDTH             2                      // Burst type width
`define AXI_RESP_WIDTH              2                      // Response width

// AXI Constants
`define AXI_BURST_FIXED             2'b00
`define AXI_BURST_INCR              2'b01
`define AXI_BURST_WRAP              2'b10

`define AXI_RESP_OKAY               2'b00
`define AXI_RESP_EXOKAY             2'b01
`define AXI_RESP_SLVERR             2'b10
`define AXI_RESP_DECERR             2'b11

// AXI Acceptance Capability
`define AXI_READ_ACCEPT_CAP         {{AXI_RD_ACCEPT}}      // Max outstanding reads
`define AXI_WRITE_ACCEPT_CAP        {{AXI_WR_ACCEPT}}      // Max outstanding writes
{{/IF_AXI}}

{{#IF_AHB}}
// AHB Interface Parameters
`define AHB_ADDR_WIDTH              {{AHB_ADDR_WIDTH}}
`define AHB_DATA_WIDTH              {{AHB_DATA_WIDTH}}
`define AHB_BURST_WIDTH             3
`define AHB_TRANS_WIDTH             2
`define AHB_SIZE_WIDTH              3
{{/IF_AHB}}

{{#IF_CUSTOM}}
// Custom Host Interface Parameters
{{CUSTOM_HOST_IF_PARAMS}}
{{/IF_CUSTOM}}

//==============================================================================
// Memory Interface Parameters
//==============================================================================
// Memory Geometry
`define DDR_BANK_BITS               {{BANK_BITS}}          // Bank address bits
`define DDR_ROW_BITS                {{ROW_BITS}}           // Row address bits  
`define DDR_COL_BITS                {{COL_BITS}}           // Column address bits
`define DDR_ADDR_WIDTH              {{ADDR_WIDTH}}         // Address bus width
`define DDR_DQ_WIDTH                {{DQ_WIDTH}}           // Data width
`define DDR_DQS_WIDTH               {{DQS_WIDTH}}          // DQS width
`define DDR_DM_WIDTH                {{DM_WIDTH}}           // Data mask width
`define DDR_CS_WIDTH                {{CS_WIDTH}}           // Chip select width

// Derived Parameters
`define DDR_BANK_COUNT              (1 << `DDR_BANK_BITS)  // Number of banks
`define DDR_ROW_COUNT               (1 << `DDR_ROW_BITS)   // Rows per bank
`define DDR_COL_COUNT               (1 << `DDR_COL_BITS)   // Columns per row

//==============================================================================
// PHY Interface Parameters ({{PHY_IF_TYPE}})
//==============================================================================
{{#IF_DFI}}
// DFI (DDR PHY Interface) Parameters
`define DFI_FREQ_RATIO              {{DFI_RATIO}}          // Controller:PHY frequency ratio
`define DFI_DATA_WIDTH              {{DFI_DATA_WIDTH}}     // DFI data width
`define DFI_CS_WIDTH                {{DFI_CS_WIDTH}}       // DFI chip select width
`define DFI_ADDR_WIDTH              {{DFI_ADDR_WIDTH}}     // DFI address width
`define DFI_BANK_WIDTH              {{DFI_BANK_WIDTH}}     // DFI bank width
`define DFI_CTRL_WIDTH              {{DFI_CTRL_WIDTH}}     // DFI control width
{{/IF_DFI}}

{{#IF_CUSTOM_PHY}}
// Custom PHY Interface Parameters
{{CUSTOM_PHY_IF_PARAMS}}
{{/IF_CUSTOM_PHY}}

//==============================================================================
// DDR Timing Parameters (in clock cycles)
//==============================================================================
// Helper macro to round up ns to clock cycles
`define ROUND_UP_CYCLES(ns)         (((ns)*1000 + `CLK_PERIOD_PS - 1) / `CLK_PERIOD_PS)

// Core Timing Parameters
`define BURST_LENGTH                {{BURST_LENGTH}}       // Burst length
`define CAS_LATENCY                 {{CAS_LATENCY}}        // CL - Read latency
`define WRITE_LATENCY               {{WRITE_LATENCY}}      // CWL - Write latency
`define ADDITIVE_LATENCY            {{ADDITIVE_LATENCY}}   // AL

// Row Timing Parameters (Bank-specific)
`define T_RCD_CYCLES                {{T_RCD}}              // Row to Column delay
`define T_RP_CYCLES                 {{T_RP}}               // Row Precharge time
`define T_RAS_MIN_CYCLES            {{T_RAS_MIN}}          // Row Active time (min)
`define T_RAS_MAX_CYCLES            {{T_RAS_MAX}}          // Row Active time (max)
`define T_RC_CYCLES                 {{T_RC}}               // Row Cycle time
`define T_RTP_CYCLES                {{T_RTP}}              // Read to Precharge
`define T_WR_CYCLES                 {{T_WR}}               // Write Recovery time
`define T_WTP_CYCLES                {{T_WTP}}              // Write to Precharge

// Inter-Bank Timing Parameters
`define T_RRD_CYCLES                {{T_RRD}}              // Row to Row delay
`define T_CCD_CYCLES                {{T_CCD}}              // CAS to CAS delay
`define T_WTR_CYCLES                {{T_WTR}}              // Write to Read delay
`define T_RTW_CYCLES                {{T_RTW}}              // Read to Write delay
`define T_FAW_CYCLES                {{T_FAW}}              // Four Activate Window

// Refresh Timing Parameters
`define T_RFC_CYCLES                {{T_RFC}}              // Refresh Cycle time
`define T_REFI_CYCLES               {{T_REFI}}             // Refresh Interval
`define T_RFC_MIN_CYCLES            {{T_RFC_MIN}}          // Min Refresh time
`define T_RFC_MAX_CYCLES            {{T_RFC_MAX}}          // Max Refresh time

// Power-Down Timing (Optional)
`define T_XP_CYCLES                 {{T_XP}}               // Exit Power-down
`define T_XPDLL_CYCLES              {{T_XPDLL}}            // Exit Power-down (DLL on)
`define T_XS_CYCLES                 {{T_XS}}               // Exit Self-refresh
`define T_XSDLL_CYCLES              {{T_XSDLL}}            // Exit Self-refresh (DLL on)

// Initialization Timing
`define T_INIT_CYCLES               {{T_INIT}}             // Initialization time
`define T_MRD_CYCLES                {{T_MRD}}              // Mode Register delay
`define T_MOD_CYCLES                {{T_MOD}}              // Mode Register update

// ODT Timing ({{DDR_GEN}} specific)
{{#IF_DDR2_OR_HIGHER}}
`define T_AOFD_CYCLES               {{T_AOFD}}             // ODT turn-off delay
`define T_AOND_CYCLES               {{T_AOND}}             // ODT turn-on delay
`define T_AONPD_CYCLES              {{T_AONPD}}            // ODT turn-on power-down
`define T_AOFPD_CYCLES              {{T_AOFPD}}            // ODT turn-off power-down
{{/IF_DDR2_OR_HIGHER}}

//==============================================================================
// Controller Configuration Parameters
//==============================================================================
// Page Policy
`define PAGE_POLICY                 {{PAGE_POLICY}}        // 0=Closed, 1=Open, 2=Adaptive
`define ROW_OPEN_CYCLES             {{ROW_OPEN_CYCLES}}    // Cycles to keep row open

// Queue Depths
`define CMD_QUEUE_DEPTH             {{CMD_QUEUE_DEPTH}}    // Command queue depth
`define WR_DATA_QUEUE_DEPTH         {{WR_QUEUE_DEPTH}}     // Write data queue
`define RD_DATA_QUEUE_DEPTH         {{RD_QUEUE_DEPTH}}     // Read data queue

// Reordering
`define ENABLE_REORDERING           {{ENABLE_REORDER}}     // Enable command reordering
`define MAX_REORDER_DEPTH           {{MAX_REORDER}}        // Max reorder window

//==============================================================================
// Type Definitions
//==============================================================================
// Address types
typedef logic [`DDR_BANK_BITS-1:0]     bank_addr_t;
typedef logic [`DDR_ROW_BITS-1:0]      row_addr_t;
typedef logic [`DDR_COL_BITS-1:0]      col_addr_t;
typedef logic [`DDR_ADDR_WIDTH-1:0]    ddr_addr_t;

// Host interface types
{{#IF_AXI}}
typedef logic [`AXI_ID_WIDTH-1:0]      axi_id_t;
typedef logic [`AXI_ADDR_WIDTH-1:0]    axi_addr_t;
typedef logic [`AXI_DATA_WIDTH-1:0]    axi_data_t;
typedef logic [`AXI_STRB_WIDTH-1:0]    axi_strb_t;
typedef logic [`AXI_LEN_WIDTH-1:0]     axi_len_t;
typedef logic [`AXI_SIZE_WIDTH-1:0]    axi_size_t;
typedef logic [`AXI_BURST_WIDTH-1:0]   axi_burst_t;
typedef logic [`AXI_RESP_WIDTH-1:0]    axi_resp_t;
{{/IF_AXI}}

{{ADDITIONAL_TYPEDEFS}}

//==============================================================================
// Address Mapping Functions
//==============================================================================
// Map system address to bank/row/column
// Mapping scheme: {{ADDR_MAP_SCHEME}} (RBC/BRC/Custom)

function automatic bank_addr_t get_bank_addr(logic [`AXI_ADDR_WIDTH-1:0] addr);
    {{BANK_ADDR_MAPPING}}
endfunction

function automatic row_addr_t get_row_addr(logic [`AXI_ADDR_WIDTH-1:0] addr);
    {{ROW_ADDR_MAPPING}}
endfunction

function automatic col_addr_t get_col_addr(logic [`AXI_ADDR_WIDTH-1:0] addr);
    {{COL_ADDR_MAPPING}}
endfunction

//==============================================================================
// Timing Check Macros
//==============================================================================
`define CHECK_TIMING(counter, threshold) ((counter) >= (threshold))

//==============================================================================
// Debug and Verification
//==============================================================================
`ifdef SIMULATION
    `define SIM_SPEEDUP_FACTOR      {{SIM_SPEEDUP}}        // Reduce delays in sim
    `define VERBOSE_LEVEL           {{VERBOSE_LEVEL}}      // 0=quiet, 3=very verbose
`endif

`endif // __{{MODULE_NAME}}_PARAMS_SVH__
