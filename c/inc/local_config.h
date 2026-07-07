#ifndef _LOCAL_CONFIG_H_
#define _LOCAL_CONFIG_H_

#include <stdint.h>

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

#endif
