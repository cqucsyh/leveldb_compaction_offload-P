`timescale 1ns / 1ps

// OPT-C1a: Registered comparator pipeline — breaks mem→compare→state critical path.
// OPT-C1b: Single-cycle valid (replaces C1a toggle); works because CMP_CHUNK==MAX_USER_KEY_BYTES.
// OPT-2A/2B: Multi-byte chunk comparator (CMP_CHUNK=4 bytes/cycle).
// OPT-1C: Incremental prev_key copy in ST_COPY_PREV_KEY + ST_EMIT_PAYLOAD.
module cmpct_merger #(
    parameter integer MAX_USER_KEY_BYTES = 256,
    parameter integer MAX_KEY_BYTES      = 264,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer MAX_RECORD_BYTES   = 2048
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        seed_prev_user_key_valid,
    input  wire [15:0] seed_prev_user_key_len,
    input  wire [(MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,

    input  wire        source0_done,
    input  wire        s0_record_valid,
    output wire        s0_record_ready,
    input  wire [15:0] s0_record_key_len,
    input  wire [15:0] s0_record_value_len,
    // P6: 64-bit input from decoder (8 bytes/cycle)
    input  wire [63:0] s0_axis_tdata,
    input  wire [7:0]  s0_axis_tkeep,
    input  wire        s0_axis_tlast,
    input  wire        s0_axis_tvalid,
    output wire        s0_axis_tready,

    input  wire        source1_done,
    input  wire        s1_record_valid,
    output wire        s1_record_ready,
    input  wire [15:0] s1_record_key_len,
    input  wire [15:0] s1_record_value_len,
    // P6: 64-bit input from decoder (8 bytes/cycle)
    input  wire [63:0] s1_axis_tdata,
    input  wire [7:0]  s1_axis_tkeep,
    input  wire        s1_axis_tlast,
    input  wire        s1_axis_tvalid,
    output wire        s1_axis_tready,

    output wire        m_record_valid,
    input  wire        m_record_ready,
    output wire [15:0] m_record_key_len,
    output wire [15:0] m_record_value_len,
    // P6: 64-bit output data path (8 bytes/cycle)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,

    output reg         busy,
    output reg         done,
    output reg         error,
    output wire [31:0] output_byte_count,
    output reg  [31:0] decoded_record_count,
    output reg  [31:0] merged_record_count,
    output reg  [31:0] dropped_superseded_count,
    output reg  [31:0] value_record_count,
    output reg  [31:0] delete_record_count,
    output reg  [31:0] user_key_bytes_total,
    output reg  [31:0] value_bytes_total,
    output reg  [15:0] last_user_key_len,
    output reg  [55:0] last_sequence,
    output reg  [7:0]  last_value_type,
    output reg         last_record_keep,
    output wire        final_prev_user_key_valid,
    output wire [15:0] final_prev_user_key_len,
    output wire [(MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key
);

    localparam [3:0] ST_IDLE           = 4'd0;
    localparam [3:0] ST_FETCH          = 4'd1;
    localparam [3:0] ST_WAIT0_HEADER   = 4'd2;
    localparam [3:0] ST_CAPTURE0       = 4'd3;
    localparam [3:0] ST_WAIT1_HEADER   = 4'd4;
    localparam [3:0] ST_CAPTURE1       = 4'd5;
    localparam [3:0] ST_COMPARE_INPUTS = 4'd6;
    localparam [3:0] ST_CHECK_KEEP     = 4'd7;
    localparam [3:0] ST_FINALIZE       = 4'd8;
    localparam [3:0] ST_EMIT_HEADER    = 4'd9;
    localparam [3:0] ST_EMIT_PAYLOAD   = 4'd10;
    localparam [3:0] ST_COPY_PREV_KEY  = 4'd11;
    localparam [3:0] ST_STREAM_VALUE  = 4'd12; // OPT-A2b: cut-through value pass
    localparam [3:0] ST_DRAIN_VALUE   = 4'd13; // OPT-A2b: drain value for drop path

    reg [3:0] state;

    reg       source_done_seen0;
    reg       source_done_seen1;
    reg       buf_valid0;
    reg       buf_valid1;
    reg       have_prev_user_key;
    reg       selected_source;
    reg       keep_selected;

    reg [15:0] prev_user_key_len;
    reg [15:0] compare_index;
    reg [31:0] emit_index;
    reg [31:0] capture_index;

    // OPT-T2: Registered selected dimensions (set at ST_FINALIZE, stable during emit)
    reg [15:0] sel_user_key_len_r;
    reg [15:0] sel_key_len_r;
    reg [15:0] sel_value_len_r;

    reg [15:0] key_len0;
    reg [15:0] value_len0;
    reg [15:0] user_key_len0;
    reg [31:0] payload_total0;
    reg [63:0] tag0;

    reg [15:0] key_len1;
    reg [15:0] value_len1;
    reg [15:0] user_key_len1;
    reg [31:0] payload_total1;
    reg [63:0] tag1;

    reg [7:0] prev_user_key_mem [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] user_key_mem0 [0:MAX_USER_KEY_BYTES-1];
    reg [7:0] user_key_mem1 [0:MAX_USER_KEY_BYTES-1];
    // OPT-MF2: record_mem eliminated; emit uses user_key_mem + tag register

    integer idx;
    integer cmp_k;

    assign s0_record_ready = busy && !error && (state == ST_WAIT0_HEADER);
    // OPT-CAP4: s0_axis_tready — stream_value gated by m_axis_tready (direct pass-through)
    assign s0_axis_tready  = busy && !error && (
        (state == ST_CAPTURE0) ||
        ((state == ST_STREAM_VALUE) && (selected_source == 1'b0) && m_axis_tready) ||
        ((state == ST_DRAIN_VALUE)  && (selected_source == 1'b0))
    );
    assign s1_record_ready = busy && !error && (state == ST_WAIT1_HEADER);
    // OPT-CAP4: s1_axis_tready — stream_value gated by m_axis_tready (direct pass-through)
    assign s1_axis_tready  = busy && !error && (
        (state == ST_CAPTURE1) ||
        ((state == ST_STREAM_VALUE) && (selected_source == 1'b1) && m_axis_tready) ||
        ((state == ST_DRAIN_VALUE)  && (selected_source == 1'b1))
    );

    wire input_accept0   = s0_record_valid && s0_record_ready;
    wire payload_accept0 = s0_axis_tvalid && s0_axis_tready && s0_axis_tkeep[0];
    wire input_accept1   = s1_record_valid && s1_record_ready;
    wire payload_accept1 = s1_axis_tvalid && s1_axis_tready && s1_axis_tkeep[0];

    // P6: valid byte count per beat (popcount of 8-bit tkeep)
    wire [3:0] s0_beat_bytes = {3'b0, s0_axis_tkeep[0]} + {3'b0, s0_axis_tkeep[1]}
                              + {3'b0, s0_axis_tkeep[2]} + {3'b0, s0_axis_tkeep[3]}
                              + {3'b0, s0_axis_tkeep[4]} + {3'b0, s0_axis_tkeep[5]}
                              + {3'b0, s0_axis_tkeep[6]} + {3'b0, s0_axis_tkeep[7]};
    wire [3:0] s1_beat_bytes = {3'b0, s1_axis_tkeep[0]} + {3'b0, s1_axis_tkeep[1]}
                              + {3'b0, s1_axis_tkeep[2]} + {3'b0, s1_axis_tkeep[3]}
                              + {3'b0, s1_axis_tkeep[4]} + {3'b0, s1_axis_tkeep[5]}
                              + {3'b0, s1_axis_tkeep[6]} + {3'b0, s1_axis_tkeep[7]};
    wire [3:0] selected_beat_bytes_w = selected_source ? s1_beat_bytes : s0_beat_bytes;

    wire [15:0] selected_key_len_w      = selected_source ? key_len1 : key_len0;
    wire [15:0] selected_value_len_w    = selected_source ? value_len1 : value_len0;
    wire [15:0] selected_user_key_len_w = selected_source ? user_key_len1 : user_key_len0;
    wire [31:0] selected_payload_total_w = selected_source ? payload_total1 : payload_total0;
    wire [63:0] selected_tag_w          = selected_source ? tag1 : tag0;
    wire [7:0]  selected_compare_byte_w = selected_source ? user_key_mem1[compare_index] : user_key_mem0[compare_index];
    // ── P6: 8-byte key emit from user_key_mem + tag ──
    // OPT-T2: Use registered versions in emit phases (breaks MUX chain)
    wire [31:0] emit_remaining_key = {16'd0, sel_key_len_r} - emit_index;
    wire [3:0]  emit_word_bytes = (emit_remaining_key >= 32'd8) ? 4'd8 : emit_remaining_key[3:0];

    // P6: Tag byte access for 8-byte emit
    integer eb;
    reg [7:0] emit_tag_byte [0:7];
    always @(*) begin
        for (eb = 0; eb < 8; eb = eb + 1) begin
            if (emit_index + eb[31:0] >= {16'd0, sel_user_key_len_r}) begin
                case (emit_index + eb[31:0] - {16'd0, sel_user_key_len_r})
                    32'd0: emit_tag_byte[eb] = selected_source ? tag1[ 7: 0] : tag0[ 7: 0];
                    32'd1: emit_tag_byte[eb] = selected_source ? tag1[15: 8] : tag0[15: 8];
                    32'd2: emit_tag_byte[eb] = selected_source ? tag1[23:16] : tag0[23:16];
                    32'd3: emit_tag_byte[eb] = selected_source ? tag1[31:24] : tag0[31:24];
                    32'd4: emit_tag_byte[eb] = selected_source ? tag1[39:32] : tag0[39:32];
                    32'd5: emit_tag_byte[eb] = selected_source ? tag1[47:40] : tag0[47:40];
                    32'd6: emit_tag_byte[eb] = selected_source ? tag1[55:48] : tag0[55:48];
                    default: emit_tag_byte[eb] = selected_source ? tag1[63:56] : tag0[63:56];
                endcase
            end else begin
                emit_tag_byte[eb] = 8'd0;
            end
        end
    end

    // P6: Final per-byte selection: user_key or tag (8 bytes)
    wire [7:0] emit_b0 = (emit_index + 32'd0 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0]]
                                             : user_key_mem0[emit_index[7:0]])
                          : emit_tag_byte[0];
    wire [7:0] emit_b1 = (emit_index + 32'd1 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd1]
                                             : user_key_mem0[emit_index[7:0] + 8'd1])
                          : emit_tag_byte[1];
    wire [7:0] emit_b2 = (emit_index + 32'd2 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd2]
                                             : user_key_mem0[emit_index[7:0] + 8'd2])
                          : emit_tag_byte[2];
    wire [7:0] emit_b3 = (emit_index + 32'd3 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd3]
                                             : user_key_mem0[emit_index[7:0] + 8'd3])
                          : emit_tag_byte[3];
    wire [7:0] emit_b4 = (emit_index + 32'd4 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd4]
                                             : user_key_mem0[emit_index[7:0] + 8'd4])
                          : emit_tag_byte[4];
    wire [7:0] emit_b5 = (emit_index + 32'd5 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd5]
                                             : user_key_mem0[emit_index[7:0] + 8'd5])
                          : emit_tag_byte[5];
    wire [7:0] emit_b6 = (emit_index + 32'd6 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd6]
                                             : user_key_mem0[emit_index[7:0] + 8'd6])
                          : emit_tag_byte[6];
    wire [7:0] emit_b7 = (emit_index + 32'd7 < {16'd0, sel_user_key_len_r})
                          ? (selected_source ? user_key_mem1[emit_index[7:0] + 8'd7]
                                             : user_key_mem0[emit_index[7:0] + 8'd7])
                          : emit_tag_byte[7];

    wire [63:0] emit_word_w = {emit_b7, emit_b6, emit_b5, emit_b4,
                               emit_b3, emit_b2, emit_b1, emit_b0};
    wire [7:0]  emit_keep_w = (emit_word_bytes >= 4'd8) ? 8'b11111111 :
                              (emit_word_bytes == 4'd7) ? 8'b01111111 :
                              (emit_word_bytes == 4'd6) ? 8'b00111111 :
                              (emit_word_bytes == 4'd5) ? 8'b00011111 :
                              (emit_word_bytes == 4'd4) ? 8'b00001111 :
                              (emit_word_bytes == 4'd3) ? 8'b00000111 :
                              (emit_word_bytes == 4'd2) ? 8'b00000011 : 8'b00000001;

    // P6: 64-bit value data from selected decoder for direct pass-through
    wire [63:0] selected_stream_data_w  = selected_source ? s1_axis_tdata : s0_axis_tdata;
    wire [7:0]  selected_stream_keep_w  = selected_source ? s1_axis_tkeep : s0_axis_tkeep;
    wire        selected_stream_valid_w = selected_source ? s1_axis_tvalid : s0_axis_tvalid;

    assign m_record_valid     = busy && !error && (state == ST_EMIT_HEADER);
    assign m_record_key_len   = sel_key_len_r;
    assign m_record_value_len = sel_value_len_r;
    // P6: m_axis_tdata from 8-byte key emit or direct 64-bit value pass-through
    assign m_axis_tdata       = (state == ST_STREAM_VALUE) ? selected_stream_data_w : emit_word_w;
    assign m_axis_tkeep       = (state == ST_STREAM_VALUE) ? selected_stream_keep_w : emit_keep_w;
    assign m_axis_tvalid      = busy && !error && (
        (state == ST_EMIT_PAYLOAD) ||
        ((state == ST_STREAM_VALUE) && selected_stream_valid_w)
    );
    // P6: tlast on last key word (if no value) or last value beat
    assign m_axis_tlast       = ((state == ST_EMIT_PAYLOAD) && (sel_value_len_r == 16'd0) &&
                                 (emit_index + {28'd0, emit_word_bytes} >= {16'd0, sel_key_len_r})) ||
                                ((state == ST_STREAM_VALUE) && selected_stream_valid_w &&
                                 (emit_index + {28'd0, selected_beat_bytes_w} >= {16'd0, sel_value_len_r}));

    assign final_prev_user_key_valid = have_prev_user_key;
    assign final_prev_user_key_len   = prev_user_key_len;

    genvar prev_key_idx;
    generate
        for (prev_key_idx = 0; prev_key_idx < MAX_USER_KEY_BYTES; prev_key_idx = prev_key_idx + 1) begin : gen_final_prev_key
            assign final_prev_user_key[(prev_key_idx*8) +: 8] = prev_user_key_mem[prev_key_idx];
        end
    endgenerate

    // ── OPT-2A/2B: Multi-byte chunk comparator (CMP_CHUNK bytes/cycle) ──
    // OPT-P4b: Full-width single-chunk compare — eliminates multi-chunk iteration.
    // With CMP_CHUNK == MAX_USER_KEY_BYTES, compare/check always finishes in 1 chunk (3 cycles).
    localparam integer CMP_CHUNK  = MAX_USER_KEY_BYTES;
    localparam integer COPY_CHUNK = 4;  // prev_key copy width (kept at 4 to avoid MUX→write timing issue)

    // -- ST_COMPARE_INPUTS: lexicographic compare key0 vs key1 --
    wire [15:0] cmp_min_len_w = (user_key_len0 < user_key_len1)
                                ? user_key_len0 : user_key_len1;
    wire [CMP_CHUNK-1:0] cmp01_valid, cmp01_eq, cmp01_lt;
    genvar cg;
    generate for (cg = 0; cg < CMP_CHUNK; cg = cg + 1) begin : g_cmp01
        wire [15:0] pos_w = compare_index + cg;
        assign cmp01_valid[cg] = (pos_w < user_key_len0) && (pos_w < user_key_len1);
        assign cmp01_eq[cg]    = (user_key_mem0[pos_w[7:0]] == user_key_mem1[pos_w[7:0]]);
        assign cmp01_lt[cg]    = (user_key_mem0[pos_w[7:0]] <  user_key_mem1[pos_w[7:0]]);
    end endgenerate

    // Priority encoder: first differing byte in chunk (lowest index wins)
    reg  chunk_found, chunk_lt;
    always @(*) begin
        chunk_found = 1'b0;
        chunk_lt    = 1'b0;
        for (cmp_k = CMP_CHUNK - 1; cmp_k >= 0; cmp_k = cmp_k - 1) begin
            if (cmp01_valid[cmp_k] && !cmp01_eq[cmp_k]) begin
                chunk_found = 1'b1;
                chunk_lt    = cmp01_lt[cmp_k];
            end
        end
    end
    wire cmp01_all_done = (compare_index + CMP_CHUNK >= cmp_min_len_w);

    // -- ST_CHECK_KEEP: equality compare selected key vs prev_user_key --
    wire [CMP_CHUNK-1:0] chk_valid, chk_eq;
    genvar kg;
    generate for (kg = 0; kg < CMP_CHUNK; kg = kg + 1) begin : g_chk
        wire [15:0] kpos_w = compare_index + kg;
        assign chk_valid[kg] = (kpos_w < selected_user_key_len_w);
        assign chk_eq[kg]    = ((selected_source ? user_key_mem1[kpos_w[7:0]]
                                                  : user_key_mem0[kpos_w[7:0]])
                                 == prev_user_key_mem[kpos_w[7:0]]);
    end endgenerate
    wire chk_any_diff = |(chk_valid & ~chk_eq);
    wire chk_all_done = (compare_index + CMP_CHUNK >= selected_user_key_len_w);

    // ── OPT-C1a/C1b: Pipeline registers for comparator results ──
    // OPT-C1b: cmp_pipe_valid is now combinational (not a toggle register).
    // With CMP_CHUNK == MAX_USER_KEY_BYTES, comparison always finishes in 1
    // iteration, so we only need "state stable for 1 cycle" → registered
    // outputs are valid.  This saves 1 cycle per compare/check state entry.
    reg        chunk_found_r, chunk_lt_r, cmp01_all_done_r;
    reg        chk_any_diff_r, chk_all_done_r;
    reg [3:0]  prev_state;
    wire       cmp_pipe_valid = (prev_state == state) &&
                                (state == ST_COMPARE_INPUTS || state == ST_CHECK_KEEP);

    always @(posedge clk) begin
        if (!rstn || clear) begin
            chunk_found_r   <= 1'b0;
            chunk_lt_r      <= 1'b0;
            cmp01_all_done_r <= 1'b0;
            chk_any_diff_r  <= 1'b0;
            chk_all_done_r  <= 1'b0;
            prev_state      <= ST_IDLE;
        end else begin
            prev_state       <= state;
            chunk_found_r    <= chunk_found;
            chunk_lt_r       <= chunk_lt;
            cmp01_all_done_r <= cmp01_all_done;
            chk_any_diff_r   <= chk_any_diff;
            chk_all_done_r   <= chk_all_done;
        end
    end

    // ── Main FSM ──
    always @(posedge clk) begin
        if (!rstn) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            decoded_record_count     <= 32'd0;
            merged_record_count      <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count       <= 32'd0;
            delete_record_count      <= 32'd0;
            user_key_bytes_total     <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_user_key_len        <= 16'd0;
            last_sequence            <= 56'd0;
            last_value_type          <= 8'd0;
            last_record_keep         <= 1'b0;
            state                    <= ST_IDLE;
            source_done_seen0        <= 1'b0;
            source_done_seen1        <= 1'b0;
            buf_valid0               <= 1'b0;
            buf_valid1               <= 1'b0;
            have_prev_user_key       <= 1'b0;
            selected_source          <= 1'b0;
            keep_selected            <= 1'b0;
            prev_user_key_len        <= 16'd0;
            compare_index            <= 16'd0;
            emit_index               <= 32'd0;
            capture_index            <= 32'd0;
            key_len0                 <= 16'd0;
            value_len0               <= 16'd0;
            user_key_len0            <= 16'd0;
            payload_total0           <= 32'd0;
            tag0                     <= 64'd0;
            key_len1                 <= 16'd0;
            value_len1               <= 16'd0;
            user_key_len1            <= 16'd0;
            payload_total1           <= 32'd0;
            tag1                     <= 64'd0;
            sel_user_key_len_r       <= 16'd0;
            sel_key_len_r            <= 16'd0;
            sel_value_len_r          <= 16'd0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                prev_user_key_mem[idx] <= 8'd0;
                user_key_mem0[idx]     <= 8'd0;
                user_key_mem1[idx]     <= 8'd0;
            end
        end else if (clear) begin
            busy                     <= 1'b0;
            done                     <= 1'b0;
            error                    <= 1'b0;
            decoded_record_count     <= 32'd0;
            merged_record_count      <= 32'd0;
            dropped_superseded_count <= 32'd0;
            value_record_count       <= 32'd0;
            delete_record_count      <= 32'd0;
            user_key_bytes_total     <= 32'd0;
            value_bytes_total        <= 32'd0;
            last_user_key_len        <= 16'd0;
            last_sequence            <= 56'd0;
            last_value_type          <= 8'd0;
            last_record_keep         <= 1'b0;
            state                    <= ST_IDLE;
            source_done_seen0        <= 1'b0;
            source_done_seen1        <= 1'b0;
            buf_valid0               <= 1'b0;
            buf_valid1               <= 1'b0;
            have_prev_user_key       <= 1'b0;
            selected_source          <= 1'b0;
            keep_selected            <= 1'b0;
            prev_user_key_len        <= 16'd0;
            compare_index            <= 16'd0;
            emit_index               <= 32'd0;
            capture_index            <= 32'd0;
            key_len0                 <= 16'd0;
            value_len0               <= 16'd0;
            user_key_len0            <= 16'd0;
            payload_total0           <= 32'd0;
            tag0                     <= 64'd0;
            key_len1                 <= 16'd0;
            value_len1               <= 16'd0;
            user_key_len1            <= 16'd0;
            payload_total1           <= 32'd0;
            tag1                     <= 64'd0;
            for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                prev_user_key_mem[idx] <= 8'd0;
                user_key_mem0[idx]     <= 8'd0;
                user_key_mem1[idx]     <= 8'd0;
            end
        end else begin
            done <= 1'b0;

            if (source0_done) source_done_seen0 <= 1'b1;
            if (source1_done) source_done_seen1 <= 1'b1;

            if (start && !busy) begin
                busy                     <= 1'b1;
                done                     <= 1'b0;
                error                    <= 1'b0;
                decoded_record_count     <= 32'd0;
                merged_record_count      <= 32'd0;
                dropped_superseded_count <= 32'd0;
                value_record_count       <= 32'd0;
                delete_record_count      <= 32'd0;
                user_key_bytes_total     <= 32'd0;
                value_bytes_total        <= 32'd0;
                last_user_key_len        <= 16'd0;
                last_sequence            <= 56'd0;
                last_value_type          <= 8'd0;
                last_record_keep         <= 1'b0;
                state                    <= ST_FETCH;
                source_done_seen0        <= 1'b0;
                source_done_seen1        <= 1'b0;
                buf_valid0               <= 1'b0;
                buf_valid1               <= 1'b0;
                have_prev_user_key       <= seed_prev_user_key_valid;
                selected_source          <= 1'b0;
                keep_selected            <= 1'b0;
                prev_user_key_len        <= seed_prev_user_key_valid ? seed_prev_user_key_len : 16'd0;
                compare_index            <= 16'd0;
                emit_index               <= 32'd0;
                capture_index            <= 32'd0;
                key_len0                 <= 16'd0;
                value_len0               <= 16'd0;
                user_key_len0            <= 16'd0;
                payload_total0           <= 32'd0;
                tag0                     <= 64'd0;
                key_len1                 <= 16'd0;
                value_len1               <= 16'd0;
                user_key_len1            <= 16'd0;
                payload_total1           <= 32'd0;
                tag1                     <= 64'd0;
                for (idx = 0; idx < MAX_USER_KEY_BYTES; idx = idx + 1) begin
                    if (seed_prev_user_key_valid && (idx < seed_prev_user_key_len)) begin
                        prev_user_key_mem[idx] <= seed_prev_user_key[(idx*8) +: 8];
                    end else begin
                        prev_user_key_mem[idx] <= 8'd0;
                    end
                end
            end else if (busy && !error) begin
                case (state)
                    ST_FETCH: begin
                        if (!buf_valid0 && !source_done_seen0) begin
                            state <= ST_WAIT0_HEADER;
                        end else if (!buf_valid1 && !source_done_seen1) begin
                            state <= ST_WAIT1_HEADER;
                        end else if (buf_valid0 || buf_valid1) begin
                            compare_index <= 16'd0;
                            state <= ST_COMPARE_INPUTS;
                        end else begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            error <= 1'b0;
                            state <= ST_IDLE;
                        end
                    end

                    ST_WAIT0_HEADER: begin
                        if (input_accept0) begin
                            if ((s0_record_key_len < 16'd8) ||
                                (s0_record_key_len > MAX_KEY_BYTES[15:0]) ||
                                (s0_record_value_len > MAX_VALUE_BYTES[15:0]) ||
                                ({16'd0, s0_record_key_len} + {16'd0, s0_record_value_len} > MAX_RECORD_BYTES[31:0]) ||
                                (s0_record_key_len - 16'd8 > MAX_USER_KEY_BYTES[15:0])) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                key_len0       <= s0_record_key_len;
                                value_len0     <= s0_record_value_len;
                                user_key_len0  <= s0_record_key_len - 16'd8;
                                payload_total0 <= {16'd0, s0_record_key_len} + {16'd0, s0_record_value_len};
                                tag0           <= 64'd0;
                                capture_index  <= 32'd0;
                                state          <= ST_CAPTURE0;
                            end
                        end else if (source_done_seen0) begin
                            state <= ST_FETCH;
                        end
                    end

                    // P6: capture up to 8 key bytes per cycle
                    ST_CAPTURE0: begin
                        if (payload_accept0) begin
                            if (capture_index + {28'd0, s0_beat_bytes} > {16'd0, key_len0}) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                // Write each valid byte to user_key_mem0 or tag0
                                for (cmp_k = 0; cmp_k < 8; cmp_k = cmp_k + 1) begin
                                    if (s0_axis_tkeep[cmp_k]) begin
                                        if (capture_index + cmp_k[31:0] < {16'd0, user_key_len0})
                                            user_key_mem0[capture_index[15:0] + cmp_k[15:0]] <= s0_axis_tdata[cmp_k*8 +: 8];
                                        else begin
                                            case (capture_index[3:0] + cmp_k[3:0] - user_key_len0[3:0])
                                                4'd0: tag0[7:0]   <= s0_axis_tdata[cmp_k*8 +: 8];
                                                4'd1: tag0[15:8]  <= s0_axis_tdata[cmp_k*8 +: 8];
                                                4'd2: tag0[23:16] <= s0_axis_tdata[cmp_k*8 +: 8];
                                                4'd3: tag0[31:24] <= s0_axis_tdata[cmp_k*8 +: 8];
                                                4'd4: tag0[39:32] <= s0_axis_tdata[cmp_k*8 +: 8];
                                                4'd5: tag0[47:40] <= s0_axis_tdata[cmp_k*8 +: 8];
                                                4'd6: tag0[55:48] <= s0_axis_tdata[cmp_k*8 +: 8];
                                                default: tag0[63:56] <= s0_axis_tdata[cmp_k*8 +: 8];
                                            endcase
                                        end
                                    end
                                end

                                if (capture_index + {28'd0, s0_beat_bytes} == {16'd0, key_len0}) begin
                                    // Key fully captured; value bytes stay pending
                                    if (value_len0 == 16'd0 && !s0_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else if (value_len0 != 16'd0 && s0_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        buf_valid0 <= 1'b1;
                                        // OPT-MF2: skip ST_FETCH — route directly
                                        if (buf_valid1 || source_done_seen1) begin
                                            compare_index <= 16'd0;
                                            state <= ST_COMPARE_INPUTS;
                                        end else begin
                                            state <= ST_WAIT1_HEADER;
                                        end
                                    end
                                end else if (s0_axis_tlast) begin
                                    busy  <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    capture_index <= capture_index + {28'd0, s0_beat_bytes};
                                end
                            end
                        end
                    end

                    ST_WAIT1_HEADER: begin
                        if (input_accept1) begin
                            if ((s1_record_key_len < 16'd8) ||
                                (s1_record_key_len > MAX_KEY_BYTES[15:0]) ||
                                (s1_record_value_len > MAX_VALUE_BYTES[15:0]) ||
                                ({16'd0, s1_record_key_len} + {16'd0, s1_record_value_len} > MAX_RECORD_BYTES[31:0]) ||
                                (s1_record_key_len - 16'd8 > MAX_USER_KEY_BYTES[15:0])) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                key_len1       <= s1_record_key_len;
                                value_len1     <= s1_record_value_len;
                                user_key_len1  <= s1_record_key_len - 16'd8;
                                payload_total1 <= {16'd0, s1_record_key_len} + {16'd0, s1_record_value_len};
                                tag1           <= 64'd0;
                                capture_index  <= 32'd0;
                                state          <= ST_CAPTURE1;
                            end
                        end else if (source_done_seen1) begin
                            state <= ST_FETCH;
                        end
                    end

                    // P6: capture up to 8 key bytes per cycle
                    ST_CAPTURE1: begin
                        if (payload_accept1) begin
                            if (capture_index + {28'd0, s1_beat_bytes} > {16'd0, key_len1}) begin
                                busy  <= 1'b0;
                                error <= 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                // Write each valid byte to user_key_mem1 or tag1
                                for (cmp_k = 0; cmp_k < 8; cmp_k = cmp_k + 1) begin
                                    if (s1_axis_tkeep[cmp_k]) begin
                                        if (capture_index + cmp_k[31:0] < {16'd0, user_key_len1})
                                            user_key_mem1[capture_index[15:0] + cmp_k[15:0]] <= s1_axis_tdata[cmp_k*8 +: 8];
                                        else begin
                                            case (capture_index[3:0] + cmp_k[3:0] - user_key_len1[3:0])
                                                4'd0: tag1[7:0]   <= s1_axis_tdata[cmp_k*8 +: 8];
                                                4'd1: tag1[15:8]  <= s1_axis_tdata[cmp_k*8 +: 8];
                                                4'd2: tag1[23:16] <= s1_axis_tdata[cmp_k*8 +: 8];
                                                4'd3: tag1[31:24] <= s1_axis_tdata[cmp_k*8 +: 8];
                                                4'd4: tag1[39:32] <= s1_axis_tdata[cmp_k*8 +: 8];
                                                4'd5: tag1[47:40] <= s1_axis_tdata[cmp_k*8 +: 8];
                                                4'd6: tag1[55:48] <= s1_axis_tdata[cmp_k*8 +: 8];
                                                default: tag1[63:56] <= s1_axis_tdata[cmp_k*8 +: 8];
                                            endcase
                                        end
                                    end
                                end

                                if (capture_index + {28'd0, s1_beat_bytes} == {16'd0, key_len1}) begin
                                    if (value_len1 == 16'd0 && !s1_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else if (value_len1 != 16'd0 && s1_axis_tlast) begin
                                        busy  <= 1'b0;
                                        error <= 1'b1;
                                        state <= ST_IDLE;
                                    end else begin
                                        buf_valid1 <= 1'b1;
                                        // OPT-MF2: skip ST_FETCH — route directly
                                        if (buf_valid0 || source_done_seen0) begin
                                            compare_index <= 16'd0;
                                            state <= ST_COMPARE_INPUTS;
                                        end else begin
                                            state <= ST_WAIT0_HEADER;
                                        end
                                    end
                                end else if (s1_axis_tlast) begin
                                    busy  <= 1'b0;
                                    error <= 1'b1;
                                    state <= ST_IDLE;
                                end else begin
                                    capture_index <= capture_index + {28'd0, s1_beat_bytes};
                                end
                            end
                        end
                    end

                    // OPT-C1a: chunk comparison uses registered pipeline
                    ST_COMPARE_INPUTS: begin
                        if (!buf_valid0) begin
                            selected_source <= 1'b1;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end else if (!buf_valid1) begin
                            selected_source <= 1'b0;
                            compare_index   <= 16'd0;
                            state           <= ST_CHECK_KEEP;
                        end else if (cmp_pipe_valid) begin
                            if (chunk_found_r) begin
                                selected_source <= chunk_lt_r ? 1'b0 : 1'b1;
                                compare_index   <= 16'd0;
                                state           <= ST_CHECK_KEEP;
                            end else if (cmp01_all_done_r) begin
                                if (user_key_len0 != user_key_len1) begin
                                    selected_source <= (user_key_len0 < user_key_len1) ? 1'b0 : 1'b1;
                                end else begin
                                    selected_source <= (tag0 >= tag1) ? 1'b0 : 1'b1;
                                end
                                compare_index <= 16'd0;
                                state         <= ST_CHECK_KEEP;
                            end else begin
                                compare_index <= compare_index + CMP_CHUNK;
                            end
                        end
                    end

                    // OPT-C1a: duplicate check uses registered pipeline
                    ST_CHECK_KEEP: begin
                        if (!have_prev_user_key) begin
                            keep_selected <= 1'b1;
                            state         <= ST_FINALIZE;
                        end else if (selected_user_key_len_w != prev_user_key_len) begin
                            keep_selected <= 1'b1;
                            state         <= ST_FINALIZE;
                        end else if (cmp_pipe_valid) begin
                            if (chk_any_diff_r) begin
                                keep_selected <= 1'b1;
                                state         <= ST_FINALIZE;
                            end else if (chk_all_done_r) begin
                                keep_selected <= 1'b0;
                                state         <= ST_FINALIZE;
                            end else begin
                                compare_index <= compare_index + CMP_CHUNK;
                            end
                        end
                    end

                    ST_FINALIZE: begin
                        decoded_record_count <= decoded_record_count + 32'd1;
                        user_key_bytes_total <= user_key_bytes_total + {16'd0, selected_user_key_len_w};
                        value_bytes_total    <= value_bytes_total + {16'd0, selected_value_len_w};
                        last_user_key_len    <= selected_user_key_len_w;
                        last_sequence        <= selected_tag_w[63:8];
                        last_value_type      <= selected_tag_w[7:0];
                        last_record_keep     <= keep_selected;
                        // OPT-T2: Register selected dimensions for emit/copy/drain phases
                        sel_user_key_len_r   <= selected_user_key_len_w;
                        sel_key_len_r        <= selected_key_len_w;
                        sel_value_len_r      <= selected_value_len_w;
                        if (selected_tag_w[7:0] == 8'h00) begin
                            delete_record_count <= delete_record_count + 32'd1;
                        end else begin
                            value_record_count <= value_record_count + 32'd1;
                        end
                        if (keep_selected) begin
                            merged_record_count <= merged_record_count + 32'd1;
                        end else begin
                            dropped_superseded_count <= dropped_superseded_count + 32'd1;
                        end
                        have_prev_user_key <= 1'b1;
                        prev_user_key_len  <= selected_user_key_len_w;
                        if (keep_selected) begin
                            emit_index <= 32'd0;
                            state      <= ST_EMIT_HEADER;
                        end else begin
                            // Drop path
                            compare_index <= 16'd0;
                            // OPT-MF2: overlap prev_key copy with value drain
                            if (selected_value_len_w != 16'd0) begin
                                emit_index <= 32'd0;
                                state      <= ST_DRAIN_VALUE;
                            end else begin
                                state <= ST_COPY_PREV_KEY;
                            end
                        end
                    end

                    ST_EMIT_HEADER: begin
                        if (m_record_valid && m_record_ready) begin
                            emit_index <= 32'd0;
                            state      <= ST_EMIT_PAYLOAD;
                        end
                    end

                    // P6: emit 8 key bytes per cycle
                    ST_EMIT_PAYLOAD: begin
                        if (m_axis_tvalid && m_axis_tready) begin
                            // Copy up to 8 prev_user_key bytes during key emit
                            for (cmp_k = 0; cmp_k < 8; cmp_k = cmp_k + 1) begin
                                if (emit_index + cmp_k[31:0] < {16'd0, sel_user_key_len_r})
                                    prev_user_key_mem[emit_index[7:0] + cmp_k[7:0]] <= 
                                        (cmp_k == 0) ? emit_b0 :
                                        (cmp_k == 1) ? emit_b1 :
                                        (cmp_k == 2) ? emit_b2 :
                                        (cmp_k == 3) ? emit_b3 :
                                        (cmp_k == 4) ? emit_b4 :
                                        (cmp_k == 5) ? emit_b5 :
                                        (cmp_k == 6) ? emit_b6 : emit_b7;
                            end
                            if (emit_index + {28'd0, emit_word_bytes} >= {16'd0, sel_key_len_r}) begin
                                if (sel_value_len_r != 16'd0) begin
                                    // OPT-CAP4: value bytes pass through directly
                                    emit_index        <= 32'd0;
                                    state             <= ST_STREAM_VALUE;
                                end else begin
                                    // No value: record done, go refill
                                    if (selected_source == 1'b0) begin
                                        buf_valid0 <= 1'b0;
                                        if (!source_done_seen0)
                                            state <= ST_WAIT0_HEADER;
                                        else if (buf_valid1) begin
                                            compare_index <= 16'd0;
                                            state <= ST_COMPARE_INPUTS;
                                        end else if (!source_done_seen1)
                                            state <= ST_WAIT1_HEADER;
                                        else begin
                                            busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                        end
                                    end else begin
                                        buf_valid1 <= 1'b0;
                                        if (!source_done_seen1)
                                            state <= ST_WAIT1_HEADER;
                                        else if (buf_valid0) begin
                                            compare_index <= 16'd0;
                                            state <= ST_COMPARE_INPUTS;
                                        end else if (!source_done_seen0)
                                            state <= ST_WAIT0_HEADER;
                                        else begin
                                            busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                        end
                                    end
                                end
                            end else begin
                                emit_index <= emit_index + {28'd0, emit_word_bytes};
                            end
                        end
                    end

                    // OPT-B1: multi-byte prev_key copy (drop path) — CMP_CHUNK bytes/cycle
                    // OPT-MF2: only reached when value_len==0 or drain already finished
                    // OPT-T2: Use registered sel_user_key_len_r
                    ST_COPY_PREV_KEY: begin
                        if (compare_index < sel_user_key_len_r) begin
                            for (cmp_k = 0; cmp_k < COPY_CHUNK; cmp_k = cmp_k + 1) begin
                                if (compare_index + cmp_k[15:0] < sel_user_key_len_r)
                                    prev_user_key_mem[compare_index[7:0] + cmp_k[7:0]] <= selected_source
                                        ? user_key_mem1[compare_index[7:0] + cmp_k[7:0]]
                                        : user_key_mem0[compare_index[7:0] + cmp_k[7:0]];
                            end
                            compare_index <= (compare_index + COPY_CHUNK[15:0] >= sel_user_key_len_r)
                                             ? sel_user_key_len_r
                                             : compare_index + COPY_CHUNK[15:0];
                        end else begin
                            // Copy done; go refill (drain already done or not needed)
                            if (selected_source == 1'b0) begin
                                buf_valid0 <= 1'b0;
                                if (!source_done_seen0)
                                    state <= ST_WAIT0_HEADER;
                                else if (buf_valid1) begin
                                    compare_index <= 16'd0;
                                    state <= ST_COMPARE_INPUTS;
                                end else if (!source_done_seen1)
                                    state <= ST_WAIT1_HEADER;
                                else begin
                                    busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                end
                            end else begin
                                buf_valid1 <= 1'b0;
                                if (!source_done_seen1)
                                    state <= ST_WAIT1_HEADER;
                                else if (buf_valid0) begin
                                    compare_index <= 16'd0;
                                    state <= ST_COMPARE_INPUTS;
                                end else if (!source_done_seen0)
                                    state <= ST_WAIT0_HEADER;
                                else begin
                                    busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                end
                            end
                        end
                    end

                    // P6: direct 64-bit value pass-through (no accumulator)
                    ST_STREAM_VALUE: begin
                        if (selected_stream_valid_w && m_axis_tready) begin
                            if (emit_index + {28'd0, selected_beat_bytes_w} >= {16'd0, sel_value_len_r}) begin
                                // Last value beat emitted; go refill
                                if (selected_source == 1'b0) begin
                                    buf_valid0 <= 1'b0;
                                    if (!source_done_seen0)
                                        state <= ST_WAIT0_HEADER;
                                    else if (buf_valid1) begin
                                        compare_index <= 16'd0;
                                        state <= ST_COMPARE_INPUTS;
                                    end else if (!source_done_seen1)
                                        state <= ST_WAIT1_HEADER;
                                    else begin
                                        busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                    end
                                end else begin
                                    buf_valid1 <= 1'b0;
                                    if (!source_done_seen1)
                                        state <= ST_WAIT1_HEADER;
                                    else if (buf_valid0) begin
                                        compare_index <= 16'd0;
                                        state <= ST_COMPARE_INPUTS;
                                    end else if (!source_done_seen0)
                                        state <= ST_WAIT0_HEADER;
                                    else begin
                                        busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                    end
                                end
                            end else begin
                                emit_index <= emit_index + {28'd0, selected_beat_bytes_w};
                            end
                        end
                    end

                    // P6: drain value bytes (drop path) — multi-byte per cycle
                    // OPT-MF2: concurrent prev_key copy overlapped with drain
                    // OPT-T2: Use registered sel_user_key_len_r, sel_value_len_r
                    ST_DRAIN_VALUE: begin
                        // Concurrent prev_key copy (runs every cycle, not gated by drain accept)
                        if (compare_index < sel_user_key_len_r) begin
                            for (cmp_k = 0; cmp_k < COPY_CHUNK; cmp_k = cmp_k + 1) begin
                                if (compare_index + cmp_k[15:0] < sel_user_key_len_r)
                                    prev_user_key_mem[compare_index[7:0] + cmp_k[7:0]] <= selected_source
                                        ? user_key_mem1[compare_index[7:0] + cmp_k[7:0]]
                                        : user_key_mem0[compare_index[7:0] + cmp_k[7:0]];
                            end
                            compare_index <= (compare_index + COPY_CHUNK[15:0] >= sel_user_key_len_r)
                                             ? sel_user_key_len_r
                                             : compare_index + COPY_CHUNK[15:0];
                        end
                        // Drain logic — up to 8 bytes per beat
                        if ((selected_source == 1'b0) ? payload_accept0 : payload_accept1) begin
                            if (emit_index + {28'd0, selected_beat_bytes_w} >= {16'd0, sel_value_len_r}) begin
                                // Last value beat drained
                                if (compare_index < sel_user_key_len_r &&
                                    !(compare_index + COPY_CHUNK[15:0] >= sel_user_key_len_r)) begin
                                    // Copy not yet done; finish in ST_COPY_PREV_KEY
                                    state <= ST_COPY_PREV_KEY;
                                end else begin
                                    // Both drain and copy done; go refill
                                    if (selected_source == 1'b0) begin
                                        buf_valid0 <= 1'b0;
                                        if (!source_done_seen0)
                                            state <= ST_WAIT0_HEADER;
                                        else if (buf_valid1) begin
                                            compare_index <= 16'd0;
                                            state <= ST_COMPARE_INPUTS;
                                        end else if (!source_done_seen1)
                                            state <= ST_WAIT1_HEADER;
                                        else begin
                                            busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                        end
                                    end else begin
                                        buf_valid1 <= 1'b0;
                                        if (!source_done_seen1)
                                            state <= ST_WAIT1_HEADER;
                                        else if (buf_valid0) begin
                                            compare_index <= 16'd0;
                                            state <= ST_COMPARE_INPUTS;
                                        end else if (!source_done_seen0)
                                            state <= ST_WAIT0_HEADER;
                                        else begin
                                            busy <= 1'b0; done <= 1'b1; state <= ST_IDLE;
                                        end
                                    end
                                end
                            end else begin
                                emit_index <= emit_index + {28'd0, selected_beat_bytes_w};
                            end
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
    end
    // P6: Count total key+value bytes using tkeep popcount (8-bit)
    wire [3:0] m_keep_popcnt = {3'b0, m_axis_tkeep[0]} + {3'b0, m_axis_tkeep[1]}
                              + {3'b0, m_axis_tkeep[2]} + {3'b0, m_axis_tkeep[3]}
                              + {3'b0, m_axis_tkeep[4]} + {3'b0, m_axis_tkeep[5]}
                              + {3'b0, m_axis_tkeep[6]} + {3'b0, m_axis_tkeep[7]};
    reg [31:0] output_byte_count_r;
    assign output_byte_count = output_byte_count_r;
    always @(posedge clk) begin
        if (!rstn || clear)
            output_byte_count_r <= 32'd0;
        else if (start && !busy)
            output_byte_count_r <= 32'd0;
        else if (m_axis_tvalid && m_axis_tready)
            output_byte_count_r <= output_byte_count_r + {28'd0, m_keep_popcnt};
    end

    // ── Profiling counters (synthesis: optimized out if unconnected) ──
    `ifdef SIMULATION
    reg [31:0] prof_wait0, prof_wait1, prof_cap0, prof_cap1;
    reg [31:0] prof_compare, prof_check, prof_finalize;
    reg [31:0] prof_emit_hdr, prof_emit_pay, prof_stream_val;
    reg [31:0] prof_drain_val, prof_copy_key, prof_idle;
    always @(posedge clk) begin
        if (!rstn || clear || (start && !busy)) begin
            prof_wait0 <= 0; prof_wait1 <= 0;
            prof_cap0  <= 0; prof_cap1  <= 0;
            prof_compare <= 0; prof_check <= 0;
            prof_finalize <= 0; prof_emit_hdr <= 0;
            prof_emit_pay <= 0; prof_stream_val <= 0;
            prof_drain_val <= 0; prof_copy_key <= 0;
            prof_idle <= 0;
        end else if (busy) begin
            case (state)
                ST_WAIT0_HEADER:   prof_wait0     <= prof_wait0 + 1;
                ST_WAIT1_HEADER:   prof_wait1     <= prof_wait1 + 1;
                ST_CAPTURE0:       prof_cap0      <= prof_cap0 + 1;
                ST_CAPTURE1:       prof_cap1      <= prof_cap1 + 1;
                ST_COMPARE_INPUTS: prof_compare   <= prof_compare + 1;
                ST_CHECK_KEEP:     prof_check     <= prof_check + 1;
                ST_FINALIZE:       prof_finalize  <= prof_finalize + 1;
                ST_EMIT_HEADER:    prof_emit_hdr  <= prof_emit_hdr + 1;
                ST_EMIT_PAYLOAD:   prof_emit_pay  <= prof_emit_pay + 1;
                ST_STREAM_VALUE:   prof_stream_val<= prof_stream_val + 1;
                ST_DRAIN_VALUE:    prof_drain_val <= prof_drain_val + 1;
                ST_COPY_PREV_KEY:  prof_copy_key  <= prof_copy_key + 1;
                default:           prof_idle      <= prof_idle + 1;
            endcase
        end
    end
    `endif

endmodule

/* --- cmpct_merger_wrap removed: byte counter inlined into cmpct_merger --- */
/* --- Below kept only as dead code guard; can be deleted safely. --- */
`ifdef DEAD_MERGER_WRAP
module cmpct_merger_wrap_DEAD #(
    parameter integer MAX_USER_KEY_BYTES = 256,
    parameter integer MAX_KEY_BYTES      = 264,
    parameter integer MAX_VALUE_BYTES    = 1024,
    parameter integer MAX_RECORD_BYTES   = 2048,
    parameter integer MAX_RECORDS        = 256,
    parameter integer MAX_OUTPUT_BYTES   = 73728
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        start,
    input  wire        seed_prev_user_key_valid,
    input  wire [15:0] seed_prev_user_key_len,
    input  wire [(MAX_USER_KEY_BYTES*8)-1:0] seed_prev_user_key,

    input  wire        source0_done,
    input  wire        s0_record_valid,
    output wire        s0_record_ready,
    input  wire [15:0] s0_record_key_len,
    input  wire [15:0] s0_record_value_len,
    // OPT-CAP4: 32-bit input from decoder
    input  wire [31:0] s0_axis_tdata,
    input  wire [3:0]  s0_axis_tkeep,
    input  wire        s0_axis_tlast,
    input  wire        s0_axis_tvalid,
    output wire        s0_axis_tready,

    input  wire        source1_done,
    input  wire        s1_record_valid,
    output wire        s1_record_ready,
    input  wire [15:0] s1_record_key_len,
    input  wire [15:0] s1_record_value_len,
    // OPT-CAP4: 32-bit input from decoder
    input  wire [31:0] s1_axis_tdata,
    input  wire [3:0]  s1_axis_tkeep,
    input  wire        s1_axis_tlast,
    input  wire        s1_axis_tvalid,
    output wire        s1_axis_tready,

    output wire        busy,
    output wire        done,
    output wire        error,
    output wire [31:0] output_byte_count,

    // Record-stream header (exposed directly from decoder, consumed by encoder)
    output wire        m_record_valid,
    input  wire        m_record_ready,
    output wire [15:0] m_record_key_len,
    output wire [15:0] m_record_value_len,

    // OPT-W1: 32-bit key+value byte stream
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,

    output wire [31:0] merge_decoded_record_count,
    output wire [31:0] merge_merged_record_count,
    output wire [31:0] merge_dropped_superseded_count,
    output wire [31:0] merge_value_record_count,
    output wire [31:0] merge_delete_record_count,
    output wire [31:0] merge_user_key_bytes_total,
    output wire [31:0] merge_value_bytes_total,
    output wire [15:0] merge_last_user_key_len,
    output wire [55:0] merge_last_sequence,
    output wire [7:0]  merge_last_value_type,
    output wire        merge_last_record_keep,
    output wire        final_prev_user_key_valid,
    output wire [15:0] final_prev_user_key_len,
    output wire [(MAX_USER_KEY_BYTES*8)-1:0] final_prev_user_key
);

    wire        merge_busy;
    wire        merge_done;
    wire        merge_error;

    cmpct_merger_core #(
        .MAX_USER_KEY_BYTES(MAX_USER_KEY_BYTES),
        .MAX_KEY_BYTES(MAX_KEY_BYTES),
        .MAX_VALUE_BYTES(MAX_VALUE_BYTES),
        .MAX_RECORD_BYTES(MAX_RECORD_BYTES)
    ) u_cmpct_merger_core (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(start),
        .seed_prev_user_key_valid(seed_prev_user_key_valid),
        .seed_prev_user_key_len(seed_prev_user_key_len),
        .seed_prev_user_key(seed_prev_user_key),
        .source0_done(source0_done),
        .s0_record_valid(s0_record_valid),
        .s0_record_ready(s0_record_ready),
        .s0_record_key_len(s0_record_key_len),
        .s0_record_value_len(s0_record_value_len),
        .s0_axis_tdata(s0_axis_tdata),
        .s0_axis_tkeep(s0_axis_tkeep),
        .s0_axis_tlast(s0_axis_tlast),
        .s0_axis_tvalid(s0_axis_tvalid),
        .s0_axis_tready(s0_axis_tready),
        .source1_done(source1_done),
        .s1_record_valid(s1_record_valid),
        .s1_record_ready(s1_record_ready),
        .s1_record_key_len(s1_record_key_len),
        .s1_record_value_len(s1_record_value_len),
        .s1_axis_tdata(s1_axis_tdata),
        .s1_axis_tkeep(s1_axis_tkeep),
        .s1_axis_tlast(s1_axis_tlast),
        .s1_axis_tvalid(s1_axis_tvalid),
        .s1_axis_tready(s1_axis_tready),
        .m_record_valid(m_record_valid),
        .m_record_ready(m_record_ready),
        .m_record_key_len(m_record_key_len),
        .m_record_value_len(m_record_value_len),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .busy(merge_busy),
        .done(merge_done),
        .error(merge_error),
        .decoded_record_count(merge_decoded_record_count),
        .merged_record_count(merge_merged_record_count),
        .dropped_superseded_count(merge_dropped_superseded_count),
        .value_record_count(merge_value_record_count),
        .delete_record_count(merge_delete_record_count),
        .user_key_bytes_total(merge_user_key_bytes_total),
        .value_bytes_total(merge_value_bytes_total),
        .last_user_key_len(merge_last_user_key_len),
        .last_sequence(merge_last_sequence),
        .last_value_type(merge_last_value_type),
        .last_record_keep(merge_last_record_keep),
        .final_prev_user_key_valid(final_prev_user_key_valid),
        .final_prev_user_key_len(final_prev_user_key_len),
        .final_prev_user_key(final_prev_user_key)
    );

    // OPT-W1: Count total key+value bytes using tkeep popcount
    wire [2:0] m_keep_popcnt = {2'b0, m_axis_tkeep[0]} + {2'b0, m_axis_tkeep[1]}
                              + {2'b0, m_axis_tkeep[2]} + {2'b0, m_axis_tkeep[3]};
    reg [31:0] output_byte_count_r;
    assign output_byte_count = output_byte_count_r;
    always @(posedge clk) begin
        if (!rstn || clear)
            output_byte_count_r <= 32'd0;
        else if (start && !merge_busy)
            output_byte_count_r <= 32'd0;
        else if (m_axis_tvalid && m_axis_tready)
            output_byte_count_r <= output_byte_count_r + {29'd0, m_keep_popcnt};
    end

    assign busy  = merge_busy;
    assign done  = merge_done;
    assign error = merge_error;

endmodule
`endif
