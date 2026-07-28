// SS Handheld 2D PPU - affine BG scanline renderer (v0.4a)
//
// Free-angle rotate/scale background. Per output pixel, DDA-accumulated
// source coords (s10.8) sample a 512x512px wrapping world made of the same
// 64x64 tilemap / 8x8 4bpp tile format as text layers (flips ignored, like
// GBA affine BGs). One-entry map-word + tile-word caches absorb most fetches
// at mild angles/scales, so the shared EBR tile cache fixes it.
//
//   u(x) = ox + pb*line_y + pa*x
//   v(x) = oy + pd*line_y + pc*x        pa..pd: s8.8, ox/oy: s10.8

module ppu_bg_affine_line #(
    parameter LINE_W = 480
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    output reg         done,
    input  wire [8:0]  line_y,

    // affine params
    input  wire signed [15:0] pa,
    input  wire signed [15:0] pb,
    input  wire signed [15:0] pc,
    input  wire signed [15:0] pd,
    input  wire signed [17:0] ox,       // s10.8 world origin
    input  wire signed [17:0] oy,

    input  wire [31:0] map_base,
    input  wire [31:0] tile_base,

    // palette preload
    input  wire        pal_wen,
    input  wire [7:0]  pal_waddr,
    input  wire [15:0] pal_wdata,

    // memory read port
    output reg  [31:0] m_araddr,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,

    // line buffer write port
    output reg  [8:0]  lb_waddr,
    output reg  [15:0] lb_wdata,
    output reg         lb_wopaque,
    output reg         lb_wen
);

    reg [15:0] palette [0:255];
    always @(posedge clk)
    begin
        if (pal_wen)
        begin
            palette[pal_waddr] <= pal_wdata;
        end
    end

    // DDA accumulators (s10.8; integer part wraps 0..511)
    reg signed [17:0] u;
    reg signed [17:0] v;
    reg [8:0] px;

    wire [8:0] wx = u[16:8];  // world x (wraps 512)
    wire [8:0] wy = v[16:8];

    wire [5:0]  tx        = wx[8:3];
    wire [5:0]  ty        = wy[8:3];
    wire [11:0] map_index = {ty, tx};

    // one-entry caches
    reg  [31:0] mapw_addr;  reg mapw_ok;  reg [31:0] mapw;
    reg  [31:0] tilw_addr;  reg tilw_ok;  reg [31:0] tilw;

    wire [31:0] want_mapw = map_base + {21'd0, map_index[11:1]};
    wire [15:0] entry     = map_index[0] ? mapw[31:16] : mapw[15:0];
    wire [31:0] want_tilw = tile_base + {19'd0, entry[9:0], wy[2:0]};

    reg [3:0] nibble;
    always @(*)
    begin
        case (wx[2:0])
            3'd0: nibble = tilw[3:0];
            3'd1: nibble = tilw[7:4];
            3'd2: nibble = tilw[11:8];
            3'd3: nibble = tilw[15:12];
            3'd4: nibble = tilw[19:16];
            3'd5: nibble = tilw[23:20];
            3'd6: nibble = tilw[27:24];
            default: nibble = tilw[31:28];
        endcase
    end

    localparam S_IDLE   = 4'd0;
    localparam S_SETUP  = 4'd1;
    localparam S_SETUP2 = 4'd8;
    localparam S_CHKMAP = 4'd2;
    localparam S_MAPR   = 4'd3;
    localparam S_CHKTIL = 4'd4;
    localparam S_TILR   = 4'd5;
    localparam S_EMIT   = 4'd6;
    localparam S_DONE   = 4'd7;

    reg [3:0] state;
    reg signed [26:0] mU, mV; // line-origin products

    always @(posedge clk)
    begin
        lb_wen <= 1'b0;
        done   <= 1'b0;

        if (rst)
        begin
            state     <= S_IDLE;
            m_arvalid <= 1'b0;
            mapw_ok   <= 1'b0;
            tilw_ok   <= 1'b0;
        end
        else
        begin
            case (state)
                S_IDLE:
                begin
                    if (start)
                    begin
                        state <= S_SETUP;
                    end
                end

                S_SETUP:
                begin
                    // per-line origin, stage 1: products
                    mU    <= pb * $signed({1'b0, line_y});
                    mV    <= pd * $signed({1'b0, line_y});
                    state <= S_SETUP2;
                end

                S_SETUP2:
                begin
                    // stage 2: sums (caches persist across lines)
                    u     <= ox + mU[17:0];
                    v     <= oy + mV[17:0];
                    px    <= 9'd0;
                    state <= S_CHKMAP;
                end

                S_CHKMAP:
                begin
                    if (mapw_ok && (mapw_addr == want_mapw))
                    begin
                        state <= S_CHKTIL;
                    end
                    else
                    begin
                        m_araddr  <= want_mapw;
                        m_arvalid <= 1'b1;
                        if (m_arvalid && m_arready)
                        begin
                            m_arvalid <= 1'b0;
                            state     <= S_MAPR;
                        end
                    end
                end

                S_MAPR:
                begin
                    if (m_rvalid)
                    begin
                        mapw      <= m_rdata;
                        mapw_addr <= want_mapw;
                        mapw_ok   <= 1'b1;
                        state     <= S_CHKTIL;
                    end
                end

                S_CHKTIL:
                begin
                    if (tilw_ok && (tilw_addr == want_tilw))
                    begin
                        state <= S_EMIT;
                    end
                    else
                    begin
                        m_araddr  <= want_tilw;
                        m_arvalid <= 1'b1;
                        if (m_arvalid && m_arready)
                        begin
                            m_arvalid <= 1'b0;
                            state     <= S_TILR;
                        end
                    end
                end

                S_TILR:
                begin
                    if (m_rvalid)
                    begin
                        tilw      <= m_rdata;
                        tilw_addr <= want_tilw;
                        tilw_ok   <= 1'b1;
                        state     <= S_EMIT;
                    end
                end

                S_EMIT:
                begin
                    lb_waddr   <= px;
                    lb_wdata   <= palette[{entry[15:12], nibble}];
                    lb_wopaque <= (nibble != 4'd0);
                    lb_wen     <= 1'b1;
                    u <= u + {{2{pa[15]}}, pa};
                    v <= v + {{2{pc[15]}}, pc};
                    if (px == LINE_W[8:0] - 9'd1)
                    begin
                        state <= S_DONE;
                    end
                    else
                    begin
                        px    <= px + 9'd1;
                        state <= S_CHKMAP;
                    end
                end

                S_DONE:
                begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule