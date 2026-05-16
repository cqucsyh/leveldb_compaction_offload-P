`timescale 1ns / 1ps

// desc_pair_matcher
//
// OPT-P1b: Zips two independent handle streams (from SSTable parsers)
// into matched (src0, src1) descriptor pairs for the nblock engine.
//
// Each parser emits handles one at a time via a valid/ready stream.
// This module waits for a handle from each *active* side, then emits
// a paired descriptor.  When one side finishes (s*_all_done && !s*_valid),
// its contribution becomes zero-size so the nblock engine treats it as
// an empty source (the merger passes through the other side's records).
//
// Interface:
//   s0_* / s1_*  : handle streams from parser FIFOs (valid/ready + addr/size)
//   s0_all_done / s1_all_done : asserted once the parser has emitted its last handle
//   m_desc_*     : paired descriptor stream to nblock engine
//   m_desc_last  : asserted on the final descriptor
//
module desc_pair_matcher #(
    parameter integer ADDR_WIDTH = 64
) (
    input  wire                    clk,
    input  wire                    rstn,
    input  wire                    clear,
    input  wire                    start,

    // Handle stream from parser 0
    input  wire                    s0_handle_valid,
    output wire                    s0_handle_ready,
    input  wire [ADDR_WIDTH-1:0]   s0_handle_addr,
    input  wire [31:0]             s0_handle_size,
    input  wire                    s0_all_done,

    // Handle stream from parser 1
    input  wire                    s1_handle_valid,
    output wire                    s1_handle_ready,
    input  wire [ADDR_WIDTH-1:0]   s1_handle_addr,
    input  wire [31:0]             s1_handle_size,
    input  wire                    s1_all_done,

    // Matched descriptor stream output
    output reg                     m_desc_valid,
    input  wire                    m_desc_ready,
    output reg  [ADDR_WIDTH-1:0]   m_desc_src0_addr,
    output reg  [31:0]             m_desc_src0_size,
    output reg  [ADDR_WIDTH-1:0]   m_desc_src1_addr,
    output reg  [31:0]             m_desc_src1_size,
    output reg                     m_desc_last,

    output reg                     busy,
    output reg                     done,
    output reg  [31:0]             pair_count
);

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    localparam [1:0] ST_IDLE    = 2'd0;
    localparam [1:0] ST_GATHER  = 2'd1;
    localparam [1:0] ST_EMIT    = 2'd2;
    localparam [1:0] ST_DONE    = 2'd3;

    reg [1:0] state;

    // Latch "all done" flags (they may be pulses from the parser)
    reg s0_done_r, s1_done_r;

    // Captured fields for current pair
    reg [ADDR_WIDTH-1:0] cap_s0_addr;
    reg [31:0]           cap_s0_size;
    reg                  cap_s0_got;    // handle captured (or side is done → zero)

    reg [ADDR_WIDTH-1:0] cap_s1_addr;
    reg [31:0]           cap_s1_size;
    reg                  cap_s1_got;

    // Ready signals — only assert when we are in GATHER and need data
    assign s0_handle_ready = (state == ST_GATHER) && !cap_s0_got && !s0_done_r;
    assign s1_handle_ready = (state == ST_GATHER) && !cap_s1_got && !s1_done_r;

    always @(posedge clk) begin
        if (!rstn) begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            m_desc_valid <= 1'b0;
            m_desc_last  <= 1'b0;
            pair_count  <= 32'd0;
            s0_done_r   <= 1'b0;
            s1_done_r   <= 1'b0;
            cap_s0_got  <= 1'b0;
            cap_s1_got  <= 1'b0;
        end else if (clear) begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            m_desc_valid <= 1'b0;
            m_desc_last  <= 1'b0;
            pair_count  <= 32'd0;
            s0_done_r   <= 1'b0;
            s1_done_r   <= 1'b0;
            cap_s0_got  <= 1'b0;
            cap_s1_got  <= 1'b0;
        end else begin
            // Latch persistent done flags
            if (s0_all_done) s0_done_r <= 1'b1;
            if (s1_all_done) s1_done_r <= 1'b1;

            done <= 1'b0;

            case (state)

                ST_IDLE: begin
                    if (start && !busy) begin
                        busy       <= 1'b1;
                        pair_count <= 32'd0;
                        s0_done_r  <= 1'b0;
                        s1_done_r  <= 1'b0;
                        cap_s0_got <= 1'b0;
                        cap_s1_got <= 1'b0;
                        state      <= ST_GATHER;
                    end
                end

                // --------------------------------------------------------
                // GATHER: collect one handle from each active side.
                //   - If a side has a valid handle, capture it.
                //   - If a side is done (no more handles), mark as "got"
                //     with zero addr/size.
                //   - When both sides are "got", transition to EMIT.
                // --------------------------------------------------------
                ST_GATHER: begin
                    // Capture side 0
                    if (!cap_s0_got) begin
                        if (s0_handle_valid) begin
                            cap_s0_addr <= s0_handle_addr;
                            cap_s0_size <= s0_handle_size;
                            cap_s0_got  <= 1'b1;
                        end else if (s0_done_r) begin
                            cap_s0_addr <= {ADDR_WIDTH{1'b0}};
                            cap_s0_size <= 32'd0;
                            cap_s0_got  <= 1'b1;
                        end
                    end

                    // Capture side 1
                    if (!cap_s1_got) begin
                        if (s1_handle_valid) begin
                            cap_s1_addr <= s1_handle_addr;
                            cap_s1_size <= s1_handle_size;
                            cap_s1_got  <= 1'b1;
                        end else if (s1_done_r) begin
                            cap_s1_addr <= {ADDR_WIDTH{1'b0}};
                            cap_s1_size <= 32'd0;
                            cap_s1_got  <= 1'b1;
                        end
                    end

                    // Both sides captured?
                    // (Use combinational lookahead so we can transition on
                    //  the same cycle both sides become "got".)
                    if ((cap_s0_got || s0_handle_valid || s0_done_r) &&
                        (cap_s1_got || s1_handle_valid || s1_done_r)) begin

                        // Check for terminal: both sides done, no new data
                        if ((cap_s0_got ? 1'b1 : !s0_handle_valid) && s0_done_r &&
                            (cap_s1_got ? 1'b1 : !s1_handle_valid) && s1_done_r &&
                            !cap_s0_got && !cap_s1_got) begin
                            // Both sides are done and neither has pending data
                            state <= ST_DONE;
                        end
                    end

                    // Transition when both captured (registered)
                    if (cap_s0_got && cap_s1_got) begin
                        // Both are now captured — check if both zero (both done)
                        if (s0_done_r && cap_s0_size == 32'd0 &&
                            s1_done_r && cap_s1_size == 32'd0) begin
                            // No real data — terminal
                            state <= ST_DONE;
                        end else begin
                            state <= ST_EMIT;
                        end
                    end
                end

                // --------------------------------------------------------
                // EMIT: present the matched pair on the output stream.
                // Defer m_desc_valid until m_desc_last is known:
                //   - If another handle is queued on either side → not last
                //   - If both parsers finished → is last
                //   - Otherwise wait (parser still running, can't decide yet)
                // --------------------------------------------------------
                ST_EMIT: begin
                    m_desc_src0_addr <= cap_s0_addr;
                    m_desc_src0_size <= cap_s0_size;
                    m_desc_src1_addr <= cap_s1_addr;
                    m_desc_src1_size <= cap_s1_size;

                    if (!m_desc_valid) begin
                        if (s0_handle_valid || s1_handle_valid) begin
                            // Another handle already queued → definitely not last
                            m_desc_last  <= 1'b0;
                            m_desc_valid <= 1'b1;
                        end else if ((s0_done_r || s0_all_done) &&
                                     (s1_done_r || s1_all_done)) begin
                            // Both parsers finished, no pending handles → is last
                            m_desc_last  <= 1'b1;
                            m_desc_valid <= 1'b1;
                        end
                        // else: parser(s) still running, wait for handle or done
                    end

                    if (m_desc_valid && m_desc_ready) begin
                        m_desc_valid <= 1'b0;
                        pair_count   <= pair_count + 32'd1;
                        cap_s0_got   <= 1'b0;
                        cap_s1_got   <= 1'b0;

                        if (m_desc_last) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_GATHER;
                        end
                    end
                end

                ST_DONE: begin
                    m_desc_valid <= 1'b0;
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    state        <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
