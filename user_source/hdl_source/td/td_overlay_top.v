//==============================================================================
//  td_overlay_top.v
//  ---------------------------------------------------------------------------
//  扩展要求2 的"单一集成点"：一个模块同时接入两路信号
//    (1) 摄像头域：ISP 96bit 输出监视口（只读）
//    (2) 像素域：hdmi_mixer 输出（vs/hs/de/data），叠加后送去 hdmi_tx
//  内部完成：颜色分类 -> 分带统计 -> 目标分割 -> 形状判别 -> BCD 编码
//           -> 跨时钟域 -> 检测框 + 信息面板叠加
//
//  与原有工程的耦合只有 5 根监视线 + 1 段视频通路，不改动 MIPI/ISP/DDR/HDMI
//  任何时序，因此对基础要求 1/2/3/4 的功能没有影响。
//==============================================================================

module td_overlay_top #(
    parameter integer IMG_W      = 1280,
    parameter integer IMG_H      = 720,
    parameter integer BAND_H     = 80,
    parameter integer NBAND      = 9,
    // 颜色阈值（可在此处或上层直接改）
    parameter [7:0]   P_VMIN     = 8'd48,
    parameter [7:0]   P_CD       = 8'd32,
    parameter [7:0]   P_YD       = 8'd40,
    parameter [7:0]   P_YRG      = 8'd24,
    parameter [7:0]   P_YMIN     = 8'd96,
    parameter [17:0]  P_BAND_MIN = 18'd160,
    parameter [10:0]  P_MIN_W    = 11'd24,
    parameter [10:0]  P_MIN_H    = 11'd24,
    parameter [19:0]  P_MIN_AREA = 20'd600,
    // 面板位置
    parameter integer PANEL_X    = 8,
    parameter integer PANEL_Y    = 600
)(
    // ---- 摄像头/ISP 域（监视口） ----
    input  wire        I_cam_clk,
    input  wire        I_cam_rst_n,
    input  wire        I_cam_tuser,
    input  wire        I_cam_tlast,
    input  wire        I_cam_tvalid,
    input  wire [95:0] I_cam_tdata,

    // ---- HDMI 像素域（视频通路） ----
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

    // ---- 观测 ----
    output wire [3:0]  O_cnt_total,
    output wire        O_det_busy,
    output wire [9:0]  O_cam_y,
    output wire [3:0]  O_cam_band
);

    wire [715:0] W_res;
    wire         W_tog;
    wire [715:0] W_res_pix;

    td_detector #(
        .IMG_W       (IMG_W),
        .IMG_H       (IMG_H),
        .BAND_H      (BAND_H),
        .NBAND       (NBAND),
        .P_VMIN      (P_VMIN),
        .P_CD        (P_CD),
        .P_YD        (P_YD),
        .P_YRG       (P_YRG),
        .P_YMIN      (P_YMIN),
        .P_BAND_MIN  (P_BAND_MIN),
        .P_MIN_W     (P_MIN_W),
        .P_MIN_H     (P_MIN_H),
        .P_MIN_AREA  (P_MIN_AREA)
    ) u_detector (
        .I_clk     (I_cam_clk),
        .I_rst_n   (I_cam_rst_n),
        .I_tuser   (I_cam_tuser),
        .I_tlast   (I_cam_tlast),
        .I_tvalid  (I_cam_tvalid),
        .I_tdata   (I_cam_tdata),
        .O_res     (W_res),
        .O_res_tog (W_tog),
        .O_cur_y   (O_cam_y),
        .O_cur_band(O_cam_band),
        .O_busy    (O_det_busy)
    );

    td_res_sync #( .W(716) ) u_res_sync (
        .I_cam_clk  (I_cam_clk),
        .I_cam_rst_n(I_cam_rst_n),
        .I_res      (W_res),
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
