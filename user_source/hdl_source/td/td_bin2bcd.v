//==============================================================================
//  td_bin2bcd.v
//  ---------------------------------------------------------------------------
//  20bit 二进制 -> 6 位 BCD（双倍加三 / double-dabble 移位算法）。
//  每拍完成一次移位迭代，共 20 拍 + 启动/完成握手。坐标、尺寸、面积、计数值
//  都在垂直消隐期串行转换，只占一个 20x24 的移位寄存器组，不含除法器。
//
//      start 之后 busy 拉高，20 拍后 done 输出一拍脉冲，
//      O_bcd 为 6 个 nibble：{d5,d4,d3,d2,d1,d0}，d5 为最高位（十万位）。
//==============================================================================

module td_bin2bcd (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_start,
    input  wire [19:0] I_value,
    output reg         O_busy,
    output reg         O_done,
    output reg  [23:0] O_bcd
);

    reg [19:0] S_bin;
    reg [23:0] S_bcd;
    reg [4:0]  S_it;

    // 逐 nibble 的"加三"修正：nibble >= 5 时 +3
    function [3:0] F_add3;
        input [3:0] n;
        begin
            F_add3 = (n >= 4'd5) ? (n + 4'd3) : n;
        end
    endfunction

    wire [23:0] S_bcd_corr = {
        F_add3(S_bcd[23:20]), F_add3(S_bcd[19:16]), F_add3(S_bcd[15:12]),
        F_add3(S_bcd[11:8]),  F_add3(S_bcd[7:4]),   F_add3(S_bcd[3:0])
    };

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_bin  <= 20'd0;
            S_bcd  <= 24'd0;
            S_it   <= 5'd0;
            O_busy <= 1'b0;
            O_done <= 1'b0;
            O_bcd  <= 24'd0;
        end
        else begin
            O_done <= 1'b0;

            if (I_start && !O_busy) begin
                S_bin  <= I_value;
                S_bcd  <= 24'd0;
                S_it   <= 5'd20;
                O_busy <= 1'b1;
            end
            else if (O_busy) begin
                if (S_it == 5'd0) begin
                    O_busy <= 1'b0;
                    O_done <= 1'b1;
                    O_bcd  <= S_bcd;
                end
                else begin
                    S_bcd <= {S_bcd_corr[22:0], S_bin[19]};
                    S_bin <= {S_bin[18:0], 1'b0};
                    S_it  <= S_it - 5'd1;
                end
            end
        end
    end

endmodule
