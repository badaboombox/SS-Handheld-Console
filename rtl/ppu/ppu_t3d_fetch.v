// SS Handheld 2D PPU - 3D framebuffer line fetcher v2 (burst)
// Fetches one line (LINE_W/2 words) as LINE_W/16 8-word bursts.

module ppu_t3d_fetch #(
    parameter LINE_W = 480
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    output reg         done,
    input  wire [8:0]  line_y,
    input  wire [31:0] base,          // word address of framebuffer

    output reg  [31:0] m_araddr,
    output reg         m_arvalid,
    output wire        m_burst,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire        m_rvalid,

    // line buffer write: two pixels per beat
    output reg  [7:0]  lb_word,
    output reg  [31:0] lb_data,
    output reg         lb_wen
);

    localparam WORDS  = LINE_W / 2;

    assign m_burst = 1'b1;

    localparam T_IDLE = 2'd0;
    localparam T_AR   = 2'd1;
    localparam T_R    = 2'd2;
    localparam T_DONE = 2'd3;

    reg [1:0] state;
    reg [7:0] wx;        // word index within line
    reg [2:0] beat;

    always @(posedge clk)
    begin
        done   <= 1'b0;
        lb_wen <= 1'b0;

        if (rst)
        begin
            state     <= T_IDLE;
            m_arvalid <= 1'b0;
        end
        else
        begin
            case (state)
                T_IDLE:
                begin
                    if (start)
                    begin
                        wx    <= 8'd0;
                        state <= T_AR;
                    end
                end

                T_AR:
                begin
                    m_araddr  <= base + ({23'd0, line_y} * WORDS[31:0]) + {24'd0, wx};
                    m_arvalid <= 1'b1;
                    beat      <= 3'd0;
                    if (m_arvalid && m_arready)
                    begin
                        m_arvalid <= 1'b0;
                        state     <= T_R;
                    end
                end

                T_R:
                begin
                    if (m_rvalid)
                    begin
                        lb_word <= wx + {5'd0, beat};
                        lb_data <= m_rdata;
                        lb_wen  <= 1'b1;
                        if (beat == 3'd7)
                        begin
                            if (wx == WORDS[7:0] - 8'd8)
                            begin
                                state <= T_DONE;
                            end
                            else
                            begin
                                wx    <= wx + 8'd8;
                                state <= T_AR;
                            end
                        end
                        else
                        begin
                            beat <= beat + 3'd1;
                        end
                    end
                end

                T_DONE:
                begin
                    done  <= 1'b1;
                    state <= T_IDLE;
                end

                default: state <= T_IDLE;
            endcase
        end
    end

endmodule