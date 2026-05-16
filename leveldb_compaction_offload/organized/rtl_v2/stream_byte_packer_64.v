`timescale 1ns / 1ps

// P7: Variable-tkeep 64-bit byte packer
// Accepts 64-bit words with variable tkeep (contiguous from LSB, 1-8 valid bytes)
// and packs them into dense 64-bit words (tkeep always 11111111 except final word).
// Throughput: 8 bytes/cycle in steady state.
//
// Uses a 15-byte shift-register accumulator (7 residual max + 8 new max = 15).
// Pipeline-friendly: single always block, no deep combinational chains.

module stream_byte_packer_64 (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire [63:0]  s_axis_tdata,
    input  wire [7:0]   s_axis_tkeep,
    input  wire         s_axis_tlast,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    output wire [63:0]  m_axis_tdata,
    output wire [7:0]   m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready
);

    reg [119:0] acc;       // 15-byte accumulator
    reg [3:0]   acc_cnt;   // valid byte count (0..15)
    reg         last_seen; // tlast was accepted, flush remaining

    // Input byte count (popcount of tkeep)
    wire [3:0] in_cnt = {3'b0, s_axis_tkeep[0]} + {3'b0, s_axis_tkeep[1]}
                       + {3'b0, s_axis_tkeep[2]} + {3'b0, s_axis_tkeep[3]}
                       + {3'b0, s_axis_tkeep[4]} + {3'b0, s_axis_tkeep[5]}
                       + {3'b0, s_axis_tkeep[6]} + {3'b0, s_axis_tkeep[7]};

    // Output when 8+ bytes OR flushing remaining bytes
    assign m_axis_tvalid = (acc_cnt >= 4'd8) || (last_seen && acc_cnt > 4'd0);
    assign m_axis_tdata  = acc[63:0];
    assign m_axis_tkeep  = (acc_cnt >= 4'd8) ? 8'hff :
                           (acc_cnt >= 4'd7) ? 8'h7f :
                           (acc_cnt >= 4'd6) ? 8'h3f :
                           (acc_cnt >= 4'd5) ? 8'h1f :
                           (acc_cnt >= 4'd4) ? 8'h0f :
                           (acc_cnt >= 4'd3) ? 8'h07 :
                           (acc_cnt >= 4'd2) ? 8'h03 :
                           (acc_cnt >= 4'd1) ? 8'h01 : 8'h00;
    assign m_axis_tlast  = last_seen && (acc_cnt <= 4'd8);

    wire output_accept = m_axis_tvalid && m_axis_tready;
    wire [3:0] cnt_after_out = output_accept ?
                               ((acc_cnt >= 4'd8) ? acc_cnt - 4'd8 : 4'd0) : acc_cnt;

    // Accept input when remaining space >= 8 (worst-case input) AND not flushing
    assign s_axis_tready = (cnt_after_out <= 4'd7) && !last_seen;

    wire input_accept = s_axis_tvalid && s_axis_tready;

    // Compute next accumulator state combinationally
    reg [119:0] next_acc;
    reg [3:0]   next_cnt;

    always @(*) begin
        // Phase 1: after potential output (shift right by 8 bytes)
        if (output_accept) begin
            next_acc = {56'd0, acc[119:64]};
            next_cnt = cnt_after_out;
        end else begin
            next_acc = acc;
            next_cnt = acc_cnt;
        end

        // Phase 2: insert input valid bytes at next_cnt position
        if (input_accept) begin
            // Barrel-shift input bytes into accumulator at byte position next_cnt
            // Unrolled for each possible next_cnt value (0..7)
            case (next_cnt)
                4'd0: begin
                    if (s_axis_tkeep[0]) next_acc[  7:  0] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 15:  8] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 23: 16] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 31: 24] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 39: 32] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 47: 40] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[ 55: 48] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[ 63: 56] = s_axis_tdata[63:56];
                end
                4'd1: begin
                    if (s_axis_tkeep[0]) next_acc[ 15:  8] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 23: 16] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 31: 24] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 39: 32] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 47: 40] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 55: 48] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[ 63: 56] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[ 71: 64] = s_axis_tdata[63:56];
                end
                4'd2: begin
                    if (s_axis_tkeep[0]) next_acc[ 23: 16] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 31: 24] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 39: 32] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 47: 40] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 55: 48] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 63: 56] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[ 71: 64] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[ 79: 72] = s_axis_tdata[63:56];
                end
                4'd3: begin
                    if (s_axis_tkeep[0]) next_acc[ 31: 24] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 39: 32] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 47: 40] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 55: 48] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 63: 56] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 71: 64] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[ 79: 72] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[ 87: 80] = s_axis_tdata[63:56];
                end
                4'd4: begin
                    if (s_axis_tkeep[0]) next_acc[ 39: 32] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 47: 40] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 55: 48] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 63: 56] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 71: 64] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 79: 72] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[ 87: 80] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[ 95: 88] = s_axis_tdata[63:56];
                end
                4'd5: begin
                    if (s_axis_tkeep[0]) next_acc[ 47: 40] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 55: 48] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 63: 56] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 71: 64] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 79: 72] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 87: 80] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[ 95: 88] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[103: 96] = s_axis_tdata[63:56];
                end
                4'd6: begin
                    if (s_axis_tkeep[0]) next_acc[ 55: 48] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 63: 56] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 71: 64] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 79: 72] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 87: 80] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[ 95: 88] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[103: 96] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[111:104] = s_axis_tdata[63:56];
                end
                4'd7: begin
                    if (s_axis_tkeep[0]) next_acc[ 63: 56] = s_axis_tdata[ 7: 0];
                    if (s_axis_tkeep[1]) next_acc[ 71: 64] = s_axis_tdata[15: 8];
                    if (s_axis_tkeep[2]) next_acc[ 79: 72] = s_axis_tdata[23:16];
                    if (s_axis_tkeep[3]) next_acc[ 87: 80] = s_axis_tdata[31:24];
                    if (s_axis_tkeep[4]) next_acc[ 95: 88] = s_axis_tdata[39:32];
                    if (s_axis_tkeep[5]) next_acc[103: 96] = s_axis_tdata[47:40];
                    if (s_axis_tkeep[6]) next_acc[111:104] = s_axis_tdata[55:48];
                    if (s_axis_tkeep[7]) next_acc[119:112] = s_axis_tdata[63:56];
                end
                default: ; // shouldn't happen (cnt_after_out <= 7 guaranteed)
            endcase
            next_cnt = next_cnt + in_cnt;
        end
    end

    always @(posedge clk) begin
        if (!rstn || clear) begin
            acc       <= 120'd0;
            acc_cnt   <= 4'd0;
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
