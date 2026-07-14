#include "inc/lcpu_general.h"
#include "inc/comlib.h"
#include "inc/ip.h"
#include "inc/tcp.h"
#include "inc/http.h"
#include "inc/eth.h"
#include "inc/whitelist.h"
#include "inc/local_config.h"

// --- 替代 tcp_connection_t 结构体的并行数组定义 ---
uint8_t  connection_states[MAX_CONNECTIONS];
uint32_t connection_seq_nums[MAX_CONNECTIONS];
uint32_t connection_ack_nums[MAX_CONNECTIONS];
uint16_t connection_src_ports[MAX_CONNECTIONS];
uint16_t connection_dst_ports[MAX_CONNECTIONS];
uint32_t connection_src_ips[MAX_CONNECTIONS];
uint32_t connection_dst_ips[MAX_CONNECTIONS];

// Timer / housekeeping arrays
uint32_t connection_time_wait_start[MAX_CONNECTIONS];
uint32_t connection_last_activity[MAX_CONNECTIONS];
uint32_t connection_last_tx_time[MAX_CONNECTIONS];
uint8_t  connection_syn_retries[MAX_CONNECTIONS];

uint32_t available_connections = MAX_CONNECTIONS;

#define TCP_POST_FIELD_COUNT  6
#define TCP_POST_FIELD_WIDTH  8
#define TCP_POST_FIELD_LONG_WIDTH  24
#define TCP_POST_RESPONSE_BUF_SIZE  640
#define TCP_POST_KEY_MAX_LEN  8

// Initialize all connections to CLOSED
void tcp_connection_init() {
    uint32 i;
    for (i = 0; i < MAX_CONNECTIONS; i++) {
        connection_states[i]         = TCP_STATE_CLOSED;
        connection_seq_nums[i]       = 0;
        connection_ack_nums[i]       = 0;
        connection_src_ports[i]      = 0;
        connection_dst_ports[i]      = 0;
        connection_src_ips[i]        = 0;
        connection_dst_ips[i]        = 0;
        connection_time_wait_start[i] = 0;
        connection_last_activity[i]  = 0;
        connection_last_tx_time[i]   = 0;
        connection_syn_retries[i]    = 0;
    }
    available_connections = MAX_CONNECTIONS;
}

int find_free_connection() {
    uint32 i;
    for (i = 0; i < MAX_CONNECTIONS; i++) {
        if (connection_states[i] == TCP_STATE_CLOSED) {
            return i;
        }
    }
    return -1;
}

int get_available_connections() {
    return available_connections;
}

int find_connection(uint16 src_port, uint16 dst_port, uint32 src_ip, uint32 dst_ip) {
    uint32 i;
    for (i = 0; i < MAX_CONNECTIONS; i++) {
        if (connection_states[i] != TCP_STATE_CLOSED &&
            connection_src_ports[i] == src_port &&
            connection_dst_ports[i] == dst_port &&
            connection_src_ips[i] == src_ip &&
            connection_dst_ips[i] == dst_ip) {
            return i;
        }
    }
    return -1;
}

#if DEBUG_En_tcp
void print_connections() {
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        printf("Connection %d:\n", i);
        printf("  State: %d\n", connection_states[i]);
        printf("  Sequence Number: %lu\n", connection_seq_nums[i]);
        printf("  Acknowledgment Number: %lu\n", connection_ack_nums[i]);
        printf("  Source Port: %d\n", connection_src_ports[i]);
        printf("  Destination Port: %d\n", connection_dst_ports[i]);
        printf("  Source IP: %lu\n", connection_src_ips[i]);
        printf("  Destination IP: %lu\n", connection_dst_ips[i]);
    }
}
#endif

void close_connection(int conn_idx) {
    if (conn_idx < 0 || conn_idx >= MAX_CONNECTIONS) return;

    if (connection_states[conn_idx] != TCP_STATE_CLOSED) {
        connection_states[conn_idx]         = TCP_STATE_CLOSED;
        connection_seq_nums[conn_idx]       = 0;
        connection_ack_nums[conn_idx]       = 0;
        connection_src_ports[conn_idx]      = 0;
        connection_dst_ports[conn_idx]      = 0;
        connection_src_ips[conn_idx]        = 0;
        connection_dst_ips[conn_idx]        = 0;
        connection_time_wait_start[conn_idx] = 0;
        connection_last_activity[conn_idx]  = 0;
        connection_last_tx_time[conn_idx]   = 0;
        connection_syn_retries[conn_idx]    = 0;
        available_connections++;
#if DEBUG_En_tcp
        printf("Connection %d closed. 当前可用连接数量: %lu\n", conn_idx, available_connections);
#endif
    }
}

static void tcp_write_u16_be(uint8 *buffer, uint16 value) {
    buffer[0] = (uint8)((value >> 8) & 0xFF);
    buffer[1] = (uint8)(value & 0xFF);
}

static void tcp_write_u32_be(uint8 *buffer, uint32 value) {
    buffer[0] = (uint8)((value >> 24) & 0xFF);
    buffer[1] = (uint8)((value >> 16) & 0xFF);
    buffer[2] = (uint8)((value >> 8) & 0xFF);
    buffer[3] = (uint8)(value & 0xFF);
}

static void fill_tcp_header(int conn_idx, uint8 flags, uint8 header[tcp_header_len]) {
    memset(header, 0, tcp_header_len);
    tcp_write_u16_be(&header[0], connection_dst_ports[conn_idx]);
    tcp_write_u16_be(&header[2], connection_src_ports[conn_idx]);
    tcp_write_u32_be(&header[4], connection_seq_nums[conn_idx]);
    tcp_write_u32_be(&header[8], connection_ack_nums[conn_idx]);
    header[12] = 0x50;   // data offset = 5 (20-byte header)
    header[13] = flags;
    header[14] = 0xFF;   // window = 65535
    header[15] = 0xFF;
    // checksum at [16..17] stays 0 (memset above)
}

static uint32 tcp_checksum_add_bytes(uint32 sum, const uint8 *bytes, uint16 len) {
    uint16 i;
    for (i = 0; i + 1 < len; i += 2) {
        sum += ((uint16)bytes[i] << 8) | bytes[i + 1];
    }
    if (i < len) {
        sum += (uint16)bytes[i] << 8;
    }
    return sum;
}

static uint16 tcp_checksum_build(
    const uint8 header[tcp_header_len],
    uint16 checksum_ini,
    uint32 src_ip,
    uint32 dst_ip,
    const uint8 *payload,
    uint16 payload_len
) {
    uint32 sum = checksum_ini;
    uint16 tcp_len = tcp_header_len + payload_len;

    sum += (uint16)((src_ip >> 16) & 0xFFFF);
    sum += (uint16)(src_ip & 0xFFFF);
    sum += (uint16)((dst_ip >> 16) & 0xFFFF);
    sum += (uint16)(dst_ip & 0xFFFF);
    sum += (uint16)IP_PROTOCOL_TCP;
    sum += tcp_len;

    sum = tcp_checksum_add_bytes(sum, header, tcp_header_len);
    if (payload != NULL && payload_len > 0) {
        sum = tcp_checksum_add_bytes(sum, payload, payload_len);
    }

    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16)(~sum);
}

static void tcp_set_checksum(uint8 header[tcp_header_len], uint16 checksum) {
    header[16] = (uint8)((checksum >> 8) & 0xFF);
    header[17] = (uint8)(checksum & 0xFF);
}

static void send_tcp_segment(const uint8 header[tcp_header_len], const uint8 *payload, uint16 payload_len) {
    uint16 i;
    uint16 actual_len = eth_header_len + ip_header_len + tcp_header_len + payload_len;
    uint16 rec_pkt_len = actual_len + 4;
    uint16 tcp_start = eth_header_len + ip_header_len;

    for (i = 0; i < tcp_header_len; i++) {
        LCPU_WR_BYTE(tcp_start + i, header[i]);
    }

    if (payload != NULL) {
        uint16 payload_start = tcp_start + tcp_header_len;
        for (i = 0; i < payload_len; i++) {
            LCPU_WR_BYTE(payload_start + i, payload[i]);
        }
    }

    if (rec_pkt_len < 64) {
        rec_pkt_len = 64;
    }
    LCPU_WR_PUSH_PACKET(rec_pkt_len);
}

