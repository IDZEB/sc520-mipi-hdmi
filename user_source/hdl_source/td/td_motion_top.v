//==============================================================================
//  td_motion_top.v  --  进阶要求4：帧差法运动检测 + 运动区域叠加
//  ---------------------------------------------------------------------------
//  思路
//  ----
//  摄像头域里逐行累加亮度（每行 320 拍 x 4 像素），行结束时把这一行的亮度和
//  与"上一帧同一行"的值比较，差值超过门限就认为这一行有运动。行剖面只占
//  720 x 16 bit = 1.4 kB 的 RAM，不需要外部帧缓存（DDR 已被视频通路占满）。
//
//  帧边界
//  ------
//  监控口没有 tuser，行宽也不是固定 320 拍，所以用"数据流间隙"判帧：连续
//  3000 拍没有 tvalid 就认为进入新的帧。这是硬件上验证过能工作的方案。
//
//  输出
//  ----
//  与 td_osd_overlay 的 716 位结果总线兼容：
//    box0  = 运动带包围盒（x1=0, x2=1279, y1..y2 = 有运动的行范围）
//    [131:128] = 有运动的行数（饱和到 15），OSD 显示成 "COUNT: n"
//  因此 OSD 会画出横跨画面的运动带 + 计数，无需改动 OSD。
//==============================================================================

