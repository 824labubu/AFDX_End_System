`timescale 1ns / 1ps

// 检查应用字节流的反压保持和报文元信息稳定性。
module app_stream_assertions (
    input wire clk,
    input wire reset_n,
    input wire [7:0] data,
    input wire valid,
    input wire ready,
    input wire last,
    input wire [15:0] src_udp,
    input wire [15:0] dst_udp,
    input wire [7:0] application_port
);
    reg stalled;
    reg message_active;
    reg [48:0] held_beat;
    reg [39:0] held_metadata;
    wire [48:0] current_beat = {data, last, src_udp, dst_udp, application_port};
    wire [39:0] current_metadata = {src_udp, dst_udp, application_port};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stalled <= 0;
            message_active <= 0;
            held_beat <= 0;
            held_metadata <= 0;
        end else begin
            if ((^{valid, ready, last}) === 1'bx)
                $fatal(1, "stream control contains X/Z");
            if (last && !valid)
                $fatal(1, "last without valid");
            if (valid && (^current_beat) === 1'bx)
                $fatal(1, "valid stream beat contains X/Z");
            if (stalled && (!valid || current_beat !== held_beat))
                $fatal(1, "stream beat changed under backpressure");
            if (valid) begin
                if (message_active && current_metadata !== held_metadata)
                    $fatal(1, "metadata changed within message");
                held_metadata <= current_metadata;
                message_active <= !(ready && last);
            end
            stalled <= valid && !ready;
            held_beat <= current_beat;
        end
    end
endmodule
