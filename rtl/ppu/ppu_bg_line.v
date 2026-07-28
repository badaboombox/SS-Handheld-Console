// SS Handheld 2D PPU - text BG layer scanline renderer (v0.1)
//
// Renders one scanline of one text background layer into the line buffer.
// Per 8px tile column: fetch tilemap entry -> fetch tile row -> unpack 8
// pixels (hflip-aware), palette lookup, write RGB565 pixels.
//
// Tilemap: 64x64 entries, 16b each (2 per 32b word):
//   [9:0] tile index, [10] hflip, [11] vflip, [15:12] palette
// Tile: 8 rows x 32b word (8 nibbles; low nibble = leftmost pixel pre-flip).
// Nibble 0 = transparent -> backdrop color (v0.1).
//
// Memory port: word-addressed read master (arvalid/arready, rvalid),
// shaped to sit behind the SDRAM arbiter.

module ppu_bg_line #(
    parameter LINE_W = 480
) (
    input  wire        clk,
    input  wire        rst,

    // control
    input  wire        start,        // pulse: render line_y with current cfg
    output reg         done,
    input  wire [8:0]  line_y,

    // layer config (static during a line)
    input  wire [9:0]  scroll_x,
    input  wire [8:0]  scroll_y,
    input  wire [31:0] map_base,     // word address of tilemap
    input  wire [31:0] tile_base,    // word address of tileset

    // palette preload (256 x RGB565; [pal(4b) colorIdx(4b)])
    input  wire        pal_wen,
    input  wire [7:0]  pal_waddr,
    input  wire [15:0] pal_wdata,

    // memory read port (word addresses)
    output reg  [31:0] m_araddr,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,

    // line buffer write port (v0.2: +opaque flag; every in-window pixel is
    // written each line so buffers never hold wrong opacity)
    output reg  [8:0]  lb_waddr,
    output reg  [15:0] lb_wdata,
    output reg         lb_wopaque,
    output reg         lb_wen,
    output wire [2:0]  dbg_state
);

    // palette RAM (infers BRAM/distributed)
    reg [15:0] palette [0:255];
    always @(posedge clk)
    begin
        if (pal_wen)
        begin
            palette[pal_waddr] <= pal_wdata;
        end
    end

    // derived source coordinates
    wire [9:0] y_src   = {1'b0, line_y} + {1'b0, scroll_y};
    wire [5:0] ty      = y_src[8:3];
    wire [2:0] row     = y_src[2:0];
    wire [2:0] fine_x  = scroll_x[2:0];
    wire [5:0] tx0     = scroll_x[8:3]; // tilemap is 64 wide; wraps

    localparam COLS = (LINE_W / 8) + 1; // +1 column covers fine scroll spill

    localparam S_IDLE    = 3'd0;
    localparam S_MAP_AR  = 3'd1;
    localparam S_MAP_R   = 3'd2;
    localparam S_TILE_AR = 3'd3;
    localparam S_TILE_R  = 3'd4;
    localparam S_PIX     = 3'd5;
    localparam S_DONE    = 3'd6;

    reg [2:0]  state;
    assign dbg_state = state;
    reg [6:0]  col;           // 0 .. COLS-1
    reg [15:0] entry;
    reg [31:0] tile_row;
    reg [2:0]  k;             // pixel within tile row
    reg signed [10:0] out_x;  // starts at -fine_x

    wire [5:0]  tcol      = tx0 + col[5:0];
    wire [11:0] map_index = {ty, tcol};             // ty*64 + tcol
    wire [2:0]  eff_row   = entry[11] ? (3'd7 - row) : row; // vflip

    // pixel select with hflip
    wire [2:0]  nib_sel = entry[10] ? (3'd7 - k) : k;
    reg  [3:0]  nibble;
    always @(*)
    begin
        case (nib_sel)
            3'd0: nibble = tile_row[3:0];
            3'd1: nibble = tile_row[7:4];
            3'd2: nibble = tile_row[11:8];
            3'd3: nibble = tile_row[15:12];
            3'd4: nibble = tile_row[19:16];
            3'd5: nibble = tile_row[23:20];
            3'd6: nibble = tile_row[27:24];
            default: nibble = tile_row[31:28];
        endcase
    end

    wire [7:0] pal_addr = {entry[15:12], nibble};

    always @(posedge clk)
    begin
        lb_wen <= 1'b0;
        done   <= 1'b0;

        if (rst)
        begin
            state     <= S_IDLE;
            m_arvalid <= 1'b0;
            col       <= 7'd0;
        end
        else
        begin
            case (state)
                S_IDLE:
                begin
                    if (start)
                    begin
                        col   <= 7'd0;
                        out_x <= -{8'd0, fine_x};
                        state <= S_MAP_AR;
                    end
                end

                S_MAP_AR:
                begin
                    m_araddr  <= map_base + {21'd0, map_index[11:1]};
                    m_arvalid <= 1'b1;
                    if (m_arvalid && m_arready)
                    begin
                        m_arvalid <= 1'b0;
                        state     <= S_MAP_R;
                    end
                end

                S_MAP_R:
                begin
                    if (m_rvalid)
                    begin
                        entry <= map_index[0] ? m_rdata[31:16] : m_rdata[15:0];
                        state <= S_TILE_AR;
                    end
                end

                S_TILE_AR:
                begin
                    m_araddr  <= tile_base + {19'd0, entry[9:0], eff_row};
                    m_arvalid <= 1'b1;
                    if (m_arvalid && m_arready)
                    begin
                        m_arvalid <= 1'b0;
                        state     <= S_TILE_R;
                    end
                end

                S_TILE_R:
                begin
                    if (m_rvalid)
                    begin
                        tile_row <= m_rdata;
                        k        <= 3'd0;
                        state    <= S_PIX;
                    end
                end

                S_PIX:
                begin
                    if ((out_x >= 0) && (out_x < LINE_W))
                    begin
                        lb_waddr   <= out_x[8:0];
                        lb_wdata   <= palette[pal_addr];
                        lb_wopaque <= (nibble != 4'd0);
                        lb_wen     <= 1'b1;
                    end
                    out_x <= out_x + 11'sd1;
                    if (k == 3'd7)
                    begin
                        if (col == COLS[6:0] - 7'd1)
                        begin
                            state <= S_DONE;
                        end
                        else
                        begin
                            col   <= col + 7'd1;
                            state <= S_MAP_AR;
                        end
                    end
                    else
                    begin
                        k <= k + 3'd1;
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