// --- Periodic housekeeping: TIME_WAIT expiry, idle timeout, SYN retry ---
void tcp_periodic_check(void) {
    uint32 now = LCPU_LOCAL_TIME_L();
    uint32 i;

    for (i = 0; i < MAX_CONNECTIONS; i++) {
        uint8 state = connection_states[i];
        if (state == TCP_STATE_CLOSED) continue;

        // TIME_WAIT expiry
        if (state == TCP_STATE_TIME_WAIT) {
            if ((now - connection_time_wait_start[i]) >= TCP_TIMEWAIT_TICKS) {
#if DEBUG_En_tcp
                printf("TIME_WAIT expired for conn %lu, closing.\n", i);
#endif
                close_connection(i);
                continue;
            }
        }

        // Idle timeout (all non-CLOSED states except TIME_WAIT which has its own timer)
        if (state != TCP_STATE_TIME_WAIT) {
            if ((now - connection_last_activity[i]) >= TCP_IDLE_TIMEOUT_TICKS) {
#if DEBUG_En_tcp
                printf("Idle timeout for conn %lu (state %u), sending RST and closing.\n", i, state);
#endif
                // Send RST so the host immediately knows the connection is dead,
                // avoiding ~20s TCP retransmission timeout on the host side.
                send_rst(i);
                close_connection(i);
                continue;
            }
        }

        // SYN+ACK retransmission
        if (state == TCP_STATE_SYN_RECEIVED) {
            if (connection_syn_retries[i] > 0 &&
                (now - connection_last_tx_time[i]) >= TCP_SYN_RETRY_TICKS) {
                if (connection_syn_retries[i] < TCP_SYN_MAX_RETRIES) {
                    connection_syn_retries[i]++;
#if DEBUG_En_tcp
                    printf("SYN+ACK retry %u for conn %lu\n", connection_syn_retries[i], i);
#endif
                    connection_last_tx_time[i] = now;
                    send_syn_ack(i);
                } else {
#if DEBUG_En_tcp
                    printf("SYN+ACK max retries reached for conn %lu, closing.\n", i);
#endif
                    close_connection(i);
                }
            }
        }
    }
}

static uint8 tcp_hex_char_to_val(char ch) {
    if (ch >= '0' && ch <= '9') return (uint8)(ch - '0');
    if (ch >= 'A' && ch <= 'F') return (uint8)(ch - 'A' + 10);
    if (ch >= 'a' && ch <= 'f') return (uint8)(ch - 'a' + 10);
    return 0xFF;
}

// Search for a JSON key in the RX payload and extract its value.
// key: e.g. "addr", "data", "mode"
// field_out: output buffer of at least [TCP_POST_FIELD_WIDTH+1] bytes, null-terminated
// Returns 1 if key found and value extracted, 0 otherwise.
static uint8 tcp_find_json_field(uint16_t tcp_data_len, const char *key, char field_out[TCP_POST_FIELD_WIDTH + 1]) {
    uint32_t base = OFF_TCP_PAYLOAD;
    uint8_t key_len = 0;
    uint16_t pos = 0;
    uint8_t i;

    // Init output
    for (i = 0; i < TCP_POST_FIELD_WIDTH; i++) {
        field_out[i] = ' ';
    }
    field_out[TCP_POST_FIELD_WIDTH] = '\0';

    // Compute key length
    while (key[key_len] != '\0') key_len++;

    // Scan payload for the key pattern: "key"
    while (pos + key_len + 2 <= tcp_data_len) {
        LCPU_RD_SET_ADDR(base + pos);

        // Look for opening quote
        if (LCPU_RD_DATA8() != 0x22) { pos++; continue; }

        // Match key characters
        uint8 matched = 1;
        for (i = 0; i < key_len; i++) {
            LCPU_RD_SET_ADDR(base + pos + 1 + i);
            if (LCPU_RD_DATA8() != (uint8)key[i]) {
                matched = 0;
                break;
            }
        }
        if (!matched) { pos++; continue; }

        // Check closing quote and colon: "key":
        LCPU_RD_SET_ADDR(base + pos + 1 + key_len);
        if (LCPU_RD_DATA8() != 0x22) { pos++; continue; }
        LCPU_RD_SET_ADDR(base + pos + 1 + key_len + 1);
        if (LCPU_RD_DATA8() != 0x3A) { pos++; continue; }  // ':'

        // Now extract the value between the next pair of quotes
        uint16_t val_start = pos + 1 + key_len + 2;  // skip ":"
        if (val_start >= tcp_data_len) return 0;
        LCPU_RD_SET_ADDR(base + val_start);
        if (LCPU_RD_DATA8() != 0x22) { pos++; continue; }  // opening quote of value

        val_start++;  // skip opening quote
        uint8_t char_count = 0;
        for (i = 0; i < TCP_POST_FIELD_WIDTH && (val_start + i) < tcp_data_len; i++) {
            LCPU_RD_SET_ADDR(base + val_start + i);
            uint8 ch = LCPU_RD_DATA8();
            if (ch == 0x22) break;  // closing quote
            field_out[char_count++] = (char)ch;
        }
        field_out[char_count] = '\0';
        return 1;
    }
    return 0;
}

static uint32 read_ascii_hex_field(const char field[TCP_POST_FIELD_WIDTH + 1]) {
    uint32 value = 0;
    uint8 i;
    for (i = 0; i < TCP_POST_FIELD_WIDTH; i++) {
        uint8 nibble;
        if (field[i] == ' ' || field[i] == '\0') break;
        nibble = tcp_hex_char_to_val(field[i]);
        if (nibble == 0xFF) break;
        value = (value << 4) | nibble;
    }
    return value;
}

static void patch_hex_placeholder(char *response, const char *placeholder, uint32 value) {
    char hex_str[8];
    char *position = strstr(response, placeholder);
    if (position == NULL) return;
    to_hex_string(value, hex_str);
    memcpy(position + 2, hex_str, sizeof(hex_str));
}

static void build_post_response_payload(char response[TCP_POST_RESPONSE_BUF_SIZE], uint32 address, uint32 data, const char *mode) {
    size_t response_len = strlen(post_response);
    if (response_len >= TCP_POST_RESPONSE_BUF_SIZE) {
        response_len = TCP_POST_RESPONSE_BUF_SIZE - 1;
    }
    memcpy(response, post_response, response_len);
    response[response_len] = '\0';

    // 替换全部 XXX → "读" 或 "写"（两者均 3 字节，等长替换）
    const char *mode_text = (mode[0] == 'w' || mode[0] == 'W') ? "写" : "读";
    char *mode_pos = response;
    while ((mode_pos = strstr(mode_pos, "XXX")) != NULL) {
        memcpy(mode_pos, mode_text, 3);
        mode_pos += 3;
    }

    patch_hex_placeholder(response, "0x00000000", address);
    patch_hex_placeholder(response, "0x88888888", data);
}

// Send SYN+ACK packet for a connection specified by index
void send_syn_ack(int conn_idx) {
    uint8 tcp_header[tcp_header_len];
    uint16 checksum;

    if (conn_idx < 0 || conn_idx >= MAX_CONNECTIONS || connection_states[conn_idx] == TCP_STATE_CLOSED) return;

    fill_tcp_header(conn_idx, TCP_FLAG_SYN | TCP_FLAG_ACK, tcp_header);
    checksum = tcp_checksum_build(tcp_header, 0, connection_dst_ips[conn_idx], connection_src_ips[conn_idx], NULL, 0);
    tcp_set_checksum(tcp_header, checksum);

    ip_header_update(connection_src_ips[conn_idx], ip_header_len + tcp_header_len);
    send_tcp_segment(tcp_header, NULL, 0);

    // Track transmission for retry logic
    connection_last_tx_time[conn_idx] = LCPU_LOCAL_TIME_L();
    if (connection_syn_retries[conn_idx] == 0) {
        connection_syn_retries[conn_idx] = 1;
    }
}

