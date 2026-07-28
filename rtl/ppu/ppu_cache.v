// SS Handheld 2D PPU - shared read cache v2 (A3)
//
// Direct-mapped, 64 lines x 8 words (2 KB data), burst-filled: a miss issues
// one 8-word burst (m_burst=1) and refills the whole line, so SDRAM sees only
// burst traffic from renderers. Hit: 1-cycle response. `flush` invalidates.

module ppu_cache (
    input  wire        clk,
    input  wire        rst,
    input  wire        flush,

    // requester side (single-word reads from the renderer arbiter)
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output reg         s_rvalid,

    // memory side (8-word burst fills)
    output reg  [31:0] m_araddr,
    output reg         m_arvalid,
    output wire        m_burst,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,

    // stats
    output reg  [31:0] stat_hits,
    output reg  [31:0] stat_misses,
    output wire [1:0]  dbg_state
);

    localparam LINES = 64;
    localparam IDXW  = 6;              // 64 lines
    localparam OFFW  = 3;              // 8 words/line
    localparam TAGW  = 32 - IDXW - OFFW;

    reg [31:0]      data [0:LINES*8-1];
    reg [TAGW-1:0]  tag  [0:LINES-1];
    reg [LINES-1:0] valid;

    wire [OFFW-1:0] off  = s_araddr[OFFW-1:0];
    wire [IDXW-1:0] idx  = s_araddr[OFFW +: IDXW];
    wire [TAGW-1:0] atag = s_araddr[31:OFFW+IDXW];
    wire            hit  = valid[idx] && (tag[idx] == atag);

    assign m_burst = 1'b1;

    localparam C_IDLE = 2'd0;
    localparam C_MISS = 2'd1;
    localparam C_FILL = 2'd2;

    reg [1:0]       state;
    assign dbg_state = state;
    reg [IDXW-1:0]  fill_idx;
    reg [TAGW-1:0]  fill_tag;
    reg [OFFW-1:0]  fill_off;          // beats received
    reg [OFFW-1:0]  want_off;          // requested word within the line

    assign s_arready = (state == C_IDLE);

    always @(posedge clk)
    begin
        s_rvalid <= 1'b0;

        if (rst)
        begin
            state       <= C_IDLE;
            valid       <= {LINES{1'b0}};
            m_arvalid   <= 1'b0;
            stat_hits   <= 32'd0;
            stat_misses <= 32'd0;
        end
        else
        begin
            // flush runs in PARALLEL with the FSM: an `else if` here once
            // swallowed an in-flight request when vsync raced a handshake
            // (deadlock). A line filled this same cycle re-validates after.
            if (flush)
            begin
                valid <= {LINES{1'b0}};
            end
            case (state)
                C_IDLE:
                begin
                    if (s_arvalid)
                    begin
                        if (hit)
                        begin
                            s_rdata   <= data[{idx, off}];
                            s_rvalid  <= 1'b1;
                            stat_hits <= stat_hits + 32'd1;
                        end
                        else
                        begin
                            m_araddr    <= {s_araddr[31:OFFW], {OFFW{1'b0}}};
                            m_arvalid   <= 1'b1;
                            fill_idx    <= idx;
                            fill_tag    <= atag;
                            fill_off    <= {OFFW{1'b0}};
                            want_off    <= off;
                            stat_misses <= stat_misses + 32'd1;
                            state       <= C_MISS;
                        end
                    end
                end

                C_MISS:
                begin
                    if (m_arready)
                    begin
                        m_arvalid <= 1'b0;
                        state     <= C_FILL;
                    end
                end

                C_FILL:
                begin
                    if (m_rvalid)
                    begin
                        data[{fill_idx, fill_off}] <= m_rdata;
                        if (fill_off == want_off)
                        begin
                            s_rdata  <= m_rdata;
                            s_rvalid <= 1'b1;   // early return of the hot word
                        end
                        if (fill_off == {OFFW{1'b1}})
                        begin
                            tag[fill_idx]   <= fill_tag;
                            valid[fill_idx] <= 1'b1;
                            state           <= C_IDLE;
                        end
                        fill_off <= fill_off + {{OFFW-1{1'b0}}, 1'b1};
                    end
                end

                default: state <= C_IDLE;
            endcase
        end
    end

endmodule