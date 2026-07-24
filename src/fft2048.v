// ============================================================================
// FFT2048 — iteratieve radix-2 DIT FFT, 2048 punten, 18-bit complex,
// block-floating-point. Bouwsteen voor de convolution reverb
// (doc/CONV_REVERB_DESIGN.md); bewust vendor-neutraal (geen FFT-IP) zodat
// hij later ook naar Gowin (Tang Nano FX-module) kan.
//
// Gebruik:
//   1. idle: schrijf 2048 complexe samples via wr_* (natuurlijke volgorde;
//      intern bit-reversed opgeslagen).
//   2. puls start (inv=0 forward, 1 = inverse/geconjugeerde twiddles).
//   3. wacht op done-puls; lees via rd_* (natuurlijke volgorde, 2-cycle
//      leeslatency).
//
// Block-floating-point: vóór elke stage wordt, als de maximale magnitude
// van de vorige stage ≥ 2^16 is, alles bij het lezen 1 bit geschaald
// (headroom voor de ×2-groei per butterfly). exp_out telt die shifts:
//   wiskundig_resultaat = uitgelezen_waarde × 2^exp_out
// (De inverse is verder ongenormaliseerd: deel zelf nog door 2048, oftewel
// tel 11 op bij de exponent-boekhouding van de aanroeper.)
//
// Eén gedeelde 18×18-vermenigvuldiger, ~12 cycli per butterfly →
// 11×1024 butterflies ≈ 135k cycli ≈ 5 ms @27 MHz per transform (ruim
// binnen het 21,3 ms-blokbudget van de convolutie-engine, 3 transforms/blok).
//
// Twiddles: fft_twiddle.hex (Q1.17, {cos,sin}), gen_fft_tables.py.
// ============================================================================

