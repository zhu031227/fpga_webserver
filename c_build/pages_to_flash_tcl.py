#!/usr/bin/env python3
"""
pages_to_flash_tcl.py — 把 Web 页面打包成「TOC + 内容」镜像，生成自包含 TCL
脚本 html_flash_initial.tcl，把页面烧进 SPI Flash 0x420000（erase + program）。

与固件烧写（bin_to_flash_tcl.py → Instruct_flash_initial.tcl）同款 JTAG 写路径：
    PC(JTAG) → LCPU → lcpu_sflash(SubBus 0x4000) → SPI Flash

布局（与 doc/Flash地址划分说明.md、c/inc/web_pages.h 一致）：
    0x420000 扇区 0：TOC（8B 头 + N×16B 条目）
    0x421000 起每页各占一个 4KB 扇区（4KB 对齐，只擦用到的扇区）

TOC 头：magic "WEBP"(4B) + version u16 + count u16
TOC 条目（16B）：route_id u32 | content_type u8 + 3B reserved | offset u32 | length u32

字节序：写入时把 image[0] 放到 word 的 MSB（flash_program_word 是 MSB-first），
配合 flash_mem_reader 硬件的 32bit 字节交换，RISC-V（小端）读回来恰好是自然字节序。

用法：
    python3 pages_to_flash_tcl.py [out_tcl] [flash_addr]
    （默认 out_tcl=../tcl/html_flash_initial.tcl, flash_addr=0x420000）

依赖（Vivado）：source ip_lcpu/tcl/jtag_slib.tcl ; jopen
"""

import pathlib
import sys

# 复用 bin_to_flash_tcl.py 的 TCL 工具函数前导（SFLASH_BASE 0x4000 + flash_* procs）
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from bin_to_flash_tcl import FLASH_INIT_PREAMBLE

SECTOR_SIZE = 0x1000       # 4KB 扇区
WEB_FLASH_ADDR = 0x420000  # Web 页面区基址
RISCV_RESET_ADDR = 0xF     # riscv_reset_l（写 flash 期间保持复位）

HTML_DIR = pathlib.Path(__file__).parent.parent / "html"

# 页面清单：route_id, 文件名（相对 html/）, content_type（见 web_pages.h 枚举）
#   CT_HTML=0, CT_CSS=1, CT_JS=2, CT_PNG=3, CT_SVG=4, CT_ICO=5, CT_JSON=6, CT_PLAIN=7
PAGES = [
    (1, "index.html",       0),   # '/'           → WEB_ROUTE_MAIN
    (2, "wlconfig.html",    0),   # '/wlconfig'   → WEB_ROUTE_WLCONFIG
    (3, "localconfig.html", 0),   # '/localconfig'→ WEB_ROUTE_LOCALCONFIG
]


def pack_word(b: bytes) -> int:
    """把 4 字节（自然序）打包成要写入的 32bit 字：b[0] 放 MSB（MSB-first 写入）。"""
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]


def build_image():
    contents = [(rid, ct, (HTML_DIR / fname).read_bytes()) for rid, fname, ct in PAGES]
    n = len(contents)
    offsets = [SECTOR_SIZE * (i + 1) for i in range(n)]  # 0x1000, 0x2000, ...

    # TOC 字节串（字段小端，配合硬件字节交换后 RISC-V 自然读取）
    toc = bytearray()
    toc += b"WEBP"                       # magic
    toc += (1).to_bytes(2, "little")     # version
    toc += (n).to_bytes(2, "little")     # count
    for i, (rid, ct, data) in enumerate(contents):
        toc += rid.to_bytes(4, "little")
        toc += ct.to_bytes(1, "little")
        toc += b"\x00\x00\x00"           # reserved 3B
        toc += offsets[i].to_bytes(4, "little")
        toc += len(data).to_bytes(4, "little")

    # 程序清单（只编程实际用到的字，4KB 扇区内的空隙保持擦除态 0xFF）
    prog = []  # (flash_byte_addr, word)
    for k in range(0, len(toc), 4):
        prog.append((WEB_FLASH_ADDR + k, pack_word(toc[k:k + 4])))
    for i, (rid, ct, data) in enumerate(contents):
        base = offsets[i]
        nwords = (len(data) + 3) // 4
        for w in range(nwords):
            b = data[w * 4:w * 4 + 4]
            if len(b) < 4:
                b = b + b"\xFF" * (4 - len(b))  # 尾部按擦除态 0xFF 填充
            prog.append((WEB_FLASH_ADDR + base + w * 4, pack_word(b)))

    nsec = 1 + n  # TOC 扇区 + 每页各一个扇区
    return len(toc), nsec, prog


def gen_tcl(out_tcl: pathlib.Path):
    toc_len, nsec, prog = build_image()
    L = []
    L.append("# ============================================================================")
    L.append("# html_flash_initial.tcl — Web 页面写入 SPI Flash 0x420000（TOC + 内容）")
    L.append("# （自包含：TOC + 页面字节内嵌，可拷贝到任意调试电脑独立运行）")
    L.append("# 依赖（Vivado 里先执行）：source ip_lcpu/tcl/jtag_slib.tcl ; jopen")
    L.append("# ============================================================================")
    L.append(FLASH_INIT_PREAMBLE)
    L.append("")
    L.append("# ============ 主流程 ============")
    L.append("")
    L.append("# 1. 复位 RISC-V（写 flash 期间保持复位，防止 CPU 读半截页面）")
    L.append(f"jwrite 0x{RISCV_RESET_ADDR:X} 0x0")
    L.append("delay_ms 10")
    L.append("")
    L.append(f"# 2. 擦除 {nsec} 个 4KB 扇区 @ 0x{WEB_FLASH_ADDR:X}（只擦用到的扇区）")
    for s in range(nsec):
        L.append(f"flash_sector_erase 0x{WEB_FLASH_ADDR + s * SECTOR_SIZE:X}")
    L.append("")
    L.append(f"# 3. 编程 {len(prog)} 个字（TOC {toc_len}B + 页面内容）")
    for addr, word in prog:
        L.append(f"flash_program_word 0x{addr:X} 0x{word:08X}")
    L.append("")
    L.append("# 4. 释放 RISC-V 复位")
    L.append(f"jwrite 0x{RISCV_RESET_ADDR:X} 0x1")
    L.append(f"puts \"  web pages flashed: {len(prog)} words @ 0x{WEB_FLASH_ADDR:X}\"")
    out_tcl.write_text("\n".join(L) + "\n", encoding="utf-8")
    print(f"  Generated: {out_tcl.name} ({len(prog)} words, {nsec} sectors, TOC {toc_len}B)")


if __name__ == "__main__":
    out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
        pathlib.Path(__file__).parent.parent / "tcl" / "html_flash_initial.tcl")
    gen_tcl(out)
