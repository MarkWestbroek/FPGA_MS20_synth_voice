// ============================================================================
// MS20_FILTER — Korg MS-20 style State-Variable Filter (SVF)
//
// Emuleert het karakteristieke MS-20 filtergeluid via een digitale
// state-variable filter (SVF) met niet-lineaire (tanh-achtige) soft-clipping
// in de resonantie-terugkoppelpad.
//
// Structuur (Chamberlin SVF):
//   hp = in - lp - k * soft_clip(bp)
//   bp = bp + g * hp
//   lp = lp + g * bp
//
// Parameters (Q12.20 fixed-point):
//   g  = 2 * pi * fc / fs     (cutoff frequency)
//   k  = resonance amount      (0..~4, self-oscillatie bij ~4)
//   mode: 0=LP, 1=HP
//
// De soft-clip in de resonantie-feedback geeft de karakteristieke
// "scream" van de MS-20 wanneer de resonance hoog staat.
// ============================================================================

`timescale 1ns / 1ps

module ms20_filter (
    input  wire         clk,
    input  wire         rst,
    input  wire         ce,              // Clock enable (audio sample rate)

    // Audio I/O — Q12.20
    input  wire signed [31:0] audio_in,
    output wire signed [31:0] audio_out,

    // Filter parameters — Q12.20
    input  wire signed [31:0] g,         // Cutoff: 2*pi*fc/fs
    input  wire signed [31:0] k,         // Resonance (0..4.0)
    input  wire         mode            // 0 = Low-Pass, 1 = High-Pass
);

    // ========================================================================
    // State registers — Q12.20
    // ========================================================================
    reg signed [31:0] lp;   // Low-pass state
    reg signed [31:0] bp;   // Band-pass state

    // ========================================================================
    // Soft-clip (tanh-achtig) voor MS-20 karakter
    // ========================================================================
    // Drempelwaarde: 0.5 in Q12.20 — let op: signed literals gebruiken!
    wire signed [31:0] CLIP_THR = 32'sh00080000;   // +0.5
    wire signed [31:0] CLIP_NTHR = -32'sh00080000; // -0.5

    wire signed [31:0] bp_clipped;

    assign bp_clipped = (bp > CLIP_THR)  ? (CLIP_THR + ((bp - CLIP_THR) >>> 2)) :
                        (bp < CLIP_NTHR) ? (CLIP_NTHR + ((bp - CLIP_NTHR) >>> 2)) :
                        bp;

    // ========================================================================
    // SVF-berekening (combinatorisch, 1 klokcyclus pipeline)
    // ========================================================================

    // Stap 1: hp = in - lp - k * soft_clip(bp)
    wire signed [63:0] prod_k;    // k * bp_clipped
    assign prod_k = $signed(k) * $signed(bp_clipped);

    // Scale k*bp_clipped terug naar Q12.20 (arithmetic shift >>> 20)
    wire signed [31:0] feedback_scaled;
    assign feedback_scaled = prod_k >>> 20;

    // hp (high-pass) intermediate
    wire signed [31:0] hp;
    assign hp = $signed(audio_in) - $signed(lp) - $signed(feedback_scaled);

    // Stap 2: bp_next = bp + g * hp
    wire signed [63:0] prod_g_hp;
    assign prod_g_hp = $signed(g) * $signed(hp);
    wire signed [31:0] bp_delta;
    assign bp_delta = prod_g_hp >>> 20;
    wire signed [31:0] bp_next;
    assign bp_next = $signed(bp) + $signed(bp_delta);

    // Stap 3: lp_next = lp + g * bp_next
    wire signed [63:0] prod_g_bp;
    assign prod_g_bp = $signed(g) * $signed(bp_next);
    wire signed [31:0] lp_delta;
    assign lp_delta = prod_g_bp >>> 20;
    wire signed [31:0] lp_next;
    assign lp_next = $signed(lp) + $signed(lp_delta);

    // ========================================================================
    // Uitgangsselectie: LP of HP
    // ========================================================================
    assign audio_out = (mode == 1'b1) ? hp : lp;

    // ========================================================================
    // State update
    // ========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lp <= 32'h0;
            bp <= 32'h0;
        end else if (ce) begin
            lp <= lp_next;
            bp <= bp_next;
        end
    end

endmodule
