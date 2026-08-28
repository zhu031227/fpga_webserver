#!/usr/bin/env python3
"""
bin_to_quartus_hex.py — Convert padded firmware binary to Intel HEX format
for Altera/Intel Quartus RAM initialization.

Usage: python3 bin_to_quartus_hex.py <firmware_pads.bin> <output.hex> <bin_size_bytes>
Example: python3 bin_to_quartus_hex.py out/firmware_pads.bin ../rtl/InstructRAM.hex 16384
"""

import sys
import pathlib


def bin_to_quartus_hex(input_bin: pathlib.Path, output_hex: pathlib.Path,
                       depth_words: int, word_bytes: int = 4) -> None:
    data = input_bin.read_bytes()
    required_bytes = depth_words * word_bytes

    # Pad or truncate to exact size
    if len(data) < required_bytes:
        data = data + b"\x00" * (required_bytes - len(data))
    else:
        data = data[:required_bytes]

    record_count = 0
    with output_hex.open('w', encoding='ascii') as f:
        address = 0
        for i in range(0, required_bytes, word_bytes):
            chunk = data[i:i + word_bytes][::-1]  # big-endian → little-endian
            byte_count = len(chunk)
            if byte_count == 0:
                continue

            # Intel HEX record: :BBAAAATTDDDD...DDCC
            record = f":{byte_count:02X}{(address >> 8) & 0xFF:02X}{address & 0xFF:02X}00"
            record += ''.join(f"{b:02X}" for b in chunk)

            # Checksum: two's complement of sum of all bytes
            cksum = byte_count + ((address >> 8) & 0xFF) + (address & 0xFF)
            cksum += sum(chunk)
            cksum = (-cksum) & 0xFF
            record += f"{cksum:02X}\n"

            f.write(record)
            address += 1
            record_count += 1

        # End-of-file record
        f.write(":00000001FF\n")

    print(f"  HEX generated: {record_count} records, {required_bytes} bytes")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python3 bin_to_quartus_hex.py <input.bin> <output.hex> <bin_size_bytes>")
        sys.exit(1)

    input_bin = pathlib.Path(sys.argv[1])
    output_hex = pathlib.Path(sys.argv[2])
    bin_size_bytes = int(sys.argv[3])

    if bin_size_bytes % 4 != 0:
        print("Error: bin_size_bytes must be divisible by 4.")
        sys.exit(1)

    if not input_bin.exists():
        print(f"Error: input file not found: {input_bin}")
        sys.exit(1)

    depth_words = bin_size_bytes // 4
    bin_to_quartus_hex(input_bin, output_hex, depth_words)
