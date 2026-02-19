//==============================================================================
// Host Interface Contract
// Shared context file for all memory controller types
//==============================================================================

// PROTOCOL: Custom Ready/Valid Interface
// Used when spec.json has: "host_if.bus": "custom"
//
// REQUEST SIGNALS:
//   req_valid  : Host asserts when request is valid
//   req_ready  : Controller asserts when ready to accept
//   req_write  : 1 = write, 0 = read
//   req_addr   : Byte address (width = ADDR_WIDTH)
//   req_wdata  : Write data (width = DATA_WIDTH)
//   req_wstrb  : Byte enables (width = DATA_WIDTH/8)
//
// RESPONSE SIGNALS:
//   rsp_valid  : Controller asserts when response ready
//   rsp_ready  : Host asserts when ready to accept
//   rsp_rdata  : Read data
//   rsp_err    : Error flag
//
// HANDSHAKE: Transfer occurs when valid && ready on clock edge

// BYTE STROBES:
//   wstrb[0] enables bits [7:0]
//   wstrb[1] enables bits [15:8]
//   wstrb[2] enables bits [23:16]
//   wstrb[3] enables bits [31:24]

// ADDRESS ALIGNMENT:
//   32-bit data: addresses aligned to 4 bytes
//   mem_addr = req_addr[ADDR_WIDTH-1 : $clog2(DATA_WIDTH/8)]
