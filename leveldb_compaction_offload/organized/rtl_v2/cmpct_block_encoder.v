`timescale 1ns / 1ps

// P7: 64-bit wide streaming encoder (8 bytes/cycle throughput).
// Evolved from OPT-ENC-W32. Key changes:
//   - Input/output are 64-bit + 8-bit tkeep
//   - ST_RECV_KEY: 8 bytes/cycle with pipelined 8-way prefix comparison
//   - Varint states: emit full varint (1-5 bytes) in 1 cycle within 64-bit word
//   - ST_WRITE_KEY: 8 bytes/cycle from key buffer
//   - ST_STREAM_VALUE: 64-bit pass-through
//   - ST_APPEND_RESTARTS: 2 restarts (8 bytes) per cycle
//   - ST_APPEND_RST_CNT: 4 bytes in 1 cycle (within 64-bit word)
module cmpct_block_encoder #(
    parameter integer MAX_RECORDS       = 256,
    parameter integer MAX_PAYLOAD_BYTES = 4096,
    parameter integer MAX_BLOCK_BYTES   = 4096,
    parameter integer MAX_KEY_BYTES     = 256,
    parameter integer MAX_VALUE_BYTES   = 1024,
    parameter integer RESTART_INTERVAL  = 16
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        s_record_valid,
    output wire        s_record_ready,
    input  wire [15:0] s_record_key_len,
    input  wire [15:0] s_record_value_len,
    input  wire        source_done,
    // P7: 64-bit input (from merger FIFO directly)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    // P7: 64-bit output (to enc_out packer)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         busy,
    output reg         done,
    output reg         error,
    output reg  [31:0] input_record_count,
    output reg  [31:0] encoded_entry_count,
    output reg  [31:0] restart_count,
    output reg  [31:0] shared_key_bytes_total,
    output reg  [31:0] unshared_key_bytes_total,
    output reg  [31:0] value_bytes_total,
    output reg  [15:0]                  last_key_len,
    output wire [(MAX_KEY_BYTES*8)-1:0]   last_key_bytes,
    output reg  [15:0]                  last_value_len,
    output reg  [15:0]                  last_shared_bytes,
    output reg  [15:0]                  last_non_shared_bytes,
    output reg  [31:0]                  output_block_bytes
);

    // =========================================================================
    // States
    // =========================================================================
    localparam [3:0] ST_IDLE            = 4'd0;
    localparam [3:0] ST_WAIT_RECORD     = 4'd1;
    localparam [3:0] ST_RECV_KEY        = 4'd2;
    localparam [3:0] ST_WRITE_VARINTS  = 4'd3;  // P13: combined varint emission
    localparam [3:0] ST_WRITE_VARINTS_OVF = 4'd4;  // P13: overflow (total > 8 bytes, rare)
    localparam [3:0] ST_WRITE_VALUE_LEN = 4'd5;  // P13: dead state (kept for encoding)
    localparam [3:0] ST_WRITE_KEY       = 4'd6;
    localparam [3:0] ST_STREAM_VALUE    = 4'd7;
    localparam [3:0] ST_APPEND_RESTARTS = 4'd8;
    localparam [3:0] ST_APPEND_RST_CNT  = 4'd9;
    localparam [3:0] ST_FINISH          = 4'd10;

    reg [3:0] state;

    // =========================================================================
    // Memories
    // =========================================================================
    (* ram_style = "distributed" *) reg [7:0] key_buf_a [0:MAX_KEY_BYTES-1];
    (* ram_style = "distributed" *) reg [7:0] key_buf_b [0:MAX_KEY_BYTES-1];
    reg [31:0] restart_offset_mem [0:MAX_RECORDS-1];

    reg        prev_buf_sel;
    reg [15:0] prev_key_len;

    // =========================================================================
    // Working registers
    // =========================================================================
    reg [15:0] current_key_len;
    reg [15:0] current_value_len;
    reg [15:0] current_shared_len;
    reg [15:0] current_unshared_len;
    reg        mismatch_found;
    reg        is_restart_point;

    reg [15:0] recv_idx;
    reg [31:0] block_write_index;
    reg [15:0] block_copy_idx;
    reg [31:0] value_rem;
    reg [31:0] restart_emit_idx;
    reg [31:0] entries_since_restart;
    reg        source_done_seen;

    // P7: 64-bit output registers
    reg [63:0] emit_data;
    reg [7:0]  emit_keep;
    reg        emit_valid;
    reg        emit_last;

    // =========================================================================
    // Varint helpers
    // =========================================================================
    function automatic [2:0] varint32_len;
        input [31:0] value;
        begin
            if      (value < 32'd128)       varint32_len = 3'd1;
            else if (value < 32'd16384)     varint32_len = 3'd2;
            else if (value < 32'd2097152)   varint32_len = 3'd3;
            else if (value < 32'd268435456) varint32_len = 3'd4;
            else                            varint32_len = 3'd5;
        end
    endfunction

    // P7: Pack a complete varint into {keep[7:0], data[63:0]} in 1 cycle
    function automatic [71:0] varint32_pack;
        input [31:0] value;
        reg [2:0] len;
        reg [7:0] b0, b1, b2, b3;
        begin
            len = varint32_len(value);
            b0 = (len > 3'd1) ? (value[6:0] | 8'h80) : value[6:0];
            b1 = (len > 3'd2) ? (value[13:7] | 8'h80) : value[13:7];
            b2 = (len > 3'd3) ? (value[20:14] | 8'h80) : value[20:14];
            b3 = value[27:21];
            case (len)
                3'd1: varint32_pack = {8'b0000_0001, 56'd0, b0};
                3'd2: varint32_pack = {8'b0000_0011, 48'd0, b1, b0};
                3'd3: varint32_pack = {8'b0000_0111, 40'd0, b2, b1, b0};
                default: varint32_pack = {8'b0000_1111, 32'd0, b3, b2, b1, b0};
            endcase
        end
    endfunction

    // =========================================================================
    // Combinational signals
    // =========================================================================
    wire can_emit = !emit_valid || m_axis_tready;

    assign s_record_ready = busy && !error && (state == ST_WAIT_RECORD);
    assign s_axis_tready  = busy && !error && (
        (state == ST_RECV_KEY) ||
        (state == ST_STREAM_VALUE && value_rem != 32'd0 && can_emit)
    );

    assign m_axis_tdata  = emit_data;
    assign m_axis_tkeep  = emit_keep;
    assign m_axis_tvalid = emit_valid;
    assign m_axis_tlast  = emit_valid && emit_last;

    wire input_accept = s_axis_tvalid && s_axis_tready;

    // P7: Input byte count from 8-bit tkeep (pipelined-friendly tree)
    wire [3:0] in_bytes = {3'b0, s_axis_tkeep[0]} + {3'b0, s_axis_tkeep[1]}
                        + {3'b0, s_axis_tkeep[2]} + {3'b0, s_axis_tkeep[3]}
                        + {3'b0, s_axis_tkeep[4]} + {3'b0, s_axis_tkeep[5]}
                        + {3'b0, s_axis_tkeep[6]} + {3'b0, s_axis_tkeep[7]};

    // last_key_bytes: expose the prev (most recently completed) key buffer
    genvar lki;
    generate
        for (lki = 0; lki < MAX_KEY_BYTES; lki = lki + 1) begin : g_last_key
            assign last_key_bytes[(lki*8) +: 8] = prev_buf_sel ? key_buf_b[lki] : key_buf_a[lki];
        end
    endgenerate

    // P7: 8-way prev key byte reads for prefix comparison
    wire [7:0] prev_b0 = prev_buf_sel ? key_buf_b[recv_idx+0] : key_buf_a[recv_idx+0];
    wire [7:0] prev_b1 = prev_buf_sel ? key_buf_b[recv_idx+1] : key_buf_a[recv_idx+1];
    wire [7:0] prev_b2 = prev_buf_sel ? key_buf_b[recv_idx+2] : key_buf_a[recv_idx+2];
    wire [7:0] prev_b3 = prev_buf_sel ? key_buf_b[recv_idx+3] : key_buf_a[recv_idx+3];
    wire [7:0] prev_b4 = prev_buf_sel ? key_buf_b[recv_idx+4] : key_buf_a[recv_idx+4];
    wire [7:0] prev_b5 = prev_buf_sel ? key_buf_b[recv_idx+5] : key_buf_a[recv_idx+5];
    wire [7:0] prev_b6 = prev_buf_sel ? key_buf_b[recv_idx+6] : key_buf_a[recv_idx+6];
    wire [7:0] prev_b7 = prev_buf_sel ? key_buf_b[recv_idx+7] : key_buf_a[recv_idx+7];

    // P7: 8-way current key byte reads for ST_WRITE_KEY
    wire [15:0] key_rd_base = current_shared_len + block_copy_idx;
    wire [7:0] key_e0 = prev_buf_sel ? key_buf_a[key_rd_base+0] : key_buf_b[key_rd_base+0];
    wire [7:0] key_e1 = prev_buf_sel ? key_buf_a[key_rd_base+1] : key_buf_b[key_rd_base+1];
    wire [7:0] key_e2 = prev_buf_sel ? key_buf_a[key_rd_base+2] : key_buf_b[key_rd_base+2];
    wire [7:0] key_e3 = prev_buf_sel ? key_buf_a[key_rd_base+3] : key_buf_b[key_rd_base+3];
    wire [7:0] key_e4 = prev_buf_sel ? key_buf_a[key_rd_base+4] : key_buf_b[key_rd_base+4];
    wire [7:0] key_e5 = prev_buf_sel ? key_buf_a[key_rd_base+5] : key_buf_b[key_rd_base+5];
    wire [7:0] key_e6 = prev_buf_sel ? key_buf_a[key_rd_base+6] : key_buf_b[key_rd_base+6];
    wire [7:0] key_e7 = prev_buf_sel ? key_buf_a[key_rd_base+7] : key_buf_b[key_rd_base+7];

    // P7: Remaining unshared key bytes to emit
    wire [15:0] key_rem = current_unshared_len - block_copy_idx;
    wire [3:0]  key_emit_bytes = (key_rem >= 16'd8) ? 4'd8 : key_rem[3:0];

    // P7: Varint packed results (combinational, 72-bit: {keep[7:0], data[63:0]})
    wire [71:0] shared_packed   = varint32_pack({16'd0, current_shared_len});
    wire [71:0] unshared_packed = varint32_pack({16'd0, current_unshared_len});
    wire [71:0] value_packed    = varint32_pack({16'd0, current_value_len});

    wire [2:0] shared_vlen   = varint32_len({16'd0, current_shared_len});
    wire [2:0] unshared_vlen = varint32_len({16'd0, current_unshared_len});
    wire [2:0] value_vlen    = varint32_len({16'd0, current_value_len});

    // =========================================================================
    // P13: Combined varint packing (timing-friendly, from registered lengths)
    // Packs shared_varint || unshared_varint || value_varint into one 64-bit word.
    // Max total: 5+5+5=15 bytes; typical: 1+1+1=3 or 1+1+2=4.
    // Overflow (total > 8) handled by ST_WRITE_VARINTS_OVF.
    // =========================================================================
    wire [3:0] p13_offs_u = {1'b0, shared_vlen};
    wire [3:0] p13_offs_v = {1'b0, shared_vlen} + {1'b0, unshared_vlen};
    wire [3:0] p13_total  = p13_offs_v + {1'b0, value_vlen};
    wire       p13_ovf    = (p13_total > 4'd8);

    // Individual varint byte extracts (max 5 bytes each, LSB-first)
    wire [39:0] p13_sv = shared_packed[39:0];
    wire [39:0] p13_uv = unshared_packed[39:0];
    wire [39:0] p13_vv = value_packed[39:0];

    // Build combined 120-bit buffer using position muxes (5:1 and 9:1)
    // Stage 1: shared at position 0 (no shift needed)
    // Stage 2: unshared shifted by shared_vlen bytes
    // Stage 3: value shifted by (shared_vlen + unshared_vlen) bytes
    reg [119:0] p13_combined;
    always @(*) begin
        p13_combined = {80'd0, p13_sv};
        case (p13_offs_u[2:0])
            3'd1: p13_combined[47:8]    = p13_combined[47:8]   | {p13_uv};
            3'd2: p13_combined[55:16]   = p13_combined[55:16]  | {p13_uv};
            3'd3: p13_combined[63:24]   = p13_combined[63:24]  | {p13_uv};
            3'd4: p13_combined[71:32]   = p13_combined[71:32]  | {p13_uv};
            default: p13_combined[79:40] = p13_combined[79:40] | {p13_uv};
        endcase
        case (p13_offs_v)
            4'd2:  p13_combined[55:16]   = p13_combined[55:16]   | {p13_vv};
            4'd3:  p13_combined[63:24]   = p13_combined[63:24]   | {p13_vv};
            4'd4:  p13_combined[71:32]   = p13_combined[71:32]   | {p13_vv};
            4'd5:  p13_combined[79:40]   = p13_combined[79:40]   | {p13_vv};
            4'd6:  p13_combined[87:48]   = p13_combined[87:48]   | {p13_vv};
            4'd7:  p13_combined[95:56]   = p13_combined[95:56]   | {p13_vv};
            4'd8:  p13_combined[103:64]  = p13_combined[103:64]  | {p13_vv};
            4'd9:  p13_combined[111:72]  = p13_combined[111:72]  | {p13_vv};
            default: p13_combined[119:80] = p13_combined[119:80] | {p13_vv};
        endcase
    end

    wire [63:0] p13_data_lo = p13_combined[63:0];
    wire [63:0] p13_data_hi = p13_combined[119:56]; // bytes 7-14 (for overflow)
    wire [7:0]  p13_keep_lo = (p13_total >= 4'd8) ? 8'hff :
                              (p13_total == 4'd7) ? 8'h7f :
                              (p13_total == 4'd6) ? 8'h3f :
                              (p13_total == 4'd5) ? 8'h1f :
                              (p13_total == 4'd4) ? 8'h0f :
                              (p13_total == 4'd3) ? 8'h07 :
                              (p13_total == 4'd2) ? 8'h03 : 8'h01;
    wire [3:0]  p13_hi_len  = p13_total - 4'd8;
    wire [7:0]  p13_keep_hi = (p13_hi_len >= 4'd7) ? 8'h7f :
                              (p13_hi_len == 4'd6) ? 8'h3f :
                              (p13_hi_len == 4'd5) ? 8'h1f :
                              (p13_hi_len == 4'd4) ? 8'h0f :
                              (p13_hi_len == 4'd3) ? 8'h07 :
                              (p13_hi_len == 4'd2) ? 8'h03 : 8'h01;

    // =========================================================================
    // P7: 8-way prefix comparison (combinational, chain structure)
    // Timing note: 8-deep chain is safe for distributed RAM (single-LUT reads)
    // =========================================================================
    reg [15:0] new_shared_len;
    reg        new_mismatch;

    wire [7:0] in_b [0:7];
    assign in_b[0] = s_axis_tdata[ 7: 0];
    assign in_b[1] = s_axis_tdata[15: 8];
    assign in_b[2] = s_axis_tdata[23:16];
    assign in_b[3] = s_axis_tdata[31:24];
    assign in_b[4] = s_axis_tdata[39:32];
    assign in_b[5] = s_axis_tdata[47:40];
    assign in_b[6] = s_axis_tdata[55:48];
    assign in_b[7] = s_axis_tdata[63:56];

    wire [7:0] prev_b [0:7];
    assign prev_b[0] = prev_b0; assign prev_b[1] = prev_b1;
    assign prev_b[2] = prev_b2; assign prev_b[3] = prev_b3;
    assign prev_b[4] = prev_b4; assign prev_b[5] = prev_b5;
    assign prev_b[6] = prev_b6; assign prev_b[7] = prev_b7;

    // Per-byte match signals (flat, no chain dependency)
    wire [7:0] byte_match;
    genvar cmp_i;
    generate
        for (cmp_i = 0; cmp_i < 8; cmp_i = cmp_i + 1) begin : g_cmp
            assign byte_match[cmp_i] = s_axis_tkeep[cmp_i] &&
                                       (recv_idx + cmp_i < prev_key_len) &&
                                       (in_b[cmp_i] == prev_b[cmp_i]);
        end
    endgenerate

    // First mismatch position (priority encode)
    wire [3:0] first_mismatch_pos;
    wire       any_valid_mismatch;
    assign first_mismatch_pos =
        (!byte_match[0] && s_axis_tkeep[0]) ? 4'd0 :
        (!byte_match[1] && s_axis_tkeep[1]) ? 4'd1 :
        (!byte_match[2] && s_axis_tkeep[2]) ? 4'd2 :
        (!byte_match[3] && s_axis_tkeep[3]) ? 4'd3 :
        (!byte_match[4] && s_axis_tkeep[4]) ? 4'd4 :
        (!byte_match[5] && s_axis_tkeep[5]) ? 4'd5 :
        (!byte_match[6] && s_axis_tkeep[6]) ? 4'd6 :
        (!byte_match[7] && s_axis_tkeep[7]) ? 4'd7 : 4'd8;
    assign any_valid_mismatch = (first_mismatch_pos < 4'd8);

    always @(*) begin
        new_shared_len = current_shared_len;
        new_mismatch   = mismatch_found;
        if (input_accept && state == ST_RECV_KEY && !is_restart_point && !mismatch_found) begin
            if (any_valid_mismatch) begin
                new_shared_len = recv_idx + {12'd0, first_mismatch_pos};
                new_mismatch   = 1'b1;
            end else begin
                // All valid bytes matched
                new_shared_len = recv_idx + {12'd0, in_bytes};
            end
        end
    end

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always @(posedge clk) begin
        if (!rstn || clear) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            input_record_count       <= 32'd0;
            encoded_entry_count      <= 32'd0;
            restart_count            <= 32'd0;
            shared_key_bytes_total   <= 32'd0;
            unshared_key_bytes_total <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_key_len             <= 16'd0;
            last_value_len           <= 16'd0;
            last_shared_bytes        <= 16'd0;
            last_non_shared_bytes    <= 16'd0;
            output_block_bytes       <= 32'd0;
            state                    <= ST_IDLE;
            prev_buf_sel             <= 1'b0;
            prev_key_len             <= 16'd0;
            current_key_len          <= 16'd0;
            current_value_len        <= 16'd0;
            current_shared_len       <= 16'd0;
            current_unshared_len     <= 16'd0;
            mismatch_found           <= 1'b0;
            is_restart_point         <= 1'b0;
            recv_idx                 <= 16'd0;
            block_write_index        <= 32'd0;
            block_copy_idx           <= 16'd0;
            value_rem                <= 32'd0;
            restart_emit_idx         <= 32'd0;
            entries_since_restart    <= 32'd0;
            source_done_seen         <= 1'b0;
            emit_data                <= 64'd0;
            emit_keep                <= 8'd0;
            emit_valid               <= 1'b0;
            emit_last                <= 1'b0;
        end else begin
            done <= 1'b0;
            if (source_done) source_done_seen <= 1'b1;

            // Auto-clear emit on acceptance
            if (emit_valid && m_axis_tready) begin
                emit_valid <= 1'b0;
            end

            case (state)
                // =============================================================
                ST_IDLE: begin
                    if (start && !busy) begin
                        busy                  <= 1'b1;
                        done                  <= 1'b0;
                        error                 <= 1'b0;
                        input_record_count    <= 32'd0;
                        encoded_entry_count   <= 32'd0;
                        restart_count         <= 32'd1;
                        shared_key_bytes_total   <= 32'd0;
                        unshared_key_bytes_total <= 32'd0;
                        value_bytes_total     <= 32'd0;
                        last_key_len          <= 16'd0;
                        last_value_len        <= 16'd0;
                        last_shared_bytes     <= 16'd0;
                        last_non_shared_bytes <= 16'd0;
                        output_block_bytes    <= 32'd0;
                        prev_buf_sel          <= 1'b0;
                        prev_key_len          <= 16'd0;
                        block_write_index     <= 32'd0;
                        entries_since_restart  <= 32'd0;
                        source_done_seen      <= 1'b0;
                        emit_valid            <= 1'b0;
                        emit_last             <= 1'b0;
                        restart_offset_mem[0] <= 32'd0;
                        state                 <= ST_WAIT_RECORD;
                    end
                end

                // =============================================================
                ST_WAIT_RECORD: begin
                    if (s_record_valid && s_record_ready) begin
                        current_key_len    <= s_record_key_len;
                        current_value_len  <= s_record_value_len;
                        input_record_count <= input_record_count + 32'd1;

                        if (entries_since_restart == RESTART_INTERVAL) begin
                            is_restart_point <= 1'b1;
                            if (restart_count < MAX_RECORDS)
                                restart_offset_mem[restart_count] <= block_write_index;
                            restart_count        <= restart_count + 32'd1;
                            entries_since_restart <= 32'd0;
                        end else begin
                            is_restart_point <= 1'b0;
                        end

                        recv_idx           <= 16'd0;
                        current_shared_len <= 16'd0;
                        mismatch_found     <= 1'b0;

                        if (s_record_key_len == 16'd0) begin
                            current_unshared_len <= 16'd0;
                            state <= ST_WRITE_VARINTS;  // P13
                        end else begin
                            state <= ST_RECV_KEY;
                        end
                    end else if ((source_done || source_done_seen) && !s_record_valid) begin
                        restart_emit_idx <= 32'd0;
                        state            <= ST_APPEND_RESTARTS;
                    end
                end

                // =============================================================
                // P7: Receive 8 key bytes/cycle with inline prefix
                ST_RECV_KEY: begin
                    if (input_accept) begin
                        // Write bytes to CURRENT key buffer (8 lanes)
                        if (!prev_buf_sel) begin
                            if (s_axis_tkeep[0]) key_buf_b[recv_idx+0] <= s_axis_tdata[ 7: 0];
                            if (s_axis_tkeep[1]) key_buf_b[recv_idx+1] <= s_axis_tdata[15: 8];
                            if (s_axis_tkeep[2]) key_buf_b[recv_idx+2] <= s_axis_tdata[23:16];
                            if (s_axis_tkeep[3]) key_buf_b[recv_idx+3] <= s_axis_tdata[31:24];
                            if (s_axis_tkeep[4]) key_buf_b[recv_idx+4] <= s_axis_tdata[39:32];
                            if (s_axis_tkeep[5]) key_buf_b[recv_idx+5] <= s_axis_tdata[47:40];
                            if (s_axis_tkeep[6]) key_buf_b[recv_idx+6] <= s_axis_tdata[55:48];
                            if (s_axis_tkeep[7]) key_buf_b[recv_idx+7] <= s_axis_tdata[63:56];
                        end else begin
                            if (s_axis_tkeep[0]) key_buf_a[recv_idx+0] <= s_axis_tdata[ 7: 0];
                            if (s_axis_tkeep[1]) key_buf_a[recv_idx+1] <= s_axis_tdata[15: 8];
                            if (s_axis_tkeep[2]) key_buf_a[recv_idx+2] <= s_axis_tdata[23:16];
                            if (s_axis_tkeep[3]) key_buf_a[recv_idx+3] <= s_axis_tdata[31:24];
                            if (s_axis_tkeep[4]) key_buf_a[recv_idx+4] <= s_axis_tdata[39:32];
                            if (s_axis_tkeep[5]) key_buf_a[recv_idx+5] <= s_axis_tdata[47:40];
                            if (s_axis_tkeep[6]) key_buf_a[recv_idx+6] <= s_axis_tdata[55:48];
                            if (s_axis_tkeep[7]) key_buf_a[recv_idx+7] <= s_axis_tdata[63:56];
                        end

                        // Inline prefix comparison (8-way combinational)
                        current_shared_len <= new_shared_len;
                        mismatch_found     <= new_mismatch;

                        recv_idx <= recv_idx + {12'd0, in_bytes};

                        if (recv_idx + {12'd0, in_bytes} >= current_key_len) begin
                            // P13: Pre-compute unshared_len (saves 1 cycle in varint state)
                            current_unshared_len <= current_key_len - new_shared_len;
                            state <= ST_WRITE_VARINTS;
                        end
                    end
                end

                // =============================================================
                // P13: Combined varint emission — all 3 varints in 1 cycle
                // Inputs: current_shared_len, current_unshared_len, current_value_len
                // (all registered, stable on entry to this state)
                ST_WRITE_VARINTS: begin
                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data  <= p13_data_lo;
                        emit_keep  <= p13_keep_lo;
                        emit_valid <= 1'b1;
                        if (p13_ovf) begin
                            // Rare: total > 8 bytes; emit first 8, then remainder
                            block_write_index <= block_write_index + 32'd8;
                            state <= ST_WRITE_VARINTS_OVF;
                        end else begin
                            // Common: all varints fit in 1 word
                            block_write_index <= block_write_index + {28'd0, p13_total};
                            block_copy_idx <= 16'd0;
                            if (current_unshared_len == 16'd0) begin
                                value_rem <= {16'd0, current_value_len};
                                state <= ST_STREAM_VALUE;
                            end else begin
                                state <= ST_WRITE_KEY;
                            end
                        end
                    end
                end

                // =============================================================
                // P13: Overflow — emit remaining varint bytes (total was > 8)
                ST_WRITE_VARINTS_OVF: begin
                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data  <= p13_data_hi;
                        emit_keep  <= p13_keep_hi;
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + {28'd0, p13_hi_len};
                        block_copy_idx <= 16'd0;
                        if (current_unshared_len == 16'd0) begin
                            value_rem <= {16'd0, current_value_len};
                            state <= ST_STREAM_VALUE;
                        end else begin
                            state <= ST_WRITE_KEY;
                        end
                    end
                end

                // P13: ST_WRITE_VALUE_LEN kept as dead state for encoding safety
                ST_WRITE_VALUE_LEN: begin
                    busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                end

                // =============================================================
                // P7: Emit 8 unshared key bytes/cycle
                ST_WRITE_KEY: begin
                    if (block_copy_idx >= current_unshared_len) begin
                        value_rem <= {16'd0, current_value_len};
                        state     <= ST_STREAM_VALUE;
                    end else if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data <= {key_e7, key_e6, key_e5, key_e4,
                                      key_e3, key_e2, key_e1, key_e0};
                        case (key_emit_bytes)
                            4'd1: emit_keep <= 8'b0000_0001;
                            4'd2: emit_keep <= 8'b0000_0011;
                            4'd3: emit_keep <= 8'b0000_0111;
                            4'd4: emit_keep <= 8'b0000_1111;
                            4'd5: emit_keep <= 8'b0001_1111;
                            4'd6: emit_keep <= 8'b0011_1111;
                            4'd7: emit_keep <= 8'b0111_1111;
                            default: emit_keep <= 8'b1111_1111;
                        endcase
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + {28'd0, key_emit_bytes};
                        block_copy_idx    <= block_copy_idx + {12'd0, key_emit_bytes};
                    end
                end

                // =============================================================
                // P7: 64-bit value pass-through
                ST_STREAM_VALUE: begin
                    if (value_rem == 32'd0) begin
                        encoded_entry_count      <= encoded_entry_count + 32'd1;
                        shared_key_bytes_total   <= shared_key_bytes_total + {16'd0, current_shared_len};
                        unshared_key_bytes_total <= unshared_key_bytes_total + {16'd0, current_unshared_len};
                        value_bytes_total        <= value_bytes_total + {16'd0, current_value_len};
                        last_key_len             <= current_key_len;
                        last_value_len           <= current_value_len;
                        last_shared_bytes        <= current_shared_len;
                        last_non_shared_bytes    <= current_unshared_len;
                        prev_key_len             <= current_key_len;
                        prev_buf_sel             <= ~prev_buf_sel;
                        entries_since_restart    <= entries_since_restart + 32'd1;
                        state                    <= ST_WAIT_RECORD;
                    end else if (input_accept) begin
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                        end else begin
                            emit_data  <= s_axis_tdata;
                            emit_keep  <= s_axis_tkeep;
                            emit_valid <= 1'b1;
                            block_write_index <= block_write_index + {28'd0, in_bytes};
                            value_rem         <= value_rem - {28'd0, in_bytes};
                        end
                    end
                end

                // =============================================================
                // P7: 2 restart offsets (8 bytes) per cycle
                ST_APPEND_RESTARTS: begin
                    if (restart_emit_idx >= restart_count) begin
                        state <= ST_APPEND_RST_CNT;
                    end else if (can_emit) begin
                        if (restart_emit_idx + 32'd1 >= restart_count) begin
                            // Only 1 restart left — emit in lower 4 bytes
                            emit_data  <= {32'd0, restart_offset_mem[restart_emit_idx]};
                            emit_keep  <= 8'b0000_1111;
                            emit_valid <= 1'b1;
                            block_write_index <= block_write_index + 32'd4;
                            restart_emit_idx  <= restart_emit_idx + 32'd1;
                        end else begin
                            // 2 restarts — emit both in 8 bytes
                            emit_data  <= {restart_offset_mem[restart_emit_idx + 32'd1],
                                           restart_offset_mem[restart_emit_idx]};
                            emit_keep  <= 8'b1111_1111;
                            emit_valid <= 1'b1;
                            block_write_index <= block_write_index + 32'd8;
                            restart_emit_idx  <= restart_emit_idx + 32'd2;
                        end
                    end
                end

                // =============================================================
                // P7: restart count in 1 cycle with tlast (4 bytes in 64-bit word)
                ST_APPEND_RST_CNT: begin
                    if (can_emit) begin
                        emit_data  <= {32'd0, restart_count};
                        emit_keep  <= 8'b0000_1111;
                        emit_valid <= 1'b1;
                        emit_last  <= 1'b1;
                        output_block_bytes <= block_write_index + 32'd4;
                        state <= ST_FINISH;
                    end
                end

                // =============================================================
                ST_FINISH: begin
                    if (!emit_valid) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        emit_last <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    busy  <= 1'b0;
                    error <= 1'b1;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // ── Profiling counters (synthesis: optimized out if unconnected) ──
    `ifdef SIMULATION
    reg [31:0] prof_wait_rec, prof_recv_key, prof_write_varints, prof_write_varints_ovf;
    reg [31:0] prof_write_key, prof_stream_val;
    reg [31:0] prof_append_rst, prof_append_cnt, prof_finish;
    always @(posedge clk) begin
        if (!rstn || clear || (start && !busy)) begin
            prof_wait_rec <= 0; prof_recv_key <= 0;
            prof_write_varints <= 0; prof_write_varints_ovf <= 0;
            prof_write_key <= 0;
            prof_stream_val <= 0; prof_append_rst <= 0;
            prof_append_cnt <= 0; prof_finish <= 0;
        end else if (busy) begin
            case (state)
                ST_WAIT_RECORD:      prof_wait_rec  <= prof_wait_rec + 1;
                ST_RECV_KEY:         prof_recv_key  <= prof_recv_key + 1;
                ST_WRITE_VARINTS:    prof_write_varints <= prof_write_varints + 1;
                ST_WRITE_VARINTS_OVF: prof_write_varints_ovf <= prof_write_varints_ovf + 1;
                ST_WRITE_KEY:        prof_write_key <= prof_write_key + 1;
                ST_STREAM_VALUE:     prof_stream_val<= prof_stream_val + 1;
                ST_APPEND_RESTARTS:  prof_append_rst<= prof_append_rst + 1;
                ST_APPEND_RST_CNT:   prof_append_cnt<= prof_append_cnt + 1;
                ST_FINISH:           prof_finish    <= prof_finish + 1;
                default: ;
            endcase
        end
    end
    `endif

endmodule
