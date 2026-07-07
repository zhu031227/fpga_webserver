// spi_bootloader — SPI Flash → InstructRAM firmware bootloader
//
// Triggered by WC register write. Reads firmware from SPI Flash and writes
// it word-by-word into the InstructRAM (via pram_* interface).
//
// Operation:
//   1. Wait for trigger pulse
//   2. Read flash word at flash_addr via spi_ctrl
//   3. Write word to pram, increment addresses
//   4. Repeat until length bytes transferred
//   5. Assert done; status[2]=error on failure
//
// op_start is held high until op_done (level-triggered), safe for CDC
// between 50MHz system clock and slower spi_clk (5MHz).

module spi_bootloader #(
    parameter int PRAM_ADDR_WIDTH = 15
) (
    input  clk,
    input  reset_l,

    // Control / status
    input             trigger,          // single-cycle pulse from WC register
    input  [31:0]     flash_addr,       // Flash source byte address
    input  [31:0]     length,           // Bytes to transfer (multiple of 4)
    output reg [2:0]  status,           // [0]=busy, [1]=done, [2]=error

    // InstructRAM write port (muxed with LCPU pram path)
    output reg                        pram_wr,
    output reg [PRAM_ADDR_WIDTH-1:0]  pram_addr,
    output reg [31:0]                 pram_wdata,

    // SPI master interface (to spi_ctrl, level-triggered op_start)
    output reg         spi_op_start,
    output reg [15:0]  spi_channel_len,
    output reg [63:0]  spi_wdata,
    input  [31:0]      spi_rdata,
    input              spi_op_done
);

  localparam S_IDLE       = 3'd0;
  localparam S_READ_CMD   = 3'd1;
  localparam S_READ_WAIT  = 3'd2;
  localparam S_WRITE_PRAM = 3'd3;
  localparam S_NEXT       = 3'd4;
  localparam S_DONE       = 3'd5;

  reg [2:0]  state;
  reg [31:0] flash_addr_reg;
  reg [31:0] bytes_remaining;
  reg [31:0] pram_addr_reg;

  always @(posedge clk or negedge reset_l) begin
    if (!reset_l) begin
      state           <= S_IDLE;
      status          <= 3'b000;
      pram_wr         <= 1'b0;
      pram_addr       <= 0;
      pram_wdata      <= 32'b0;
      spi_op_start    <= 1'b0;
      spi_channel_len <= 16'd0;
      spi_wdata       <= 64'd0;
      flash_addr_reg  <= 32'd0;
      bytes_remaining <= 32'd0;
      pram_addr_reg   <= 0;
    end else begin
      pram_wr <= 1'b0;  // default: pulse

      case (state)

        S_IDLE: begin
          status       <= 3'b000;
          spi_op_start <= 1'b0;
          if (trigger) begin
            flash_addr_reg  <= flash_addr;
            bytes_remaining <= length;
            pram_addr_reg   <= 0;
            state <= S_READ_CMD;
          end
        end

        S_READ_CMD: begin
          status[0]       <= 1'b1;  // busy
          spi_wdata[63:56] <= 8'h03;
          spi_wdata[55:32] <= flash_addr_reg[23:0];
          spi_wdata[31:0]  <= 32'h0;
          spi_channel_len  <= 16'd64;      // 8 cmd + 24 addr + 32 data
          spi_op_start     <= 1'b1;        // hold until op_done (CDC-safe)
          state <= S_READ_WAIT;
        end

        S_READ_WAIT: begin
          if (spi_op_done) begin
            spi_op_start <= 1'b0;
            pram_wr      <= 1'b1;
            pram_addr    <= pram_addr_reg;
            pram_wdata   <= spi_rdata;
            state <= S_WRITE_PRAM;
          end
        end

        S_WRITE_PRAM: begin
          flash_addr_reg  <= flash_addr_reg + 4;
          pram_addr_reg   <= pram_addr_reg + 1;
          bytes_remaining <= bytes_remaining - 4;
          state <= S_NEXT;
        end

        S_NEXT: begin
          if (bytes_remaining <= 32'd4)
            state <= S_DONE;
          else
            state <= S_READ_CMD;
        end

        S_DONE: begin
          status <= 3'b010;  // done, stays until next trigger
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
