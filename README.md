# SC520 MIPI Camera → HDMI (Anlogic PH1P35)

基于 Anlogic PH1P35 的 MIPI 摄像头实时图像采集、处理与 HDMI 显示工程，
含帧延迟测量 OSD（advanced requirement 3）。

> 摄像头：SmartSens **SC520**，MIPI CSI-2 2-lane，RAW10 **1280×720**
> 输出：HDMI 1080p（经 DDR 帧缓冲）
> 工具链：Anlogic **TD 6.2.1 SP1**（`PH1P35MDG324`, speed `-3`）

---

## 功能

| 功能 | 说明 |
|---|---|
| MIPI CSI-2 接收 | 2-lane，PH1P MIPIIO 硬核，RAW10 解包 |
| Bayer 去马赛克 | 双线性插值，**BGGR** 阵列，4 像素/时钟 |
| 自动白平衡 | 灰世界 + 增益微调 |
| 低照度增强 | Gamma 0.7 + 高光滚降 |
| 色彩增强 | 色度死区增益（避免偏色） |
| 降噪 / 锐化 | 亮度降噪 + 水平 unsharp |
| 边缘检测 | 厂商边缘模块 + 滞回阈值 |
| 目标检测 | 按行带分割的目标框（`td/`） |
| DDR 帧缓冲 | 乒乓缓冲，平滑帧率 |
| HDMI 输出 | 1080p @ 60Hz |
| **帧延迟 OSD** | 右上角显示 `LAT<n>F` 与 `<ddd>MS`，见 [README_LATENCY_PATCH_v4.md](README_LATENCY_PATCH_v4.md) |
| UDP 图像回传 | 千兆网口推流到 PC（便于调试取帧） |
| UART 图传 / 在线调参 | 板上 FT2232 通道 |

---

## 目录结构

```
.
├── td_project/                     TD 工程与构建脚本
│   ├── camera_to_dsi_display.al    工程文件（源文件清单、约束）
│   ├── camera_to_dsi_display.sdc   时序约束
│   ├── camera_to_dsi_display_inst.bid
│   ├── build_lat.tcl               完整构建脚本（elaborate→route→bitgen）
│   └── al_ip/                      ChipWatcher 调试 IP
└── user_source/
    ├── hdl_source/                 全部 RTL
    │   ├── design_top_wrapper.v    顶层
    │   ├── isp/                    ISP 链（demosaic / AWB / 数据位宽转换）
    │   ├── mipi_dphy_rx/           MIPI D-PHY 接收
    │   ├── ph1p35_ddr/             DDR2 控制器
    │   ├── uics520_cfg/            SC520 传感器 I2C 寄存器表
    │   ├── uiisp_beta/             AE / 图像辅助模块
    │   ├── vtc/                    HDMI 时序控制
    │   └── td/                     目标检测
    ├── ip_source/                  IP 定义（PLL / DDR / FIFO / 分频器 / MCU）
    └── constraints_source/         引脚约束（pin.adc）
```

---

## 编译

需要 Anlogic TD 6.2.1 SP1（器件库 `ph1_35p.db`）。

**方式一：命令行（推荐，工程已带脚本）**

```tcl
# 在 td_project/ 目录下执行
td_commands_prompt
```

```tcl
source build_lat.tcl
```

**方式二：GUI**

TD 中打开 `td_project/camera_to_dsi_display.al`，运行综合 → 布局布线 → 生成比特流。

> ⚠️ `td_project/build_lat.tcl` 里的相对路径以 `td_project/` 为基准
> （`../user_source/...`），**不要把 `user_source/` 这一层目录挪走或压平**，
> 否则工程无法打开。

产物：`td_project/camera_to_dsi_display_lat.bit`

---

## 构建结果（最近一次）

| 项 | 值 |
|---|---|
| Slices | 20,552 / 21,216（**96.87%**） |
| ERAM | 90 / 108 |
| DSP | 34 / 40 |
| Setup WNS | **−2.414 ns**（以太网时钟域，历史遗留问题） |
| Hold WNS | +0.020 ns |

> ⚠️ 资源占用已达 96.87%，**再加逻辑会超限**。
> CCD 以太网域的 −2.414 ns 建立时间违例在本工程引入前就存在。

---

## 已知限制

- **资源几乎用满**：96.87% slices，新增功能需先优化已有逻辑
- **以太网时钟域存在建立时间违例**（−2.414 ns），影响 UDP 回传稳定性，不影响 HDMI 显示
- 目标检测基于**行带颜色统计**，不是形状识别；复杂背景下会误检
- `_lat_v1/`、`_lat_v1_orig/` 为延迟补丁的历史快照，**不参与编译**
- 工程内 `*.bak_*` 为开发期备份，已被 `.gitignore` 排除

---

## 第三方代码与许可

本工程基于米联客（MiLianKe）SC520 摄像头显示例程二次开发。第三方来源：

| 来源 | 用途 | 许可 |
|---|---|---|
| MiLianKe `lab_ex1_mipi_hdmi_SC520` | 原始采集/显示框架、SC520 I2C 配置、demosaic | 厂商例程（仅作学习参考） |
| AMD mini-ISP | 部分 ISP 模块思路与实现 | MIT |
| Anlogic TD IP | PLL / DDR2 / FIFO / 分频器 | 厂商 IP |

原始厂商工程版权归 MiLianKe 所有；本仓库对其增量修改部分按 MIT 发布。

---

## 授权

[MIT License](LICENSE)
