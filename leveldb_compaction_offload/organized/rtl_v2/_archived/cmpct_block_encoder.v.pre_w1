`timescale 1ns / 1ps

// OPT-2C Streaming encoder: accepts a record-stream header per record
// (s_record_valid/ready + s_record_key_len / s_record_value_len) plus the
// key+value byte payload on s_axis_*, and a source_done pulse after the last
// record.  Prefix sharing is computed inline while receiving key bytes.
// All encoded bytes (varints, key suffix, value, restart array, restart count)
// are streamed directly to m_axis — no block_mem second scan.
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
    // Record-stream header (one handshake per record, before its bytes arrive)
    input  wire        s_record_valid,
    output wire        s_record_ready,
    input  wire [15:0] s_record_key_len,
    input  wire [15:0] s_record_value_len,
    // End-of-all-records signal (may be a 1-cycle pulse; latched internally)
    input  wire        source_done,
    // Per-record key+value byte stream (key bytes then value bytes)
    input  wire [7:0]  s_axis_tdata,
    input  wire [0:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    // Encoded block output byte stream
    output wire [7:0]  m_axis_tdata,
    output wire [0:0]  m_axis_tkeep,
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

    // ---------------------------------------------------------------------------
    // States
    // ---------------------------------------------------------------------------
    localparam [3:0] ST_IDLE            = 4'd0;
    localparam [3:0] ST_WAIT_RECORD     = 4'd1;   // wait for record header or source_done
    localparam [3:0] ST_RECV_KEY        = 4'd2;   // receive key bytes; compute prefix inline
    localparam [3:0] ST_WRITE_SHARED    = 4'd3;   // stream varint(shared_len) to m_axis
    localparam [3:0] ST_WRITE_UNSHARED  = 4'd4;   // stream varint(unshared_len) to m_axis
    localparam [3:0] ST_WRITE_VALUE_LEN = 4'd5;   // stream varint(value_len) to m_axis
    localparam [3:0] ST_WRITE_KEY       = 4'd6;   // stream unshared key suffix to m_axis
    localparam [3:0] ST_STREAM_VALUE    = 4'd7;   // pass value bytes from s_axis to m_axis
    localparam [3:0] ST_APPEND_RESTARTS = 4'd8;   // append restart offsets
    localparam [3:0] ST_APPEND_RST_CNT  = 4'd9;   // append restart count (4 bytes)
    localparam [3:0] ST_FINISH          = 4'd10;  // wait for last byte acceptance

    reg [3:0] state;

    // ---------------------------------------------------------------------------
    // Memories (OPT-2C: block_mem removed — output is streamed directly)
    // ---------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [7:0] key_buf_a [0:MAX_KEY_BYTES-1]; // ping-pong A
    (* ram_style = "distributed" *) reg [7:0] key_buf_b [0:MAX_KEY_BYTES-1]; // ping-pong B
    reg [31:0] restart_offset_mem [0:MAX_RECORDS-1];

    // prev_buf_sel: 0 => prev=buf_a, cur writes to buf_b
    //              1 => prev=buf_b, cur writes to buf_a
    reg        prev_buf_sel;
    reg [15:0] prev_key_len;

    // ---------------------------------------------------------------------------
    // Working registers
    // ---------------------------------------------------------------------------
    reg [15:0] current_key_len;
    reg [15:0] current_value_len;
    reg [15:0] current_shared_len;
    reg [15:0] current_unshared_len;
    reg        mismatch_found;      // prefix diverged; stop comparing
    reg        is_restart_point;    // current record forced to shared=0

    reg [15:0] recv_idx;            // byte index during ST_RECV_KEY
    reg [31:0] block_write_index;
    reg [15:0] block_copy_idx;      // byte index during ST_WRITE_KEY
    reg [31:0] value_rem;           // value bytes remaining in ST_STREAM_VALUE
    reg [2:0]  varint_idx;          // byte within current varint emission
    reg [31:0] restart_emit_idx;
    reg [1:0]  fixed32_byte_idx;
    reg [31:0] entries_since_restart;
    reg        source_done_seen;
    // OPT-2C: streaming output registers (replace block_mem + output sub-process)
    reg [7:0]  emit_byte;            // byte to present on m_axis_tdata
    reg        emit_valid;           // m_axis_tvalid
    reg        emit_last;            // m_axis_tlast

    // ---------------------------------------------------------------------------
    // Helper functions (identical to original)
    // ---------------------------------------------------------------------------
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

    function automatic [7:0] varint32_get_byte;
        input [31:0] value;
        input [2:0]  index;
        input [2:0]  total_len;
        reg [31:0] shifted;
        begin
            shifted = value >> (index * 7);
            varint32_get_byte = shifted[6:0];
            if (index + 3'd1 < total_len)
                varint32_get_byte = shifted[6:0] | 8'h80;
        end
    endfunction

    function automatic [7:0] fixed32_get_byte;
        input [31:0] value;
        input [1:0]  index;
        begin
            case (index)
                2'd0: fixed32_get_byte = value[7:0];
                2'd1: fixed32_get_byte = value[15:8];
                2'd2: fixed32_get_byte = value[23:16];
                default: fixed32_get_byte = value[31:24];
            endcase
        end
    endfunction

    // ---------------------------------------------------------------------------
    // Combinational assignments
    // ---------------------------------------------------------------------------
    // OPT-2C: can_emit is true when the output slot is free or just accepted
    wire can_emit = !emit_valid || m_axis_tready;

    assign s_record_ready = busy && !error && (state == ST_WAIT_RECORD);
    assign s_axis_tready  = busy && !error &&
                            ((state == ST_RECV_KEY) ||
                             (state == ST_STREAM_VALUE && value_rem != 32'd0 && can_emit));

    // OPT-2C: streaming output — emit_byte/emit_valid/emit_last drive m_axis
    assign m_axis_tdata  = emit_byte;
    assign m_axis_tkeep  = 1'b1;
    assign m_axis_tvalid = emit_valid;
    assign m_axis_tlast  = emit_valid && emit_last;

    wire input_accept  = s_axis_tvalid && s_axis_tready && s_axis_tkeep[0];

    // last_key_bytes: expose the prev (most recently completed) key buffer contents
    genvar lki;
    generate
        for (lki = 0; lki < MAX_KEY_BYTES; lki = lki + 1) begin : g_last_key_bytes
            assign last_key_bytes[(lki*8) +: 8] = prev_buf_sel ? key_buf_b[lki] : key_buf_a[lki];
        end
    endgenerate

    // Read from the PREVIOUS key buffer at recv_idx (for prefix comparison)
    wire [7:0] prev_key_byte = prev_buf_sel ? key_buf_b[recv_idx] : key_buf_a[recv_idx];
    // Read from the CURRENT key buffer at offset (shared + copy_idx) for ST_WRITE_KEY
    wire [7:0] cur_key_emit  = prev_buf_sel ? key_buf_a[current_shared_len + block_copy_idx]
                                            : key_buf_b[current_shared_len + block_copy_idx];

    // Combinational varint lengths (stable when writing varints)
    wire [2:0] shared_varint_len   = varint32_len({16'd0, current_shared_len});
    wire [2:0] unshared_varint_len = varint32_len({16'd0, current_unshared_len});
    wire [2:0] value_varint_len    = varint32_len({16'd0, current_value_len});

    // ---------------------------------------------------------------------------
    // Sequential logic
    // ---------------------------------------------------------------------------
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
            varint_idx               <= 3'd0;
            restart_emit_idx         <= 32'd0;
            fixed32_byte_idx         <= 2'd0;
            entries_since_restart    <= 32'd0;
            source_done_seen         <= 1'b0;
            emit_byte                <= 8'd0;
            emit_valid               <= 1'b0;
            emit_last                <= 1'b0;
        end else begin
            done <= 1'b0;

            // Latch source_done (it may be a 1-cycle pulse)
            if (source_done) source_done_seen <= 1'b1;

            // OPT-2C: auto-clear emit_valid when downstream accepts the byte.
            // State-machine assignments below can override via last-NB-wins.
            if (emit_valid && m_axis_tready) begin
                emit_valid <= 1'b0;
            end

            case (state)
                // -----------------------------------------------------------------
                ST_IDLE: begin
                    if (start && !busy) begin
                        busy                     <= 1'b1;
                        done                     <= 1'b0;
                        error                    <= 1'b0;
                        input_record_count       <= 32'd0;
                        encoded_entry_count      <= 32'd0;
                        restart_count            <= 32'd1; // first restart always at offset 0
                        shared_key_bytes_total   <= 32'd0;
                        unshared_key_bytes_total <= 32'd0;
                        value_bytes_total        <= 32'd0;
                        last_key_len             <= 16'd0;
                        last_value_len           <= 16'd0;
                        last_shared_bytes        <= 16'd0;
                        last_non_shared_bytes    <= 16'd0;
                        output_block_bytes       <= 32'd0;
                        prev_buf_sel             <= 1'b0;
                        prev_key_len             <= 16'd0;
                        block_write_index        <= 32'd0;
                        entries_since_restart    <= 32'd0;
                        source_done_seen         <= 1'b0;
                        emit_valid               <= 1'b0;
                        emit_last                <= 1'b0;
                        restart_offset_mem[0]    <= 32'd0;
                        state                    <= ST_WAIT_RECORD;
                    end
                end

                // -----------------------------------------------------------------
                ST_WAIT_RECORD: begin
                    if (s_record_valid && s_record_ready) begin
                        current_key_len   <= s_record_key_len;
                        current_value_len <= s_record_value_len;
                        input_record_count <= input_record_count + 32'd1;

                        // Restart-point check
                        if (entries_since_restart == RESTART_INTERVAL) begin
                            is_restart_point <= 1'b1;
                            if (restart_count < MAX_RECORDS)
                                restart_offset_mem[restart_count] <= block_write_index;
                            restart_count        <= restart_count + 32'd1;
                            entries_since_restart <= 32'd0;
                        end else begin
                            is_restart_point <= 1'b0;
                        end

                        // Start key reception
                        recv_idx           <= 16'd0;
                        current_shared_len <= 16'd0;
                        mismatch_found     <= 1'b0;

                        if (s_record_key_len == 16'd0) begin
                            // Zero-length key: skip RECV_KEY; unshared = 0
                            current_unshared_len <= 16'd0;
                            varint_idx           <= 3'd0;
                            state                <= ST_WRITE_SHARED;
                        end else begin
                            state <= ST_RECV_KEY;
                        end

                    end else if ((source_done || source_done_seen) && !s_record_valid) begin
                        // All records delivered — stream restart array next
                        restart_emit_idx   <= 32'd0;
                        fixed32_byte_idx   <= 2'd0;
                        state              <= ST_APPEND_RESTARTS;
                    end
                end

                // -----------------------------------------------------------------
                ST_RECV_KEY: begin
                    if (input_accept) begin
                        // Write byte to CURRENT key buffer
                        if (!prev_buf_sel)
                            key_buf_b[recv_idx] <= s_axis_tdata;
                        else
                            key_buf_a[recv_idx] <= s_axis_tdata;

                        // Inline prefix sharing (skip if restart point or already diverged)
                        if (!is_restart_point && !mismatch_found) begin
                            if (recv_idx < prev_key_len &&
                                s_axis_tdata == prev_key_byte) begin
                                current_shared_len <= recv_idx + 16'd1;
                            end else begin
                                mismatch_found <= 1'b1;
                            end
                        end

                        recv_idx <= recv_idx + 16'd1;

                        if (recv_idx + 16'd1 == current_key_len) begin
                            // All key bytes received; transition to varint emission
                            // current_shared_len is now final (NB assignment above
                            // takes effect next cycle, so current_unshared_len will
                            // be computed on the first cycle of ST_WRITE_SHARED)
                            varint_idx <= 3'd0;
                            state      <= ST_WRITE_SHARED;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Stream varint(shared_len) bytes directly to m_axis.
                // On entry: current_shared_len is final.
                // Compute current_unshared_len on the first cycle (varint_idx==0).
                ST_WRITE_SHARED: begin
                    if (varint_idx == 3'd0)
                        current_unshared_len <= current_key_len - current_shared_len;

                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy  <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_byte <= varint32_get_byte({16'd0, current_shared_len},
                                                      varint_idx, shared_varint_len);
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + 32'd1;
                        if (varint_idx + 3'd1 >= shared_varint_len) begin
                            varint_idx <= 3'd0;
                            state      <= ST_WRITE_UNSHARED;
                        end else begin
                            varint_idx <= varint_idx + 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Stream varint(unshared_len) bytes directly.
                ST_WRITE_UNSHARED: begin
                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy  <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_byte <= varint32_get_byte({16'd0, current_unshared_len},
                                                      varint_idx, unshared_varint_len);
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + 32'd1;
                        if (varint_idx + 3'd1 >= unshared_varint_len) begin
                            varint_idx <= 3'd0;
                            state      <= ST_WRITE_VALUE_LEN;
                        end else begin
                            varint_idx <= varint_idx + 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Stream varint(value_len) bytes directly.
                ST_WRITE_VALUE_LEN: begin
                    if (block_write_index >= MAX_BLOCK_BYTES) begin
                        busy  <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                    end else if (can_emit) begin
                        emit_byte <= varint32_get_byte({16'd0, current_value_len},
                                                      varint_idx, value_varint_len);
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + 32'd1;
                        if (varint_idx + 3'd1 >= value_varint_len) begin
                            block_copy_idx <= 16'd0;
                            if (current_unshared_len == 16'd0) begin
                                value_rem <= {16'd0, current_value_len};
                                state     <= ST_STREAM_VALUE;
                            end else begin
                                state <= ST_WRITE_KEY;
                            end
                        end else begin
                            varint_idx <= varint_idx + 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Stream unshared key suffix from key buffer directly.
                ST_WRITE_KEY: begin
                    if (block_copy_idx < current_unshared_len) begin
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy  <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                        end else if (can_emit) begin
                            emit_byte <= cur_key_emit;
                            emit_valid <= 1'b1;
                            block_write_index <= block_write_index + 32'd1;
                            block_copy_idx    <= block_copy_idx + 16'd1;
                        end
                    end else begin
                        value_rem <= {16'd0, current_value_len};
                        state     <= ST_STREAM_VALUE;
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Pass value bytes from s_axis directly to m_axis output.
                ST_STREAM_VALUE: begin
                    if (value_rem == 32'd0) begin
                        // Record fully consumed; update stats, swap key buffers
                        encoded_entry_count      <= encoded_entry_count + 32'd1;
                        shared_key_bytes_total   <= shared_key_bytes_total   + current_shared_len;
                        unshared_key_bytes_total <= unshared_key_bytes_total + current_unshared_len;
                        value_bytes_total        <= value_bytes_total        + current_value_len;
                        last_key_len             <= current_key_len;
                        last_value_len           <= current_value_len;
                        last_shared_bytes        <= current_shared_len;
                        last_non_shared_bytes    <= current_unshared_len;
                        prev_key_len             <= current_key_len;
                        prev_buf_sel             <= ~prev_buf_sel;
                        entries_since_restart    <= entries_since_restart + 32'd1;
                        state                    <= ST_WAIT_RECORD;
                    end else if (input_accept) begin
                        // input_accept already gates on can_emit via s_axis_tready
                        if (block_write_index >= MAX_BLOCK_BYTES) begin
                            busy  <= 1'b0; error <= 1'b1; state <= ST_IDLE;
                        end else begin
                            emit_byte <= s_axis_tdata;
                            emit_valid <= 1'b1;
                            block_write_index <= block_write_index + 32'd1;
                            value_rem         <= value_rem - 32'd1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Stream restart offset array directly to output.
                ST_APPEND_RESTARTS: begin
                    if (restart_emit_idx < restart_count) begin
                        if (can_emit) begin
                            emit_byte <= fixed32_get_byte(
                                            restart_offset_mem[restart_emit_idx],
                                            fixed32_byte_idx);
                            emit_valid <= 1'b1;
                            block_write_index <= block_write_index + 32'd1;
                            if (fixed32_byte_idx == 2'd3) begin
                                fixed32_byte_idx <= 2'd0;
                                restart_emit_idx <= restart_emit_idx + 32'd1;
                            end else begin
                                fixed32_byte_idx <= fixed32_byte_idx + 2'd1;
                            end
                        end
                    end else begin
                        fixed32_byte_idx <= 2'd0;
                        state            <= ST_APPEND_RST_CNT;
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Stream restart count (fixed32) directly; tlast on last byte.
                ST_APPEND_RST_CNT: begin
                    if (can_emit) begin
                        emit_byte <= fixed32_get_byte(restart_count, fixed32_byte_idx);
                        emit_valid <= 1'b1;
                        block_write_index <= block_write_index + 32'd1;
                        if (fixed32_byte_idx == 2'd3) begin
                            emit_last <= 1'b1;
                            // Set output_block_bytes = total bytes emitted
                            output_block_bytes <= block_write_index + 32'd1;
                            state <= ST_FINISH;
                        end else begin
                            fixed32_byte_idx <= fixed32_byte_idx + 2'd1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // OPT-2C: Wait for the last byte (with tlast) to be accepted.
                ST_FINISH: begin
                    if (!emit_valid) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
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
