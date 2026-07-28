// SS Handheld 2D PPU - memory read arbiter (v0.6)
//
// N requesters -> one word-read port. Fixed priority (port 0 highest),
// single outstanding transaction, rdata broadcast + rvalid routed to owner.
// Models the SDRAM arbiter slot the PPU occupies (A11).

module ppu_arbiter #(
    parameter N = 8
) (
    input  wire              clk,
    input  wire              rst,

    // requesters (s_burst: 8-beat read, must be 8-aligned)
    input  wire [N*32-1:0]   s_araddr,
    input  wire [N-1:0]      s_arvalid,
    input  wire [N-1:0]      s_burst,
    output wire [N-1:0]      s_arready,
    output wire [N-1:0]      s_rvalid,
    output wire [31:0]       s_rdata,

    // memory side
    output reg  [31:0]       m_araddr,
    output reg               m_arvalid,
    output reg               m_burst,
    input  wire              m_arready,
    input  wire [31:0]       m_rdata,
    input  wire              m_rvalid,

    output wire              dbg_busy,
    output wire [3:0]        dbg_owner
);

    reg               busy;
    reg [$clog2(N)-1:0] owner;
    reg [3:0]         beats_left;

    assign dbg_busy  = busy;
    assign dbg_owner = {{4-$clog2(N){1'b0}}, owner};

    // fixed-priority pick
    integer i;
    reg [$clog2(N)-1:0] pick;
    reg                 pick_valid;
    always @(*)
    begin
        pick = {$clog2(N){1'b0}};
        pick_valid = 1'b0;
        for (i = N - 1; i >= 0; i = i - 1)
        begin
            if (s_arvalid[i])
            begin
                pick = i[$clog2(N)-1:0];
                pick_valid = 1'b1;
            end
        end
    end

    // grant: accept the picked request when idle
    assign s_arready = (!busy && pick_valid && !m_arvalid)
                       ? ({{N-1{1'b0}}, 1'b1} << pick) : {N{1'b0}};

    assign s_rdata  = m_rdata;
    assign s_rvalid = (busy && m_rvalid) ? ({{N-1{1'b0}}, 1'b1} << owner) : {N{1'b0}};

    always @(posedge clk)
    begin
        if (rst)
        begin
            busy      <= 1'b0;
            m_arvalid <= 1'b0;
        end
        else
        begin
            if (!busy && pick_valid && !m_arvalid)
            begin
                owner      <= pick;
                m_araddr   <= s_araddr[pick*32 +: 32];
                m_burst    <= s_burst[pick];
                beats_left <= s_burst[pick] ? 4'd8 : 4'd1;
                m_arvalid  <= 1'b1;
                busy       <= 1'b1;
            end
            if (m_arvalid && m_arready)
            begin
                m_arvalid <= 1'b0;
            end
            if (busy && m_rvalid)
            begin
                beats_left <= beats_left - 4'd1;
                if (beats_left == 4'd1)
                begin
                    busy <= 1'b0;
                end
            end
        end
    end

endmodule