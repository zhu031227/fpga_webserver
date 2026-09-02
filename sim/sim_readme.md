# FPGA WebServer 仿真

## 快速开始

```bash
# 快速仿真（无波形）
make

# 带波形仿真
make wave

# 清理
make clean
```

## 波形查看

```bash
gtkwave tb_webserver_verilator.vcd
```

## 依赖

- Verilator 5.x
- gtkwave（波形查看）