// Handle incoming SYN packet
void tcp_handle_syn(uint16 src_port, uint16 dst_port, uint32 src_ip, uint32 seq_num) {
    if (dst_port != HTTP_PORT) return;

    int conn_idx = find_free_connection();
    if (conn_idx == -1) {
#if DEBUG_En_tcp
        printf("连接已满，无法处理新的 SYN 请求\n");
#endif
        return;
    }

    connection_states[conn_idx]         = TCP_STATE_SYN_RECEIVED;
    connection_src_ports[conn_idx]      = src_port;
    connection_dst_ports[conn_idx]      = dst_port;
    connection_src_ips[conn_idx]        = src_ip;
    connection_dst_ips[conn_idx]        = g_local_ip;
    connection_seq_nums[conn_idx]       = LCPU_LOCAL_TIME_L();   // Randomized ISN
    connection_ack_nums[conn_idx]       = seq_num + 1;
    connection_last_activity[conn_idx]  = LCPU_LOCAL_TIME_L();
    connection_last_tx_time[conn_idx]   = 0;
    connection_syn_retries[conn_idx]    = 0;

    available_connections--;

#if DEBUG_En_tcp
    printf("处理 SYN: conn_idx=%d, src_port=%d. 当前可用连接数量: %lu\n", conn_idx, src_port, available_connections);
#endif

    send_syn_ack(conn_idx);
}

// Parse POST data (kept for compatibility)
void parse_post_data(const char *post_data) {
    char addr[256] = {0};
    char data[256] = {0};

    char *addr_pos = strstr(post_data, "\"addr\":\"");
    char *data_pos = strstr(post_data, "\"data\":\"");

    if (addr_pos) {
        addr_pos += 8;
        char *end = strchr(addr_pos, '"');
        if (end) {
            strncpy(addr, addr_pos, end - addr_pos);
            addr[end - addr_pos] = '\0';
        }
    }

    if (data_pos) {
        data_pos += 8;
        char *end = strchr(data_pos, '"');
        if (end) {
            strncpy(data, data_pos, end - data_pos);
            data[end - data_pos] = '\0';
        }
    }
#if DEBUG_En_tcp
    // printf("Parsed POST - Addr: %s, Data: %s\n", addr, data);
#endif
}

// Key-based POST field extraction: find addr, data, mode by key name
static void tcp_read_post_fields_keyed(
    uint16_t tcp_data_len,
    char field_addr[TCP_POST_FIELD_WIDTH + 1],
    char field_data[TCP_POST_FIELD_WIDTH + 1],
    char field_mode[TCP_POST_FIELD_WIDTH + 1]
) {
    tcp_find_json_field(tcp_data_len, "addr", field_addr);
    tcp_find_json_field(tcp_data_len, "data", field_data);
    tcp_find_json_field(tcp_data_len, "mode", field_mode);
}

static void tcp_run_reg_access(
    const char field_addr[TCP_POST_FIELD_WIDTH + 1],
    const char field_data[TCP_POST_FIELD_WIDTH + 1],
    const char field_mode[TCP_POST_FIELD_WIDTH + 1],
    uint32 *address,
    uint32 *response_data
) {
    uint32 wrdata = read_ascii_hex_field(field_data);
    *address = read_ascii_hex_field(field_addr);

    if (field_mode[0] == 'w' || field_mode[0] == 'W') {
        write_lcpu_register(*address, wrdata);
        *response_data = wrdata;
#if DEBUG_En_tcp
        printf("write address 0x%x, write data 0x%x\n", *address, wrdata);
#endif
    } else {
        *response_data = read_lcpu_register(*address);
#if DEBUG_En_tcp
        printf("read address 0x%x, read data 0x%x\n", *address, *response_data);
#endif
    }
}

void send_http_response(int conn_idx, const char *response) {
    uint16_t response_len = strlen(response);
    uint16_t offset = 0;

    while (offset < response_len) {
        uint8 tcp_header[tcp_header_len];
        uint16_t checksum;
        uint16_t data_to_send = (response_len - offset > MSS) ? MSS : (response_len - offset);
        const uint8 *payload_ptr = (const uint8 *)(response + offset);

        fill_tcp_header(conn_idx, TCP_FLAG_ACK, tcp_header);

        checksum = tcp_checksum_build(tcp_header, 0, connection_dst_ips[conn_idx], connection_src_ips[conn_idx], payload_ptr, data_to_send);
        tcp_set_checksum(tcp_header, checksum);

        // Write Ethernet header for every segment (eth_proc only writes it once)
        eth_tx_header_fill();
        ip_header_update(connection_src_ips[conn_idx], ip_header_len + tcp_header_len + data_to_send);
        send_tcp_segment(tcp_header, payload_ptr, data_to_send);

        // Wait for TX FIFO to drain before sending next segment
        while (LCPU_WR_FULL()) {}

        connection_seq_nums[conn_idx] += data_to_send;
        offset += data_to_send;
    }
    connection_last_activity[conn_idx] = LCPU_LOCAL_TIME_L();
}

static void tcp_send_post_response(int conn_idx, uint32 address, uint32 data, const char *mode) {
    char response[TCP_POST_RESPONSE_BUF_SIZE];
    build_post_response_payload(response, address, data, mode);
    send_http_response(conn_idx, response);
}

static void tcp_handle_post_request(int conn_idx, uint16_t tcp_data_len) {
    char field_addr[TCP_POST_FIELD_WIDTH + 1];
    char field_data[TCP_POST_FIELD_WIDTH + 1];
    char field_mode[TCP_POST_FIELD_WIDTH + 1];
    uint32 address = 0;
    uint32 response_data = 0;

    tcp_read_post_fields_keyed(tcp_data_len, field_addr, field_data, field_mode);
    tcp_run_reg_access(field_addr, field_data, field_mode, &address, &response_data);
    tcp_send_post_response(conn_idx, address, response_data, field_mode);
}

// --- Simple JSON string value extractor: finds "key":"value" in payload ---
// Uses plain for-loop with index cap to avoid compiler optimization issues
static uint8 json_get_str(uint16_t data_len, const char *key, char *out, uint8_t out_max) {
    uint32_t base = OFF_TCP_PAYLOAD;
    uint8_t klen = 0;
    uint16_t i, j;
    uint16_t limit;

    while (key[klen]) klen++;

    // Cap search to avoid reading beyond packet
    limit = data_len;
    if (limit > 1500) limit = 1500;

    // Scan for "key":" pattern
    for (i = 0; i + klen + 3 < limit; i++) {
        LCPU_RD_SET_ADDR(base + i);
        if (LCPU_RD_DATA8() != '"') continue;

        // Check key
        for (j = 0; j < klen; j++) {
            LCPU_RD_SET_ADDR(base + i + 1 + j);
            if (LCPU_RD_DATA8() != (uint8_t)key[j]) break;
        }
        if (j < klen) continue;

        // Check closing ":
        LCPU_RD_SET_ADDR(base + i + 1 + klen);
        if (LCPU_RD_DATA8() != '"') continue;
        LCPU_RD_SET_ADDR(base + i + 1 + klen + 1);
        if (LCPU_RD_DATA8() != ':') continue;

        // Skip opening " of value
        j = i + 1 + klen + 2;
        if (j >= limit) return 0;
        LCPU_RD_SET_ADDR(base + j);
        if (LCPU_RD_DATA8() != '"') continue;
        j++;

        // Read value until closing "
        for (i = 0; i < out_max && j < limit; i++, j++) {
            LCPU_RD_SET_ADDR(base + j);
            uint8_t c = LCPU_RD_DATA8();
            if (c == '"') break;
            out[i] = (char)c;
        }
        out[i] = '\0';
        return 1;
    }
    return 0;
}

