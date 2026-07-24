// ============================================================================
// TAPE_ECHO — Space-Echo-achtige band-echo in BRAM (Fase C1, zie
// doc/ARTY_S7_PLAN.md)
//
// Model: vaste schrijfkop, één fractionele leeskop op variabele afstand.
//   * De delay-knop verschuift de leeskop met SLEW → de karakteristieke
//     pitch-zwiep van echte tape bij het draaien aan de tijd.
//   * Wow: driehoek-LFO op de leespositie (bandtransport-zwabber).
//   * Feedbackpad: lees → één-pool damping (dof worden per generatie) →
//     ×feedback → som met input → tanh-bandsaturatie → schrijfkop.
//     Feedback ≥ 1.0 mag: zelf-oscillatie is het halve instrument.
//
// Geheugen: 2^MAX_LOG2 samples à 18 bit (default 32768 ≈ 0,68 s @48 kHz,
// 16 RAMB36 op de Arty S7-50; past bewust NIET op de GW2A naast de synth).
// Opslag: audio geclampt op ±4.0, bits [22:5] van Q12.20.
// De tanh-saturatie vóór de schrijfkop maakt de clamp praktisch onbereikbaar.
//
// Alle audio/parameters Q12.20 tenzij anders vermeld. Verwerking per ce-tick
// via een FSM (~15 cycli), max 1 vermenigvuldiging per cyclus (de les van de
// SVF-pijplijn: 3 geketende mults halen de 37ns-cyclus niet). BRAM met
// adres- én dataregister (2-cycle leeslatency, als de KS-delaylijn).
// ============================================================================

