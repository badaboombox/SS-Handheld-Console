// Behavioral SDR SDRAM model (sim only) - 4M x 32b (2x 16-bit chips lockstep).
// Decodes ACT/RD/WR/PALL/REF/MRS, CL-latency read pipeline, byte masks.
// Loose timing (no violation checks) - the controller TB verifies protocol
// by data correctness; real-chip timing margins come from datasheet math.

module sdram_model #(
    parameter CL = 3
) (
    input  wire        clk,
    input  wire        s_cke,
    input  wire        s_cs_n,
    input  wire        s_ras_n,
    input  wire        s_cas_n,
    input  wire        s_we_n,
    input  wire [1:0]  s_ba,
    input  wire [11:0] s_a,
    input  wire [3:0]  s_dqm,
    input  wire [31:0] s_dq_i,     // data from controller (writes)
    output reg  [31:0] s_dq_o,     // data to controller (reads)
    input  wire        s_dq_oe
);

    reg [31:0] mem [0:(1<<22)-1]; // 16 MB

    reg [11:0] row [0:3];

    wire [2:0] cmd = {s_ras_n, s_cas_n, s_we_n};

    // BL=8 sequential burst generator (mode register assumed BL8, A9=1
    // single writes, matching the controller's MRS)
    reg [13:0] b_base;    // {row-less} bank+col base handled via full addr
    reg [21:0] b_addr;
    reg [3:0]  b_cnt;

    // read pipeline (CL alignment)
    reg [21:0] rd_addr [0:4];
    reg [4:0]  rd_valid;

    integer i;
    always @(posedge clk)
    begin
        // advance read pipeline; data appears CL cycles after each beat
        for (i = 4; i > 0; i = i - 1)
        begin
            rd_addr[i]  <= rd_addr[i-1];
            rd_valid[i] <= rd_valid[i-1];
        end
        // remaining burst beats
        if (b_cnt != 4'd0)
        begin
            rd_addr[0]  <= b_addr;
            rd_valid[0] <= 1'b1;
            b_addr      <= {b_addr[21:3], b_addr[2:0] + 3'd1}; // wraps in block
            b_cnt       <= b_cnt - 4'd1;
        end
        else
        begin
            rd_valid[0] <= 1'b0;
        end

        // command decode (after the generator so an RD's first beat wins)
        if (s_cke && !s_cs_n)
        begin
            case (cmd)
                3'b011: row[s_ba] <= s_a;                       // ACT
                3'b101: begin                                    // RD: burst of 8
                    rd_addr[0]  <= {row[s_ba], s_ba, s_a[7:0]}; // beat 0 now
                    rd_valid[0] <= 1'b1;
                    b_addr <= {row[s_ba], s_ba, s_a[7:3], s_a[2:0] + 3'd1};
                    b_cnt  <= 4'd7;                              // beats 1-7
                end
                3'b100: begin                                    // WR (single, A9=1)
                    for (i = 0; i < 4; i = i + 1)
                    begin
                        if (!s_dqm[i])
                            mem[{row[s_ba], s_ba, s_a[7:0]}][i*8 +: 8] <= s_dq_i[i*8 +: 8];
                    end
                end
                default: ;                                       // NOP/PALL/REF/MRS
            endcase
        end

        if (rd_valid[CL-1])
            s_dq_o <= mem[rd_addr[CL-1]];
    end

endmodule