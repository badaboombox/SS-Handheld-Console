// SS Handheld - FMC bridge v0.1 (spec 6.6, D24-D28)
//
// CPU-side: STM32 FMC async NOR/PSRAM-style slave, 16-bit data, 10-bit
// word address. FPGA-side: everything synchronized into the GPU clock
// domain (2FF sync + write-strobe edge detect).
//
// Windows (fmc_a[9:8]):
//   00 REGS    : write 16b register (rw_* bus; SoC top decodes into PPU
//                config / OAM / palette / matrix ports)
//   01 STREAM  : write pairs (lo16 then hi16) -> 32b words into the command
//                FIFO -> cmd AXIS out (RasterIX s_cmd_axis)
//   10 SDRAM_UP: a[1:0]=0 PTR_LO, 1 PTR_HI (word address), 2 DATA (pairs;
//                auto-increment) -> up_* write port toward the SDRAM arbiter
//   11 STATUS  : read a[0]=0 -> cmd FIFO free words, 1 -> flags
//
// v0.1: no NWAIT (FIFO depth + STATUS polling per spec); reads only in the
// STATUS window.

module fmc_bridge #(
    parameter FIFO_LG = 9   // 512 x 32 command FIFO
) (
    input  wire        clk,      // GPU domain
    input  wire        rst,

    // FMC pins
    input  wire        fmc_ne,
    input  wire        fmc_nwe,
    input  wire        fmc_noe,
    input  wire [9:0]  fmc_a,
    input  wire [15:0] fmc_d_i,
    output reg  [15:0] fmc_d_o,
    output wire        fmc_d_oe,

    // register write bus (SoC top decodes)
    output reg         rw_wen,
    output reg  [7:0]  rw_addr,
    output reg  [15:0] rw_wdata,

    // command stream out (AXIS-lite)
    output wire [31:0] cmd_tdata,
    output wire        cmd_tvalid,
    input  wire        cmd_tready,

    // SDRAM upload port (word writes, toward arbiter)
    output reg         up_wen,
    output reg  [21:0] up_addr,
    output reg  [31:0] up_wdata,

    // status flags readback (init_done, vblank, ...)
    input  wire [15:0] status_flags,

    // wait request toward the STM32 (board maps to FMC NWAIT, active low
    // there since polarity handled at the pad). Asserted while the command FIFO
    // is nearly full so back-to-back STREAM writes throttle instead of drop.
    output wire        fmc_wait
);

    // CDC: sync controls, detect end-of-write strobe

    reg [2:0] ne_s, nwe_s, noe_s;
    always @(posedge clk)
    begin
        ne_s  <= {ne_s[1:0], fmc_ne};
        nwe_s <= {nwe_s[1:0], fmc_nwe};
        noe_s <= {noe_s[1:0], fmc_noe};
    end

    // write completes on NWE rising edge while selected; address and data
    // are stable then (FMC hold time covers the sync delay)
    wire wr_stb = !ne_s[1] && nwe_s[1] && !nwe_s[2];

    wire [1:0] win = fmc_a[9:8];

    // command FIFO 

    reg [31:0] fifo [0:(1<<FIFO_LG)-1];
    reg [FIFO_LG:0] wptr, rptr;
    wire [FIFO_LG:0] level = wptr - rptr;
    wire fifo_full  = level[FIFO_LG];
    wire fifo_empty = (level == 0);
    wire [15:0] fifo_free = (16'd1 << FIFO_LG) - {{15-FIFO_LG{1'b0}}, level};

    assign fmc_wait = (fifo_free < 16'd8);

    assign cmd_tdata  = fifo[rptr[FIFO_LG-1:0]];
    assign cmd_tvalid = !fifo_empty;

    reg [15:0] pair_lo;
    reg        pair_have;

    // upload pointer 

    reg [21:0] up_ptr;
    reg [15:0] up_lo;
    reg        up_have;

    always @(posedge clk)
    begin
        rw_wen <= 1'b0;
        up_wen <= 1'b0;

        if (rst)
        begin
            wptr      <= {FIFO_LG+1{1'b0}};
            rptr      <= {FIFO_LG+1{1'b0}};
            pair_have <= 1'b0;
            up_have   <= 1'b0;
        end
        else
        begin
            // stream pop
            if (cmd_tvalid && cmd_tready)
            begin
                rptr <= rptr + 1'b1;
            end

            if (wr_stb)
            begin
                case (win)
                    2'b00: // REGS
                    begin
                        rw_wen   <= 1'b1;
                        rw_addr  <= fmc_a[7:0];
                        rw_wdata <= fmc_d_i;
                    end

                    2'b01: // STREAM (lo then hi)
                    begin
                        if (!pair_have)
                        begin
                            pair_lo   <= fmc_d_i;
                            pair_have <= 1'b1;
                        end
                        else
                        begin
                            if (!fifo_full)
                            begin
                                fifo[wptr[FIFO_LG-1:0]] <= {fmc_d_i, pair_lo};
                                wptr <= wptr + 1'b1;
                            end
                            pair_have <= 1'b0;
                        end
                    end

                    2'b10: // SDRAM_UP
                    begin
                        case (fmc_a[1:0])
                            2'd0: up_ptr[15:0]  <= fmc_d_i;
                            2'd1: up_ptr[21:16] <= fmc_d_i[5:0];
                            2'd2:
                            begin
                                if (!up_have)
                                begin
                                    up_lo   <= fmc_d_i;
                                    up_have <= 1'b1;
                                end
                                else
                                begin
                                    up_wen   <= 1'b1;
                                    up_addr  <= up_ptr;
                                    up_wdata <= {fmc_d_i, up_lo};
                                    up_ptr   <= up_ptr + 22'd1;
                                    up_have  <= 1'b0;
                                end
                            end
                            default: ;
                        endcase
                    end

                    default: ; // STATUS is read-only
                endcase
            end
        end
    end

    // read path (STATUS window only) 

    assign fmc_d_oe = !ne_s[1] && !noe_s[1] && (win == 2'b11);

    always @(posedge clk)
    begin
        fmc_d_o <= fmc_a[0] ? status_flags : fifo_free;
    end

endmodule