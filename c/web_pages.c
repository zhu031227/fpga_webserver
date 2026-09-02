#include "inc/lcpu_general.h"
#include "inc/web_pages.h"
#include "inc/tcp.h"
#include "inc/flash_cfg.h"

// body 流式发送的分块大小（≤ MSS=1460，控制栈占用）
#define WEB_BUF_SIZE 256

// ---- P3 (2026-08-31): 页面/TOC 读全部改走 lcpu_sflash 寄存器路径 ----
// 原 FLASH_MEM_RD32 走 flash_mem_reader 内存映射窗（停等无超时，任一次停等
// = 整机挂死且软件无法救）。sflash 路径带超时，最坏返回 -1 而非挂死。
// 字节序：以 TOC MAGIC 自校准（同 flash_cfg 配置区做法）。
static int pg_swap = -1;   // -1=未校准, 0=native, 1=需要 bswap

static uint32_t pg_bswap32(uint32_t v)
{
    return ((v & 0x000000FFu) << 24) | ((v & 0x0000FF00u) << 8) |
           ((v & 0x00FF0000u) >> 8)  | ((v & 0xFF000000u) >> 24);
}

// 读一字（校准后）。成功 0；sflash 超时 -1（调用方按"页面不可用"降级）
static int pg_read_word(uint32 flash_addr, uint32 *out)
{
    uint32_t raw;   /* flash_cfg.h 用 stdint 类型(工具链下=unsigned long), 指针须同型 */
    if (flash_cfg_read_word(flash_addr, &raw) != 0) return -1;
    if (pg_swap == 1) raw = pg_bswap32(raw);
    *out = (uint32)raw;
    return 0;
}

// u32 → 十进制字符串，返回写入字符数
static int write_u32_dec(char *buf, uint32 val) {
    char tmp[12];
    int n = 0, p = 0;
    if (val == 0) { buf[0] = '0'; return 1; }
    while (val) { tmp[n++] = (char)('0' + (val % 10)); val /= 10; }
    while (n > 0) buf[p++] = tmp[--n];
    return p;
}

// Content-Type 枚举 → MIME 字符串
static const char *web_content_type_str(uint8 ct) {
    switch (ct) {
        case CT_HTML:  return "text/html";
        case CT_CSS:   return "text/css";
        case CT_JS:    return "application/javascript";
        case CT_PNG:   return "image/png";
        case CT_SVG:   return "image/svg+xml";
        case CT_ICO:   return "image/x-icon";
        case CT_JSON:  return "application/json";
        case CT_PLAIN: return "text/plain";
        default:       return "application/octet-stream";
    }
}

// 查 TOC：在 flash 0x420000 目录表里找 route_id，回填内容地址/长度/类型。
// 找到返回 1，否则 0（含 sflash 超时/校验失败的降级路径）。
int web_page_lookup(uint32 route_id, uint32 *flash_addr, uint32 *length, uint8 *content_type) {
    uint32 magic, raw;
    if (pg_read_word(WEB_TOC_FLASH_ADDR + WEB_TOC_OFF_MAGIC, &raw) != 0) return 0;
    // 首读自校准：MAGIC 命中哪种字节序就用哪种（同 flash_cfg 配置区技巧）
    if (pg_swap < 0) {
        if (raw == WEB_TOC_MAGIC)               pg_swap = 0;
        else if (pg_bswap32(raw) == WEB_TOC_MAGIC) { pg_swap = 1; raw = pg_bswap32(raw); }
        else return 0;                            // MAGIC 不符（未烧页/扇区坏）→ 未找到
        magic = raw;
    } else {
        magic = raw;
    }
    // 调试：把读到的 magic/route_id 写到 debug 寄存器，jread 0x10/0x11 查看
    lcpu_baseaddr->debug_rw_0 = magic;
    lcpu_baseaddr->debug_rw_1 = route_id;
    if (magic != WEB_TOC_MAGIC) return 0;

    uint32 vc;
    if (pg_read_word(WEB_TOC_FLASH_ADDR + WEB_TOC_OFF_VERCNT, &vc) != 0) return 0;
    uint32 count = vc >> 16;   // count 在高 16 位（0x04=version:16, 0x06=count:16）
    uint32 i;
    for (i = 0; i < count; i++) {
        uint32 base = WEB_TOC_FLASH_ADDR + WEB_TOC_OFF_ENTRIES + i * WEB_ENTRY_SIZE;
        uint32 rt, ct, off, len;
        if (pg_read_word(base + WEB_ENTRY_OFF_ROUTE, &rt)  != 0) return 0;
        if (rt != route_id) continue;
        if (pg_read_word(base + WEB_ENTRY_OFF_CTYPE, &ct)  != 0) return 0;
        if (pg_read_word(base + WEB_ENTRY_OFF_OFFSET, &off) != 0) return 0;
        if (pg_read_word(base + WEB_ENTRY_OFF_LEN,   &len)  != 0) return 0;
        *flash_addr   = WEB_TOC_FLASH_ADDR + off;
        *length       = len;
        *content_type = (uint8)(ct & 0xFFu);
        return 1;
    }
    return 0;
}

// 从 flash 流式发 body：按 32 位字读（sflash 路径，带超时），逐字节填入发送缓冲。
// 读超时则中止 body（响应截断，客户端按短读处理）——绝不挂死整机。
static void send_web_body(int conn_idx, uint32 flash_addr, uint32 length) {
    uint32 sent = 0;
    while (sent < length) {
        uint32 remaining = length - sent;
        uint32 chunk = (remaining > WEB_BUF_SIZE) ? WEB_BUF_SIZE : remaining;
        uint8 buf[WEB_BUF_SIZE];
        uint32 cur_word = 0;
        uint32 cur_word_off = 0xFFFFFFFFu;  // 已缓存字偏移（相对 flash_addr），无效初值
        uint32 i;
        for (i = 0; i < chunk; i++) {
            uint32 pos = sent + i;
            uint32 word_off = pos & ~3u;   // 所在字的 4 字节对齐偏移
            if (word_off != cur_word_off) {
                if (pg_read_word(flash_addr + word_off, &cur_word) != 0) return;  // 超时中止
                cur_word_off = word_off;
            }
            buf[i] = (uint8)(cur_word >> ((pos & 3u) << 3));
        }
        send_http_buffer(conn_idx, buf, chunk);
        sent += chunk;
    }
}

// 发送一个 web 页面：查 TOC → 生成 HTTP 头（Content-Length/Content-Type）→ 流式发 body
void send_web_page(int conn_idx, uint32 route_id) {
    uint32 flash_addr, length;
    uint8 content_type;
    char header[128];
    int pos = 0;
    const char *s;

    if (!web_page_lookup(route_id, &flash_addr, &length, &content_type)) {
        send_http_response(conn_idx,
            "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nContent-Type: text/plain\r\n\r\nNot Found");
        return;
    }

    s = "HTTP/1.1 200 OK\r\nContent-Length: ";
    while (*s) header[pos++] = *s++;
    pos += write_u32_dec(header + pos, length);
    s = "\r\nContent-Type: ";
    while (*s) header[pos++] = *s++;
    s = web_content_type_str(content_type);
    while (*s) header[pos++] = *s++;
    s = "\r\n\r\n";
    while (*s) header[pos++] = *s++;

    send_http_buffer(conn_idx, (const uint8 *)header, (uint32)pos);
    send_web_body(conn_idx, flash_addr, length);
}
