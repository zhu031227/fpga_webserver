#ifndef _LOCAL_CONFIG_H_
#define _LOCAL_CONFIG_H_

#include <stdint.h>
#include "flash_cfg.h"

// Local config structure
typedef struct {
    uint8_t  mac[6];
    uint32_t ip;
    uint32_t netmask;
    uint32_t gateway;
} local_config_t;

// Init: load from Flash or use defaults
void local_config_init(void);

// Get current config
void local_config_get(local_config_t *c);

// Set config (writes registers, optional Flash save)
int  local_config_set(local_config_t *c);

// Flash persistence
int  local_config_save_to_flash(void);
int  local_config_load_from_flash(void);

// 保存指定配置到 flash（不改运行时 g_config / g_local_ip），返回 0 成功。
// 供「保存配置」路由：先存 flash 再回响应（避免先改 IP 导致响应源 IP 错），
// 响应后再 local_config_set 应用运行时。
int  local_config_save_snapshot_to_flash(const local_config_t *cfg);

// 供 flash_cfg 层读取当前本机配置快照（避免直接访问静态 g_config）
void local_config_get_snapshot(flash_cfg_local_t *lc);

#endif