// --- String utility helpers ---

// Write uint8 as 1-3 decimal digits, return chars written
static int write_u8_dec(char *buf, uint8_t val) {
    int p = 0;
    if (val >= 100) { buf[p++] = '0' + val / 100; val %= 100; }
    if (val >= 10 || p > 0) { buf[p++] = '0' + val / 10; val %= 10; }
    buf[p++] = '0' + val;
    return p;
}

// Write uint16 as decimal string, return chars written
static int write_u16_dec(char *buf, uint16_t val) {
    int p = 0;
    if (val >= 10000) { buf[p++] = '0' + val / 10000; val %= 10000; }
    if (val >= 1000)  { buf[p++] = '0' + val / 1000;  val %= 1000; }
    if (val >= 100)   { buf[p++] = '0' + val / 100;   val %= 100; }
    if (val >= 10)    { buf[p++] = '0' + val / 10;    val %= 10; }
    buf[p++] = '0' + val;
    return p;
}

// MAC uint8[6] → "XX:XX:XX:XX:XX:XX"
static void mac_to_str(uint8_t mac[6], char *out) {
    int p = 0, i;
    for (i = 0; i < 6; i++) {
        out[p++] = hex_to_ascii(mac[i] >> 4);
        out[p++] = hex_to_ascii(mac[i] & 0xF);
        if (i < 5) out[p++] = ':';
    }
    out[p] = '\0';
}

// uint32 IP → "XXX.XXX.XXX.XXX"
static void ip32_to_str(uint32_t ip, char *out) {
    int p = 0;
    p += write_u8_dec(out + p, (uint8_t)((ip >> 24) & 0xFF)); out[p++] = '.';
    p += write_u8_dec(out + p, (uint8_t)((ip >> 16) & 0xFF)); out[p++] = '.';
    p += write_u8_dec(out + p, (uint8_t)((ip >> 8) & 0xFF));  out[p++] = '.';
    p += write_u8_dec(out + p, (uint8_t)(ip & 0xFF));
    out[p] = '\0';
}

// Parse "XX:XX:XX:XX:XX:XX" → uint8_t[6]. Returns 0 on success, -1 on error.
static int parse_mac_str(const char *str, uint8_t mac[6]) {
    int i;
    for (i = 0; i < 6; i++) {
        uint8_t hi = hex_char_to_val(str[i * 3]);
        uint8_t lo = hex_char_to_val(str[i * 3 + 1]);
        if (hi == 0xFF || lo == 0xFF) return -1;
        mac[i] = (hi << 4) | lo;
    }
    return 0;
}

// Parse "XXX.XXX.XXX.XXX" → uint32_t IP
static uint32_t parse_ip_str(const char *str) {
    uint32_t ip = 0, byte_val = 0;
    while (*str) {
        if (*str == '.') { ip = (ip << 8) | byte_val; byte_val = 0; }
        else if (*str >= '0' && *str <= '9') { byte_val = byte_val * 10 + (*str - '0'); }
        str++;
    }
    ip = (ip << 8) | byte_val;
    return ip;
}

// Build HTTP JSON response and send it.
// json_body must be null-terminated; Content-Length is computed automatically.
#define API_RESP_BUF_SIZE  512
static void api_send_json(int conn_idx, const char *json_body) {
    char buf[API_RESP_BUF_SIZE];
    int pos = 0;
    int body_len = 0;
    const char *p;

    // Measure body length
    p = json_body;
    while (*p) { body_len++; p++; }

    // Write header
    p = "HTTP/1.1 200 OK\r\nContent-Length: ";
    while (*p) buf[pos++] = *p++;
    pos += write_u16_dec(buf + pos, (uint16_t)body_len);
    p = "\r\nContent-Type: application/json\r\n\r\n";
    while (*p) buf[pos++] = *p++;

    // Write body
    p = json_body;
    while (*p) buf[pos++] = *p++;
    buf[pos] = '\0';

    send_http_response(conn_idx, buf);
}

// --- GET /api/wl/status ---
static void api_wl_status(int conn_idx) {
    char body[96];
    int p = 0;
    const char *s;
    uint8_t en = whitelist_is_enabled();
    uint8_t dp = whitelist_get_default_pass();
    uint16_t used = whitelist_hw_get_used_count();
    uint16_t max = whitelist_hw_get_max_entries();

    s = "{\"enabled\":";
    while (*s) body[p++] = *s++;
    body[p++] = en ? 't' : 'f';
    body[p++] = en ? 'r' : 'a';
    body[p++] = en ? 'u' : 'l';
    body[p++] = en ? 'e' : 's';
    if (!en) body[p++] = 'e';
    s = ",\"defpass\":";
    while (*s) body[p++] = *s++;
    body[p++] = dp ? 't' : 'f';
    body[p++] = dp ? 'r' : 'a';
    body[p++] = dp ? 'u' : 'l';
    body[p++] = dp ? 'e' : 's';
    if (!dp) body[p++] = 'e';
    s = ",\"used\":";
    while (*s) body[p++] = *s++;
    p += write_u16_dec(body + p, used);
    s = ",\"max\":";
    while (*s) body[p++] = *s++;
    p += write_u16_dec(body + p, max);
    body[p++] = '}';
    body[p] = '\0';

    api_send_json(conn_idx, body);
}

// --- GET /api/wl/list (reads actual BRAM via HW) ---
#define WL_LIST_BUF_SIZE  4096
static void api_wl_list(int conn_idx) {
    char buf[WL_LIST_BUF_SIZE];
    int pos = 0;
    int body_start;
    int body_len;
    uint16_t max = whitelist_hw_get_max_entries();
    uint16_t i;
    uint8_t first = 1;
    const char *s;

    // Write HTTP header prefix (Content-Length placeholder will be patched)
    s = "HTTP/1.1 200 OK\r\nContent-Length: ";
    while (*s) buf[pos++] = *s++;
    int cl_pos = pos;  // remember where Content-Length digits start
    buf[pos++] = ' '; buf[pos++] = ' '; buf[pos++] = ' '; buf[pos++] = ' ';
    s = "\r\nContent-Type: application/json\r\n\r\n";
    while (*s) buf[pos++] = *s++;

    body_start = pos;

    // Build JSON array body (reads HW BRAM directly)
    buf[pos++] = '[';
    for (i = 0; i < max && pos < (WL_LIST_BUF_SIZE - 64); i++) {
        uint8_t mac[6];
        if (whitelist_hw_read_entry((uint8_t)i, mac) == 0) {
            char mac_str[18];
            if (!first) buf[pos++] = ',';
            first = 0;
            mac_to_str(mac, mac_str);
            buf[pos++] = '{'; buf[pos++] = '"'; buf[pos++] = 'i'; buf[pos++] = 'd';
            buf[pos++] = 'x'; buf[pos++] = '"'; buf[pos++] = ':';
            pos += write_u16_dec(buf + pos, i);
            buf[pos++] = ','; buf[pos++] = '"'; buf[pos++] = 'm'; buf[pos++] = 'a';
            buf[pos++] = 'c'; buf[pos++] = '"'; buf[pos++] = ':'; buf[pos++] = '"';
            {
                const char *mp = mac_str;
                while (*mp) buf[pos++] = *mp++;
            }
            buf[pos++] = '"'; buf[pos++] = ','; buf[pos++] = '"'; buf[pos++] = 'v';
            buf[pos++] = 'a'; buf[pos++] = 'l'; buf[pos++] = 'i'; buf[pos++] = 'd';
            buf[pos++] = '"'; buf[pos++] = ':'; buf[pos++] = 't'; buf[pos++] = 'r';
            buf[pos++] = 'u'; buf[pos++] = 'e'; buf[pos++] = '}';
        }
    }
    buf[pos++] = ']';
    buf[pos] = '\0';

    body_len = pos - body_start;

    // Patch Content-Length into the 4 placeholder bytes
    // body_len is at most 9999 (fits 4 digits)
    buf[cl_pos + 3] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 2] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 1] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 0] = '0' + (body_len % 10);

    send_http_response(conn_idx, buf);
}

