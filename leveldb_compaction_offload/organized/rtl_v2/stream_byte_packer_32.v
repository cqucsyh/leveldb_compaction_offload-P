`timescale 1ns / 1ps

// OPT-PKR: Variable-tkeep 32-bit byte packer
// Replaces the 32→8→32 serialization path (stream_width_adapter + stream_pack_adapter)
// which limited throughput to 1 byte/cycle.
// This module accepts 32-bit words with variable tkeep (0001..1111, contiguous from LSB)
// and packs them into dense 32-bit words (tkeep always 1111 except final word).
// Throughput: 4 bytes/cycle in steady state.
//
// Uses a 7-byte shift-register accumulator (3 residual max + 4 new max = 7).

module stream_byte_packer_32 (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire [31:0] s_axis_tdata,
    input  wire [3:0]  s_axis_tkeep,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    output wire [31:0] m_axis_tdata,
    output wire [3:0]  m_axis_tkeep,
    output wire        m_axis_tlast,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready
);

    reg [55:0] acc;       // 7-byte accumulator
    reg [2:0]  acc_cnt;   // valid byte count (0..7)
    reg        last_seen; // tlast was accepted, flush remaining

    wire [2:0] in_cnt = {2'b0, s_axis_tkeep[0]} + {2'b0, s_axis_tkeep[1]}
                       + {2'b0, s_axis_tkeep[2]} + {2'b0, s_axis_tkeep[3]};

    // Output when 4+ bytes OR flushing remaining bytes
    assign m_axis_tvalid = (acc_cnt >= 3'd4) || (last_seen && acc_cnt > 3'd0);
    assign m_axis_tdata  = acc[31:0];
    assign m_axis_tkeep  = (acc_cnt >= 3'd4) ? 4'b1111 :
                           (acc_cnt == 3'd3) ? 4'b0111 :
                           (acc_cnt == 3'd2) ? 4'b0011 :
                           (acc_cnt == 3'd1) ? 4'b0001 : 4'b0000;
    assign m_axis_tlast  = last_seen && (acc_cnt <= 3'd4);

    wire output_accept = m_axis_tvalid && m_axis_tready;
    wire [2:0] cnt_after_out = output_accept ?
                               ((acc_cnt >= 3'd4) ? acc_cnt - 3'd4 : 3'd0) : acc_cnt;

    // Accept input when remaining space >= 4 (worst-case input) AND not flushing
    assign s_axis_tready = (cnt_after_out <= 3'd3) && !last_seen;

    wire input_accept = s_axis_tvalid && s_axis_tready;

    // Compute next accumulator state combinationally
    reg [55:0] next_acc;
    reg [2:0]  next_cnt;

    always @(*) begin
        // Phase 1: after potential output (shift right by 4 bytes)
        if (output_accept) begin
            next_acc = {24'd0, acc[55:32]};
            next_cnt = cnt_after_out;
        end else begin
            next_acc = acc;
            next_cnt = acc_cnt;
        end

        // Phase 2: insert input valid bytes at next_cnt position
        if (input_accept) begin
            case (next_cnt)
                3'd0: begin
                    if (s_axis_tkeep[0]) next_acc[7:0]   = s_axis_tdata[7:0];
                    if (s_axis_tkeep[1]) next_acc[15:8]  = s_axis_tdata[15:8];
                    if (s_axis_tkeep[2]) next_acc[23:16] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[31:24] = s_axis_tdata[31:24];
                end
                3'd1: begin
                    if (s_axis_tkeep[0]) next_acc[15:8]  = s_axis_tdata[7:0];
                    if (s_axis_tkeep[1]) next_acc[23:16] = s_axis_tdata[15:8];
                    if (s_axis_tkeep[2]) next_acc[31:24] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[39:32] = s_axis_tdata[31:24];
                end
                3'd2: begin
                    if (s_axis_tkeep[0]) next_acc[23:16] = s_axis_tdata[7:0];
                    if (s_axis_tkeep[1]) next_acc[31:24] = s_axis_tdata[15:8];
                    if (s_axis_tkeep[2]) next_acc[39:32] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[47:40] = s_axis_tdata[31:24];
                end
                3'd3: begin
                    if (s_axis_tkeep[0]) next_acc[31:24] = s_axis_tdata[7:0];
                    if (s_axis_tkeep[1]) next_acc[39:32] = s_axis_tdata[15:8];
                    if (s_axis_tkeep[2]) next_acc[47:40] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[55:48] = s_axis_tdata[31:24];
                end
                default: ; // shouldn't happen (cnt_after_out <= 3 guaranteed)
            endcase
            next_cnt = next_cnt + in_cnt;
        end
    end

    always @(posedge clk) begin
        if (!rstn || clear) begin
            acc       <= 56'd0;
            acc_cnt   <= 3'd0;
            last_seen <= 1'b0;
        end else begin
            acc     <= next_acc;
            acc_cnt <= next_cnt;
            if (input_accept && s_axis_tlast)
                last_seen <= 1'b1;
            if (output_accept && m_axis_tlast)
                last_seen <= 1'b0;
        end
    end

endmodule