module td_motion_top #(
    parameter integer IMG_W      = 1280,
    parameter integer IMG_H      = 720,
    parameter integer PANEL_X    = 8,
    parameter integer PANEL_Y    = 600,
    // 兼容 td_overlay_top 的参数名（本模块不使用）
    parameter integer BAND_H     = 80,
    parameter integer NBAND      = 9,
    parameter [7:0]   P_VMIN     = 8'd48,
    parameter [7:0]   P_CD       = 8'd32,
    parameter [7:0]   P_YD       = 8'd40,
    parameter [7:0]   P_YRG      = 8'd24,
    parameter [7:0]   P_YMIN     = 8'd96,
    parameter [17:0]  P_BAND_MIN = 18'd160,
    parameter [10:0]  P_MIN_W    = 11'd24,
    parameter [10:0]  P_MIN_H    = 11'd24,
    parameter [19:0]  P_MIN_AREA = 20'd600
)(
    input  wire        I_cam_clk,
    input  wire        I_cam_rst_n,
    input  wire        I_cam_tuser,
    input  wire        I_cam_tlast,
    input  wire        I_cam_tvalid,
    input  wire [95:0] I_cam_tdata,

    input  wire        I_pix_clk,
    input  wire        I_pix_rst_n,
    input  wire        I_vsync,
    input  wire        I_hsync,
    input  wire        I_de,
    input  wire [23:0] I_data,
    output wire        O_vsync,
    output wire        O_hsync,
    output wire        O_de,
    output wire [23:0] O_data,

    output wire [3:0]  O_cnt_total,
    output wire        O_det_busy,
    output wire [9:0]  O_cam_y,
    output wire [3:0]  O_cam_band
);

    localparam [15:0]  LP_GAP_MIN  = 16'd3000;   // 空闲拍数超过它就开始新的一帧
    localparam [15:0]  LP_DIFF_MIN = 16'd900;    // 行亮度和的变化超过它就判为运动
    localparam [10:0]  LP_MIN_ROWS = 11'd6;      // 少于这么多行认为是噪声
    localparam integer NL          = 720;

    //--------------------------------------------------------------------------
    //  frame gap detector
    //--------------------------------------------------------------------------
    reg  [15:0] S_gap;
    reg         S_tv_d;
    wire        W_fs = I_cam_tvalid && !S_tv_d && (S_gap >= LP_GAP_MIN);

    always @(posedge I_cam_clk or negedge I_cam_rst_n) begin
        if (!I_cam_rst_n) begin
            S_gap  <= 16'd0;
            S_tv_d <= 1'b0;
        end
        else begin
            S_tv_d <= I_cam_tvalid;
            if (!I_cam_tvalid) S_gap <= (S_gap == 16'hFFFF) ? S_gap : S_gap + 16'd1;
            else           S_gap <= 16'd0;
        end
    end

    //--------------------------------------------------------------------------
    //  per-line luma accumulation
    //--------------------------------------------------------------------------
    wire [11:0] P_l0 = {2'b00, I_cam_tdata[95:88]} + {1'b0, I_cam_tdata[87:80], 1'b0} + {2'b00, I_cam_tdata[79:72]};
    wire [11:0] P_l1 = {2'b00, I_cam_tdata[71:64]} + {1'b0, I_cam_tdata[63:56], 1'b0} + {2'b00, I_cam_tdata[55:48]};
    wire [11:0] P_l2 = {2'b00, I_cam_tdata[47:40]} + {1'b0, I_cam_tdata[39:32], 1'b0} + {2'b00, I_cam_tdata[31:24]};
    wire [11:0] P_l3 = {2'b00, I_cam_tdata[23:16]} + {1'b0, I_cam_tdata[15:8], 1'b0} + {2'b00, I_cam_tdata[7:0]};

    wire [13:0] W_beat_l = P_l0 + P_l1 + P_l2 + P_l3;     // <= 4080
    wire [9:0]  W_beat_s = W_beat_l[13:4];                // /16, <= 255

    reg  [17:0] S_acc;
    reg  [10:0] S_y;
    reg  [10:0] S_xb;

    reg  [15:0] S_line_ram [0:NL-1];

    reg  [10:0] S_y1, S_y2, S_rows;
    reg         S_any;

    reg  [715:0] O_res_r;
    reg          O_res_tog_r;

    wire [17:0] W_acc_next = S_acc + {8'd0, W_beat_s, 4'd0};

    // motion test of the line that just finished
    wire [15:0] W_old  = S_line_ram[S_y];
    wire [17:0] W_new  = S_acc;
    wire [17:0] W_diff = (W_new > {2'b00, W_old}) ? (W_new - {2'b00, W_old})
                                                  : ({2'b00, W_old} - W_new);
    wire        W_move = (W_diff > {2'b00, LP_DIFF_MIN});
    wire        W_emit = (S_rows >= LP_MIN_ROWS);

    always @(posedge I_cam_clk or negedge I_cam_rst_n) begin
        if (!I_cam_rst_n) begin
            S_acc  <= 18'd0;
            S_y    <= 11'd0;
            S_xb   <= 11'd0;
            S_y1   <= 11'd0;
            S_y2   <= 11'd0;
            S_rows <= 11'd0;
            S_any  <= 1'b0;
            O_res_r <= 716'd0;
            O_res_tog_r <= 1'b0;
        end
        else if (W_fs) begin
            // 上一帧的运动带在这里发布，然后清空统计量
            O_res_r <= {
                24'd0,                                                  // [715:692] shapes
                160'd0,                                                 // [691:532] unused
                {W_emit, 2'd0, 11'd0, S_y1, 11'd1279, S_y2, 1'b0},      // [531:484] box0
                336'd0,                                                 // [483:148] box1..7
                4'd0, 4'd0, 4'd0, 4'd0,                                 // [147:132] class counts
                (S_rows >= 11'd15) ? 4'd15 : S_rows[3:0],               // [131:128] count
                128'd0                                                  // [127:0]  BCD
            };
            O_res_tog_r <= ~O_res_tog_r;
            S_acc  <= 18'd0;
            S_y    <= 11'd0;
            S_xb   <= 11'd0;
            S_y1   <= 11'd0;
            S_y2   <= 11'd0;
            S_rows <= 11'd0;
            S_any  <= 1'b0;
        end
        else if (I_cam_tvalid) begin
            S_acc <= W_acc_next;

            if (I_cam_tlast) begin
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
                S_xb  <= 11'd0;
                if (S_y < NL - 1) S_y <= S_y + 11'd1;
            end
            else begin
                S_xb <= S_xb + 11'd1;
            end
        end
    end

    assign O_cam_y    = S_y[9:0];
    assign O_cam_band = S_rows[3:0];
    assign O_det_busy = 1'b0;

    //--------------------------------------------------------------------------
    //  cross to the pixel domain and overlay
    //--------------------------------------------------------------------------
    wire [715:0] W_res_pix;
    wire         W_tog = O_res_tog_r;

    td_res_sync #( .W(716) ) u_res_sync (
        .I_cam_clk  (I_cam_clk),
        .I_cam_rst_n(I_cam_rst_n),
        .I_res      (O_res_r),
        .I_tog      (W_tog),
        .I_pix_clk  (I_pix_clk),
        .I_pix_rst_n(I_pix_rst_n),
        .I_vsync    (I_vsync),
        .I_update_now(1'b0),
        .O_res      (W_res_pix),
        .O_update   ()
    );

    td_osd_overlay #(
        .IMG_W  (IMG_W),
        .IMG_H  (IMG_H),
        .PANEL_X(PANEL_X),
        .PANEL_Y(PANEL_Y)
    ) u_osd (
        .I_clk      (I_pix_clk),
        .I_rst_n    (I_pix_rst_n),
        .I_vsync    (I_vsync),
        .I_hsync    (I_hsync),
        .I_de       (I_de),
        .I_data     (I_data),
        .I_res      (W_res_pix),
        .O_vsync    (O_vsync),
        .O_hsync    (O_hsync),
        .O_de       (O_de),
        .O_data     (O_data),
        .O_cnt_total(O_cnt_total)
    );

endmodule
