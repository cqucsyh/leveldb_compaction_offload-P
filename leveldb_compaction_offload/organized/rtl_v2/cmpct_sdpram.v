// Simple Dual-Port RAM — clean template for guaranteed BRAM inference.
// Port A: write-only.  Port B: synchronous read-only (1-cycle latency).
module cmpct_sdpram #(
    parameter DEPTH     = 4096,
    parameter WIDTH     = 8,
    parameter ADDR_BITS = $clog2(DEPTH)
)(
    input  wire                  clk,
    // Write port
    input  wire                  we,
    input  wire [ADDR_BITS-1:0]  waddr,
    input  wire [WIDTH-1:0]      wdata,
    // Read port (1-cycle latency: data appears on rdata one cycle after raddr is presented)
    input  wire                  re,
    input  wire [ADDR_BITS-1:0]  raddr,
    output reg  [WIDTH-1:0]      rdata
);

    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        if (re)
            rdata <= mem[raddr];
    end

endmodule
