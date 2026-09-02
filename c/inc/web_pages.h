#ifndef _WEB_PAGES_H_
#define _WEB_PAGES_H_

#include "lcpu_general.h"

// ============================================================
// Web 页面 Flash 固化（方案 B）：TOC + 内容存 flash 0x420000
// 固件经 flash_mem_reader（0x90000000 段）按字读取。
// 字节序：flash_mem_reader 硬件做字节交换，flash 呈现小端内存，
// 打包工具 pages_to_flash_tcl.py 据此写入（image[0] 放 word MSB）。
// ============================================================

// TOC 在 flash 的字节地址（== Web 页面区基址 0x420000）
#define WEB_TOC_FLASH_ADDR   0x00420000u

// TOC 头（8 字节）：magic(u32) + version(u16) + count(u16)
#define WEB_TOC_OFF_MAGIC    0x00   // u32 "WEBP"，小端 = 0x50424557
#define WEB_TOC_MAGIC        0x50424557u
#define WEB_TOC_OFF_VERCNT   0x04   // u32 低 16 位 version，高 16 位 count
#define WEB_TOC_OFF_ENTRIES  0x08   // N × 16B 条目

// 每个 TOC 条目（16 字节）
#define WEB_ENTRY_OFF_ROUTE  0x00   // u32 route_id
#define WEB_ENTRY_OFF_CTYPE  0x04   // u8 content_type + 3B reserved
#define WEB_ENTRY_OFF_OFFSET 0x08   // u32 内容 flash 字节偏移（相对 0x420000，4KB 对齐）
#define WEB_ENTRY_OFF_LEN    0x0C   // u32 字节长度
#define WEB_ENTRY_SIZE       16

// 路由 ID（与打包工具的 html 文件一一对应）
#define WEB_ROUTE_MAIN        1     // '/'
#define WEB_ROUTE_WLCONFIG    2     // '/wlconfig'
#define WEB_ROUTE_LOCALCONFIG 3     // '/localconfig'

// Content-Type 枚举（存 TOC 条目 content_type 字段，1 字节）
typedef enum {
    CT_HTML  = 0,   // text/html
    CT_CSS   = 1,   // text/css
    CT_JS    = 2,   // application/javascript
    CT_PNG   = 3,   // image/png
    CT_SVG   = 4,   // image/svg+xml
    CT_ICO   = 5,   // image/x-icon
    CT_JSON  = 6,   // application/json
    CT_PLAIN = 7    // text/plain
} web_content_type_t;

// 查 TOC：route_id → (flash 内容地址, 长度, 类型)。找到返回 1，否则 0。
int web_page_lookup(uint32 route_id, uint32 *flash_addr, uint32 *length, uint8 *content_type);

// 发送一个 web 页面：查 TOC → 生成 HTTP 头（Content-Length/Content-Type）→ 从 flash 流式发 body。
void send_web_page(int conn_idx, uint32 route_id);

#endif /* _WEB_PAGES_H_ */
