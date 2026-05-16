`timescale 1ns / 1ps

// OPT-ENC-W32: 32-bit wide streaming encoder (4 bytes/cycle throughput).
// Replaces the 8-bit encoder. Key changes:
//   - Input/output are 32-bit + 4-bit tkeep
//   - ST_RECV_KEY: 4 bytes/cycle with inline 4-way prefix comparison
//   - Varint states: emit full varint (1-2 bytes) in 1 cycle
//   - ST_WRITE_KEY: 4 bytes/cycle from key buffer
//   - ST_STREAM_VALUE: 32-bit pass-through
//   - ST_APPEND_RESTARTS: 1 restart (4 bytes) per cycle
//   - ST_APPEND_RST_CNT: 4 bytes in 1 cycle
module real_data_block_encoder #(
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
    // OPT-ENC-W32: 32-bit input (from merger FIFO directly)
    input  wire [31:0] s_axis_tdata,
    input  wire [3:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    // OPT-ENC-W32: 32-bit output (to enc_out FIFO directly)
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
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
    localparam [3:0] ST_WRITE_SHARED    = 4'd3;
    localparam [3:0] ST_WRITE_UNSHARED  = 4'd4;
    localparam [3:0] ST_WRITE_VALUE_LEN = 4'd5;
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

    // OPT-ENC-W32: 32-bit output registers
    reg [31:0] emit_data;
    reg [3:0]  emit_keep;
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

    // Pack a complete varint into {data[31:0], keep[3:0]} in 1 cycle
    function automatic [35:0] varint32_pack;
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
                3'd1: varint32_pack = {4'b0001, 24'd0, b0};
                3'd2: varint32_pack = {4'b0011, 16'd0, b1, b0};
                3'd3: varint32_pack = {4'b0111, 8'd0, b2, b1, b0};
                default: varint32_pack = {4'b1111, b3, b2, b1, b0};
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

    // Input byte count from tkeep
    wire [2:0] in_bytes = {2'b0, s_axis_tkeep[0]} + {2'b0, s_axis_tkeep[1]}
                        + {2'b0, s_axis_tkeep[2]} + {2'b0, s_axis_tkeep[3]};

    // last_key_bytes: expose the prev (most recently completed) key buffer
    genvar lki;
    generate
        for (lki = 0; lki < MAX_KEY_BYTES; lki = lki + 1) begin : g_last_key
            assign last_key_bytes[(lki*8) +: 8] = prev_buf_sel ? key_buf_b[lki] : key_buf_a[lki];
        end
    endgenerate

    // OPT-ENC-W32: 4-way prev key byte reads for prefix comparison
    wire [7:0] prev_b0 = prev_buf_sel ? key_buf_b[recv_idx+0] : key_buf_a[recv_idx+0];
    wire [7:0] prev_b1 = prev_buf_sel ? key_buf_b[recv_idx+1] : key_buf_a[recv_idx+1];
    wire [7:0] prev_b2 = prev_buf_sel ? key_buf_b[recv_idx+2] : key_buf_a[recv_idx+2];
    wire [7:0] prev_b3 = prev_buf_sel ? key_buf_b[recv_idx+3] : key_buf_a[recv_idx+3];

    // OPT-ENC-W32: 4-way current key byte reads for ST_WRITE_KEY
    wire [15:0] key_rd_base = current_shared_len + block_copy_idx;
    wire [7:0] key_e0 = prev_buf_sel ? key_buf_a[key_rd_base+0] : key_buf_b[key_rd_base+0];
    wire [7:0] key_e1 = prev_buf_sel ? key_buf_a[key_rd_base+1] : key_buf_b[key_rd_base+1];
    wire [7:0] key_e2 = prev_buf_sel ? key_buf_a[key_rd_base+2] : key_buf_b[key_rd_base+2];
    wire [7:0] key_e3 = prev_buf_sel ? key_buf_a[key_rd_base+3] : key_buf_b[key_rd_base+3];

    // Remaining unshared key bytes to emit
    wire [15:0] key_rem = current_unshared_len - block_copy_idx;
    wire [2:0]  key_emit_bytes = (key_rem >= 16'd4) ? 3'd4 : key_rem[2:0];

    // Varint packed results (combinational)
    wire [35:0] shared_packed   = varint32_pack({16'd0, current_shared_len});
    wire [35:0] unshared_packed = varint32_pack({16'd0, current_unshared_len});
    wire [35:0] value_packed    = varint32_pack({16'd0, current_value_len});

    wire [2:0] shared_vlen   = varint32_len({16'd0, current_shared_len});
    wire [2:0] unshared_vlen = varint32_len({16'd0, current_unshared_len});
    wire [2:0] value_vlen    = varint32_len({16'd0, current_value_len});

    // =========================================================================
    // 4-way prefix comparison (combinational)
    // =========================================================================
    reg [15:0] new_shared_len;
    reg        new_mismatch;

    always @(*) begin
        new_shared_len = current_shared_len;
        new_mismatch   = mismatch_found;
        if (input_accept && state == ST_RECV_KEY && !is_restart_point && !mismatch_found) begin
            // Byte 0
            if (s_axis_tkeep[0] && recv_idx < prev_key_len && s_axis_tdata[7:0] == prev_b0) begin
                new_shared_len = recv_idx + 16'd1;
                // Byte 1
                if (s_axis_tkeep[1] && recv_idx + 16'd1 < prev_key_len && s_axis_tdata[15:8] == prev_b1) begin
                    new_shared_len = recv_idx + 16'd2;
                    // Byte 2
                    if (s_axis_tkeep[2] && recv_idx + 16'd2 < prev_key_len && s_axis_tdata[23:16] == prev_b2) begin
                        new_shared_len = recv_idx + 16'd3;
                        // Byte 3
                        if (s_axis_tkeep[3] && recv_idx + 16'd3 < prev_key_len && s_axis_tdata[31:24] == prev_b3) begin
                            new_shared_len = recv_idx + 16'd4;
                        end else if (s_axis_tkeep[3]) begin
                            new_mismatch = 1'b1;
                        end
                    end else if (s_axis_tkeep[2]) begin
                        new_mismatch = 1'b1;
                    end
                end else if (s_axis_tkeep[1]) begin
                    new_mismatch = 1'b1;
                end
            end else if (s_axis_tkeep[0]) begin
                new_mismatch = 1'b1;
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
            emit_data                <= 32'd0;
            emit_keep                <= 4'd0;
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
                            state <= ST_WRITE_SHARED;
                        end else begin
                            state <= ST_RECV_KEY;
                        end
                    end else if ((source_done || source_done_seen) && !s_record_valid) begin
                        restart_emit_idx <= 32'd0;
                        state            <= ST_APPEND_RESTARTS;
                    end
                end

                // =============================================================
                // OPT-ENC-W32: Receive 4 key bytes/cycle with inline prefix
                ST_RECV_KEY: begin
                    if (input_accept) begin
                        // Write bytes to CURRENT key buffer
                        if (!prev_buf_sel) begin
                            if (s_axis_tkeep[0]) key_buf_b[recv_idx+0] <= s_axis_tdata[7:0];
                            if (s_axis_tkeep[1]) key_buf_b[recv_idx+1] <= s_axis_tdata[15:8];
                            if (s_axis_tkeep[2]) key_buf_b[recv_idx+2] <= s_axis_tdata[23:16];
                            if (s_axis_tkeep[3]) key_buf_b[recv_idx+3] <= s_axis_tdata[31:24];
                        end else begin
                            if (s_axis_tkeep[0]) key_buf_a[recv_idx+0] <= s_axis_tdata[7:0];
                            if (s_axis_tkeep[1]) key_buf_a[recv_idx+1] <= s_axis_tdata[15:8];
                            if (s_axis_tkeep[2]) key_buf_a[recv_idx+2] <= s_axis_tdata[23:16];
                            if (s_axis_tkeep[3]) key_buf_a[recv_idx+3] <= s_axis_tdata[31:24];
                        end

                        // Inline prefix comparison (4-way combinational)
                        current_shared_len <= new_shared_len;
                        mismatch_found     <= new_mismatch;

                        recv_idx <= recv_idx + {13'd0, in_bytes};

                        if (recv_idx + {13'd0, in_bytes} >= current_key_len) begin
                            state <= ST_WRITE_SHARED;
                        end
                    end
                end

                // =============================================================
                // OPT-ENC-W32 + P1: Emit full varint in 1 cycle
                ST_WRITE_SHARED: begin
                    // Compute unshared_len on entry (shared_len is final)
                    current_unshared_len <= current_key_len - current_shared_len;

                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data  <= shared_packed[31:0];
                        emit_keep  <= shared_packed[35:32];
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + {29'd0, shared_vlen};
                        state <= ST_WRITE_UNSHARED;
                    end
                end

                // =============================================================
                ST_WRITE_UNSHARED: begin
                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data  <= unshared_packed[31:0];
                        emit_keep  <= unshared_packed[35:32];
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + {29'd0, unshared_vlen};
                        state <= ST_WRITE_VALUE_LEN;
                    end
                end

                // =============================================================
                ST_WRITE_VALUE_LEN: begin
                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data  <= value_packed[31:0];
                        emit_keep  <= value_packed[35:32];
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + {29'd0, value_vlen};
                        block_copy_idx <= 16'd0;
                        if (current_unshared_len == 16'd0) begin
                            value_rem <= {16'd0, current_value_len};
                            state <= ST_STREAM_VALUE;
                        end else begin
                            state <= ST_WRITE_KEY;
                        end
                    end
                end

                // =============================================================
                // OPT-ENC-W32: Emit 4 unshared key bytes/cycle
                ST_WRITE_KEY: begin
                    if (block_copy_idx >= current_unshared_len) begin
                        value_rem <= {16'd0, current_value_len};
                        state     <= ST_STREAM_VALUE;
                    end else if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_data <= {key_e3, key_e2, key_e1, key_e0};
                        case (key_emit_bytes)
                            3'd1: emit_keep <= 4'b0001;
                            3'd2: emit_keep <= 4'b0011;
                            3'd3: emit_keep <= 4'b0111;
                            default: emit_keep <= 4'b1111;
                        endcase
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + {29'd0, key_emit_bytes};
                        block_copy_idx    <= block_copy_idx + {13'd0, key_emit_bytes};
                    end
                end

                // =============================================================
                // OPT-ENC-W32: 32-bit value pass-through
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
                            block_write_index <= block_write_index + {29'd0, in_bytes};
                            value_rem         <= value_rem - {29'd0, in_bytes};
                        end
                    end
                end

                // =============================================================
                // OPT-ENC-W32: 1 restart offset (4 bytes) per cycle
                ST_APPEND_RESTARTS: begin
                    if (restart_emit_idx >= restart_count) begin
                        state <= ST_APPEND_RST_CNT;
                    end else if (can_emit) begin
                        emit_data  <= restart_offset_mem[restart_emit_idx];
                        emit_keep  <= 4'b1111;
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + 32'd4;
                        restart_emit_idx  <= restart_emit_idx + 32'd1;
                    end
                end

                // =============================================================
                // OPT-ENC-W32: restart count in 1 cycle with tlast
                ST_APPEND_RST_CNT: begin
                    if (can_emit) begin
                        emit_data  <= restart_count;
                        emit_keep  <= 4'b1111;
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

endmodule
