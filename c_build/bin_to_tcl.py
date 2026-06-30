#!/usr/bin/env python3
"""
bin_to_tcl.py — Convert padded firmware binary to TCL jwrite script.

Usage: python3 bin_to_tcl.py <firmware_pads.bin> <output.tcl> <base_addr> <reset_addr>
Example: python3 bin_to_tcl.py out/firmware_pads.bin ../tcl/InstructRAM.tcl 0x8000 0xf
"""

import sys
import pathlib


def bin_to_tcl(bin_file: pathlib.Path, tcl_file: pathlib.Path,
               baseaddr: str, reset_addr: str) -> None:
    data = bin_file.read_bytes()

    # Pad to a multiple of 4 bytes
    remainder = len(data) % 4
    if remainder:
        data += b'\x00' * (4 - remainder)

    # Find the last non-zero word (skip trailing zero padding)
    last_nonzero = -1
    for i in range(len(data) // 4 - 1, -1, -1):
        chunk = data[i*4:i*4+4]
        if any(b != 0 for b in chunk):
            last_nonzero = i
            break

    if last_nonzero < 0:
        print("Warning: firmware binary is all zeros.")
        last_nonzero = 0

    base = int(baseaddr, 16)
    rst_addr = int(reset_addr, 16)  # input is hex (with or without 0x)

    with tcl_file.open('w', encoding='ascii') as f:
        # Start: disable JTAG RAM write (enter config mode)
        f.write(f"jwrite 0x{rst_addr:X} 0x0\n")

        # Write firmware data words (byte-reversed for JTAG little-endian)
        for i in range(last_nonzero + 1):
            chunk = data[i*4:i*4+4]
            reversed_chunk = chunk[::-1]
            hex_string = ''.join(f'{byte:02X}' for byte in reversed_chunk)
            f.write(f"jwrite 0x{base + i:X} 0x{hex_string}\n")

        # End: enable JTAG RAM write (commit, release reset)
        f.write(f"jwrite 0x{rst_addr:X} 0x1\n")

    data_words = last_nonzero + 1
    print(f"  TCL generated: {data_words} words, "
          f"addr 0x{base:X}..0x{base + last_nonzero:X}")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python3 bin_to_tcl.py <input.bin> <output.tcl> <base_addr> <reset_addr>")
        sys.exit(1)

    input_bin = pathlib.Path(sys.argv[1])
    output_tcl = pathlib.Path(sys.argv[2])
    base_addr = sys.argv[3]
    reset_addr = sys.argv[4]

    if not input_bin.exists():
        print(f"Error: input file not found: {input_bin}")
        sys.exit(1)

    bin_to_tcl(input_bin, output_tcl, base_addr, reset_addr)
