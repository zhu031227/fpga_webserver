#include "inc/lcpu_general.h"
#include "inc/comlib.h"
#include "inc/eth.h"
#include "inc/arp.h"
#include "inc/ip.h"
#include "inc/icmp.h"
#include "inc/tcp.h"
#include "inc/http.h"
#include "inc/local_config.h"
#include "inc/whitelist.h"
#include "build_time.h"

// Runtime globals (cached from registers)
uint32 g_local_ip = Local_IP_ADDR;
uint32 g_local_mac_high = Local_MAC_HIGH;
uint32 g_local_mac_low = Local_MAC_LOW;

// P0 取证计数器: 主循环弹包数 / 发包 push 数 (JTAG 读 0x13, [15:0]=rx [31:16]=tx)
volatile uint32 g_dbg_rx_cnt = 0;
volatile uint32 g_dbg_tx_cnt = 0;
volatile uint32 g_dbg_parse_cnt = 0;   // 解析成功(非NO_PROC)计数 → debug_rw_1
volatile uint32 g_dbg_first_word = 0;  // 最近弹包首字(以太网头) → debug_rw_0

void designApp() {
    uint32 rec_pkt_len = 0;
    uint32 eth_proc_result = 0;
    uint32 ip_proc_result = 0;

    // write software build timestamp to registers
    lcpu_baseaddr->sw_build_date = BUILD_DATE;
    lcpu_baseaddr->sw_build_time = BUILD_TIME;

    // Load local IP/MAC config from Flash (or use defaults)
    local_config_init();

    // Load whitelist from Flash
    whitelist_init();

    tcp_connection_init();

    while (1) {
        heart_beat_mod2();

        tcp_periodic_check();

        if (!LCPU_RD_EMPTY()) {
            g_dbg_rx_cnt++;
            LCPU_RD_START_PACKET();
            {   /* P0 取证: 抄包首字(dst MAC 前4字节)到 debug_rw_0 */
                LCPU_RD_SET_ADDR(0);
                uint32 w = ((uint32)LCPU_RD_DATA8() << 24);
                LCPU_RD_INC_ADDR();
                w |= ((uint32)LCPU_RD_DATA8() << 16);
                LCPU_RD_INC_ADDR();
                w |= ((uint32)LCPU_RD_DATA8() << 8);
                LCPU_RD_INC_ADDR();
                w |= (uint32)LCPU_RD_DATA8();
                g_dbg_first_word = w;
            }
            rec_pkt_len = LCPU_RD_PKT_LEN();
            if (LCPU_WR_TEST_ENABLE()) {
                cp_fifo_test(rec_pkt_len);
            } else {
                eth_proc_result = eth_proc();
                if (eth_proc_result != NO_PROC) g_dbg_parse_cnt++;  /* 解析成功计数(处理分支内, 无滞留污染) */
                switch (eth_proc_result) {
                    case ARP_PROC:
                        arp_reply();
                        break;
                    case IP_PROC:
                        ip_proc_result = ip_proc();
                        switch (ip_proc_result) {
                            case ICMP_PROC:
                                icmp_reply();
                                break;
                            case TCP_PROC:
                                tcp_packet_handler();
                                break;
                            default:
                                break;
                        }
                        break;
                    default:
                        break;
                }
            }
        }
        // 每圈回写取证计数器到 debug 寄存器 (JTAG 直读)
        lcpu_baseaddr->debug_rw_3 = (g_dbg_tx_cnt << 16) | (g_dbg_rx_cnt & 0xFFFFu);
        lcpu_baseaddr->debug_rw_1 = g_dbg_parse_cnt & 0xFFFFu;
        lcpu_baseaddr->debug_rw_0 = g_dbg_first_word;
    }
}
