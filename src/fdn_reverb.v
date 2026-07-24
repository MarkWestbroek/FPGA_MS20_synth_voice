// ============================================================================
// FDN_REVERB — 8×8 feedback-delay-network reverb (Fase D, doc/ARTY_S7_PLAN.md)
//
//   in ──┬─(±inj)──[z^-L0]──┐
//        ├─(±inj)──[z^-L1]──┤   8 delay-lijnen met priemlengtes (963..2011),
//        ⋮                  ├─► Hadamard (alleen optellers) ─►×g─► damping ─┐
//        └─(±inj)──[z^-L7]──┘                                              │
//              ▲───────────────────────────────────────────────────────────┘
//
//   wet = (v0 − v1 + v2 − v3 + …)/4   (gedecorreleerde tap-som)
//
// * Hadamard 8×8 unnormalized (H·Hᵀ = 8I) → uitgang >>>3; de lus is dan
//   stabiel voor g < √8 ≈ 2,83. Muzikaal bereik g ≈ 1,8 (kort) … 2,6 (lang).
// * Per lijn één-pool damping in de lus: hoge frequenties sterven sneller,
//   zoals lucht/muren doen. damp_a hoger = helderder.
// * Geheugen: één BRAM 8×2048×18b ({lijn,adres}) = 8 RAMB36 op de S7-50.
//   Opslag ±4.0 geclampt, bits [22:5] van Q12.20 (als tape_echo).
// * FSM ~30 cycli per sample, max één vermenigvuldiging per cyclus
//   (SVF-pijplijn-les). Alles Q12.20.
// ============================================================================

