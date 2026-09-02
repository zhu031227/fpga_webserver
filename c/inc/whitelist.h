#ifndef _WHITELIST_H_
#define _WHITELIST_H_

#include <stdint.h>
#include "flash_cfg.h"

// mac_whitelist SubBus base address (reg_webserver SubBus range: 0x5000-0x5FFF)
#define WL_SUBBUS_ADDR  0x5000

// Whitelist internal register offsets
#define WL_REG_ENTRY_INDEX      0x00
#define WL_REG_ENTRY_MAC_H      0x01
#define WL_REG_ENTRY_MAC_L      0x02
#define WL_REG_ENTRY_WR         0x03
#define WL_REG_ENTRY_DEL        0x04
#define WL_REG_ENTRY_CLEAR      0x05
#define WL_REG_ENTRY_RD_MAC_H   0x06
#define WL_REG_ENTRY_RD_MAC_L   0x07
#define WL_REG_ENTRY_RD_VALID   0x08
#define WL_REG_ENTRY_FREE_IDX   0x09
#define WL_REG_MAX_ENTRIES      0x0A
#define WL_REG_USED_CNT         0x0B

// Init: load whitelist from Flash
void whitelist_init(void);

// Global control
void whitelist_enable(uint8_t enable);
uint8_t whitelist_is_enabled(void);
void    whitelist_set_default_pass(uint8_t pass);  // wl_ctrl[1]: 白名单禁用时策略 0=全断,1=全放
uint8_t whitelist_get_default_pass(void);

// Entry operations (via SubBus 0x5000 → mac_whitelist BRAM)
int  whitelist_add(uint8_t mac[6]);
int  whitelist_delete(uint8_t index);
int  whitelist_get_entry(uint8_t index, uint8_t mac_out[6]);
void whitelist_clear_all(void);
uint16_t whitelist_get_max_entries(void);
uint16_t whitelist_get_used_count(void);
uint8_t whitelist_get_free_index(void);

// HW BRAM read-back (reads actual BRAM, bypasses software cache)
int      whitelist_hw_read_entry(uint8_t index, uint8_t mac_out[6]);
uint16_t whitelist_hw_get_used_count(void);
uint16_t whitelist_hw_get_max_entries(void);
uint8_t  whitelist_hw_get_free_index(void);
uint16_t whitelist_hw_get_slot_count(void);   // 枚举用物理槽数：mode2=128, mode0=16
int      whitelist_hw_diag(char *buf, int buf_size);

// Flash persistence
int  whitelist_save_to_flash(void);
int  whitelist_load_from_flash(void);

// 供 flash_cfg 层读取/恢复白名单快照（sw cache + wl_ctrl）
void whitelist_get_snapshot(flash_cfg_wl_t *wl);
void whitelist_apply_snapshot(const flash_cfg_wl_t *wl);

#endif
