// SS Handheld - AXI slave -> SDRAM controller bridge v0.1
//
// Gives RasterIX's 32-bit AXI memory port (its internal crossbar output) a
// path onto our sdram_ctrl request interface. Single outstanding transaction
// by design (reads win over writes when both are pending). Reads are chunked
// into BL8 bursts while the address is 8-word aligned and >= 8 beats remain,
// singles otherwise; each chunk is collected into an 8-deep FIFO and drained
// to the R channel, decoupling the controller's un-backpressured rvalid
// stream from AXI rready. Writes issue one controller write per W beat
// (wstrb -> wbe) and wait for wdone, which is slow but simple. RasterIX traffic is
// not on the scanline-critical path (arbiter gives the PPU priority anyway).
//
// AXI assumptions (hold for every RasterIX master behind the crossbar):
// 32-bit data, INCR bursts, axsize = 4 bytes. IDs reflected, resp = OKAY.
//
// The m_* client port follows the gpu_top convention: m_req is LEVEL-held
// and consumed on m_req && m_ready (a pulse can lose to a refresh).

module axi_sdram_bridge #(
    parameter ID_WIDTH = 8
) (
    input  wire                  clk,
    input  wire                  rst,

    // AXI slave: write address / data / response
    input  wire [ID_WIDTH-1:0]   s_awid,
    input  wire [31:0]           s_awaddr,
    input  wire [7:0]            s_awlen,
    input  wire                  s_awvalid,
    output reg                   s_awready,

    input  wire [31:0]           s_wdata,
    input  wire [3:0]            s_wstrb,
    input  wire                  s_wlast,
    input  wire                  s_wvalid,
    output wire                  s_wready,

    output reg  [ID_WIDTH-1:0]   s_bid,
    output wire [1:0]            s_bresp,
    output reg                   s_bvalid,
    input  wire                  s_bready,

    // AXI slave: read address / data
    input  wire [ID_WIDTH-1:0]   s_arid,
    input  wire [31:0]           s_araddr,
    input  wire [7:0]            s_arlen,
    input  wire                  s_arvalid,
    output reg                   s_arready,

    output reg  [ID_WIDTH-1:0]   s_rid,
    output wire [31:0]           s_rdata,
    output wire [1:0]            s_rresp,
    output wire                  s_rlast,
    output wire                  s_rvalid,
    input  wire                  s_rready,

    // SDRAM client port (word addressed)
    output wire                  m_req,
    output wire                  m_we,
    output wire                  m_burst,
    output wire [21:0]           m_addr,
    output wire [31:0]           m_wdata,
    output wire [3:0]            m_wbe,
    input  wire                  m_ready,
    input  wire [31:0]           m_rdata,
    input  wire                  m_rvalid,
    input  wire                  m_wdone,

    output wire [2:0]            dbg_state
);

    assign s_bresp = 2'b00;
    assign s_rresp = 2'b00;

    assign dbg_state = state;

    localparam ST_IDLE    = 3'd0;
    localparam ST_RD_REQ  = 3'd1;
    localparam ST_RD_DATA = 3'd2;
    localparam ST_WR_BEAT = 3'd3;
    localparam ST_WR_ISSUE= 3'd4;
    localparam ST_WR_WAIT = 3'd5;
    localparam ST_WR_RESP = 3'd6;

    reg [2:0]  state;

    // transaction latches
    reg [21:0] addr_w;       // current word address
    reg [8:0]  req_left;     // read beats not yet requested
    reg [8:0]  drain_left;   // read beats not yet drained to R
    reg [3:0]  fill_left;    // beats of current chunk still to arrive
    reg        wlast_r;
    reg [31:0] wdata_r;
    reg [3:0]  wstrb_r;

    reg        pend;         // level-held request toward the mux
    reg        pend_we;
    reg        pend_burst;

    // read data FIFO (8 x 32)
    reg [31:0] rf [0:7];
    reg [3:0]  rwp, rrp;
    wire [3:0] rlevel     = rwp - rrp;
    wire       rf_empty   = (rlevel == 4'd0);

    assign s_rdata  = rf[rrp[2:0]];
    assign s_rvalid = !rf_empty;
    assign s_rlast  = (drain_left == 9'd1);
    assign s_wready = (state == ST_WR_BEAT);

    assign m_req   = pend;
    assign m_we    = pend_we;
    assign m_burst = pend_burst;
    assign m_addr  = addr_w;
    assign m_wdata = wdata_r;
    assign m_wbe   = wstrb_r;

    wire rd_chunk8 = (addr_w[2:0] == 3'd0) && (req_left >= 9'd8);

    always @(posedge clk)
    begin
        s_awready <= 1'b0;
        s_arready <= 1'b0;

        if (rst)
        begin
            state    <= ST_IDLE;
            pend     <= 1'b0;
            s_bvalid <= 1'b0;
            rwp      <= 4'd0;
            rrp      <= 4'd0;
        end
        else
        begin
            // read data collection runs independent of the FSM state
            if (m_rvalid && (fill_left != 4'd0))
            begin
                rf[rwp[2:0]] <= m_rdata;
                rwp          <= rwp + 4'd1;
                fill_left    <= fill_left - 4'd1;
            end

            // R channel drain
            if (s_rvalid && s_rready)
            begin
                rrp        <= rrp + 4'd1;
                drain_left <= drain_left - 9'd1;
            end

            case (state)
                ST_IDLE:
                begin
                    if (s_arvalid && !s_arready)
                    begin
                        s_arready  <= 1'b1;
                        s_rid      <= s_arid;
                        addr_w     <= s_araddr[23:2];
                        req_left   <= {1'b0, s_arlen} + 9'd1;
                        drain_left <= {1'b0, s_arlen} + 9'd1;
                        fill_left  <= 4'd0;
                        state      <= ST_RD_REQ;
                    end
                    else if (s_awvalid && !s_awready)
                    begin
                        s_awready <= 1'b1;
                        s_bid     <= s_awid;
                        addr_w    <= s_awaddr[23:2];
                        state     <= ST_WR_BEAT;
                    end
                end

                // read: request one chunk, wait for it, drain, repeat
                ST_RD_REQ:
                begin
                    if (!pend)
                    begin
                        pend       <= 1'b1;
                        pend_we    <= 1'b0;
                        pend_burst <= rd_chunk8;
                        fill_left  <= rd_chunk8 ? 4'd8 : 4'd1;
                        req_left   <= req_left - (rd_chunk8 ? 9'd8 : 9'd1);
                    end
                    else if (m_ready)
                    begin
                        pend  <= 1'b0;
                        state <= ST_RD_DATA;
                    end
                end

                ST_RD_DATA:
                begin
                    // chunk fully arrived and fully drained -> next chunk / done
                    if ((fill_left == 4'd0) && rf_empty)
                    begin
                        addr_w <= addr_w + (pend_burst ? 22'd8 : 22'd1);
                        state  <= (drain_left == 9'd0) ? ST_IDLE : ST_RD_REQ;
                    end
                end

                // write: one controller write per W beat
                ST_WR_BEAT:
                begin
                    if (s_wvalid)
                    begin
                        wdata_r <= s_wdata;
                        wstrb_r <= s_wstrb;
                        wlast_r <= s_wlast;
                        state   <= ST_WR_ISSUE;
                    end
                end

                ST_WR_ISSUE:
                begin
                    if (!pend)
                    begin
                        pend       <= 1'b1;
                        pend_we    <= 1'b1;
                        pend_burst <= 1'b0;
                    end
                    else if (m_ready)
                    begin
                        pend  <= 1'b0;
                        state <= ST_WR_WAIT;
                    end
                end

                ST_WR_WAIT:
                begin
                    if (m_wdone)
                    begin
                        addr_w <= addr_w + 22'd1;
                        if (wlast_r)
                        begin
                            s_bvalid <= 1'b1;
                            state    <= ST_WR_RESP;
                        end
                        else
                        begin
                            state <= ST_WR_BEAT;
                        end
                    end
                end

                ST_WR_RESP:
                begin
                    if (s_bready)
                    begin
                        s_bvalid <= 1'b0;
                        state    <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule