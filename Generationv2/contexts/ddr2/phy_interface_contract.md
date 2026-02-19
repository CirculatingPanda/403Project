# DDR2 PHY Interface Contract

## Purpose
Defines the exact boundary between the memory controller and the PHY layer.
This contract prevents the LLM from inventing signals and ensures correct PHY integration.

---

## Interface Overview

The controller drives commands and write data to the PHY, and receives read data from the PHY.
The PHY handles all physical-layer operations: DQS generation/sampling, write leveling, read DQS gating, and I/O timing.

**Clocking:** All signals synchronous to `phy_clk` unless noted otherwise.

---

## Signal Groups

### 1. Clock and Reset
```
phy_clk         input   1-bit   PHY clock (typically same as memory clock or 2x)
phy_rst_n       input   1-bit   Asynchronous reset, active low
```

### 2. Command Interface (Controller → PHY)

**Command Valid/Ready Handshake:**
```
phy_cmd_valid   output  1-bit   Command valid (controller asserts when ready to issue)
phy_cmd_ready   input   1-bit   PHY ready to accept command (backpressure from PHY)
```

**Command Fields (valid when phy_cmd_valid && phy_cmd_ready):**
```
phy_cmd[3:0]    output  4-bit   Encoded command:
                                  4'b0000 = NOP
                                  4'b0001 = ACTIVATE (open row)
                                  4'b0010 = READ
                                  4'b0011 = WRITE
                                  4'b0100 = PRECHARGE
                                  4'b0101 = REFRESH
                                  4'b0110 = MODE_REG_SET
                                  4'b0111 = PRECHARGE_ALL
                                  4'b1000 = SELF_REFRESH_ENTRY
                                  4'b1001 = SELF_REFRESH_EXIT
                                  Others reserved

phy_bank[2:0]   output  3-bit   Bank address (for ACT, READ, WRITE, PRE commands)
phy_addr[12:0]  output  13-bit  Address bus:
                                  - ACTIVATE: row address
                                  - READ/WRITE: column address
                                  - PRECHARGE: A10 signals all-banks
                                  - MODE_REG_SET: mode register value
```

**Alternative Raw Command Outputs (if PHY prefers direct control):**
```
phy_cs_n        output  1-bit   Chip select, active low
phy_ras_n       output  1-bit   Row address strobe, active low
phy_cas_n       output  1-bit   Column address strobe, active low
phy_we_n        output  1-bit   Write enable, active low
```

**Note:** Use either `phy_cmd[3:0]` (encoded) OR raw `{cs_n, ras_n, cas_n, we_n}` depending on your PHY.
For this reference design, we use `phy_cmd[3:0]`.

---

### 3. Write Data Interface (Controller → PHY)

**Write Data Valid/Ready Handshake:**
```
phy_wr_valid    output  1-bit   Write data valid
phy_wr_ready    input   1-bit   PHY ready to accept write data
```

**Write Data Payload (valid when phy_wr_valid && phy_wr_ready):**
```
phy_wr_data[DQ_WIDTH-1:0]     output  Write data (e.g., 64 bits for x16 device)
phy_wr_dm[DM_WIDTH-1:0]       output  Write data mask (byte lanes, active high = mask)
phy_wr_last                   output  1-bit  Last beat of write burst
```

**For DDR2 x16 (DQ_WIDTH=16, DM_WIDTH=2):**
- `phy_wr_data[15:0]`
- `phy_wr_dm[1:0]` where dm[0] masks dq[7:0], dm[1] masks dq[15:8]

**Timing Notes:**
- Write data must be presented **before or with** the WRITE command (controller responsibility)
- Typical: Controller asserts phy_wr_valid 1 cycle before phy_cmd_valid for WRITE
- PHY will serialize and align data with DQS

---

### 4. Read Data Interface (PHY → Controller)

**Read Data Valid:**
```
phy_rd_valid    input   1-bit   Read data valid (asserted by PHY when data returns)
phy_rd_data[DQ_WIDTH-1:0]  input   Read data from PHY
phy_rd_last     input   1-bit   Last beat of read burst
```

**Optional Transaction ID (if controller tracks multiple outstanding reads):**
```
phy_rd_id[ID_WIDTH-1:0]   input   Transaction ID matching original READ command
```

**Timing Notes:**
- Read data returns **CL + PHY_LATENCY** cycles after READ command
- For DDR2-800, CL=5: expect data at cycle 5 + 2 (PHY delay) = 7 cycles after READ
- PHY handles DQS gating and data capture

