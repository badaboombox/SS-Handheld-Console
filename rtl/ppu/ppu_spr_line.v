// SS Handheld 2D PPU - sprite (OBJ) scanline renderer (v0.3)
//
// OAM: 256 entries x 2 words, preloadable:
//   w0: [9:0] x, [18:10] y, [20:19] size (8/16/32/64 square),
//       [22:21] priority, [23] enable, [24] hflip, [25] vflip, [29:26] palette
//   w1: [9:0] base tile index (1D mapping, 8x8 4bpp tiles, tileset shared fmt)
//       [15] affine enable, [14:10] matrix index, [16] double-size window
//       (affine mode ignores h/v flip; matrix = texture step per screen px,
//        GBA-style inverse transform, s8.8)
//
// Per line: scan OAM in index order, collect up to SPR_PER_LINE hits, then
// render each hit into the sprite line buffer. Lower OAM index wins per pixel
// (first-writer-wins mask). X in 0..1023 wraps (x > 512 acts negative).

module ppu_spr_line #(
    parameter LINE_W       = 480,
    parameter SPR_PER_LINE = 64   // sprites overlapping one scanline (DS-class)
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    output reg         done,
    input  wire [8:0]  line_y,

    input  wire [31:0] tile_base,    // sprite tileset (word address)

    // OAM preload: waddr = {entry[7:0], word_sel}
    input  wire        oam_wen,
    input  wire [8:0]  oam_waddr,
    input  wire [31:0] oam_wdata,

    // affine matrix table preload: waddr = {mat[4:0], param[1:0]} (pa,pb,pc,pd)
    input  wire        mat_wen,
    input  wire [6:0]  mat_waddr,
    input  wire [15:0] mat_wdata,

    // palette preload (shared format with BG)
    input  wire        pal_wen,
    input  wire [7:0]  pal_waddr,
    input  wire [15:0] pal_wdata,

    // memory read port
    output reg  [31:0] m_araddr,
    output reg         m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,

    // sprite line buffer write port: {priority, RGB565}
    output reg  [8:0]  lb_waddr,
    output reg  [15:0] lb_wdata,
    output reg  [1:0]  lb_wpri,
    output reg         lb_wen,
    output reg         lb_clear,     // pulse at line start: invalidate buffer
    output wire [3:0]  dbg_state
);

    // OAM (two arrays -> both words readable per cycle)
    reg [31:0] oam_w0 [0:255];
    reg [31:0] oam_w1 [0:255];
    always @(posedge clk)
    begin
        if (oam_wen)
        begin
            if (oam_waddr[0])
                oam_w1[oam_waddr[8:1]] <= oam_wdata;
            else
                oam_w0[oam_waddr[8:1]] <= oam_wdata;
        end
    end

    // affine matrices
    reg [15:0] mat_pa [0:31];
    reg [15:0] mat_pb [0:31];
    reg [15:0] mat_pc [0:31];
    reg [15:0] mat_pd [0:31];
    always @(posedge clk)
    begin
        if (mat_wen)
        begin
            case (mat_waddr[1:0])
                2'd0: mat_pa[mat_waddr[6:2]] <= mat_wdata;
                2'd1: mat_pb[mat_waddr[6:2]] <= mat_wdata;
                2'd2: mat_pc[mat_waddr[6:2]] <= mat_wdata;
                default: mat_pd[mat_waddr[6:2]] <= mat_wdata;
            endcase
        end
    end

    // palette. Mapped to block RAM (DP16KD) as a simple-dual-port: one write
    // port (asset upload) + one registered read port whose address is muxed
    // between the text (S_PIX) and affine (S_APLOT) plot states. The default
    // distributed-LUTRAM form had THREE ports (write + two async reads) so it
    // could not use a 2-port BRAM; its 256:1 read mux got spread out by the
    // full-chip placer and dominated the sprite critical path (~4.6 ns, mostly
    // routing). The registered read `lb_wdata <= palette[pal_ra]` keeps the
    // original latency (address this cycle, data next); lb_wen - set in the
    // FSM on the same edge - gates whether the line buffer captures it, so
    // reading every cycle (even on non-plot cycles) is harmless.
    (* ram_style = "block" *) reg [15:0] palette [0:255];
    wire [7:0] pal_ra = s_aff ? {s_pal, a_nibble} : {s_pal, nibble};
    always @(posedge clk)
    begin
        if (pal_wen)
            palette[pal_waddr] <= pal_wdata;
        lb_wdata <= palette[pal_ra];
    end

    // first-writer-wins mask
    reg [LINE_W-1:0] wr_mask;

    // scan-hit list (element holds an OAM index 0..255 -> 8 bits)
    reg [7:0] hits [0:SPR_PER_LINE-1];
    reg [6:0] hit_cnt;   // 0..64
    reg [6:0] hit_i;

    // current sprite registers
    reg [9:0] s_x;
    reg [8:0] s_y;
    reg [1:0] s_size;
    reg [1:0] s_pri;
    reg       s_hf, s_vf;
    reg [3:0] s_pal;
    reg [9:0] s_tile;
    reg       s_aff;
    reg       s_dbl;
    reg [4:0] s_mat;

    // affine working registers
    reg signed [15:0] a_pa, a_pb, a_pc, a_pd;
    reg signed [17:0] a_u, a_v;         // s10.8 texture coords
    reg [7:0]         apx;              // window pixel counter
    reg [31:0]        tc_addr;          // 1-entry tile-word cache
    reg               tc_ok;
    reg [31:0]        tc_word;

    reg  [6:0]  s_h;      // 8..64        (registered at S_LOAD2)
    reg  [3:0]  s_wtiles; // 1..8
    reg  [7:0]  w_win;    // render window (2x when affine+dbl)
    wire [8:0]  ry_raw   = line_y - s_y;                 // wraps mod 512
    wire [6:0]  row_eff7 = s_vf ? (s_h - 7'd1 - ry_raw[6:0]) : ry_raw[6:0];

    reg  [3:0]  colc;                                    // tile column counter
    wire [3:0]  col_eff  = s_hf ? (s_wtiles - 4'd1 - colc) : colc;

    // 1D tile mapping: tile + rowtile*wtiles + col. s_wtiles is always a power
    // of two (= 1<<s_size, square sprites) so the product is a shift by s_size
    // - done as `*` it inferred a full MULT18X18D whose round-trip routing to
    // the distant DSP column dominated the tile-fetch critical path (~8.6 ns).
    wire [9:0]  tidx = s_tile + ({6'd0, row_eff7[6:3]} << s_size) + {6'd0, col_eff};

    reg  [31:0] tile_row;
    reg  [2:0]  k;
    wire [2:0]  nib_sel = s_hf ? (3'd7 - k) : k;
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

    // output x for current pixel (wraps in 1024 space). Maintained as a
    // registered counter rather than a combinational s_x+colc*8+k add: init to
    // s_x+colc*8 at S_TR (k=0), then +1 per S_PIX pixel. Since k increments by 1
    // each cycle, ox_r == the old combinational ox every cycle (identical
    // mod-1024 wrap), but the multi-term adder no longer feeds the lb_wen carry
    // chain - pulls s_x off the sprite critical path.
    reg [9:0] ox_r;

    // scan-phase: registered OAM read (stage 1) then hit-evaluate (stage 2)
    // to keep the EBR->decode path off the critical cone
    reg  [8:0]  scan_i;    // counts 0..256 (256-deep OAM)
    reg  [7:0]  scan_e;    // entry index being evaluated (scan_i - 1)
    reg  [31:0] sc_w0_r;
    reg  [31:0] sc_w1_r;
    wire [8:0]  sc_ry  = line_y - sc_w0_r[18:10];
    wire [7:0]  sc_h   = (sc_w1_r[15] && sc_w1_r[16]) ? (8'd16 << sc_w0_r[20:19])
                                                      : (8'd8  << sc_w0_r[20:19]);
    wire        sc_hit = sc_w0_r[23] && ({1'd0, sc_ry} < {2'd0, sc_h});

    // load-phase registered OAM words
    reg  [31:0] ld_w0;
    reg  [31:0] ld_w1;

    // affine window geometry for the current sprite (registered at S_LOAD2)
    reg signed [9:0] a_dy;
    // texture bounds: 0 <= u,v < s_h (sprite native size)
    wire        a_u_ok  = !a_u[17] && ({1'b0, a_u[16:8]} < {3'd0, s_h});
    wire        a_v_ok  = !a_v[17] && ({1'b0, a_v[16:8]} < {3'd0, s_h});
    wire [9:0]  a_tidx  = s_tile + ({6'd0, a_v[13:11]} << s_size) + {6'd0, a_u[13:11]};
    wire [31:0] a_want  = tile_base + {19'd0, a_tidx, 3'd0} + {29'd0, a_v[10:8]};
    wire [9:0]  a_ox    = s_x + {2'd0, apx};

    reg [3:0] a_nibble;
    always @(*)
    begin
        case (a_u[10:8])
            3'd0: a_nibble = tc_word[3:0];
            3'd1: a_nibble = tc_word[7:4];
            3'd2: a_nibble = tc_word[11:8];
            3'd3: a_nibble = tc_word[15:12];
            3'd4: a_nibble = tc_word[19:16];
            3'd5: a_nibble = tc_word[23:20];
            3'd6: a_nibble = tc_word[27:24];
            default: a_nibble = tc_word[31:28];
        endcase
    end

    localparam S_IDLE   = 4'd0;
    localparam S_SCAN   = 4'd1;
    localparam S_LOAD   = 4'd2;
    localparam S_LOAD2  = 4'd6;
    localparam S_TAR    = 4'd3;
    localparam S_TR     = 4'd4;
    localparam S_PIX    = 4'd5;
    localparam S_DONE   = 4'd7;
    localparam S_ASETUP  = 4'd8;
    localparam S_ASETUP2 = 4'd12;
    localparam S_ACHK    = 4'd9;
    localparam S_ATR     = 4'd10;
    localparam S_APLOT   = 4'd11;

    // affine setup pipeline products
    reg signed [25:0] mUA, mUB, mVA, mVB;

    reg [3:0] state;
    assign dbg_state = state;

    always @(posedge clk)
    begin
        lb_wen   <= 1'b0;
        lb_clear <= 1'b0;
        done     <= 1'b0;

        if (rst)
        begin
            state     <= S_IDLE;
            m_arvalid <= 1'b0;
            tc_ok     <= 1'b0;
        end
        else
        begin
            case (state)
                S_IDLE:
                begin
                    if (start)
                    begin
                        scan_i   <= 9'd0;
                        hit_cnt  <= 7'd0;
                        wr_mask  <= {LINE_W{1'b0}};
                        lb_clear <= 1'b1;
                        state    <= S_SCAN;
                    end
                end

                S_SCAN:
                begin
                    // stage 1: registered OAM read for scan_i
                    sc_w0_r <= oam_w0[scan_i[7:0]];
                    sc_w1_r <= oam_w1[scan_i[7:0]];
                    scan_e  <= scan_i[7:0];
                    // stage 2: evaluate the previously read entry
                    if ((scan_i != 9'd0) && sc_hit && (hit_cnt < SPR_PER_LINE[6:0]))
                    begin
                        hits[hit_cnt[5:0]] <= scan_e;
                        hit_cnt            <= hit_cnt + 7'd1;
                    end
                    if (scan_i == 9'd256)   // 0..255 read + one drain evaluate
                    begin
                        hit_i <= 7'd0;
                        state <= S_LOAD;
                    end
                    else
                    begin
                        scan_i <= scan_i + 9'd1;
                    end
                end

                S_LOAD:
                begin
                    if (hit_i >= hit_cnt)
                    begin
                        state <= S_DONE;
                    end
                    else
                    begin
                        ld_w0 <= oam_w0[hits[hit_i[5:0]]];
                        ld_w1 <= oam_w1[hits[hit_i[5:0]]];
                        state <= S_LOAD2;
                    end
                end

                S_LOAD2:
                begin
                    s_x    <= ld_w0[9:0];
                    s_y    <= ld_w0[18:10];
                    s_size <= ld_w0[20:19];
                    s_pri  <= ld_w0[22:21];
                    s_hf   <= ld_w0[24];
                    s_vf   <= ld_w0[25];
                    s_pal  <= ld_w0[29:26];
                    s_tile <= ld_w1[9:0];
                    s_aff  <= ld_w1[15];
                    s_mat  <= ld_w1[14:10];
                    s_dbl  <= ld_w1[16];
                    s_h      <= 7'd8 << ld_w0[20:19];
                    s_wtiles <= 4'd1 << ld_w0[20:19];
                    w_win    <= (ld_w1[15] && ld_w1[16]) ? (8'd16 << ld_w0[20:19])
                                                         : (8'd8  << ld_w0[20:19]);
                    a_dy     <= $signed({1'b0, line_y - ld_w0[18:10]})
                              - $signed({3'b0,
                                  (ld_w1[15] && ld_w1[16]) ? (7'd8 << ld_w0[20:19])
                                                           : (7'd4 << ld_w0[20:19])});
                    a_pa   <= $signed(mat_pa[ld_w1[14:10]]);
                    a_pb   <= $signed(mat_pb[ld_w1[14:10]]);
                    a_pc   <= $signed(mat_pc[ld_w1[14:10]]);
                    a_pd   <= $signed(mat_pd[ld_w1[14:10]]);
                    colc   <= 4'd0;
                    state  <= ld_w1[15] ? S_ASETUP : S_TAR;
                end

                S_TAR:
                begin
                    m_araddr  <= tile_base + {19'd0, tidx, 3'd0} + {29'd0, row_eff7[2:0]};
                    m_arvalid <= 1'b1;
                    if (m_arvalid && m_arready)
                    begin
                        m_arvalid <= 1'b0;
                        state     <= S_TR;
                    end
                end

                S_TR:
                begin
                    if (m_rvalid)
                    begin
                        tile_row <= m_rdata;
                        k        <= 3'd0;
                        ox_r     <= s_x + {2'd0, colc, 3'd0};  // k=0 base
                        state    <= S_PIX;
                    end
                end

                S_PIX:
                begin
                    if ((ox_r < LINE_W) && (nibble != 4'd0) && !wr_mask[ox_r[8:0]])
                    begin
                        lb_waddr    <= ox_r[8:0];
                        // lb_wdata comes from the registered palette read (pal_ra)
                        lb_wpri     <= s_pri;
                        lb_wen      <= 1'b1;
                        wr_mask[ox_r[8:0]] <= 1'b1;
                    end
                    if (k == 3'd7)
                    begin
                        if (colc == (s_wtiles - 4'd1))
                        begin
                            hit_i <= hit_i + 7'd1;
                            state <= S_LOAD;
                        end
                        else
                        begin
                            colc  <= colc + 4'd1;
                            state <= S_TAR;
                        end
                    end
                    else
                    begin
                        k    <= k + 3'd1;
                        ox_r <= ox_r + 10'd1;   // tracks s_x+colc*8+k
                    end
                end

                // affine path 

                S_ASETUP:
                begin
                    // window-left texture coords: center-relative inverse map
                    // dx0 = -w_win/2; u0 = pa*dx0 + pb*dy + s_h/2 (s10.8)
                    // stage 1: the four products
                    mUA   <= a_pa * (-$signed({10'b0, w_win[7:1]}));
                    mUB   <= a_pb * a_dy;
                    mVA   <= a_pc * (-$signed({10'b0, w_win[7:1]}));
                    mVB   <= a_pd * a_dy;
                    state <= S_ASETUP2;
                end

                S_ASETUP2:
                begin
                    // stage 2: sums
                    a_u   <= mUA[17:0] + mUB[17:0] + $signed({4'd0, s_h, 7'd0});
                    a_v   <= mVA[17:0] + mVB[17:0] + $signed({4'd0, s_h, 7'd0});
                    apx   <= 8'd0;
                    state <= S_ACHK;
                end

                S_ACHK:
                begin
                    if (!(a_u_ok && a_v_ok))
                    begin
                        state <= S_APLOT; // out of texture: skip fetch, no plot
                    end
                    else if (tc_ok && (tc_addr == a_want))
                    begin
                        state <= S_APLOT;
                    end
                    else
                    begin
                        m_araddr  <= a_want;
                        m_arvalid <= 1'b1;
                        if (m_arvalid && m_arready)
                        begin
                            m_arvalid <= 1'b0;
                            state     <= S_ATR;
                        end
                    end
                end

                S_ATR:
                begin
                    if (m_rvalid)
                    begin
                        tc_word <= m_rdata;
                        tc_addr <= a_want;
                        tc_ok   <= 1'b1;
                        state   <= S_APLOT;
                    end
                end

                S_APLOT:
                begin
                    if (a_u_ok && a_v_ok && (a_ox < LINE_W)
                        && (a_nibble != 4'd0) && !wr_mask[a_ox[8:0]])
                    begin
                        lb_waddr         <= a_ox[8:0];
                        // lb_wdata comes from the registered palette read (pal_ra)
                        lb_wpri          <= s_pri;
                        lb_wen           <= 1'b1;
                        wr_mask[a_ox[8:0]] <= 1'b1;
                    end
                    a_u <= a_u + {{2{a_pa[15]}}, a_pa};
                    a_v <= a_v + {{2{a_pc[15]}}, a_pc};
                    if (apx == (w_win - 8'd1))
                    begin
                        hit_i <= hit_i + 7'd1;
                        state <= S_LOAD;
                    end
                    else
                    begin
                        apx   <= apx + 8'd1;
                        state <= S_ACHK;
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