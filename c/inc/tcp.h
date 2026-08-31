#ifndef TCP_H_
#define TCP_H_

#include <stdint.h>

#define MSS               1460
#define MAX_CONNECTIONS   16

#define TCP_STATE_CLOSED       0
#define TCP_STATE_LISTEN       1
#define TCP_STATE_SYN_RECEIVED 2
#define TCP_STATE_ESTABLISHED  3
#define TCP_STATE_FIN_WAIT_1   4
#define TCP_STATE_FIN_WAIT_2   5
#define TCP_STATE_CLOSING      6
#define TCP_STATE_TIME_WAIT    7
#define TCP_STATE_LAST_ACK     8
#define TCP_STATE_CLOSE_WAIT    9

#define TCP_FLAG_FIN  0x01u
#define TCP_FLAG_SYN  0x02u
#define TCP_FLAG_RST  0x04u
#define TCP_FLAG_PSH  0x08u
#define TCP_FLAG_ACK  0x10u
#define TCP_FLAG_URG  0x20u

#pragma pack(push, 1)

// TCP 场景下使用的以太网头（14 字节，线上为网络字节序）。
typedef struct {
    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];
    uint16_t ether_type; // 0x0800 (IPv4)
} tcp_eth_header_t;

// IPv4 头（无选项时 20 字节，IHL=5）。
typedef struct {
    uint8_t  ver_ihl;
    uint8_t  dscp_ecn;
    uint16_t total_len;
    uint16_t identification;
    uint16_t flags_frag_offset;
    uint8_t  ttl;
    uint8_t  protocol; // 0x06 (TCP)
    uint16_t hdr_checksum;
    uint8_t  src_ip[4];
    uint8_t  dst_ip[4];
} tcp_ipv4_header_t;

// TCP 基本头（无选项时 20 字节，data_offset=5）。
typedef struct {
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t seq_num;
    uint32_t ack_num;
    uint8_t  data_offset_reserved; // 高 4bit 为头长（单位 4 字节）
    uint8_t  flags;
    uint16_t window;
    uint16_t checksum;
    uint16_t urgent_ptr;
} tcp_header_t;

// TCP 校验和伪首部（仅用于校验和计算，不在线上传输）。
typedef struct {
    uint8_t  src_ip[4];
    uint8_t  dst_ip[4];
    uint8_t  zero;
    uint8_t  protocol; // 0x06
    uint16_t tcp_len;
} tcp_pseudo_header_t;

// 完整 TCP 帧（不含 FCS，payload 为可变长度）。
typedef struct {
    tcp_eth_header_t  eth;
    tcp_ipv4_header_t ip;
    tcp_header_t      tcp;
} tcp_frame_t;

#pragma pack(pop)

extern uint8_t  connection_states[MAX_CONNECTIONS];
extern uint32_t connection_seq_nums[MAX_CONNECTIONS];
extern uint32_t connection_ack_nums[MAX_CONNECTIONS];
extern uint16_t connection_src_ports[MAX_CONNECTIONS];
extern uint16_t connection_dst_ports[MAX_CONNECTIONS];
extern uint32_t connection_src_ips[MAX_CONNECTIONS];
extern uint32_t connection_dst_ips[MAX_CONNECTIONS];
extern uint32_t available_connections;

// Timer / housekeeping fields
extern uint64_t connection_time_wait_start[MAX_CONNECTIONS];
extern uint64_t connection_last_activity[MAX_CONNECTIONS];
extern uint64_t connection_last_tx_time[MAX_CONNECTIONS];
extern uint8_t  connection_syn_retries[MAX_CONNECTIONS];

void tcp_connection_init();
int  find_free_connection();
int  get_available_connections();
int  find_connection(uint16 src_port, uint16 dst_port, uint32 src_ip, uint32 dst_ip);
void close_connection(int conn_idx);
void send_syn_ack(int conn_idx);
void tcp_handle_syn(uint16 src_port, uint16 dst_port, uint32 src_ip, uint32 seq_num);
void send_http_response(int conn_idx, const char *response);
void send_http_buffer(int conn_idx, const uint8 *payload, uint32 payload_len);
void parse_post_data(const char *post_data);
void http_request_handler(int conn_idx, uint16_t tcp_data_len);
void send_ack(int conn_idx);
void send_rst(int conn_idx);
void tcp_packet_handler();
void tcp_periodic_check(void);

#endif // TCP_H_