---

### 5. DQS Control (Controller → PHY, if controller manages DQS timing)

**DQS Output Enable:**
```
phy_dqs_oe      output  1-bit   DQS output enable (for write operations)
```

**DQS Gate for Read:**
```
phy_dqs_gate    output  1-bit   DQS gate enable (tells PHY when to expect read DQS)
```

**Note:** Many modern PHYs handle DQS timing internally. Include these only if your PHY requires controller-driven DQS control.

---

### 6. ODT Control (On-Die Termination)

```
phy_odt[RANKS-1:0]   output   ODT enable per rank (typically 1 bit for single rank)
```

**Usage:**
- Assert during writes to the rank
- De-assert during reads
- Typical: ODT on during own writes, off during reads

---

### 7. Initialization and Calibration

```
phy_init_done    input   1-bit   PHY initialization complete (DLL lock, calibration done)
```

**Sequence:**
1. Controller holds in reset until phy_init_done asserts
2. Controller runs JEDEC init sequence (precharge, mode register sets, etc.)
3. Normal operation begins

---

## Complete Port List Example

### For DDR2 x16, Single Rank:
```systemverilog
module ddr2_controller (
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
    output logic [15:0] phy_wr_data,
    output logic [1:0]  phy_wr_dm,
    output logic        phy_wr_last,
    
    // Read data interface (from PHY)
    input  logic        phy_rd_valid,
    input  logic [15:0] phy_rd_data,
    input  logic        phy_rd_last,
    
    // ODT control
    output logic        phy_odt,
    
    // Initialization
    input  logic        phy_init_done,
    
    // ... host interface signals ...
);
```

---

## Timing Diagrams

### WRITE Command with Data
```
Cycle:     0    1    2    3    4    5
           
phy_cmd_valid:   ______/‾‾‾\_____
phy_cmd:         ======< WRITE >====
phy_bank:        ======< 001 >======
phy_addr:        ======< COL >======

phy_wr_valid:    ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾  (stays high for burst)
phy_wr_data:     ====< D0 >< D1 >< D2 >< D3 >====  (BL=4)
phy_wr_dm:       ====< 0  >< 0  >< 0  >< 1  >====  (last byte masked)
phy_wr_last:     ____________/‾‾‾\____
```

### READ Command with Data Return
```
Cycle:     0    1    2    3    4    5    6    7    8    9
           
phy_cmd_valid:   ‾‾\___________________________
phy_cmd:         ==< READ >====================
phy_bank:        ==< 010 >=====================
phy_addr:        ==< COL >=====================

                 (CL=5 + PHY delay=2 = 7 cycles)
phy_rd_valid:    _________________________/‾‾‾‾‾‾‾‾‾‾‾\___
phy_rd_data:     =========================< D0 >< D1 >< D2 >< D3 >====
phy_rd_last:     __________________________________/‾‾‾\____
```

---

## PHY Latency Specification

### Write Path
- **Controller → PHY:** 0 cycles (synchronous)
- **PHY → DRAM:** PHY handles write leveling and DQS alignment

### Read Path
- **Command → Data:** CL (CAS Latency) cycles at DRAM
- **PHY Latency:** +2 cycles typical (DQS capture and deserialization)
- **Total:** CL + 2 cycles from READ command to phy_rd_valid

**Example for DDR2-800 (CL=5):**
- READ command issued at cycle 0
- Data appears on phy_rd_data at cycle 7

---

## Burst Handling

### Write Bursts
- Controller asserts `phy_wr_valid` for BL beats
- `phy_wr_last` asserts on final beat
- PHY ready backpressure via `phy_wr_ready`

### Read Bursts
- PHY asserts `phy_rd_valid` for BL beats
- `phy_rd_last` asserts on final beat
- Controller must be ready to accept (no backpressure on read path)

**Burst Length:** Typically BL=4 or BL=8 for DDR2

---

## Command Encoding Reference