// --- GET /api/wl/hwlist (reads actual BRAM, bypasses software cache) ---
static void api_wl_hwlist(int conn_idx) {
    char buf[WL_LIST_BUF_SIZE];
    int pos = 0;
    int body_start;
    int body_len;
    uint16_t max = whitelist_hw_get_max_entries();
    uint16_t used = whitelist_hw_get_used_count();
    uint8_t free_idx = whitelist_hw_get_free_index();
    uint16_t i;
    uint8_t first = 1;
    const char *s;

    // Write HTTP header
    s = "HTTP/1.1 200 OK\r\nContent-Length: ";
    while (*s) buf[pos++] = *s++;
    int cl_pos = pos;
    buf[pos++] = ' '; buf[pos++] = ' '; buf[pos++] = ' '; buf[pos++] = ' ';
    s = "\r\nContent-Type: application/json\r\n\r\n";
    while (*s) buf[pos++] = *s++;

    body_start = pos;

    // JSON: { "max":N, "used":N, "free":N, "entries": [...] }
    buf[pos++] = '{';
    s = "\"max\":";
    while (*s) buf[pos++] = *s++;
    pos += write_u16_dec(buf + pos, max);
    s = ",\"used\":";
    while (*s) buf[pos++] = *s++;
    pos += write_u16_dec(buf + pos, used);
    s = ",\"free\":";
    while (*s) buf[pos++] = *s++;
    pos += write_u16_dec(buf + pos, free_idx);
    s = ",\"entries\":[";
    while (*s) buf[pos++] = *s++;

    for (i = 0; i < max && pos < (WL_LIST_BUF_SIZE - 64); i++) {
        uint8_t mac[6];
        if (whitelist_hw_read_entry((uint8_t)i, mac) == 0) {
            char mac_str[18];
            if (!first) buf[pos++] = ',';
            first = 0;
            mac_to_str(mac, mac_str);
            buf[pos++] = '{'; buf[pos++] = '"'; buf[pos++] = 'i'; buf[pos++] = 'd';
            buf[pos++] = 'x'; buf[pos++] = '"'; buf[pos++] = ':';
            pos += write_u16_dec(buf + pos, i);
            buf[pos++] = ','; buf[pos++] = '"'; buf[pos++] = 'm'; buf[pos++] = 'a';
            buf[pos++] = 'c'; buf[pos++] = '"'; buf[pos++] = ':'; buf[pos++] = '"';
            {
                const char *mp = mac_str;
                while (*mp) buf[pos++] = *mp++;
            }
            buf[pos++] = '"'; buf[pos++] = '}';
        }
    }
    buf[pos++] = ']';
    buf[pos++] = '}';
    buf[pos] = '\0';

    body_len = pos - body_start;

    // Patch Content-Length
    buf[cl_pos + 3] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 2] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 1] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 0] = '0' + (body_len % 10);

    send_http_response(conn_idx, buf);
}

// --- GET /api/wl/diag (hardware diagnostic) ---
static void api_wl_diag(int conn_idx) {
    static char buf[WL_LIST_BUF_SIZE];
    int pos = 0;
    int body_start;
    int buf_size = WL_LIST_BUF_SIZE;
    const char *s;

    s = "HTTP/1.1 200 OK\r\nContent-Length: ";
    while (*s && pos < buf_size) buf[pos++] = *s++;
    int cl_pos = pos;
    buf[pos++] = ' '; buf[pos++] = ' '; buf[pos++] = ' '; buf[pos++] = ' ';
    s = "\r\nContent-Type: application/json\r\n\r\n";
    while (*s && pos < buf_size) buf[pos++] = *s++;

    body_start = pos;
    // whitelist_hw_diag now outputs complete JSON, no extra wrapping needed
    int diag_len = whitelist_hw_diag(buf + pos, buf_size - pos - 8);
    pos += diag_len;
    buf[pos] = '\0';

    int body_len = pos - body_start;
    buf[cl_pos + 3] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 2] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 1] = '0' + (body_len % 10); body_len /= 10;
    buf[cl_pos + 0] = '0' + (body_len % 10);

    send_http_response(conn_idx, buf);
}

// --- POST /api/wl/add ---
static void api_wl_add(int conn_idx, uint16_t tcp_data_len) {
    char field_mac[TCP_POST_FIELD_LONG_WIDTH + 1];
    uint8_t mac[6];

    json_get_str(tcp_data_len, "mac", field_mac, TCP_POST_FIELD_LONG_WIDTH);
    if (parse_mac_str(field_mac, mac) != 0) {
        api_send_json(conn_idx, "{\"code\":-1,\"msg\":\"invalid MAC\"}");
        return;
    }
    int idx = whitelist_add(mac);
    if (idx < 0) {
        api_send_json(conn_idx, "{\"code\":-1,\"msg\":\"table full\"}");
    } else {
        api_send_json(conn_idx, "{\"code\":0,\"msg\":\"ok\"}");
    }
}

// --- POST /api/wl/delete ---
static void api_wl_delete(int conn_idx, uint16_t tcp_data_len) {
    char field_idx[TCP_POST_FIELD_WIDTH + 1];
    if (json_get_str(tcp_data_len, "index", field_idx, TCP_POST_FIELD_WIDTH)) {
        uint8_t idx = 0;
        int i = 0;
        while (field_idx[i] >= '0' && field_idx[i] <= '9') {
            idx = idx * 10 + (field_idx[i] - '0');
            i++;
        }
        whitelist_delete(idx);
        api_send_json(conn_idx, "{\"code\":0,\"msg\":\"deleted\"}");
    } else {
        api_send_json(conn_idx, "{\"code\":-1,\"msg\":\"no index field\"}");
    }
}

// --- POST /api/wl/clear ---
static void api_wl_clear(int conn_idx) {
    whitelist_clear_all();
    api_send_json(conn_idx, "{\"code\":0,\"msg\":\"ok\"}");
}

// --- POST /api/wl/toggle ---
static void api_wl_toggle(int conn_idx) {
    if (whitelist_is_enabled())
        whitelist_enable(0);
    else
        whitelist_enable(1);
    api_send_json(conn_idx, "{\"code\":0,\"msg\":\"ok\"}");
}

// --- POST /api/wl/defpass ---
static void api_wl_defpass(int conn_idx) {
    if (whitelist_get_default_pass())
        whitelist_set_default_pass(0);
    else
        whitelist_set_default_pass(1);
    api_send_json(conn_idx, "{\"code\":0,\"msg\":\"ok\"}");
}

// --- GET /api/local/status ---
static void api_local_status(int conn_idx) {
    local_config_t cfg;
    char mac_s[18], ip_s[16], nm_s[16], gw_s[16];
    char body[128];
    int p = 0;
    const char *s;

    local_config_get(&cfg);
    mac_to_str(cfg.mac, mac_s);
    ip32_to_str(cfg.ip, ip_s);
    ip32_to_str(cfg.netmask, nm_s);
    ip32_to_str(cfg.gateway, gw_s);

    // Build JSON body: {"mac":"...","ip":"...","netmask":"...","gateway":"..."}
    s = "{\"mac\":\"";       while (*s) body[p++] = *s++;
    s = mac_s;               while (*s) body[p++] = *s++;
    s = "\",\"ip\":\"";      while (*s) body[p++] = *s++;
    s = ip_s;                while (*s) body[p++] = *s++;
    s = "\",\"netmask\":\""; while (*s) body[p++] = *s++;
    s = nm_s;                while (*s) body[p++] = *s++;
    s = "\",\"gateway\":\""; while (*s) body[p++] = *s++;
    s = gw_s;                while (*s) body[p++] = *s++;
    body[p++] = '"'; body[p++] = '}';
    body[p] = '\0';

    api_send_json(conn_idx, body);
}

