#include "inc/http.h"
#include "inc/lcpu_general.h"
#include "inc/whitelist.h"
#include "inc/local_config.h"
#include "inc/comlib.h"

/*
 * HTTP routing:
 *   GET  /              → main page          （flash 固化，见 web_pages.c）
 *   GET  /wlconfig      → whitelist config page  （flash 固化）
 *   GET  /localconfig   → local config page      （flash 固化）
 *   POST /api/wl/add    → add MAC
 *   POST /api/wl/delete → delete entry
 *   POST /api/wl/clear  → clear all
 *   POST /api/wl/toggle → enable/disable
 *   POST /api/wl/defpass → toggle default-pass policy (block-all / pass-all when disabled)
 *   GET  /api/wl/status → whitelist status
 *   GET  /api/wl/list   → list all entries
 *   GET  /api/local/status → local config
 *   POST /api/local/save   → save local config
 *
 * 页面内容已从固件内嵌字符串迁到 SPI Flash 0x420000（方案 B：flash_mem_reader
 * 内存映射读），本文件只保留 API 的 JSON 响应模板，页面路由在 tcp.c 里改调
 * send_web_page()。
 */

// POST response template
const char *post_response =
    "HTTP/1.1 200 OK\r\n"
    "Content-Length: 21\r\n"
    "Connection: keep-alive\r\n"
    "Content-Type: application/json\r\n\r\n"
    "{\"code\":0,\"msg\":\"ok\"}";