`timescale 1ns / 1ps

module tape_echo #(
    parameter integer MAX_LOG2 = 15,          // 2^15 = 32768 samples ≈ 0,68 s
    // Leeskop-slew in Q16.8 per tick. 32/256 = 1/8 sample/sample: de volle
    // band doorschuiven duurt ~2 s en zwiept ±2 semitonen — de tape-feel.
    parameter integer SLEW_Q8  = 32
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,                    // 48 kHz sample-tick

    input  wire signed [31:0] audio_in,       // droog in (Q12.20)
    output reg  signed [31:0] wet_out,        // alleen het natte signaal

    // Parameters
    input  wire [23:0] delay_tgt,             // doel-delay in samples, Q16.8
    input  wire signed [31:0] feedback,       // Q12.20; 1.0 = 0x00100000
    input  wire signed [31:0] damp_a,         // één-pool coeff (0..1): hoger = helderder
    input  wire [15:0] wow_depth,             // wow-diepte in samples, Q8.8
    input  wire [23:0] wow_phinc              // wow-LFO fase-increment (2^24 = 48 kHz)
);

    localparam integer DEPTH = (1 << MAX_LOG2);

    // ========================================================================
    // Band: 18-bit BRAM (adres- + dataregister → 2-cycle leeslatency)
    // ========================================================================
    reg signed [17:0] tape [0:DEPTH-1];
    integer ti;
    initial for (ti = 0; ti < DEPTH; ti = ti + 1) tape[ti] = 18'sd0;  // lege band

    reg [MAX_LOG2-1:0] t_raddr, t_raddr_r, t_waddr;
    reg signed [17:0]  t_q, t_wdata;
    reg                t_we;

    always @(posedge clk) begin
        if (t_we) tape[t_waddr] <= t_wdata;
        t_raddr_r <= t_raddr;
        t_q       <= tape[t_raddr_r];
    end

    reg [MAX_LOG2-1:0] wr_ptr;

    // ========================================================================
    // Leeskop-positie: slew naar delay_tgt + wow, geclampt op de bandlengte
    // ========================================================================
    localparam signed [24:0] SLEW = SLEW_Q8;
    // Lees-venster ruim vrij van de schrijfkop en de bandlengte.
    localparam [23:0] DELAY_MIN = 24'd1024;                    //  4.0 samples
    localparam [23:0] DELAY_MAX = (DEPTH - 16) << 8;           //  (2^15-16).0

    reg  [23:0] delay_cur;                    // Q16.8
    wire [23:0] delay_lim = (delay_tgt < DELAY_MIN) ? DELAY_MIN :
                            (delay_tgt > DELAY_MAX) ? DELAY_MAX : delay_tgt;
    wire signed [24:0] d_err  = $signed({1'b0, delay_lim}) - $signed({1'b0, delay_cur});
    wire signed [24:0] d_step = (d_err >  SLEW) ?  SLEW :
                                (d_err < -SLEW) ? -SLEW : d_err;

    // Wow: driehoek uit een 24-bit fase-accumulator, amplitude ±wow_depth
    reg  [23:0] wow_phase;
    wire [22:0] tri_raw = wow_phase[23] ? ~wow_phase[22:0] : wow_phase[22:0];
    wire signed [23:0] tri_c  = $signed({1'b0, tri_raw}) - 24'sd4194304;  // ±2^22
    wire signed [40:0] wow_pr = tri_c * $signed({1'b0, wow_depth});
    wire signed [40:0] wow_sh = wow_pr >>> 22;                 // tri∈±1 × depth → Q16.8
    wire signed [24:0] wow_off = wow_sh[24:0];

    wire signed [25:0] pos_s = $signed({2'b0, delay_cur}) + wow_off;
    wire [23:0] delay_eff = pos_s[25] ? DELAY_MIN :
                            (pos_s[23:0] < DELAY_MIN) ? DELAY_MIN :
                            (pos_s[23:0] > DELAY_MAX) ? DELAY_MAX : pos_s[23:0];

    wire [MAX_LOG2-1:0] rd_int  = wr_ptr - delay_eff[22:8];    // gehele deel
    wire [7:0]          rd_frac = delay_eff[7:0];

    // ========================================================================
    // Teruglezen: 18b → Q12.20, lerp van a (delay=int) naar b (delay=int+1,
    // het óudere sample) met gewicht frac → effectieve delay = int + frac.
    // ========================================================================
    reg signed [17:0] s_a, s_b;
    wire signed [31:0] a_ext = {{9{s_a[17]}}, s_a, 5'b0};
    wire signed [31:0] b_ext = {{9{s_b[17]}}, s_b, 5'b0};
    wire signed [32:0] ab_d   = $signed({b_ext[31], b_ext}) - $signed({a_ext[31], a_ext});
    wire signed [41:0] lerp_p = ab_d * $signed({1'b0, rd_frac});   // ±2^23 × Q0.8
    wire signed [41:0] lerp_sh = lerp_p >>> 8;
    wire signed [31:0] tape_rd = a_ext + lerp_sh[31:0];

    // ========================================================================
    // Feedback-pad, max 1 mult per FSM-stap:
    //   S_LP : lp_state ← lp + damp·(read − lp)          (mult 1)
    //   S_FB : fb_term  ← feedback · lp_state            (mult 2)
    //   S_TW : tanh-adres stabiel, BRAM-read loopt
    //   S_ADV: sat_out geldig → schrijf band
    // ========================================================================
    reg signed [31:0] lp_state, fb_term;

    wire signed [63:0] lp_pr  = $signed(damp_a) * ($signed(tape_rd) - $signed(lp_state));
    wire signed [31:0] lp_new = $signed(lp_state) + $signed(lp_pr[51:20]);

    wire signed [63:0] fb_pr  = $signed(feedback) * $signed(lp_state);

    wire signed [32:0] pre_sum = $signed({audio_in[31], audio_in})
                               + $signed({fb_term[31], fb_term});

    // Bandsaturatie: 4·tanh(x/4) — zacht voor kleine signalen, begrensd ±4.0.
    localparam signed [32:0] PRE_MAX = 33'sd16777215;          // +16.0 − 1 lsb
    localparam signed [32:0] PRE_MIN = -33'sd16777216;         // −16.0
    wire signed [32:0] pre_cl = (pre_sum > PRE_MAX) ? PRE_MAX :
                                (pre_sum < PRE_MIN) ? PRE_MIN : pre_sum;
    wire signed [32:0] pre_sh4 = pre_cl >>> 2;                 // ÷4 → LUT-domein
    wire signed [31:0] sat_in  = pre_sh4[31:0];

    localparam signed [31:0] X_MAX = 32'sd4194304;             // +4.0
    localparam signed [31:0] X_MIN = -32'sd4194304;
    wire signed [31:0] lut_sum = sat_in + X_MAX;
    wire [9:0] lut_addr = (sat_in >= X_MAX) ? 10'd1023 :
                          (sat_in <  X_MIN) ? 10'd0    :
                          lut_sum[22:13];
    wire signed [31:0] lut_tanh;
    tanh_lut u_tanh (.clk(clk), .addr(lut_addr), .data_out(lut_tanh));

    wire signed [31:0] sat_out  = lut_tanh <<< 2;              // ×4 → ±4.0
    wire signed [17:0] store_18 = sat_out[22:5];

    // ========================================================================
    // FSM — per ce één sample (~11 actieve cycli van de 562)
    // ========================================================================
    localparam S_IDLE = 4'd0;
    localparam S_RA   = 4'd1;   // adres a gezet, adres b zetten
    localparam S_RB   = 4'd2;   // wachten (a onderweg)
    localparam S_CA   = 4'd3;   // a binnen
    localparam S_CB   = 4'd4;   // b binnen → tape_rd geldig
    localparam S_LP   = 4'd5;   // damping-LP bijwerken           (mult 1)
    localparam S_FB   = 4'd6;   // feedback-term registreren      (mult 2)
    localparam S_TW   = 4'd7;   // tanh-BRAM wachtcyclus
    localparam S_ADV  = 4'd8;   // schrijven + pointers/LFO bijwerken

    reg [3:0] state;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_IDLE;
            wr_ptr    <= {MAX_LOG2{1'b0}};
            delay_cur <= 24'd2048;            // 8 samples — glijdt naar delay_tgt
            wow_phase <= 24'd0;
            lp_state  <= 32'sd0;
            fb_term   <= 32'sd0;
            s_a       <= 18'sd0;
            s_b       <= 18'sd0;
            wet_out   <= 32'sd0;
            t_we      <= 1'b0;
            t_raddr   <= {MAX_LOG2{1'b0}};
            t_waddr   <= {MAX_LOG2{1'b0}};
            t_wdata   <= 18'sd0;
        end else begin
            t_we <= 1'b0;
            case (state)
                S_IDLE: if (ce) begin
                    t_raddr <= rd_int;                    // a: delay = int
                    state   <= S_RA;
                end
                S_RA: begin
                    t_raddr <= rd_int - {{(MAX_LOG2-1){1'b0}}, 1'b1}; // b: int+1 (ouder)
                    state   <= S_RB;
                end
                S_RB: state <= S_CA;
                S_CA: begin
                    s_a   <= t_q;
                    state <= S_CB;
                end
                S_CB: begin
                    s_b   <= t_q;
                    state <= S_LP;
                end
                S_LP: begin
                    lp_state <= lp_new;
                    state    <= S_FB;
                end
                S_FB: begin
                    fb_term  <= fb_pr[51:20];
                    state    <= S_TW;                     // lut_addr zet zich hierna
                end
                S_TW: state <= S_ADV;                     // tanh-read loopt
                S_ADV: begin
                    t_we    <= 1'b1;
                    t_waddr <= wr_ptr;
                    t_wdata <= store_18;
                    wet_out <= tape_rd;                   // nat = wat de leeskop hoort
                    wr_ptr  <= wr_ptr + {{(MAX_LOG2-1){1'b0}}, 1'b1};
                    delay_cur <= delay_cur + d_step[23:0];
                    wow_phase <= wow_phase + wow_phinc;
                    state   <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