// --- POST /api/local/save ---
static void api_local_save(int conn_idx, uint16_t tcp_data_len) {
    char field[TCP_POST_FIELD_LONG_WIDTH + 1];
    local_config_t cfg;
    uint8_t mac[6];

    local_config_get(&cfg);

    if (json_get_str(tcp_data_len, "mac", field, TCP_POST_FIELD_LONG_WIDTH)) {
        if (parse_mac_str(field, mac) == 0) {
            int i; for (i = 0; i < 6; i++) cfg.mac[i] = mac[i];
        }
    }
    if (json_get_str(tcp_data_len, "ip", field, TCP_POST_FIELD_LONG_WIDTH)) {
        if (field[0] != ' ') { cfg.ip = parse_ip_str(field); }
    }
    if (json_get_str(tcp_data_len, "netmask", field, TCP_POST_FIELD_LONG_WIDTH)) {
        if (field[0] != ' ') { cfg.netmask = parse_ip_str(field); }
    }
    if (json_get_str(tcp_data_len, "gateway", field, TCP_POST_FIELD_LONG_WIDTH)) {
        if (field[0] != ' ') { cfg.gateway = parse_ip_str(field); }
    }

    // Send response FIRST — before local_config_set changes g_local_ip,
    // so the TCP source IP matches the existing connection
    api_send_json(conn_idx, "{\"code\":0,\"msg\":\"saved\"}");

    // Then apply config (changes g_local_ip, HW registers) and save to Flash
    local_config_set(&cfg);
    local_config_save_to_flash();
}

// Simple URL path match: compare packet data starting at current RD position
// against a constant string. Returns 1 if matched, 0 otherwise.
// Advances RD pointer past the matched string on success.
static uint8 match_path(const char *path) {
    while (*path) {
        LCPU_RD_INC_ADDR();
        if ((char)LCPU_RD_DATA8() != *path) return 0;
        path++;
    }
    return 1;
}

