#include "inc/lcpu_general.h"
#include "inc/comlib.h"

/* heart_beat_mod2 状态变量（全局，跨调用保持状态）
 * 必须用 uint32，不能用 uint8：
 * 这些状态变量需要跨调用保持一致，继续使用 uint32 可避免与旧固件/旧硬件假设产生布局差异。
 * 若用 uint8，三个变量打包在同一个字内，任意一个变量的写操作会覆盖其他两个。
 */
static uint32 hb2_prev_event = 0xFFFFFFFFu; /* 0xFF确保第一次调用时必定触发更新 */
static uint32 hb2_led_val    = 0x00000000u;
static uint32 hb2_going_up   = 0x00000001u; /* 1=递增方向, 0=递减方向 */

/* heart_beat_mod3 状态变量：0x1→0x2→0x4→0x8→0x1 循环左移 */
static uint32 hb3_prev_event = 0xFFFFFFFFu;
static uint32 hb3_led_val    = 0x00000001u; /* 初始值0x1 */

/*
 * Inputs: None.
 * Outputs: None.
 * Side effects: Updates LED pattern register.
 */

 /*
 * Inputs: None.
 * Outputs: None.
 * Side effects: Toggles LED register between 0x05 and 0x0A.
 */
void heart_beat_mod1() {
    uint32 second_event = LCPU_SECOND_EVENT();
    uint32 next_led = (second_event == 0u) ? 0x05u : 0x0Au;

    LCPU_SET_LED(next_led);
}

/*
 * Inputs: None.
 * Outputs: None.
 * Side effects: Cycles LED register across 0x01/0x02/0x03/0x04... using hardware time bits.
 */
void heart_beat_mod2() {
    /* 只取 bit[0]：reg_rdata[7:1] 会残留上次其他寄存器读取的值，必须屏蔽高位 */
    uint32 second_event = LCPU_SECOND_EVENT() & 0x00000001u;

    if (second_event != hb2_prev_event) {
        hb2_prev_event = second_event;  /* 更新上次事件值 */
        if (hb2_going_up) {
            if (hb2_led_val < 0x0Fu) {
                hb2_led_val++;
            } else {               /* 到达0xF，转为递减 */
                hb2_going_up = 0u;
                hb2_led_val--;
            }
        } else {
            if (hb2_led_val > 0x00u) {
                hb2_led_val--;
            } else {               /* 到达0x0，转为递增 */
                hb2_going_up = 1u;
                hb2_led_val++;
            }
        }
    }

    LCPU_SET_LED(hb2_led_val);
}

/*
 * Inputs: None.
 * Outputs: None.
 * Side effects: LED寄存器按 0x1→0x2→0x4→0x8→0x1 循环左移，每次second_event跳变时移位一次。
 */
void heart_beat_mod3() {
    /* 只取 bit[0]，屏蔽reg_rdata高位残留值 */
    uint32 second_event = LCPU_SECOND_EVENT() & 0x00000001u;

    if (second_event != hb3_prev_event) {
        hb3_prev_event = second_event;
        hb3_led_val = (hb3_led_val << 1u);
        if (hb3_led_val > 0x08u) {
            hb3_led_val = 0x01u;  /* 0x8左移后回绕至0x1 */
        }
    }

    LCPU_SET_LED(hb3_led_val);
}

/*
 * Inputs: rec_pkt_len (bytes to copy).
 * Outputs: None.
 * Side effects: Copies RX packet to TX buffer and triggers transmit.
 */
void cp_fifo_test(uint16 rec_pkt_len) {
	uint32 i=0;
  for(i=0;i<rec_pkt_len;i++){
        LCPU_RD_SET_ADDR(i);
        LCPU_WR_BYTE(i, LCPU_RD_DATA8());
	}
    LCPU_WR_PUSH_PACKET(rec_pkt_len);
}

// 延时函数，简单的空循环
/*
 * Inputs: count (loop cycles).
 * Outputs: None.
 * Side effects: Busy-wait delay.
 */
void delay(volatile uint32 count) {
    while (count--) {
        // 空操作，等待一定的时间
    }
}

/*
 * Inputs: a,b (16-bit word bytes), c (accumulator).
 * Outputs: Folded 16-bit checksum partial.
 * Side effects: None.
 */
