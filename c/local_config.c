// local_config.c — Local IP/MAC configuration management（flash 持久化）
//
// 启动时 local_config_init() 从 SPI Flash 0xC20000 自动加载本机配置（magic/checksum
// 校验失败则用编译期默认值）；「保存配置」经 local_config_save_to_flash() 把本机配置
// 连同白名单一起写回 Flash（两者共享同一 4KB 扇区）。
#include "inc/lcpu_general.h"
#include "inc/local_config.h"
#include "inc/whitelist.h"

extern uint32 g_local_ip;
extern uint32 g_local_mac_high;
extern uint32 g_local_mac_low;

static local_config_t g_config;

// 用编译期默认值填充 g_config（g_local_* 已在 designApp.c 初始化为默认值）
static void local_config_apply_defaults(void)
{
    g_config.mac[0] = (uint8_t)(g_local_mac_high >> 24);
    g_config.mac[1] = (uint8_t)(g_local_mac_high >> 16);
    g_config.mac[2] = (uint8_t)(g_local_mac_high >> 8);
    g_config.mac[3] = (uint8_t)g_local_mac_high;
    g_config.mac[4] = (uint8_t)(g_local_mac_low >> 8);
    g_config.mac[5] = (uint8_t)g_local_mac_low;
    g_config.ip      = g_local_ip;
    g_config.netmask = 0xFFFFFF00;  // 255.255.255.0 (/24)
    g_config.gateway = (g_local_ip & 0xFFFFFF00) | 0x00000001;  // .1 默认
}

// 把 flash 快照应用到 g_config + HW 寄存器 + 运行时全局
static void local_config_apply(const flash_cfg_local_t *flc)
{
    g_config.mac[0] = (uint8_t)(flc->mac_h >> 24);
    g_config.mac[1] = (uint8_t)(flc->mac_h >> 16);
    g_config.mac[2] = (uint8_t)(flc->mac_h >> 8);
    g_config.mac[3] = (uint8_t)flc->mac_h;
    g_config.mac[4] = (uint8_t)(flc->mac_l >> 8);
    g_config.mac[5] = (uint8_t)flc->mac_l;
    g_config.ip      = flc->ip;
    g_config.netmask = flc->netmask;
    g_config.gateway = flc->gateway;

    lcpu_baseaddr->local_mac_h    = flc->mac_h;
    lcpu_baseaddr->local_mac_l    = flc->mac_l;
    lcpu_baseaddr->local_ip       = flc->ip;
    lcpu_baseaddr->local_netmask  = flc->netmask;
    lcpu_baseaddr->local_gateway  = flc->gateway;

    g_local_ip       = flc->ip;
    g_local_mac_high = flc->mac_h;
    g_local_mac_low  = flc->mac_l;
}

void local_config_init(void)
{
    flash_cfg_local_t flc;
    flash_cfg_wl_t fwl;

    // 启动时从 Flash 自动加载（magic/checksum 校验失败则用默认值）
    if (flash_cfg_load(&flc, &fwl) == 0) {
        local_config_apply(&flc);
    } else {
        local_config_apply_defaults();
    }
}

void local_config_get(local_config_t *c)
{
    if (c) *c = g_config;
}

int local_config_set(local_config_t *c)
{
    if (!c) return -1;
    g_config = *c;

    // 更新 HW 寄存器（MAC 字节序：high=mac[0:3], low=mac[4:5]）
    lcpu_baseaddr->local_mac_h = ((uint32_t)c->mac[0] << 24) | ((uint32_t)c->mac[1] << 16) |
                                  ((uint32_t)c->mac[2] << 8)  | c->mac[3];
    lcpu_baseaddr->local_mac_l = ((uint32_t)c->mac[4] << 8)  | c->mac[5];
    lcpu_baseaddr->local_ip      = c->ip;
    lcpu_baseaddr->local_netmask = c->netmask;
    lcpu_baseaddr->local_gateway = c->gateway;

    // 更新运行时全局
    g_local_ip       = c->ip;
    g_local_mac_high = lcpu_baseaddr->local_mac_h;
    g_local_mac_low  = lcpu_baseaddr->local_mac_l;

    return 0;
}

// 从 local_config_t 构建 flash_cfg_local_t 快照（MAC 字节序：high=mac[0:3], low=mac[4:5]）
static void local_config_build_snapshot(const local_config_t *c, flash_cfg_local_t *lc)
{
    lc->mac_h   = ((uint32_t)c->mac[0] << 24) | ((uint32_t)c->mac[1] << 16) |
                  ((uint32_t)c->mac[2] << 8)  | c->mac[3];
    lc->mac_l   = ((uint32_t)c->mac[4] << 8)  | c->mac[5];
    lc->ip      = c->ip;
    lc->netmask = c->netmask;
    lc->gateway = c->gateway;
}

void local_config_get_snapshot(flash_cfg_local_t *lc)
{
    if (!lc) return;
    local_config_build_snapshot(&g_config, lc);
}

int local_config_save_snapshot_to_flash(const local_config_t *cfg)
{
    flash_cfg_local_t lc;
    flash_cfg_wl_t wl;
    if (!cfg) return -1;
    local_config_build_snapshot(cfg, &lc);
    whitelist_get_snapshot(&wl);
    return flash_cfg_save(&lc, &wl);
}

int local_config_save_to_flash(void)
{
    return local_config_save_snapshot_to_flash(&g_config);
}

int local_config_load_from_flash(void)
{
    flash_cfg_local_t lc;
    flash_cfg_wl_t wl;
    if (flash_cfg_load(&lc, &wl) != 0) return -1;
    local_config_apply(&lc);
    return 0;
}
