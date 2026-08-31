// flash_cfg.h — 本机配置 + MAC 白名单的 SPI Flash 持久化（v2: A/B 双扇区原子方案）
//
// 2026-08-30 健壮化重构（事故背景：/api/wl/save 写 0xC20000 中途挂死，
// 半写扇区导致之后每次引导 flash_cfg_load 经内存映射窗读扇区时 CPU 假死）：
//   1. 引导读路径彻底绕开 flash_mem_reader 内存映射窗（停等无超时，挂了无法救），
//      改走 lcpu_sflash 控制器寄存器（SubBus 0x4000，可轮询 idle、可超时）
//   2. A/B 双扇区交替保存 + 单调 SEQ，引导取"有效且 SEQ 高"者：
//      单扇区半写毒不死引导，最坏退回默认配置
//   3. 字节序自校准：以 MAGIC 字探测 R_WORD 的 native/bswap 约定
//   4. 引导阶段号写 debug_rw_2(0x12)，JTAG 可见，假死可定位
#ifndef _FLASH_CFG_H_
#define _FLASH_CFG_H_

#include <stdint.h>

// 两个 4KB 扇区：A=0xC20000（历史主扇区），B=0xC21000（2026-08-30 确认空闲）
#define FLASH_CFG_BASE_A    0x00C20000u
#define FLASH_CFG_BASE_B    0x00C21000u

#define FLASH_CFG_MAGIC     0x43474643u  // "CFGC"
#define FLASH_CFG_VERSION   2u           // v2: 布局加了 SEQ 字
#define FLASH_CFG_SEQ_INVALID 0xFFFFFFFFu

#define FLASH_CFG_WL_MAX    16

// 单扇区记录 word 布局（共 11 + 16*2 = 43 字 = 172 字节）
#define FLASH_CFG_W_MAGIC   0
#define FLASH_CFG_W_VERSION 1
#define FLASH_CFG_W_CSUM    2   // word[3..42] 的 32bit 加和（含 SEQ）
#define FLASH_CFG_W_SEQ     3   // 单调递增保存序号（0xFFFFFFFF 视为无效）
#define FLASH_CFG_W_MAC_H   4   // mac[0..3]，mac[0] 在 MSB
#define FLASH_CFG_W_MAC_L   5   // (mac[4]<<8)|mac[5]
#define FLASH_CFG_W_IP      6
#define FLASH_CFG_W_NETMASK 7
#define FLASH_CFG_W_GATEWAY 8
#define FLASH_CFG_W_WL_CTRL 9   // bit0=enable, bit1=default_pass
#define FLASH_CFG_W_WL_MASK 10  // bit i = entry i 有效
#define FLASH_CFG_W_WL_BASE 11  // 16 条 × 2 字（mac_h, mac_l）
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

// 保存：择空闲/较旧扇区写入 + 回读校验。返回 0 成功，非 0 失败（不覆盖另一份好副本）。
int flash_cfg_save(const flash_cfg_local_t *lc, const flash_cfg_wl_t *wl);

// 加载：A/B 双扇区经 sflash 寄存器超时读，取有效且 SEQ 高者。全无效返回 -1。
int flash_cfg_load(flash_cfg_local_t *lc, flash_cfg_wl_t *wl);

// 单字读（P3 页面读迁移用, 2026-08-31）：经 lcpu_sflash 寄存器路径，带超时，绝不挂死。
// *raw 为 R_WORD 原样值（native/bswap 由调用方以 MAGIC 自校准）。返回 0 成功，-1 超时。
int flash_cfg_read_word(uint32_t flash_addr, uint32_t *raw);

#endif /* _FLASH_CFG_H_ */