uint16 cks_sum_cal(uint32 a,uint32 b,uint16 c)
{
  uint32 sum = (a << 8 | b) + c;
  while (sum >> 16) {
    sum = (sum & 0xFFFF) + (sum >> 16);
  }

  return sum & 0xFFFF;
}

/*
 * Inputs: tcp_len (TCP header+payload length).
 * Outputs: TCP checksum value.
 * Side effects: Reads packet data from RX FIFO.
 */
uint16 tcp_calculate_checksum(uint16 tcp_len) {
    uint32 sum = 0;
    uint32 data;
		
		uint16 i=0;
    // 伪头部计算
    for(i=12; i<16; i++) { // 源IP
        LCPU_RD_SET_ADDR(eth_header_len + i);
        sum += (i%2) ? LCPU_RD_DATA8() : (LCPU_RD_DATA8() << 8);
    }
    for(i=16; i<20; i++) { // 目的IP
        LCPU_RD_SET_ADDR(eth_header_len + i);
        sum += (i%2) ? LCPU_RD_DATA8() : (LCPU_RD_DATA8() << 8);
    }
    sum += IP_PROTOCOL_TCP;
    //sum += htons(tcp_len);
		sum += tcp_len;

    // TCP头部和数据
    for(i=0; i<tcp_len; i++) {
        LCPU_RD_SET_ADDR(eth_header_len + ip_header_len + i);
        data = LCPU_RD_DATA8();
        if(i == 16 || i == 17) continue; // 跳过校验和字段
        if(i%2 == 0) {
            sum += data << 8;
        } else {
            sum += data;
        }
    }

    // 处理进位
    while(sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16)~sum;
}

/*
 * Inputs: None.
 * Outputs: Low 32 bits of local time counter.
 * Side effects: Reads local-time register.
 */
uint32 get_local_time_l() {
    uint32 local_time = 0;
		local_time = LCPU_LOCAL_TIME_L();
    return local_time;
}

/*
 * Inputs: addr (word offset), data (32-bit value).
 * Outputs: None.
 * Side effects: Writes LCPU mapped register.
 */
void write_lcpu_register(uint32 addr, uint32 data) {
    LCPU_REG32_WRITE(addr, data);
}

/*
 * Inputs: addr (word offset).
 * Outputs: 32-bit register value.
 * Side effects: Reads LCPU mapped register.
 */
uint32 read_lcpu_register(uint32 addr) {
    return LCPU_REG32_READ(addr);
}

//把非法的16进制数的字符
/*
 * Inputs: str_in[8].
 * Outputs: str_hex[8] sanitized.
 * Side effects: None.
 */
void str_hex_chk(char str_in[8], char str_hex[8]) {
    for (int i = 0; i < 8; i++) {
        if (!((str_in[i] >= '0' && str_in[i] <= '9') || 
              (str_in[i] >= 'A' && str_in[i] <= 'F') || 
              (str_in[i] >= 'a' && str_in[i] <= 'f'))) {
            str_hex[i] = ' ';  // 替换非法字符为空格
        } else {
            str_hex[i] = str_in[i]; // 复制原字符
        }
    }
}
/*
 * Inputs: data (32-bit).
 * Outputs: hex_str[8] ASCII hex.
 * Side effects: None.
 */
void to_hex_string(unsigned int data, char hex_str[8]) {
    const char hex_digits[] = "0123456789ABCDEF";
    
    for (int i = 7; i >= 0; i--) {
        hex_str[i] = hex_digits[data & 0xF]; // 取最低4位转换
        data >>= 4;  // 右移 4 位
    }
}

// 将单个ASCII字符转换为十六进制数的值，非法返回255
/*
 * Inputs: ch (ASCII hex character).
 * Outputs: nibble value or 255 on invalid input.
 * Side effects: None.
 */
uint8_t hex_char_to_val(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    else if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    else if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    else return 255;  // 错误
}

/*
 * Inputs: nibble (0-15).
 * Outputs: ASCII hex character.
 * Side effects: None.
 */
char hex_to_ascii(uint8_t nibble) {
    if (nibble < 10)
        return '0' + nibble;
    else
        return 'A' + (nibble - 10);
}
