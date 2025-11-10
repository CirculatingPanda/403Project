micron_ddr2_pinmap.md (sample for Micron MT47H64M16, x16, 1 Gb, 200 MHz CK)

Purpose

Canonical naming and widths for the DDR2 memory-side interface so the generator wires ports correctly and does not invent signal names or sizes.
Treat this file as authoritative reference. Do not modify it during generation; swap this file out only if the target device changes.
Device and operating point

Part: Micron MT47H64M16 (64M x 16, DDR2 SDRAM, 1 Gb)
Data width: x16
Banks: 8 (BA[2:0])
Typical address geometry (confirm in datasheet for your speed bin and package):
Row bits: 13 (A[12:0])
Column bits: 10 (A[9:0])
Clock: 200 MHz CK (DDR data rate 400 MT/s), SSTL-18 I/O
Typical burst length: BL=4 (project default; can be set to 8)
Ranks: 1 (single chip select) unless noted otherwise
Controller port names and directions

ck, ck_n: output, 1 bit each
Differential clock pair to DRAM.
cke: output, [0:0]
Clock enable (active high).
cs_n: output, [0:0], active low
Chip select.
ras_n, cas_n, we_n: output, 1 bit each, active low
Command pins.
ba: output, [2:0]
Bank address.
a: output, [12:0]
Multiplexed row/column address bus.
Notes:
A10 has special meaning in certain commands (e.g., precharge-all via A10=1; auto-precharge on reads/writes).
odt: output, [0:0], active high
On-die termination control.
dq: inout, [15:0]
Bidirectional data bus.
dqs_p: inout, [1:0]
Data strobe (P) per byte lane.
dqs_n: inout, [1:0]
Data strobe (N) per byte lane (differential with dqs_p).
dm: output, [1:0]
Data mask per byte lane (write masking).
Byte-lane (DQS) mapping (x16 organization)

Byte lane 0:
dq[7:0] associated with dqs_p[0]/dqs_n[0] and dm[0]
Byte lane 1:
dq[15:8] associated with dqs_p
Prob113_2012_q1g_prompt.txt
/dqs_n
Prob113_2012_q1g_prompt.txt
 and dm
Prob113_2012_q1g_prompt.txt
Signal polarities and conventions

Active-low signals: cs_n, ras_n, cas_n, we_n
Active-high signals: cke, odt
Differential pairs: ck/ck_n, dqs_p/dqs_n
dq, dqs_p, dqs_n are bidirectional; dm is output from controller (write mask)
Physical-to-logical notes

The a[12:0] bus carries both row and column bits, depending on the command type:
ACT uses row address on a[] and bank on ba[].
READ/WRITE use column address on a[] and bank on ba[] (with A10 controlling auto-precharge).
Precharge-all: PRE command with A10=1 (all banks).
Auto-precharge on READ/WRITE: set A10=1 during the command (bank-specific).
Assumptions for single-rank reference design

Single-rank system → one instance of cs_n, cke, odt.
If your board uses multiple ranks, replicate cs_n/cke/odt per rank and ensure your controller drives them accordingly.
Simulation/model notes (fill in per your model package)

Timescale: 1ns/1ps recommended.
Include files: specify exact Micron model file list here when you integrate the behavioral model.
Defines/flags: list any required +define+ or parameters needed by the Micron model for your tool (Icarus/Cadence).
How the generator should use this file

Do not invent port names or widths; use these exactly.
When generating top-level ports and PHY connections, follow:
Outputs to DRAM: ck, ck_n, cke, cs_n, ras_n, cas_n, we_n, odt, ba[2:0], a[12:0], dm[1:0]
Inouts to DRAM: dq[15:0], dqs_p[1:0], dqs_n[1:0]
Maintain the byte-lane groupings (dq[7:0] with dqs*_0/dm[0]; dq[15:8] with dqs*_1/dm
Prob113_2012_q1g_prompt.txt
).
Optional parameter block (if you prefer a .svh companion)

localparam int DQ_BITS = 16;
localparam int DQS_LANES = 2;
localparam int DM_BITS = 2;
localparam int BA_BITS = 3;
localparam int A_BITS = 13; // shared row/col pins; row/col splits handled by command type
localparam int RANKS = 1;
Notes and cautions

Verify the exact row/column bit counts and any mode-register specifics against your chosen MT47H64M16 datasheet/speed grade.
DDR2 does not expose a dedicated RESET# pin (that appears in later DDR generations); initialization relies on CKE sequencing and JEDEC init.
ODT values and MR/EMR encodings are set during initialization (not in this pin map). Keep those in your JEDEC init excerpt and command package.