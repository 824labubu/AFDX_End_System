// Single-session, octet-mode TFTP server over complete UDP payloads.
// DATA 完成 TID 和块号校验后才逐字节写入文件。
module app_tftp_615a #(
    parameter integer CLK_FREQ_HZ = 0,  // TBD: supply at integration
    parameter integer TFTP_TIMEOUT_MS = 1000,
    parameter integer TFTP_DALLY_MS = 1000,
    parameter integer TFTP_RETRY_LIMIT = 3,
    parameter integer FILE_ADDR_WIDTH = 1,  // TBD: supply at integration
    parameter integer MAX_FILE_BYTES = 0  // TBD: supply at integration
) (
    input wire clk,
    input wire reset_n,
    input wire [15:0] cfg_local_tid,
    input wire [7:0] rx_data,
    input wire rx_valid,
    input wire rx_last,
    input wire [15:0] rx_src_udp,
    input wire [15:0] rx_dst_udp,
    output wire [7:0] app_tx_data,
    output wire app_tx_valid,
    input wire app_tx_ready,
    output wire app_tx_last,
    output reg [15:0] app_tx_src_udp,
    output reg [15:0] app_tx_dst_udp,
    output reg file_wr_en,
    output reg [FILE_ADDR_WIDTH-1:0] file_wr_addr,
    output reg [7:0] file_wr_data,
    output reg file_commit,
    output reg [31:0] file_written_size,
    output reg file_rd_req,
    output reg [FILE_ADDR_WIDTH-1:0] file_rd_addr,
    input wire [7:0] file_rd_data,
    input wire file_rd_valid,
    input wire [31:0] file_size,
    output reg session_valid,
    output reg timeout_error
);
    localparam integer BLOCK_SIZE = 512;
    localparam integer MAX_PACKET = 516;
    localparam [15:0] SERVER_PORT = 16'd69;
    localparam [63:0] TIMEOUT_CYCLES = (64'd1 * CLK_FREQ_HZ * TFTP_TIMEOUT_MS) / 1000;
    localparam [63:0] DALLY_CYCLES = (64'd1 * CLK_FREQ_HZ * TFTP_DALLY_MS) / 1000;
    localparam [3:0] S_IDLE=0, S_RX_DATA=1, S_RX_ACK=2, S_WRITE=3,
                     S_FILE_REQ=4, S_FILE_WAIT=5, S_TX=6, S_DALLY=7;
    reg [3:0] state, after_tx;
    reg [7:0] rx_mem[0:MAX_PACKET-1];
    reg [7:0] tx_mem[0:MAX_PACKET-1];
    reg [9:0] rx_count, rx_length, tx_length, tx_index;
    reg rx_overflow, rx_complete;
    reg [15:0] packet_src_udp, packet_dst_udp;
    reg [15:0] local_tid, remote_tid, block_number;
    reg [31:0] file_offset;
    reg [9:0] data_bytes, write_index, read_index;
    reg final_block;
    reg [63:0] timer;
    reg [7:0] retry_count;
    integer k;
    integer name_end;
    reg request_valid;
    reg [15:0] opcode, incoming_block;

    assign app_tx_valid = (state == S_TX);
    assign app_tx_data = tx_mem[tx_index];
    assign app_tx_last = app_tx_valid && (tx_index == tx_length - 1'b1);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= S_IDLE;
            after_tx <= S_IDLE;
            rx_count <= 0;
            rx_length <= 0;
            rx_overflow <= 0;
            rx_complete <= 0;
            packet_src_udp <= 0;
            packet_dst_udp <= 0;
            tx_length <= 0;
            tx_index <= 0;
            app_tx_src_udp <= 0;
            app_tx_dst_udp <= 0;
            local_tid <= 0;
            remote_tid <= 0;
            block_number <= 0;
            file_offset <= 0;
            data_bytes <= 0;
            write_index <= 0;
            read_index <= 0;
            final_block <= 0;
            timer <= 0;
            retry_count <= 0;
            file_wr_en <= 0;
            file_wr_addr <= 0;
            file_wr_data <= 0;
            file_commit <= 0;
            file_written_size <= 0;
            file_rd_req <= 0;
            file_rd_addr <= 0;
            session_valid <= 0;
            timeout_error <= 0;
        end else begin
            file_wr_en <= 0;
            file_commit <= 0;
            file_rd_req <= 0;
            timeout_error <= 0;
            // 缓存完整 UDP 载荷及其端口，并标记超长报文。
            if (rx_valid) begin
                if (rx_count < MAX_PACKET)
                    rx_mem[rx_count] <= rx_data;
                else
                    rx_overflow <= 1;
                if (rx_count < MAX_PACKET + 1)
                    rx_count <= rx_count + 1'b1;
                if (rx_last) begin
                    rx_length <= rx_count + 1'b1;
                    packet_src_udp <= rx_src_udp;
                    packet_dst_udp <= rx_dst_udp;
                    rx_complete <= !rx_overflow && (rx_count < MAX_PACKET);
                    rx_count <= 0;
                    rx_overflow <= 0;
                end
            end

            // 按握手发送缓存报文，结束后进入指定等待状态。
            if (state == S_TX) begin
                if (app_tx_ready) begin
                    if (app_tx_last) begin
                        tx_index <= 0;
                        state <= after_tx;
                        timer <= 0;
                    end else
                        tx_index <= tx_index + 1'b1;
                end
            end else if (rx_complete) begin
                rx_complete <= 0;
                opcode = {rx_mem[0], rx_mem[1]};
                incoming_block = {rx_mem[2], rx_mem[3]};
                if (state == S_IDLE && packet_dst_udp == SERVER_PORT &&
                    (opcode == 16'd1 || opcode == 16'd2) && rx_length >= 9) begin
                    // 校验以 NUL 分隔的文件名和 octet 模式。
                    name_end = -1;
                    for (k = 2; k < MAX_PACKET; k = k + 1)
                        if (k < rx_length && rx_mem[k] == 0 && name_end == -1)
                            name_end = k;
                    request_valid = (name_end >= 3 && name_end <= 66 &&
                                     rx_length == name_end + 7 &&
                                     rx_mem[name_end+1] == 8'h6f &&
                                     rx_mem[name_end+2] == 8'h63 &&
                                     rx_mem[name_end+3] == 8'h74 &&
                                     rx_mem[name_end+4] == 8'h65 &&
                                     rx_mem[name_end+5] == 8'h74 &&
                                     rx_mem[name_end+6] == 0 &&
                                     cfg_local_tid != 0 &&
                                     cfg_local_tid != SERVER_PORT);
                    // 有效请求锁存双方 TID，并初始化读写会话。
                    if (request_valid) begin
                        session_valid <= 1;
                        local_tid <= cfg_local_tid;
                        remote_tid <= packet_src_udp;
                        app_tx_src_udp <= cfg_local_tid;
                        app_tx_dst_udp <= packet_src_udp;
                        file_offset <= 0;
                        file_written_size <= 0;
                        retry_count <= 0;
                        if (opcode == 16'd2) begin
                            block_number <= 0;
                            tx_mem[0] <= 0;
                            tx_mem[1] <= 4;
                            tx_mem[2] <= 0;
                            tx_mem[3] <= 0;
                            tx_length <= 4;
                            after_tx <= S_RX_DATA;
                            state <= S_TX;
                        end else if (MAX_FILE_BYTES != 0 && file_size <= MAX_FILE_BYTES) begin
                            block_number <= 1;
                            tx_mem[0] <= 0;
                            tx_mem[1] <= 3;
                            tx_mem[2] <= 0;
                            tx_mem[3] <= 1;
                            read_index <= 0;
                            data_bytes <= (file_size > BLOCK_SIZE) ? BLOCK_SIZE : file_size;
                            final_block <= (file_size < BLOCK_SIZE);
                            state <= S_FILE_REQ;
                        end else begin
                            session_valid <= 0;
                        end
                    end
                end else if (session_valid && packet_src_udp == remote_tid &&
                             packet_dst_udp == local_tid && rx_length >= 4) begin
                    if ((state == S_RX_DATA || state == S_DALLY) && opcode == 16'd3) begin
                        if (incoming_block == block_number + 1'b1 &&
                            state == S_RX_DATA && rx_length <= MAX_PACKET &&
                            MAX_FILE_BYTES != 0 &&
                            file_offset + rx_length - 4 <= MAX_FILE_BYTES) begin
                            data_bytes <= rx_length - 4;
                            write_index <= 0;
                            block_number <= incoming_block;
                            final_block <= (rx_length - 4 < BLOCK_SIZE);
                            state <= S_WRITE;
                        end else if (incoming_block == block_number) begin
                            // 重复 DATA 仅重发上次 ACK，不重复写文件。
                            tx_index <= 0;
                            state <= S_TX;
                            after_tx <= (state == S_DALLY) ? S_DALLY : S_RX_DATA;
                        end
                    end else if (state == S_RX_ACK && opcode == 16'd4 &&
                                 incoming_block == block_number) begin
                        retry_count <= 0;
                        if (final_block) begin
                            session_valid <= 0;
                            state <= S_IDLE;
                        end else begin
                            file_offset <= file_offset + data_bytes;
                            block_number <= block_number + 1'b1;
                            tx_mem[0] <= 0;
                            tx_mem[1] <= 3;
                            tx_mem[2] <= (block_number + 1'b1) >> 8;
                            tx_mem[3] <= block_number + 1'b1;
                            read_index <= 0;
                            data_bytes <= ((file_size - file_offset - data_bytes) > BLOCK_SIZE) ?
                                          BLOCK_SIZE : (file_size - file_offset - data_bytes);
                            final_block <= ((file_size - file_offset - data_bytes) < BLOCK_SIZE);
                            state <= S_FILE_REQ;
                        end
                    end else if (opcode == 16'd5) begin
                        session_valid <= 0;
                        state <= S_IDLE;
                    end
                end
            end else begin
                case (state)
                    // 顺序写入 DATA 内容，短块结束时提交文件并生成 ACK。
                    S_WRITE: begin
                        if (write_index < data_bytes) begin
                            file_wr_en <= 1;
                            file_wr_addr <= file_offset + write_index;
                            file_wr_data <= rx_mem[write_index+4];
                            write_index <= write_index + 1'b1;
                        end else begin
                            file_offset <= file_offset + data_bytes;
                            file_written_size <= file_offset + data_bytes;
                            if (final_block)
                                file_commit <= 1;
                            tx_mem[0] <= 0;
                            tx_mem[1] <= 4;
                            tx_mem[2] <= block_number[15:8];
                            tx_mem[3] <= block_number[7:0];
                            tx_length <= 4;
                            tx_index <= 0;
                            state <= S_TX;
                            after_tx <= final_block ? S_DALLY : S_RX_DATA;
                            retry_count <= 0;
                        end
                    end
                    // 逐字节请求文件数据，块内容齐备后发送 DATA。
                    S_FILE_REQ: begin
                        if (read_index < data_bytes) begin
                            file_rd_req <= 1;
                            file_rd_addr <= file_offset + read_index;
                            state <= S_FILE_WAIT;
                        end else begin
                            tx_length <= 4 + data_bytes;
                            tx_index <= 0;
                            state <= S_TX;
                            after_tx <= S_RX_ACK;
                        end
                    end
                    // 等待文件读数据有效后填充发送缓存。
                    S_FILE_WAIT:
                    if (file_rd_valid) begin
                        tx_mem[read_index+4] <= file_rd_data;
                        read_index <= read_index + 1'b1;
                        state <= S_FILE_REQ;
                    end
                    // 等待超时后重传缓存报文，达到重试上限则终止会话。
                    S_RX_DATA, S_RX_ACK: begin
                        if (TIMEOUT_CYCLES > 0 && timer >= TIMEOUT_CYCLES - 1) begin
                            timer <= 0;
                            if (retry_count < TFTP_RETRY_LIMIT) begin
                                retry_count <= retry_count + 1'b1;
                                tx_index <= 0;
                                after_tx <= state;
                                state <= S_TX;
                            end else begin
                                session_valid <= 0;
                                timeout_error <= 1;
                                state <= S_IDLE;
                            end
                        end else
                            timer <= timer + 1'b1;
                    end
                    // 保留最终 ACK 至等待期结束，以响应重复的最终 DATA。
                    S_DALLY: begin
                        if (DALLY_CYCLES > 0 && timer >= DALLY_CYCLES - 1) begin
                            session_valid <= 0;
                            state <= S_IDLE;
                            timer <= 0;
                        end else
                            timer <= timer + 1'b1;
                    end
                    default: timer <= 0;
                endcase
            end
        end
    end
endmodule