`timescale 1ns / 1ps

module fdn_reverb (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,                    // 48 kHz sample-tick

    input  wire signed [31:0] audio_in,       // droog in (Q12.20)
    output reg  signed [31:0] wet_out,        // alleen de galm

    input  wire signed [31:0] g,              // lus-gain; stabiel < 2,83 (Q12.20)
    input  wire signed [31:0] damp_a          // één-pool coeff (0..1): hoger = helderder
);

    // ========================================================================
    // Priemlengtes (≤ 2048) — onderling ruim gespreid tegen flutter-echo's
    // ========================================================================
    function [10:0] line_len;
        input [2:0] i;
        case (i)
            3'd0: line_len = 11'd1031;
            3'd1: line_len = 11'd1193;
            3'd2: line_len = 11'd1327;
            3'd3: line_len = 11'd1489;
            3'd4: line_len = 11'd1637;
            3'd5: line_len = 11'd1747;
            3'd6: line_len = 11'd1889;
            default: line_len = 11'd2011;
        endcase
    endfunction

    // ========================================================================
    // Gedeelde lijn-BRAM: {lijn[2:0], adres[10:0]} → 16384 × 18b
    // (adres- + dataregister → 2-cycle leeslatency)
    // ========================================================================
    reg signed [17:0] lines [0:16383];
    integer li;
    initial for (li = 0; li < 16384; li = li + 1) lines[li] = 18'sd0;

    reg [13:0] l_raddr, l_raddr_r, l_waddr;
    reg signed [17:0] l_q, l_wdata;
    reg               l_we;

    always @(posedge clk) begin
        if (l_we) lines[l_waddr] <= l_wdata;
        l_raddr_r <= l_raddr;
        l_q       <= lines[l_raddr_r];
    end

    reg [10:0] ptr [0:7];                     // per lijn: lees=schrijf-positie

    // ========================================================================
    // Taps, Hadamard en lus-rekenwerk
    // ========================================================================
    reg signed [31:0] v    [0:7];             // gelezen taps (Q12.20, ±4.0)
    reg signed [31:0] hadr [0:7];             // (H·v) >>> 3

    // Hadamard-boom: 3 butterfly-lagen, alleen optellers (±4.0 → ±32.0 max)
    wire signed [35:0] a0 = v[0] + v[1],  a1 = v[0] - v[1];
    wire signed [35:0] a2 = v[2] + v[3],  a3 = v[2] - v[3];
    wire signed [35:0] a4 = v[4] + v[5],  a5 = v[4] - v[5];
    wire signed [35:0] a6 = v[6] + v[7],  a7 = v[6] - v[7];
    wire signed [35:0] b0 = a0 + a2,      b1 = a1 + a3;
    wire signed [35:0] b2 = a0 - a2,      b3 = a1 - a3;
    wire signed [35:0] b4 = a4 + a6,      b5 = a5 + a7;
    wire signed [35:0] b6 = a4 - a6,      b7 = a5 - a7;
    wire signed [35:0] h0 = b0 + b4,      h1 = b1 + b5;
    wire signed [35:0] h2 = b2 + b6,      h3 = b3 + b7;
    wire signed [35:0] h4 = b0 - b4,      h5 = b1 - b5;
    wire signed [35:0] h6 = b2 - b6,      h7 = b3 - b7;

    // Gedecorreleerde natte uitgang: alternerende som van de taps ÷4
    wire signed [35:0] wsum = (v[0] - v[1]) + (v[2] - v[3])
                            + (v[4] - v[5]) + (v[6] - v[7]);
    wire signed [35:0] wsh  = wsum >>> 2;

    // Injectie: input alternerend ± per lijn, ÷2
    reg signed [31:0] inj_p;                  // +audio_in/2, gelatcht op ce

    // Lus per lijn (2 mults, elk hun eigen FSM-stap):
    //   mult 1: fbm = g · hadr[i]
    //   mult 2: lp[i] += damp · ((inj± + fbm) − lp[i])   → de lijn-schrijfwaarde
    reg  signed [31:0] lp [0:7];              // damping-state = lijn-ingang
    reg  [2:0] i_m;                           // lijn-index in de mult-fase
    reg  signed [31:0] fbm;

    wire signed [63:0] g_pr   = $signed(g) * $signed(hadr[i_m]);
    wire signed [31:0] inj_i  = i_m[0] ? -$signed(inj_p) : $signed(inj_p);
    wire signed [32:0] li_sum = $signed({fbm[31], fbm}) + $signed({inj_i[31], inj_i});
    wire signed [63:0] d_pr   = $signed(damp_a) * ($signed(li_sum[31:0]) - $signed(lp[i_m]));
    wire signed [31:0] lp_new = $signed(lp[i_m]) + $signed(d_pr[51:20]);

    // Opslag-clamp ±4.0 → 18 bits
    localparam signed [31:0] C_MAX =  32'sd4194303;
    localparam signed [31:0] C_MIN = -32'sd4194304;
    wire signed [31:0] lp_cl = (lp_new > C_MAX) ? C_MAX :
                               (lp_new < C_MIN) ? C_MIN : lp_new;

    // ========================================================================
    // FSM: reads (gepijplijnd) → Hadamard → per lijn 2 mults + write → out
    // ========================================================================
    localparam S_IDLE = 3'd0;
    localparam S_RD   = 3'd1;   // 10 cycli: 8 adressen + 2 latency, capture 2 achter
    localparam S_HAD  = 3'd2;   // Hadamard registreren
    localparam S_M1   = 3'd3;   // fbm = g·hadr[i]
    localparam S_M2   = 3'd4;   // lp[i] bijwerken + lijn schrijven; volgende i
    localparam S_OUT  = 3'd5;   // wet_out registreren

    reg [2:0] state;
    reg [3:0] rd_c;                           // read-teller 0..9
    integer k;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state   <= S_IDLE;
            rd_c    <= 4'd0;
            i_m     <= 3'd0;
            fbm     <= 32'sd0;
            inj_p   <= 32'sd0;
            wet_out <= 32'sd0;
            l_we    <= 1'b0;
            l_raddr <= 14'd0;
            l_waddr <= 14'd0;
            l_wdata <= 18'sd0;
            for (k = 0; k < 8; k = k + 1) begin
                ptr[k]  <= 11'd0;
                v[k]    <= 32'sd0;
                hadr[k] <= 32'sd0;
                lp[k]   <= 32'sd0;
            end
        end else begin
            l_we <= 1'b0;
            case (state)
                S_IDLE: if (ce) begin
                    inj_p   <= audio_in >>> 1;
                    rd_c    <= 4'd0;
                    l_raddr <= {3'd0, ptr[0]};
                    state   <= S_RD;
                end

                // rd_c telt 0..9: adres voor lijn rd_c+1 zetten (t/m 7),
                // capture van lijn rd_c-2 (vanaf 2) — 2-cycle BRAM-latency.
                S_RD: begin
                    if (rd_c < 4'd7)
                        l_raddr <= {rd_c[2:0] + 3'd1, ptr[rd_c[2:0] + 3'd1]};
                    if (rd_c >= 4'd2) begin
                        v[rd_c[2:0] - 3'd2] <=
                            {{9{l_q[17]}}, l_q, 5'b0};    // 18b → Q12.20
                    end
                    if (rd_c == 4'd9) state <= S_HAD;
                    else              rd_c  <= rd_c + 4'd1;
                end

                S_HAD: begin
                    hadr[0] <= h0[34:3]; hadr[1] <= h1[34:3];
                    hadr[2] <= h2[34:3]; hadr[3] <= h3[34:3];
                    hadr[4] <= h4[34:3]; hadr[5] <= h5[34:3];
                    hadr[6] <= h6[34:3]; hadr[7] <= h7[34:3];
                    i_m   <= 3'd0;
                    state <= S_M1;
                end

                S_M1: begin
                    fbm   <= g_pr[51:20];
                    state <= S_M2;
                end

                S_M2: begin
                    lp[i_m] <= lp_new;
                    l_we    <= 1'b1;
                    l_waddr <= {i_m, ptr[i_m]};
                    l_wdata <= lp_cl[22:5];
                    ptr[i_m] <= (ptr[i_m] == line_len(i_m) - 11'd1) ? 11'd0
                                                                    : ptr[i_m] + 11'd1;
                    if (i_m == 3'd7) state <= S_OUT;
                    else begin i_m <= i_m + 3'd1; state <= S_M1; end
                end

                S_OUT: begin
                    wet_out <= wsh[31:0];
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
