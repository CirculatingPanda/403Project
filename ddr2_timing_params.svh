//==============================================================================
// DDR2 Timing Parameters Package
// Auto-generated from specification
//==============================================================================
`ifndef DDR2_TIMING_PARAMS_SVH
`define DDR2_TIMING_PARAMS_SVH

package ddr2_timing_params;
    
    // Clock parameters
    parameter int CLK_PERIOD_PS = 2500;
    parameter real CLK_PERIOD_NS = 2.500;
    parameter int FREQ_MHZ = 400;
    
    // Activation and Precharge timing
    parameter int T_RCD = 6;      // RAS-to-CAS delay (cycles)
    parameter int T_RP = 6;        // Precharge command period (cycles)
    parameter int T_RAS = 15;  // Active to precharge delay (cycles)
    parameter int T_RC = 20;        // Active to active/refresh (cycles)
    
    // Data transfer timing
    parameter int CL = 5;   // CAS latency (cycles)
    parameter int WL = 4; // Write latency (cycles)
    parameter int T_WR = 6;        // Write recovery time (cycles)
    parameter int T_WTR = 3;      // Write to read delay (cycles)
    parameter int T_RTP = 3;      // Read to precharge (cycles)
    parameter int T_CCD = 2;      // CAS to CAS delay (cycles)
    
    // Bank timing
    parameter int T_RRD = 3;      // Active bank to active bank (cycles)
    parameter int T_FAW = 18;      // Four activate window (cycles)
    
    // Refresh timing
    parameter int T_RFC = 51;      // Refresh cycle time (cycles)
    parameter int T_REFI = 3120;    // Refresh interval (cycles)
    
    // Mode register timing
    parameter int T_MRD = 2;      // Mode register set cycle (cycles)
    parameter int T_MOD = 5;      // Mode register update delay (cycles)
    
    // Power-down and initialization
    parameter int T_XP = 3;        // Exit power-down (cycles)
    parameter int T_XPDLL = 10;  // Exit power-down with DLL (cycles)
    parameter int T_INIT = 80000;    // Initialization time (cycles)
    
    // Helper function to convert ns to cycles
    function automatic int ns_to_cycles(real ns_value);
        return int'($ceil(ns_value * 1000.0 / CLK_PERIOD_PS));
    endfunction
    
    // Helper function to convert cycles to ns
    function automatic real cycles_to_ns(int cycle_value);
        return real'(cycle_value) * CLK_PERIOD_NS;
    endfunction
    
endpackage

`endif // DDR2_TIMING_PARAMS_SVH
