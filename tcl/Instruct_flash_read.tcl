# 读 flash @ 0x400000 的一个字
# 0x03(Read) + 24bit 地址 + 32bit 数据 = 64 bits
spi_tx 0x03400000 0x0 64

# 读回（地址 3 = spi_word_get）
set rd [jread [expr {$SFLASH_BASE + 0x3}]]
puts [format "read @ 0x400000 = 0x%08X" $rd]