// Read URL path from GET request and route
void http_request_handler(int conn_idx, uint16_t tcp_data_len) {
    LCPU_RD_SET_ADDR(OFF_TCP_PAYLOAD);
    char first_char = (char)LCPU_RD_DATA8();
    uint8 handled = 0;

    if (first_char == 'G') {
        LCPU_RD_INC_ADDR();
        if (LCPU_RD_DATA8() == 'E') {
            LCPU_RD_INC_ADDR();
            if (LCPU_RD_DATA8() == 'T') {
                LCPU_RD_INC_ADDR();
                if (LCPU_RD_DATA8() == ' ') {
                    // Now at start of path: "/..." or "/ HTTP/1.1"
                    LCPU_RD_INC_ADDR();
                    char path_char = (char)LCPU_RD_DATA8();

                    if (path_char == '/') {
                        // Skip leading '/' and check sub-path
                        LCPU_RD_INC_ADDR();
                        char sub_char = (char)LCPU_RD_DATA8();

                        if (sub_char == ' ' || sub_char == '\r') {
                            // "GET /" → main page
                            send_http_response(conn_idx, main_page);
                            handled = 1;
                        } else if (sub_char == 'w') {
                            // /wlconfig or /wl...
                            if (match_path("lconfig")) {
                                send_http_response(conn_idx, wlconfig_page);
                                handled = 1;
                            }
                        } else if (sub_char == 'l') {
                            // /localconfig
                            if (match_path("ocalconfig")) {
                                send_http_response(conn_idx, localconfig_page);
                                handled = 1;
                            }
                        } else if (sub_char == 'a') {
                            // /api/* — save RD position before each match_path attempt
                            // because failed match_path corrupts the RD pointer
                            uint32_t rd_save = lcpu_baseaddr->rd_pkt_fifo.raddr;
                            if (match_path("pi/ping")) {
                                static const char ping[] =
                                    "HTTP/1.1 200 OK\r\n"
                                    "Content-Length: 4\r\n"
                                    "Content-Type: text/plain\r\n\r\n"
                                    "pong";
                                send_http_response(conn_idx, ping);
                                handled = 1;
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/local/status")) {
                                    api_local_status(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/status")) {
                                    api_wl_status(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/list")) {
                                    api_wl_list(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/hwlist")) {
                                    api_wl_hwlist(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/diag")) {
                                    api_wl_diag(conn_idx);
                                    handled = 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    } else if (first_char == 'P') {
        LCPU_RD_INC_ADDR();
        if (LCPU_RD_DATA8() == 'O') {
            LCPU_RD_INC_ADDR();
            if (LCPU_RD_DATA8() == 'S') {
                LCPU_RD_INC_ADDR();
                if (LCPU_RD_DATA8() == 'T') {
                    // Parse URL path to determine POST handler
                    // Skip " /" to reach path
                    LCPU_RD_SET_ADDR(OFF_TCP_PAYLOAD + 4); // after "POST"
                    char pc = (char)LCPU_RD_DATA8();
                    while (pc == ' ') { LCPU_RD_INC_ADDR(); pc = (char)LCPU_RD_DATA8(); }

                    if (pc == '/') {
                        LCPU_RD_INC_ADDR();
                        pc = (char)LCPU_RD_DATA8();
                        if (pc == 's' && match_path("ubmit")) {
                            // Legacy POST /submit
                            tcp_handle_post_request(conn_idx, tcp_data_len);
                            handled = 1;
                        } else if (pc == 'a') {
                            // /api/* — save RD position before each match_path
                            uint32_t rd_save = lcpu_baseaddr->rd_pkt_fifo.raddr;
                            if (match_path("pi/wl/add")) {
                                api_wl_add(conn_idx, tcp_data_len);
                                handled = 1;
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/delete")) {
                                    api_wl_delete(conn_idx, tcp_data_len);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/clear")) {
                                    api_wl_clear(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/toggle")) {
                                    api_wl_toggle(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/defpass")) {
                                    api_wl_defpass(conn_idx);
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/wl/save")) {
                                    whitelist_save_to_flash();
                                    api_send_json(conn_idx, "{\"code\":0,\"msg\":\"saved\"}");
                                    handled = 1;
                                }
                            }
                            if (!handled) {
                                lcpu_baseaddr->rd_pkt_fifo.raddr = rd_save;
                                if (match_path("pi/local/save")) {
                                    api_local_save(conn_idx, tcp_data_len);
                                    handled = 1;
                                }
                            }
                        }
                    }
                    // Fallback: treat as legacy POST
                    if (!handled) {
                        tcp_handle_post_request(conn_idx, tcp_data_len);
                        handled = 1;
                    }
                }
            }
        }
    }

    if (!handled) {
        send_ack(conn_idx);
    }
}

// Send ACK packet for a connection specified by index
void send_ack(int conn_idx) {
    uint8 tcp_header[tcp_header_len];
    uint16 checksum;

    if (conn_idx < 0 || conn_idx >= MAX_CONNECTIONS || connection_states[conn_idx] == TCP_STATE_CLOSED) return;

    fill_tcp_header(conn_idx, TCP_FLAG_ACK, tcp_header);
    checksum = tcp_checksum_build(tcp_header, 0, connection_dst_ips[conn_idx], connection_src_ips[conn_idx], NULL, 0);
    tcp_set_checksum(tcp_header, checksum);

    ip_header_update(connection_src_ips[conn_idx], ip_header_len + tcp_header_len);
    send_tcp_segment(tcp_header, NULL, 0);
#if DEBUG_En_tcp
    // printf("Sent ACK: conn_idx=%d, seq=%lu, ack=%lu\n", conn_idx, connection_seq_nums[conn_idx], connection_ack_nums[conn_idx]);
#endif
}

// Send RST packet for a connection specified by index.
// RFC 793: RST+ACK with ack_num = rcv.nxt (our connection_ack_nums), seq = snd.nxt.
// This allows the host to immediately detect that the connection is dead,
// avoiding ~20s of TCP retransmission timeout.
void send_rst(int conn_idx) {
    uint8 tcp_header[tcp_header_len];
    uint16 checksum;

    if (conn_idx < 0 || conn_idx >= MAX_CONNECTIONS || connection_states[conn_idx] == TCP_STATE_CLOSED) return;

    fill_tcp_header(conn_idx, TCP_FLAG_RST | TCP_FLAG_ACK, tcp_header);
    checksum = tcp_checksum_build(tcp_header, 0, connection_dst_ips[conn_idx], connection_src_ips[conn_idx], NULL, 0);
    tcp_set_checksum(tcp_header, checksum);

    ip_header_update(connection_src_ips[conn_idx], ip_header_len + tcp_header_len);
    send_tcp_segment(tcp_header, NULL, 0);
#if DEBUG_En_tcp
    printf("Sent RST: conn_idx=%d\n", conn_idx);
#endif
}

void tcp_packet_handler() {
    uint16 src_port = 0, dst_port = 0;
    uint32 seq_num = 0, ack_num = 0, src_ip = 0, dst_ip = 0;
    uint32 flags;
    uint16 tcp_data_len = 0;

    // --- Validate IP version & IHL ---
    LCPU_RD_SET_ADDR(OFF_IP_VER_IHL);
    uint8 ver_ihl = LCPU_RD_DATA8();
    if ((ver_ihl & 0xF0) != 0x40) {  // Version 4, IHL must be >= 5
        return;
    }
    uint8 ihl_words = ver_ihl & 0x0F;
    if (ihl_words < 5) return;
    uint8 actual_ip_header_len = ihl_words * 4;

    // --- Parse IP Header ---
    LCPU_RD_SET_ADDR(OFF_IP_SRC_IP);
    src_ip  = ((uint32)LCPU_RD_DATA8() << 24); LCPU_RD_INC_ADDR();
    src_ip |= ((uint32)LCPU_RD_DATA8() << 16); LCPU_RD_INC_ADDR();
    src_ip |= ((uint32)LCPU_RD_DATA8() << 8);  LCPU_RD_INC_ADDR();
    src_ip |= LCPU_RD_DATA8();                  LCPU_RD_INC_ADDR();

    dst_ip  = ((uint32)LCPU_RD_DATA8() << 24); LCPU_RD_INC_ADDR();
    dst_ip |= ((uint32)LCPU_RD_DATA8() << 16); LCPU_RD_INC_ADDR();
    dst_ip |= ((uint32)LCPU_RD_DATA8() << 8);  LCPU_RD_INC_ADDR();
    dst_ip |= LCPU_RD_DATA8();

    // Read IP Total Length
    LCPU_RD_SET_ADDR(OFF_IP_TOTAL_LEN);
    ip_total_len  = ((uint16)LCPU_RD_DATA8() << 8);
    LCPU_RD_INC_ADDR();
    ip_total_len |= LCPU_RD_DATA8();

    // --- Parse TCP Header ---
    uint32 tcp_offset = eth_header_len + actual_ip_header_len;

    LCPU_RD_SET_ADDR(tcp_offset + 0);
    src_port  = ((uint16)LCPU_RD_DATA8() << 8); LCPU_RD_INC_ADDR();
    src_port |= LCPU_RD_DATA8();                LCPU_RD_INC_ADDR();

    dst_port  = ((uint16)LCPU_RD_DATA8() << 8); LCPU_RD_INC_ADDR();
    dst_port |= LCPU_RD_DATA8();                LCPU_RD_INC_ADDR();

    seq_num  = ((uint32)LCPU_RD_DATA8() << 24); LCPU_RD_INC_ADDR();
    seq_num |= ((uint32)LCPU_RD_DATA8() << 16); LCPU_RD_INC_ADDR();
    seq_num |= ((uint32)LCPU_RD_DATA8() << 8);  LCPU_RD_INC_ADDR();
    seq_num |= LCPU_RD_DATA8();                  LCPU_RD_INC_ADDR();

    ack_num  = ((uint32)LCPU_RD_DATA8() << 24); LCPU_RD_INC_ADDR();
    ack_num |= ((uint32)LCPU_RD_DATA8() << 16); LCPU_RD_INC_ADDR();
    ack_num |= ((uint32)LCPU_RD_DATA8() << 8);  LCPU_RD_INC_ADDR();
    ack_num |= LCPU_RD_DATA8();

    // Read TCP data offset to get actual TCP header size
    LCPU_RD_SET_ADDR(tcp_offset + 12);
    uint8 tcp_data_ofs = (LCPU_RD_DATA8() >> 4) * 4;
    if (tcp_data_ofs < 20) tcp_data_ofs = 20;  // minimum

    LCPU_RD_SET_ADDR(tcp_offset + 13);
    flags = LCPU_RD_DATA8();

    // Calculate TCP data length
    if (ip_total_len >= (actual_ip_header_len + tcp_data_ofs)) {
        tcp_data_len = ip_total_len - actual_ip_header_len - tcp_data_ofs;
    } else {
        tcp_data_len = 0;
#if DEBUG_En_tcp
        printf("Warning: Calculated TCP data length is negative or zero based on IP total length.\n");
#endif
    }

    // Find existing connection
    int conn_idx = find_connection(src_port, dst_port, src_ip, g_local_ip);

#if DEBUG_En_tcp
    // printf("TCP Packet Received: Src Port=%d, Dst Port=%d, Seq=%lu, Ack=%lu, Flags=0x%02X, DataLen=%d, Found Conn Idx=%d\n",
    //        src_port, dst_port, seq_num, ack_num, flags, tcp_data_len, conn_idx);
    if (conn_idx != -1) {
        // printf("  Matching Connection State: %d\n", connection_states[conn_idx]);
    }
#endif

    // Handle RST
    if (flags & TCP_FLAG_RST) {
#if DEBUG_En_tcp
        printf("RST flag received for conn_idx %d (or not found). Closing connection.\n", conn_idx);
#endif
        if (conn_idx != -1) {
            close_connection(conn_idx);
        }
        return;
    }

    // Handle new connection (pure SYN)
    if (conn_idx == -1) {
        if ((flags & TCP_FLAG_SYN) && !(flags & TCP_FLAG_ACK) && !(flags & TCP_FLAG_RST) && !(flags & TCP_FLAG_FIN)) {
#if DEBUG_En_tcp
            printf("Pure SYN received. Handling new connection.\n");
#endif
            tcp_handle_syn(src_port, dst_port, src_ip, seq_num);
        }
#if DEBUG_En_tcp
        else {
            printf("Packet received for non-existent connection (and not pure SYN). Flags=0x%02X. Ignoring.\n", flags);
        }
#endif
        return;
    }

    // Update last activity timestamp for existing connection
    connection_last_activity[conn_idx] = LCPU_LOCAL_TIME_L();

    uint32 current_state = connection_states[conn_idx];

    switch (current_state) {
        case TCP_STATE_CLOSED:
#if DEBUG_En_tcp
            printf("Error: Packet received for connection %d in CLOSED state.\n", conn_idx);
#endif
            close_connection(conn_idx);
            break;

        case TCP_STATE_LISTEN:
            break;

        case TCP_STATE_SYN_RECEIVED:
            if (flags & TCP_FLAG_ACK) {
                if (ack_num == connection_seq_nums[conn_idx] + 1) {
#if DEBUG_En_tcp
                    printf("ACK for our SYN+ACK received (conn_idx %d). Transitioning to ESTABLISHED.\n", conn_idx);
#endif
                    connection_states[conn_idx] = TCP_STATE_ESTABLISHED;
                    connection_seq_nums[conn_idx]++;
                    // Reset SYN retry counter
                    connection_syn_retries[conn_idx] = 0;

                    if (tcp_data_len > 0) {
                        connection_ack_nums[conn_idx] = seq_num + tcp_data_len;
#if DEBUG_En_tcp
                        printf("  ACK in SYN_RECEIVED also contained data (%d bytes). Sending ACK.\n", tcp_data_len);
#endif
                        send_ack(conn_idx);
                        http_request_handler(conn_idx, tcp_data_len);
                    }
#if DEBUG_En_tcp
                    else {
                        printf("  Pure ACK for SYN+ACK. Connection established.\n");
                    }
#endif
                }
#if DEBUG_En_tcp
                else {
                    printf("ACK received in SYN_RECEIVED state (conn_idx %d), but ack_num (%ld) doesn't match expected (%ld).\n",
                           conn_idx, (long int)ack_num, (long int)(connection_seq_nums[conn_idx] + 1));
                }
#endif
            } else if (flags & TCP_FLAG_SYN) {
#if DEBUG_En_tcp
                printf("Duplicate SYN received in SYN_RECEIVED state (conn_idx %d). Resending SYN+ACK.\n", conn_idx);
#endif
                connection_last_tx_time[conn_idx] = 0;  // force immediate resend
                connection_syn_retries[conn_idx] = 1;
                send_syn_ack(conn_idx);
            }
            break;

        case TCP_STATE_ESTABLISHED:
            if (flags & TCP_FLAG_FIN) {
#if DEBUG_En_tcp
                printf("FIN received in ESTABLISHED state (conn_idx %d).\n", conn_idx);
#endif
                connection_ack_nums[conn_idx] = seq_num + 1;
                send_ack(conn_idx);
                connection_states[conn_idx] = TCP_STATE_CLOSE_WAIT;
                // Application-level close: send our FIN
                {
                    uint8 tcp_header[tcp_header_len];
                    uint16 checksum;
                    fill_tcp_header(conn_idx, TCP_FLAG_FIN | TCP_FLAG_ACK, tcp_header);
                    checksum = tcp_checksum_build(tcp_header, 0, connection_dst_ips[conn_idx], connection_src_ips[conn_idx], NULL, 0);
                    tcp_set_checksum(tcp_header, checksum);
                    ip_header_update(connection_src_ips[conn_idx], ip_header_len + tcp_header_len);
                    send_tcp_segment(tcp_header, NULL, 0);
                    connection_seq_nums[conn_idx]++;
                    connection_states[conn_idx] = TCP_STATE_LAST_ACK;
#if DEBUG_En_tcp
                    printf("  Sent our FIN+ACK, entering LAST_ACK (conn_idx %d).\n", conn_idx);
#endif
                }
            } else if ((flags & TCP_FLAG_ACK) && tcp_data_len > 0) {
#if DEBUG_En_tcp
                printf("Data received in ESTABLISHED state (conn_idx %d), len=%d, seq=%ld, ack=%ld.\n", conn_idx, tcp_data_len, (long int)seq_num, (long int)connection_ack_nums[conn_idx]);
#endif
                if (seq_num == connection_ack_nums[conn_idx]) {
                    connection_ack_nums[conn_idx] = seq_num + tcp_data_len;
#if DEBUG_En_tcp
                    printf("New connection ack num, and enter into http_request_handler: (conn_idx %d), ack=%ld.\n", conn_idx, (long int)connection_ack_nums[conn_idx]);
#endif
                    http_request_handler(conn_idx, tcp_data_len);
                } else {
#if DEBUG_En_tcp
                    printf("Warning: conn_idx %d received data with unexpected sequence number. Expected=%ld, Got=%ld.\n",
                           conn_idx, (long int)connection_ack_nums[conn_idx], (long int)seq_num);
#endif
                    send_ack(conn_idx);
                }
            } else if (flags == TCP_FLAG_ACK) {
#if DEBUG_En_tcp
                // printf("Pure ACK received in ESTABLISHED state (conn_idx %d), ack_num=%lu.\n", conn_idx, ack_num);
#endif
                if (ack_num > connection_seq_nums[conn_idx]) {
#if DEBUG_En_tcp
                    printf("  Warning: Received ACK for data not yet sent? ack_num=%ld, our seq_num=%ld\n", (long int)ack_num, (long int)connection_seq_nums[conn_idx]);
#endif
                }
            }
            break;

        case TCP_STATE_CLOSE_WAIT:
            // Already sent our FIN in ESTABLISHED handler above
            break;

        case TCP_STATE_FIN_WAIT_1:
            if (flags & TCP_FLAG_ACK) {
#if DEBUG_En_tcp
                printf("ACK for our FIN received (conn_idx %d). Transitioning to FIN_WAIT_2.\n", conn_idx);
#endif
                connection_states[conn_idx] = TCP_STATE_FIN_WAIT_2;
                if (flags & TCP_FLAG_FIN) {
#if DEBUG_En_tcp
                    printf("  ACK also contained FIN. Transitioning to TIME_WAIT.\n");
#endif
                    connection_ack_nums[conn_idx] = seq_num + 1;
                    send_ack(conn_idx);
                    connection_states[conn_idx] = TCP_STATE_TIME_WAIT;
                    connection_time_wait_start[conn_idx] = LCPU_LOCAL_TIME_L();
                }
            } else if (flags & TCP_FLAG_FIN) {
#if DEBUG_En_tcp
                printf("FIN received in FIN_WAIT_1 (Simultaneous Close, conn_idx %d). Transitioning to CLOSING.\n", conn_idx);
#endif
                connection_ack_nums[conn_idx] = seq_num + 1;
                send_ack(conn_idx);
                connection_states[conn_idx] = TCP_STATE_CLOSING;
            }
            break;

        case TCP_STATE_FIN_WAIT_2:
            if (flags & TCP_FLAG_FIN) {
#if DEBUG_En_tcp
                printf("FIN received in FIN_WAIT_2 (conn_idx %d). Transitioning to TIME_WAIT.\n", conn_idx);
#endif
                connection_ack_nums[conn_idx] = seq_num + 1;
                send_ack(conn_idx);
                connection_states[conn_idx] = TCP_STATE_TIME_WAIT;
                connection_time_wait_start[conn_idx] = LCPU_LOCAL_TIME_L();
            }
            break;

        case TCP_STATE_CLOSING:
            if (flags & TCP_FLAG_ACK) {
#if DEBUG_En_tcp
                printf("ACK for our FIN received in CLOSING state (conn_idx %d). Transitioning to TIME_WAIT.\n", conn_idx);
#endif
                connection_states[conn_idx] = TCP_STATE_TIME_WAIT;
                connection_time_wait_start[conn_idx] = LCPU_LOCAL_TIME_L();
            }
            break;

        case TCP_STATE_TIME_WAIT:
            if (flags & TCP_FLAG_FIN) {
#if DEBUG_En_tcp
                printf("Duplicate FIN received in TIME_WAIT (conn_idx %d). Resending ACK.\n", conn_idx);
#endif
                connection_ack_nums[conn_idx] = seq_num + 1;
                send_ack(conn_idx);
            }
            break;

        case TCP_STATE_LAST_ACK:
            if (flags & TCP_FLAG_ACK) {
                if (ack_num == connection_seq_nums[conn_idx]) {
#if DEBUG_En_tcp
                    printf("Final ACK for our FIN received (conn_idx %d). Connection closed.\n", conn_idx);
#endif
                    close_connection(conn_idx);
                }
#if DEBUG_En_tcp
                else {
                    printf("ACK received in LAST_ACK state (conn_idx %d), but ack_num (%ld) doesn't match expected (%ld).\n",
                           conn_idx, (long int)ack_num, (long int)connection_seq_nums[conn_idx]);
                }
#endif
            }
#if DEBUG_En_tcp
            else {
                printf("Unexpected packet received in LAST_ACK (conn_idx %d). Flags=0x%02X.\n", conn_idx, flags);
            }
#endif
            break;

        default:
#if DEBUG_En_tcp
            printf("Error: Connection %d is in unknown state %d.\n", conn_idx, current_state);
#endif
            close_connection(conn_idx);
            break;
    }
}