| phy_cmd[3:0] | Command          | phy_bank | phy_addr       | Notes                    |
|--------------|------------------|----------|----------------|--------------------------|
| 4'b0000      | NOP              | X        | X              | No operation             |
| 4'b0001      | ACTIVATE         | Bank     | Row address    | Opens row in bank        |
| 4'b0010      | READ             | Bank     | Column addr    | Read with auto-precharge if A10=1 |
| 4'b0011      | WRITE            | Bank     | Column addr    | Write with auto-precharge if A10=1 |
| 4'b0100      | PRECHARGE        | Bank     | A10: 0=single, 1=all | Close row(s)     |
| 4'b0101      | REFRESH          | X        | X              | Auto-refresh all banks   |
| 4'b0110      | MODE_REG_SET     | BA[2:0]  | MR value       | Load mode register       |
| 4'b0111      | PRECHARGE_ALL    | X        | X              | Shorthand for PRE with A10=1 |

---

## Alternative: DFI-Like Interface

If you prefer a DFI-compliant interface (DDR PHY Interface standard), use:

```systemverilog
// DFI Command Interface
output logic        dfi_cs_n[RANKS-1:0];
output logic        dfi_ras_n;
output logic        dfi_cas_n;
output logic        dfi_we_n;
output logic        dfi_cke[RANKS-1:0];
output logic        dfi_odt[RANKS-1:0];
output logic [2:0]  dfi_bank;
output logic [12:0] dfi_address;

// DFI Write Data
output logic [DQ_WIDTH-1:0]     dfi_wrdata;
output logic [DQ_WIDTH/8-1:0]   dfi_wrdata_mask;
output logic                    dfi_wrdata_en;

// DFI Read Data
input  logic [DQ_WIDTH-1:0]     dfi_rddata;
input  logic                    dfi_rddata_valid;
```

**For this reference design, we use the simplified command-encoded interface above.**

---

## Controller Responsibilities

The memory controller must:
1. **Enforce timing constraints** (T_RCD, T_RP, T_RC, etc.) before issuing commands
2. **Track bank states** (IDLE, ACTIVE, etc.)
3. **Schedule commands** to maximize throughput
4. **Handle refresh** at T_REFI intervals
5. **Manage write data alignment** (present data with/before WRITE command)
6. **Calculate read data return time** (CL + PHY_LATENCY)

The PHY handles:
1. **DQS generation and sampling**
2. **Write leveling** (DQS-to-CK alignment)
3. **Read DQS gating** (when to capture read data)
4. **ODT timing** (if not controlled by controller)
5. **I/O buffer delays and calibration**

---

## Integration Checklist

- [ ] Controller uses exact signal names from this contract
- [ ] Command encoding matches 4-bit table above
- [ ] Write data presented with proper timing (WL cycles before data on bus)
- [ ] Read data expected at CL + PHY_LATENCY cycles
- [ ] ODT controlled per rank during writes
- [ ] Initialization waits for phy_init_done
- [ ] Burst handling uses wr_last/rd_last correctly
- [ ] No signal name invention outside this contract

---

## Example Instantiation

```systemverilog
ddr2_controller #(
    .DQ_WIDTH(16),
    .DM_WIDTH(2),
    .BANK_BITS(3),
    .ADDR_BITS(13),
    .CL(5),
    .WL(4)
) u_ddr2_ctrl (
    .phy_clk(phy_clk),
    .phy_rst_n(phy_rst_n),
    
    // Command interface
    .phy_cmd_valid(phy_cmd_valid),
    .phy_cmd_ready(phy_cmd_ready),
    .phy_cmd(phy_cmd),
    .phy_bank(phy_bank),
    .phy_addr(phy_addr),
    
    // Write data
    .phy_wr_valid(phy_wr_valid),
    .phy_wr_ready(phy_wr_ready),
    .phy_wr_data(phy_wr_data),
    .phy_wr_dm(phy_wr_dm),
    .phy_wr_last(phy_wr_last),
    
    // Read data
    .phy_rd_valid(phy_rd_valid),
    .phy_rd_data(phy_rd_data),
    .phy_rd_last(phy_rd_last),
    
    // ODT
    .phy_odt(phy_odt),
    
    // Init
    .phy_init_done(phy_init_done),
    
    // ... host interface connections ...
);
```

---

## Notes for LLM Generation

When generating the PHY interface module:

1. **Use these exact signal names** - no `phy_command` or `phy_address_bus`
2. **Follow the handshake protocol** - valid/ready for commands and write data
3. **Calculate read latency** as CL + 2 (or parameterize PHY_LATENCY)
4. **Handle burst counts** properly using _last signals
5. **Don't invent new signals** beyond this contract

---

**This contract is authoritative. Follow it exactly during RTL generation.**
