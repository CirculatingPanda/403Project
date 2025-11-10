/*Parameterized definitions for the chosen bus: AXI4, AXI4‑Lite, AHB, or a small ready/valid custom bus.
/Exact port names, widths, handshake timing (ready/valid), burst semantics (len, size, align), and optional backpressure/latency expectations.
Simple tasks/macros for issuing a write/read (for custom buses), or a minimal AXI channel signal set if you use AXI4/AXI‑Lite.*/
//Controller facing

