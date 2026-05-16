`timescale 1ns / 1ps

// cmpct_desc_dispatch
//
// Round-robin descriptor dispatcher for multi-chain parallelism.
// Receives a paired descriptor stream from cmpct_desc_matcher and
// distributes descriptors to 2 output streams in round-robin order.
//
// Descriptor dispatch:
//   - Even-indexed pairs (0, 2, 4, ...) → chain 0
//   - Odd-indexed pairs  (1, 3, 5, ...) → chain 1
//
// desc_last handling:
//   Each chain's output has desc_last asserted on the final descriptor
//   for that chain. Since we don't know a descriptor is "last for chain X"
//   until the input stream ends, we use a 1-deep buffer per chain:
//   - New descriptors are stored in the buffer
//   - The buffer is emitted (with desc_last=0) only when the next descriptor
//     arrives for the same chain, OR emitted (with desc_last=1) when the
//     input stream terminates.
//
module cmpct_desc_dispatch #(
    parameter integer ADDR_WIDTH = 64
) (
    input  wire                    clk,
    input  wire                    rstn,
    input  wire                    clear,
    input  wire                    start,

    // Input descriptor stream (from desc_matcher)
    input  wire                    s_desc_valid,
    output wire                    s_desc_ready,
    input  wire [ADDR_WIDTH-1:0]   s_desc_src0_addr,
    input  wire [31:0]             s_desc_src0_size,
    input  wire [ADDR_WIDTH-1:0]   s_desc_src1_addr,
    input  wire [31:0]             s_desc_src1_size,
    input  wire                    s_desc_last,

    // Output descriptor streams (to chains)
    // Chain 0
    output reg                     m_desc_valid_0,
    input  wire                    m_desc_ready_0,
    output reg  [ADDR_WIDTH-1:0]   m_desc_src0_addr_0,
    output reg  [31:0]             m_desc_src0_size_0,
    output reg  [ADDR_WIDTH-1:0]   m_desc_src1_addr_0,
    output reg  [31:0]             m_desc_src1_size_0,
    output reg                     m_desc_last_0,

    // Chain 1
    output reg                     m_desc_valid_1,
    input  wire                    m_desc_ready_1,
    output reg  [ADDR_WIDTH-1:0]   m_desc_src0_addr_1,
    output reg  [31:0]             m_desc_src0_size_1,
    output reg  [ADDR_WIDTH-1:0]   m_desc_src1_addr_1,
    output reg  [31:0]             m_desc_src1_size_1,
    output reg                     m_desc_last_1,

    // Status
    output reg                     busy,
    output reg                     done,
    output reg  [31:0]             total_pair_count,
    output reg                     chain0_active,   // chain 0 has work
    output reg                     chain1_active    // chain 1 has work
);

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_FETCH   = 3'd1;  // waiting for input descriptor
    localparam [2:0] ST_FLUSH0  = 3'd2;  // emit buffered chain 0 with desc_last=1
    localparam [2:0] ST_FLUSH1  = 3'd3;  // emit buffered chain 1 with desc_last=1
    localparam [2:0] ST_DONE    = 3'd4;

    reg [2:0] state;
    reg       rr_sel;        // round-robin selector: 0=chain0 next, 1=chain1 next
    reg [31:0] pair_count;

    // Per-chain buffers (1-deep): holds the latest descriptor for each chain
    // that hasn't been emitted yet.
    reg                  buf0_valid;
    reg [ADDR_WIDTH-1:0] buf0_src0_addr;
    reg [31:0]           buf0_src0_size;
    reg [ADDR_WIDTH-1:0] buf0_src1_addr;
    reg [31:0]           buf0_src1_size;

    reg                  buf1_valid;
    reg [ADDR_WIDTH-1:0] buf1_src0_addr;
    reg [31:0]           buf1_src0_size;
    reg [ADDR_WIDTH-1:0] buf1_src1_addr;
    reg [31:0]           buf1_src1_size;

    // Input ready: only accept in FETCH state and output not stalled
    assign s_desc_ready = (state == ST_FETCH) && !m_desc_valid_0 && !m_desc_valid_1;

    always @(posedge clk) begin
        if (!rstn) begin
            state            <= ST_IDLE;
            busy             <= 1'b0;
            done             <= 1'b0;
            rr_sel           <= 1'b0;
            pair_count       <= 32'd0;
            total_pair_count <= 32'd0;
            chain0_active    <= 1'b0;
            chain1_active    <= 1'b0;
            buf0_valid       <= 1'b0;
            buf1_valid       <= 1'b0;
            m_desc_valid_0   <= 1'b0;
            m_desc_valid_1   <= 1'b0;
            m_desc_last_0    <= 1'b0;
            m_desc_last_1    <= 1'b0;
        end else if (clear) begin
            state            <= ST_IDLE;
            busy             <= 1'b0;
            done             <= 1'b0;
            rr_sel           <= 1'b0;
            pair_count       <= 32'd0;
            total_pair_count <= 32'd0;
            chain0_active    <= 1'b0;
            chain1_active    <= 1'b0;
            buf0_valid       <= 1'b0;
            buf1_valid       <= 1'b0;
            m_desc_valid_0   <= 1'b0;
            m_desc_valid_1   <= 1'b0;
            m_desc_last_0    <= 1'b0;
            m_desc_last_1    <= 1'b0;
        end else begin
            done <= 1'b0;

            // Handshake: deassert valid after accepted
            if (m_desc_valid_0 && m_desc_ready_0) m_desc_valid_0 <= 1'b0;
            if (m_desc_valid_1 && m_desc_ready_1) m_desc_valid_1 <= 1'b0;

            case (state)

                ST_IDLE: begin
                    if (start && !busy) begin
                        busy          <= 1'b1;
                        rr_sel        <= 1'b0;
                        pair_count    <= 32'd0;
                        chain0_active <= 1'b0;
                        chain1_active <= 1'b0;
                        buf0_valid    <= 1'b0;
                        buf1_valid    <= 1'b0;
                        state         <= ST_FETCH;
                    end
                end

                // --------------------------------------------------------
                // FETCH: Accept descriptors and buffer them per-chain.
                // When a new descriptor arrives for a chain that already
                // has a buffered one, emit the old one (desc_last=0) first.
                // When input signals last, flush all buffers with desc_last=1.
                // --------------------------------------------------------
                ST_FETCH: begin
                    if (s_desc_valid && s_desc_ready) begin
                        pair_count <= pair_count + 32'd1;

                        if (rr_sel == 1'b0) begin
                            // This descriptor goes to chain 0
                            if (buf0_valid) begin
                                // Emit previous buf0 with desc_last=0
                                m_desc_src0_addr_0 <= buf0_src0_addr;
                                m_desc_src0_size_0 <= buf0_src0_size;
                                m_desc_src1_addr_0 <= buf0_src1_addr;
                                m_desc_src1_size_0 <= buf0_src1_size;
                                m_desc_last_0      <= 1'b0;
                                m_desc_valid_0     <= 1'b1;
                            end
                            // Store new descriptor in buffer
                            buf0_src0_addr <= s_desc_src0_addr;
                            buf0_src0_size <= s_desc_src0_size;
                            buf0_src1_addr <= s_desc_src1_addr;
                            buf0_src1_size <= s_desc_src1_size;
                            buf0_valid     <= 1'b1;
                            chain0_active  <= 1'b1;
                        end else begin
                            // This descriptor goes to chain 1
                            if (buf1_valid) begin
                                // Emit previous buf1 with desc_last=0
                                m_desc_src0_addr_1 <= buf1_src0_addr;
                                m_desc_src0_size_1 <= buf1_src0_size;
                                m_desc_src1_addr_1 <= buf1_src1_addr;
                                m_desc_src1_size_1 <= buf1_src1_size;
                                m_desc_last_1      <= 1'b0;
                                m_desc_valid_1     <= 1'b1;
                            end
                            // Store new descriptor in buffer
                            buf1_src0_addr <= s_desc_src0_addr;
                            buf1_src0_size <= s_desc_src0_size;
                            buf1_src1_addr <= s_desc_src1_addr;
                            buf1_src1_size <= s_desc_src1_size;
                            buf1_valid     <= 1'b1;
                            chain1_active  <= 1'b1;
                        end

                        rr_sel <= ~rr_sel;

                        if (s_desc_last) begin
                            // Input stream ended — flush all buffers
                            state <= ST_FLUSH0;
                        end
                        // else: stay in ST_FETCH (will wait for output handshake
                        //        via s_desc_ready gating)
                    end
                end

                // --------------------------------------------------------
                // FLUSH0: Emit chain 0's buffered descriptor with desc_last=1
                // --------------------------------------------------------
                ST_FLUSH0: begin
                    if (!m_desc_valid_0 || (m_desc_valid_0 && m_desc_ready_0)) begin
                        if (buf0_valid) begin
                            m_desc_src0_addr_0 <= buf0_src0_addr;
                            m_desc_src0_size_0 <= buf0_src0_size;
                            m_desc_src1_addr_0 <= buf0_src1_addr;
                            m_desc_src1_size_0 <= buf0_src1_size;
                            m_desc_last_0      <= 1'b1;
                            m_desc_valid_0     <= 1'b1;
                            buf0_valid         <= 1'b0;
                            state              <= ST_FLUSH1;
                        end else begin
                            // Chain 0 has no buffered data
                            m_desc_valid_0 <= 1'b0;
                            state          <= ST_FLUSH1;
                        end
                    end
                end

                // --------------------------------------------------------
                // FLUSH1: Emit chain 1's buffered descriptor with desc_last=1
                // --------------------------------------------------------
                ST_FLUSH1: begin
                    if (!m_desc_valid_1 || (m_desc_valid_1 && m_desc_ready_1)) begin
                        // Also wait for chain 0's flush to be accepted
                        if (m_desc_valid_0 && !m_desc_ready_0) begin
                            // Chain 0 still pending, wait
                        end else begin
                            if (buf1_valid) begin
                                m_desc_src0_addr_1 <= buf1_src0_addr;
                                m_desc_src0_size_1 <= buf1_src0_size;
                                m_desc_src1_addr_1 <= buf1_src1_addr;
                                m_desc_src1_size_1 <= buf1_src1_size;
                                m_desc_last_1      <= 1'b1;
                                m_desc_valid_1     <= 1'b1;
                                buf1_valid         <= 1'b0;
                            end else begin
                                m_desc_valid_1 <= 1'b0;
                            end
                            state <= ST_DONE;
                        end
                    end
                end

                ST_DONE: begin
                    // Wait for all outputs to be accepted
                    if ((!m_desc_valid_0 || (m_desc_valid_0 && m_desc_ready_0)) &&
                        (!m_desc_valid_1 || (m_desc_valid_1 && m_desc_ready_1))) begin
                        m_desc_valid_0   <= 1'b0;
                        m_desc_valid_1   <= 1'b0;
                        total_pair_count <= pair_count;
                        busy             <= 1'b0;
                        done             <= 1'b1;
                        state            <= ST_IDLE;
                    end
                end

            endcase
        end
    end

endmodule
