###############################################################################
# SDC Timing Constraints for 
# Kind: fifo_controller
# Clock: 200 MHz (period = 5.000 ns)
# Generated: 2026-02-26 09:10:55
###############################################################################

# ══════════════════════════════════════════════════════════════════════════════
# Clock Definition
# ══════════════════════════════════════════════════════════════════════════════
create_clock -name clk -period 5.000 [get_ports clk]
set_clock_uncertainty 0.1 [get_clocks clk]
set_clock_transition  0.05 [get_clocks clk]

# ══════════════════════════════════════════════════════════════════════════════
# I/O Constraints
# ══════════════════════════════════════════════════════════════════════════════
set_input_delay  -clock clk -max 1.500 [all_inputs]
set_input_delay  -clock clk -min 0.250 [all_inputs]
set_output_delay -clock clk -max 1.500 [all_outputs]
set_output_delay -clock clk -min 0.250 [all_outputs]

# Don't constrain clock and reset as data
remove_input_delay [get_ports clk]
remove_input_delay [get_ports rst_n]

# ══════════════════════════════════════════════════════════════════════════════
# Design Rules
# ══════════════════════════════════════════════════════════════════════════════
set_max_fanout 32 [current_design]
set_max_transition 0.2 [current_design]

###############################################################################
# End of constraints
###############################################################################
