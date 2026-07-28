// SS Handheld - SDR SDRAM controller v0.1 (A2)
//
// 32-bit data bus = 2x 16-bit SDR chips (IS42S16400-class: 4M x 16,
// row 12b / bank 2b / col 8b) in lockstep -> 4M x 32b words.
//
// v0.1 policy: correct-first. All-banks-closed, single-beat reads/writes
// with auto-precharge, CL=3. Open-row + bursts + bank interleave are the
// planned efficiency upgrades (spec section 7 arbiter notes).
//
// Word address map: {row[11:0], bank[1:0], col[7:0]} = addr[21:0].
//
// dq is split (dq_i/dq_o/dq_oe) for simulator friendliness; the board top
// ties them to the bidirectional pads.

module sdram_ctrl #(
    parameter INIT_WAIT   = 26600, // 200 us @ 133 MHz (shrink in sim)
    parameter tRCD        = 3,     // 20 ns
    parameter tRP         = 3,
    parameter tRFC        = 9,     // 66 ns
    parameter tMRD        = 2,
    parameter tWR         = 2,
    parameter CL          = 3,
    parameter REFRESH_DIV = 1039   // 7.8125 us @ 133 MHz
) (
    input  wire        clk,
    input  wire        rst,

    // host port (word granularity)
    input  wire        req,
    input  wire        we,
    input  wire        burst,      // read-only: 8-word burst, addr 8-aligned
    input  wire [21:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wbe,        // byte enables for writes
    output wire        ready,      // accepts req this cycle
    output reg  [31:0] rdata,
    output reg         rvalid,
    output reg         wdone,
    output reg         init_done,

    // SDRAM pins
    output reg         s_cke,
    output reg         s_cs_n,
    output reg         s_ras_n,
    output reg         s_cas_n,
    output reg         s_we_n,
    output reg  [1:0]  s_ba,
    output reg  [11:0] s_a,
    output reg  [3:0]  s_dqm,
    input  wire [31:0] s_dq_i,
    output reg  [31:0] s_dq_o,
    output reg         s_dq_oe
);

    // command encodings {ras,cas,we} with cs asserted
    // NOP = all high (default assignment in the clocked block)
    localparam CMD_ACT  = 3'b011;
    localparam CMD_RD   = 3'b101;
    localparam CMD_WR   = 3'b100;
    localparam CMD_PALL = 3'b010;
    localparam CMD_REF  = 3'b001;
    localparam CMD_MRS  = 3'b000;

    task cmd;
        input [2:0] c;
        begin
            s_cs_n  <= 1'b0;
            s_ras_n <= c[2];
            s_cas_n <= c[1];
            s_we_n  <= c[0];
        end
    endtask

    localparam ST_INIT_WAIT = 4'd0;
    localparam ST_INIT_PALL = 4'd1;
    localparam ST_INIT_REF1 = 4'd2;
    localparam ST_INIT_REF2 = 4'd3;
    localparam ST_INIT_MRS  = 4'd4;
    localparam ST_IDLE      = 4'd5;
    localparam ST_REFRESH   = 4'd6;
    localparam ST_ACT       = 4'd7;
    localparam ST_RD_WAIT   = 4'd9;
    localparam ST_WR_WAIT   = 4'd11;

    reg [3:0]  state;
    reg [15:0] dly;
    reg [10:0] ref_cnt;
    reg        ref_due;

    reg        r_we;
    reg        r_burst;
    reg [21:0] r_addr;
    reg [31:0] r_wdata;
    reg [3:0]  r_wbe;
    // read data return engine: wait CL+1 after RD hits the bus, then rv_cnt beats
    reg [2:0]  rv_wait;
    reg [3:0]  rv_cnt;

    assign ready = init_done && (state == ST_IDLE) && !ref_due;

    always @(posedge clk)
    begin
        rvalid <= 1'b0;
        wdone  <= 1'b0;
        // default: NOP
        s_cs_n  <= 1'b0;
        s_ras_n <= 1'b1;
        s_cas_n <= 1'b1;
        s_we_n  <= 1'b1;
        s_dq_oe <= 1'b0;

        // read data return: command spends a cycle on the bus before the chip
        // registers it, so first data lands CL+1 cycles after we issue RD
        if (rv_wait != 3'd0)
        begin
            rv_wait <= rv_wait - 3'd1;
        end
        else if (rv_cnt != 4'd0)
        begin
            rdata  <= s_dq_i;
            rvalid <= 1'b1;
            rv_cnt <= rv_cnt - 4'd1;
        end

        if (rst)
        begin
            state     <= ST_INIT_WAIT;
            dly       <= INIT_WAIT[15:0];
            init_done <= 1'b0;
            s_cke     <= 1'b1;
            s_dqm     <= 4'hF;
            ref_cnt   <= 11'd0;
            ref_due   <= 1'b0;
            rv_wait   <= 3'd0;
            rv_cnt    <= 4'd0;
        end
        else
        begin
            // refresh scheduling
            if (init_done)
            begin
                if (ref_cnt == REFRESH_DIV[10:0])
                begin
                    ref_cnt <= 11'd0;
                    ref_due <= 1'b1;
                end
                else
                begin
                    ref_cnt <= ref_cnt + 11'd1;
                end
            end

            case (state)
                ST_INIT_WAIT:
                begin
                    if (dly == 16'd0)
                    begin
                        cmd(CMD_PALL);
                        s_a[10] <= 1'b1;
                        dly     <= tRP[15:0];
                        state   <= ST_INIT_PALL;
                    end
                    else
                    begin
                        dly <= dly - 16'd1;
                    end
                end

                ST_INIT_PALL:
                begin
                    if (dly == 16'd0)
                    begin
                        cmd(CMD_REF);
                        dly   <= tRFC[15:0];
                        state <= ST_INIT_REF1;
                    end
                    else dly <= dly - 16'd1;
                end

                ST_INIT_REF1:
                begin
                    if (dly == 16'd0)
                    begin
                        cmd(CMD_REF);
                        dly   <= tRFC[15:0];
                        state <= ST_INIT_REF2;
                    end
                    else dly <= dly - 16'd1;
                end

                ST_INIT_REF2:
                begin
                    if (dly == 16'd0)
                    begin
                        cmd(CMD_MRS);
                        s_ba <= 2'b00;
                        s_a  <= 12'b00_1_00_011_0_011; // A9=1 single writes, CL=3, BL=8 seq
                        dly  <= tMRD[15:0];
                        state <= ST_INIT_MRS;
                    end
                    else dly <= dly - 16'd1;
                end

                ST_INIT_MRS:
                begin
                    if (dly == 16'd0)
                    begin
                        init_done <= 1'b1;
                        s_dqm     <= 4'h0;
                        state     <= ST_IDLE;
                    end
                    else dly <= dly - 16'd1;
                end

                ST_IDLE:
                begin
                    if (ref_due)
                    begin
                        cmd(CMD_REF);
                        ref_due <= 1'b0;
                        dly     <= tRFC[15:0];
                        state   <= ST_REFRESH;
                    end
                    else if (req)
                    begin
                        r_we    <= we;
                        r_burst <= burst && !we;
                        r_addr  <= addr;
                        r_wdata <= wdata;
                        r_wbe   <= wbe;
                        cmd(CMD_ACT);
                        s_ba    <= addr[9:8];
                        s_a     <= addr[21:10];
                        dly     <= tRCD[15:0] - 16'd1;
                        state   <= ST_ACT;
                    end
                end

                ST_REFRESH:
                begin
                    if (dly == 16'd0) state <= ST_IDLE;
                    else dly <= dly - 16'd1;
                end

                ST_ACT:
                begin
                    if (dly == 16'd0)
                    begin
                        if (r_we)
                        begin
                            cmd(CMD_WR);
                            s_ba    <= r_addr[9:8];
                            s_a     <= {4'b0100, r_addr[7:0]}; // A10=1 auto-precharge
                            s_dq_o  <= r_wdata;
                            s_dq_oe <= 1'b1;
                            s_dqm   <= ~r_wbe;
                            dly     <= (tWR + tRP);
                            state   <= ST_WR_WAIT;
                        end
                        else
                        begin
                            cmd(CMD_RD);
                            s_ba    <= r_addr[9:8];
                            s_a     <= {4'b0100, r_addr[7:0]};
                            rv_wait <= CL[2:0] + 3'd1;
                            rv_cnt  <= r_burst ? 4'd8 : 4'd1;
                            // BL=8 is chip-global: the chip streams 8 beats
                            // either way; auto-precharge fires after the burst.
                            // Single reads just discard beats 2-8 (rare path;
                            // renderer traffic is cached + burst-friendly).
                            dly     <= CL[15:0] + 16'd8 + tRP[15:0];
                            state   <= ST_RD_WAIT;
                        end
                    end
                    else dly <= dly - 16'd1;
                end

                ST_RD_WAIT:
                begin
                    if (dly == 16'd0) state <= ST_IDLE;
                    else dly <= dly - 16'd1;
                end

                ST_WR_WAIT:
                begin
                    // hold byte mask one extra cycle: the chip registers the
                    // WR command (and dqm) a cycle after we drive it
                    if (dly != (tWR[15:0] + tRP[15:0]))
                        s_dqm <= 4'h0;
                    if (dly == 16'd0)
                    begin
                        wdone <= 1'b1;
                        state <= ST_IDLE;
                    end
                    else dly <= dly - 16'd1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule