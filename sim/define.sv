// sim/define.sv — 仿真专用宏（代替共享库 define.sv 正本参与仿真编译）
// 目的 1：作为 `include "define.sv"` 的解析目标（iverilog 只搜工作目录与 -I 目录）
// 目的 2：DEVICE_VENDOR 置空 → BRAM 模型走行为级推断分支，避开 XPM 库依赖
// 目的 3：LARGER_RAM 置 "distributed" → 模型几何检查按 depth 定深（"block" 会把
//         EFF_DEPTH 放大到 32768/49=668 深、要求 addr_width≥10，对 16 深小表必
//         $fatal）；行为级读语义不变（仍 1 拍同步读），综合侧仍用 "block"→BlockRAM
// 约束：仅出现在 L1/L2 tb 的 iverilog 命令行里（首个文件 + -I sim）；
//       禁止修改共享库、禁止进 filelist.cfg
`ifndef DEFINE_SV
`define DEFINE_SV
`define DEVICE_VENDOR ""
`define LARGER_RAM  "distributed"
`define SMALL_RAM   "distributed"
`endif
