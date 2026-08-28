#ifndef _FLASH_CFG_H_
#define _FLASH_CFG_H_

#include <stdint.h>

// ============================================================
// Flash 配置持久化 — 本机配置 + MAC 白名单存 SPI Flash 0xC20000
// ------------------------------------------------------------
// 写路径：RISC-V → lcpu_sflash(SubBus 0x4000) → SPI Flash
//   （WREN 0x06 → Sector Erase 0x20 → Page Program 0x02 → RDSR 0x05 轮询）
// 读路径：RISC-V → flash_mem_reader(0x90000000 内存映射) → SPI Flash
//   0x90000000 + 0xC20000 = 0x90C20000
// 字节序：lcpu_sflash 写是 MSB-first（word MSB 落 flash 低地址），flash_mem_reader
//   读做了 32bit 字节交换（flash 低地址落 word 字节 0，小端）。故保存时每个 word
//   先 bswap32 再写，读回就得到原生 word。
// ============================================================

// Flash 配置区基址（独占 1 个 4KB 扇区 0xC20000~0xC20FFF）
#define FLASH_CFG_BASE      0x00C20000u
#define FLASH_CFG_MAGIC     0x43474643u  // "CFGC"（magic 校验）
#define FLASH_CFG_VERSION   1u

#define FLASH_CFG_WL_MAX    16

// 配置区 word 布局（共 10 + 16*2 = 42 字 = 168 字节）
#define FLASH_CFG_W_MAGIC   0
#define FLASH_CFG_W_VERSION 1
#define FLASH_CFG_W_CSUM    2   // word[3..41] 的 32bit 加和
#define FLASH_CFG_W_MAC_H   3   // mac[0..3]，mac[0] 在 MSB
#define FLASH_CFG_W_MAC_L   4   // (mac[4]<<8)|mac[5]
#define FLASH_CFG_W_IP      5
#define FLASH_CFG_W_NETMASK 6
#define FLASH_CFG_W_GATEWAY 7
#define FLASH_CFG_W_WL_CTRL 8   // bit0=enable, bit1=default_pass
#define FLASH_CFG_W_WL_MASK 9   // bit i = entry i 有效
#define FLASH_CFG_W_WL_BASE 10  // 16 条 × 2 字（mac_h, mac_l）
#define FLASH_CFG_NUM_WORDS (FLASH_CFG_W_WL_BASE + FLASH_CFG_WL_MAX * 2)

// 本机配置快照
typedef struct {
    uint32_t mac_h;      // mac[0..3]
    uint32_t mac_l;      // mac[4..5]
    uint32_t ip;
    uint32_t netmask;
    uint32_t gateway;
} flash_cfg_local_t;

// 白名单快照
typedef struct {
    uint32_t ctrl;                       // bit0=enable, bit1=default_pass
    uint16_t valid_mask;                 // bit i = entry i 有效
    uint32_t mac_h[FLASH_CFG_WL_MAX];    // entry i mac[0..3]
    uint32_t mac_l[FLASH_CFG_WL_MAX];    // entry i mac[4..5]
} flash_cfg_wl_t;

// 保存：擦 0xC20000 扇区 + 写本机配置 + 白名单。返回 0 成功，非 0 失败。
int flash_cfg_save(const flash_cfg_local_t *lc, const flash_cfg_wl_t *wl);

// 加载：读 flash + 校验 magic/checksum。返回 0 成功（快照有效），非 0 表示无有效配置。
int flash_cfg_load(flash_cfg_local_t *lc, flash_cfg_wl_t *wl);

#endif /* _FLASH_CFG_H_ */