`timescale 1ns / 1ps

module fft2048 (
    input  wire        clk,
    input  wire        rst,

    // laad-poort (alleen gebruiken als busy=0)
    input  wire        wr_en,
    input  wire [10:0] wr_addr,               // natuurlijke volgorde
    input  wire signed [17:0] wr_re,
    input  wire signed [17:0] wr_im,

    // lees-poort (alleen als busy=0; 3-cycle latency: rd_addr → mux → adres-
    // register → dataregister)
    input  wire [10:0] rd_addr,
    output wire signed [17:0] rd_re,
    output wire signed [17:0] rd_im,

    // besturing
    input  wire        start,
    input  wire        inv,                   // 0 = forward, 1 = inverse
    output reg         busy,
    output reg         done,                  // 1-cycle puls
    output reg  [4:0]  exp_out                // aantal toegepaste >>1's
);

    // ========================================================================
    // Werk-RAM's (re/im apart): 2048 × 18, adres- + dataregister
    // ========================================================================
    reg signed [17:0] ram_re [0:2047];
    reg signed [17:0] ram_im [0:2047];
    integer ri;
    initial for (ri = 0; ri < 2048; ri = ri + 1) begin
        ram_re[ri] = 18'sd0;  ram_im[ri] = 18'sd0;
    end

    function [10:0] bitrev;
        input [10:0] a;
        integer i;
        for (i = 0; i < 11; i = i + 1) bitrev[i] = a[10-i];
    endfunction

    reg  [10:0] m_raddr, m_raddr_r;
    reg  signed [17:0] q_re, q_im;
    reg         m_we;
    reg  [10:0] m_waddr;
    reg  signed [17:0] m_wre, m_wim;

    always @(posedge clk) begin
        if (m_we) begin
            ram_re[m_waddr] <= m_wre;
            ram_im[m_waddr] <= m_wim;
        end
        m_raddr_r <= m_raddr;
        q_re      <= ram_re[m_raddr_r];
        q_im      <= ram_im[m_raddr_r];
    end

    assign rd_re = q_re;
    assign rd_im = q_im;

    // ========================================================================
    // Stage/butterfly-administratie (declaraties vóór gebruik in de wires)
    // ========================================================================
    reg  [3:0]  stg;                          // 0..10
    reg  [9:0]  bf;                           // 0..1023
    reg         inv_l;                        // gelatchte richting
    reg         sh;                           // deze stage: inputs >>1 ?
    reg  [17:0] max_seen;                     // max|component| (load / per stage)

    // ========================================================================
    // Twiddle-ROM: 1024 × {cos,sin} Q1.17 (1-cycle latency)
    // ========================================================================
    reg [35:0] tw_rom [0:1023];
    initial $readmemh("fft_twiddle.hex", tw_rom);

    reg  [9:0]  tw_addr;
    reg  [35:0] tw_q;
    always @(posedge clk) tw_q <= tw_rom[tw_addr];

    wire signed [17:0] tw_cos = tw_q[35:18];
    wire signed [17:0] tw_sin = tw_q[17:0];
    wire signed [17:0] w_re   = tw_cos;
    wire signed [17:0] w_im   = inv_l ? tw_sin : -tw_sin;   // e^{∓j2πk/N}

    // ========================================================================
    // Butterfly-indexering
    // ========================================================================
    wire [10:0] jmask  = (11'd1 << stg) - 11'd1;
    wire [10:0] j      = {1'b0, bf} & jmask;
    wire [10:0] idx_a  = (({1'b0, bf} & ~jmask) << 1) | j;
    wire [10:0] idx_b  = idx_a | (11'd1 << stg);
    wire [9:0]  tw_idx = j[9:0] << (4'd10 - stg);

    // Gedeelde vermenigvuldiger
    reg  signed [17:0] m_x, m_y;
    wire signed [35:0] mprod = m_x * m_y;
    reg  signed [36:0] p1, p2, p3, p4;

    // Butterfly-data
    reg  signed [17:0] a_re, a_im, b_re, b_im;
    reg  signed [17:0] bw_re, bw_im;

    // +2^16 vóór de >>>17: afronden i.p.v. afkappen (≈5 dB minder ruisvloer)
    wire signed [36:0] sum_re = p1 - p2 + 37'sd65536;   // (br·wr − bi·wi)
    wire signed [36:0] sum_im = p3 + p4 + 37'sd65536;   // (br·wi + bi·wr)

    wire signed [17:0] wa_re = a_re + bw_re;  // BFP garandeert: past in 18b
    wire signed [17:0] wa_im = a_im + bw_im;
    wire signed [17:0] wb_re = a_re - bw_re;
    wire signed [17:0] wb_im = a_im - bw_im;

    function [17:0] absv;
        input signed [17:0] x;
        absv = x[17] ? (~x + 18'd1) : x;
    endfunction

    // ========================================================================
    // FSM
    // ========================================================================
    localparam S_IDLE = 4'd0;
    localparam S_STG  = 4'd1;   // shift-beslissing voor deze stage
    localparam S_AB   = 4'd2;   // adres b + twiddle
    localparam S_AA   = 4'd3;   // adres a
    localparam S_WT   = 4'd4;   // wachten (b onderweg)
    localparam S_CB   = 4'd5;   // capture b (evt. >>1)
    localparam S_CA   = 4'd6;   // capture a (evt. >>1); mult br·wr starten
    localparam S_M2   = 4'd7;   // p1 vangen; mult bi·wi
    localparam S_M3   = 4'd8;   // p2 vangen; mult br·wi
    localparam S_M4   = 4'd9;   // p3 vangen; mult bi·wr
    localparam S_MA   = 4'd10;  // p4 vangen
    localparam S_CM   = 4'd11;  // bw = (sums >>> 17)
    localparam S_W1   = 4'd12;  // schrijf idx_a
    localparam S_W2   = 4'd13;  // schrijf idx_b; volgende butterfly/stage
    localparam S_FIN  = 4'd14;  // done-puls

    reg [3:0] state;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;  busy <= 1'b0;  done <= 1'b0;
            exp_out <= 5'd0;  max_seen <= 18'd0;
            stg <= 4'd0;  bf <= 10'd0;  sh <= 1'b0;  inv_l <= 1'b0;
            m_we <= 1'b0;  m_raddr <= 11'd0;  m_waddr <= 11'd0;
            m_wre <= 18'sd0;  m_wim <= 18'sd0;  tw_addr <= 10'd0;
            m_x <= 18'sd0;  m_y <= 18'sd0;
            p1 <= 37'sd0; p2 <= 37'sd0; p3 <= 37'sd0; p4 <= 37'sd0;
            a_re <= 18'sd0; a_im <= 18'sd0; b_re <= 18'sd0; b_im <= 18'sd0;
            bw_re <= 18'sd0; bw_im <= 18'sd0;
        end else begin
            m_we <= 1'b0;
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    // laden: bit-reversed opslaan + max bijhouden
                    if (wr_en) begin
                        m_we    <= 1'b1;
                        m_waddr <= bitrev(wr_addr);
                        m_wre   <= wr_re;
                        m_wim   <= wr_im;
                        if (absv(wr_re) > max_seen) max_seen <= absv(wr_re);
                        if (absv(wr_im) > max_seen) max_seen <= absv(wr_im);
                    end
                    m_raddr <= rd_addr;                   // leespoort doorlussen
                    if (start) begin
                        busy    <= 1'b1;
                        inv_l   <= inv;
                        exp_out <= 5'd0;
                        stg     <= 4'd0;
                        state   <= S_STG;
                    end
                end

                S_STG: begin
                    // drempel iets onder 2^16: twiddle-afronding kan |W| een
                    // fractie boven 1.0 brengen — marge tegen randoverflow
                    sh       <= (max_seen >= 18'd65500);
                    if (max_seen >= 18'd65500) exp_out <= exp_out + 5'd1;
                    max_seen <= 18'd0;
                    bf       <= 10'd0;
                    state    <= S_AB;
                end

                S_AB: begin
                    m_raddr <= idx_b;
                    tw_addr <= tw_idx;
                    state   <= S_AA;
                end
                S_AA: begin
                    m_raddr <= idx_a;
                    state   <= S_WT;
                end
                S_WT: state <= S_CB;
                S_CB: begin                               // >>1 met afronding
                    b_re  <= sh ? ((q_re + 18'sd1) >>> 1) : q_re;
                    b_im  <= sh ? ((q_im + 18'sd1) >>> 1) : q_im;
                    state <= S_CA;
                end
                S_CA: begin
                    a_re  <= sh ? ((q_re + 18'sd1) >>> 1) : q_re;
                    a_im  <= sh ? ((q_im + 18'sd1) >>> 1) : q_im;
                    m_x   <= b_re;  m_y <= w_re;          // mult 1: br·wr
                    state <= S_M2;
                end
                S_M2: begin
                    p1  <= {mprod[35], mprod};
                    m_x <= b_im;  m_y <= w_im;            // mult 2: bi·wi
                    state <= S_M3;
                end
                S_M3: begin
                    p2  <= {mprod[35], mprod};
                    m_x <= b_re;  m_y <= w_im;            // mult 3: br·wi
                    state <= S_M4;
                end
                S_M4: begin
                    p3  <= {mprod[35], mprod};
                    m_x <= b_im;  m_y <= w_re;            // mult 4: bi·wr
                    state <= S_MA;
                end
                S_MA: begin
                    p4  <= {mprod[35], mprod};
                    state <= S_CM;
                end
                S_CM: begin
                    bw_re <= sum_re[34:17];               // /2^17 (Q1.17-twiddle)
                    bw_im <= sum_im[34:17];
                    state <= S_W1;
                end
                S_W1: begin
                    m_we    <= 1'b1;
                    m_waddr <= idx_a;
                    m_wre   <= wa_re;
                    m_wim   <= wa_im;
                    if (absv(wa_re) > max_seen) max_seen <= absv(wa_re);
                    if (absv(wa_im) > max_seen) max_seen <= absv(wa_im);
                    state   <= S_W2;
                end
                S_W2: begin
                    m_we    <= 1'b1;
                    m_waddr <= idx_b;
                    m_wre   <= wb_re;
                    m_wim   <= wb_im;
                    if (absv(wb_re) > max_seen) max_seen <= absv(wb_re);
                    if (absv(wb_im) > max_seen) max_seen <= absv(wb_im);
                    if (bf == 10'd1023) begin
                        if (stg == 4'd10) state <= S_FIN;
                        else begin stg <= stg + 4'd1; state <= S_STG; end
                    end else begin
                        bf    <= bf + 10'd1;
                        state <= S_AB;
                    end
                end

                S_FIN: begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    max_seen <= 18'd0;                    // schoon voor volgende laad
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
