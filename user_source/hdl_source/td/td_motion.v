//==============================================================================
//  td_motion.v  --  进阶要求4：帧差法运动检测（只出结果总线，不含 OSD）
//  ---------------------------------------------------------------------------
//  逐行累加亮度（每行 320 拍 x 4 像素），行结束时与上一帧同一行的亮度和比较，
//  差值超过 LP_DIFF_MIN 就认为这一行有运动。行剖面只有 720 x 16 bit，不需要
//  外部帧缓存。
//
//  帧边界用数据流间隙（3000 拍），与颜色检测器相同的、硬件验证过的方案。
//
//  结果总线与 td_detector 完全兼容：
//    box0 = {valid, cls, x1=0, y1, x2=1279, y2, brt}
//    [131:128] = 有运动的行数（饱和 15）
//==============================================================================

module td_motion #(
    parameter integer IMG_W   = 1280,
    parameter integer IMG_H   = 720
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire         I_tuser,
    input  wire         I_tlast,
    input  wire         I_tvalid,
    input  wire [95:0]  I_tdata,
    output reg  [715:0] O_res,
    output reg          O_res_tog,
    output wire [9:0]   O_cur_y,
    output wire [3:0]   O_cur_band,
    output wire         O_busy
);

    localparam [15:0] LP_GAP_MIN  = 16'd3000;
    localparam [15:0] LP_DIFF_MIN = 16'd900;
    localparam [10:0] LP_MIN_ROWS = 11'd6;
    localparam integer NL         = 720;

    //--------------------------------------------------------------------------
    //  frame gap
    //--------------------------------------------------------------------------
    reg  [15:0] S_gap;
    reg         S_tv_d;
    wire        W_fs = I_tvalid && !S_tv_d && (S_gap >= LP_GAP_MIN);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_gap  <= 16'd0;
            S_tv_d <= 1'b0;
        end
        else begin
            S_tv_d <= I_tvalid;
            if (!I_tvalid) S_gap <= (S_gap == 16'hFFFF) ? S_gap : S_gap + 16'd1;
            else           S_gap <= 16'd0;
        end
    end

    //--------------------------------------------------------------------------
    //  line luma
    //--------------------------------------------------------------------------
    wire [11:0] P_l0 = {2'b00, I_tdata[95:88]} + {1'b0, I_tdata[87:80], 1'b0} + {2'b00, I_tdata[79:72]};
    wire [11:0] P_l1 = {2'b00, I_tdata[71:64]} + {1'b0, I_tdata[63:56], 1'b0} + {2'b00, I_tdata[55:48]};
    wire [11:0] P_l2 = {2'b00, I_tdata[47:40]} + {1'b0, I_tdata[39:32], 1'b0} + {2'b00, I_tdata[31:24]};
    wire [11:0] P_l3 = {2'b00, I_tdata[23:16]} + {1'b0, I_tdata[15:8], 1'b0} + {2'b00, I_tdata[7:0]};

    wire [13:0] W_beat_l = P_l0 + P_l1 + P_l2 + P_l3;
    wire [9:0]  W_beat_s = W_beat_l[13:4];

    reg  [17:0] S_acc;
    reg  [10:0] S_y;
    reg  [10:0] S_xb;
    reg  [15:0] S_line_ram [0:NL-1];

    reg  [10:0] S_y1, S_y2, S_rows;
    reg  [25:0] S_dsum;            // sum of |row delta| over the frame
    reg  [15:0] S_avg;             // scaled mean delta of the previous frame
    reg         S_any;

    wire [17:0] W_acc_next = S_acc + {8'd0, W_beat_s, 4'd0};

    wire [15:0] W_old  = S_line_ram[S_y];
    wire [17:0] W_new  = S_acc;
    wire [17:0] W_diff = (W_new > {2'b00, W_old}) ? (W_new - {2'b00, W_old})
                                                  : ({2'b00, W_old} - W_new);
    wire [17:0] W_thr  = {2'b00, S_avg} + {1'b0, S_avg, 1'b0} + {2'b00, LP_DIFF_MIN};
    wire        W_move = (W_diff > W_thr);
    wire        W_emit = (S_rows >= LP_MIN_ROWS);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_acc   <= 18'd0;
            S_y     <= 11'd0;
            S_xb    <= 11'd0;
            S_y1    <= 11'd0;
            S_y2    <= 11'd0;
            S_rows  <= 11'd0;
            S_any   <= 1'b0;
            S_dsum  <= 26'd0;
            S_avg   <= 16'd0;
            O_res   <= 716'd0;
            O_res_tog <= 1'b0;
        end
        else if (W_fs) begin
            O_res <= {
                24'd0,
                160'd0,
                {W_emit, 2'd0, 11'd0, S_y1, 11'd1279, S_y2, 1'b0},
                336'd0,
                4'd0, 4'd0, 4'd0, 4'd0,
                (S_rows >= 11'd15) ? 4'd15 : S_rows[3:0],
                128'd0
            };
            O_res_tog <= ~O_res_tog;
            S_avg  <= (S_dsum[25:11] > 16'hFFFF) ? 16'hFFFF : S_dsum[25:11];
            S_dsum <= 26'd0;
            S_acc  <= 18'd0;
            S_y    <= 11'd0;
            S_xb   <= 11'd0;
            S_y1   <= 11'd0;
            S_y2   <= 11'd0;
            S_rows <= 11'd0;
            S_any  <= 1'b0;
        end
        else if (I_tvalid) begin
            S_acc <= W_acc_next;

            if (I_tlast) begin
                if (S_y < NL) begin
                    if (W_move) begin
                        if (!S_any) begin
                            S_y1  <= S_y;
                            S_any <= 1'b1;
                        end
                        S_y2   <= S_y;
                        S_rows <= (S_rows >= 11'd15) ? S_rows : (S_rows + 11'd1);
                    end
                    S_line_ram[S_y] <= S_acc[15:0];
                end
                S_acc <= 18'd0;
                S_dsum <= S_dsum + {6'd0, W_diff};
                S_xb  <= 11'd0;
                if (S_y < NL - 1) S_y <= S_y + 11'd1;
            end
            else begin
                S_xb <= S_xb + 11'd1;
            end
        end
    end

    assign O_cur_y    = S_y[9:0];
    assign O_cur_band = S_rows[3:0];
    assign O_busy     = 1'b0;

endmodule
