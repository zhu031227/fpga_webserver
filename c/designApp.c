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
            LCPU_RD_START_PACKET();
            rec_pkt_len = LCPU_RD_PKT_LEN();
            if (LCPU_WR_TEST_ENABLE()) {
                cp_fifo_test(rec_pkt_len);
            } else {
                eth_proc_result = eth_proc();
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
    }
}
