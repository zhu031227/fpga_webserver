#include "inc/lcpu_general.h"
#include "inc/web_pages.h"
#include "inc/tcp.h"

// body 流式发送的分块大小（≤ MSS=1460，控制栈占用）
#define WEB_BUF_SIZE 256

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
// 找到返回 1，否则 0。
int web_page_lookup(uint32 route_id, uint32 *flash_addr, uint32 *length, uint8 *content_type) {
    uint32 magic = FLASH_MEM_RD32(WEB_TOC_FLASH_ADDR + WEB_TOC_OFF_MAGIC);
    // 调试：把读到的 magic/route_id 写到 debug 寄存器，jread 0x10/0x11 查看
    lcpu_baseaddr->debug_rw_0 = magic;
    lcpu_baseaddr->debug_rw_1 = route_id;
    if (magic != WEB_TOC_MAGIC) return 0;

    uint32 vc = FLASH_MEM_RD32(WEB_TOC_FLASH_ADDR + WEB_TOC_OFF_VERCNT);
    uint32 count = vc >> 16;   // count 在高 16 位（0x04=version:16, 0x06=count:16）
    uint32 i;
    for (i = 0; i < count; i++) {
        uint32 base = WEB_TOC_FLASH_ADDR + WEB_TOC_OFF_ENTRIES + i * WEB_ENTRY_SIZE;
        uint32 rt = FLASH_MEM_RD32(base + WEB_ENTRY_OFF_ROUTE);
        if (rt == route_id) {
            uint32 ct  = FLASH_MEM_RD32(base + WEB_ENTRY_OFF_CTYPE) & 0xFFu;
            uint32 off = FLASH_MEM_RD32(base + WEB_ENTRY_OFF_OFFSET);
            uint32 len = FLASH_MEM_RD32(base + WEB_ENTRY_OFF_LEN);
            *flash_addr   = WEB_TOC_FLASH_ADDR + off;
            *length       = len;
            *content_type = (uint8)ct;
            return 1;
        }
    }
    return 0;
}

// 从 flash 流式发 body：按 32 位字读，逐字节填入发送缓冲（flash 呈现小端，byte0 在前）
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
                cur_word = FLASH_MEM_RD32(flash_addr + word_off);
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
