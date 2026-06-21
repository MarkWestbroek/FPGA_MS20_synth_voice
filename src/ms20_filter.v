// ============================================================================
// MS20_FILTER — Korg MS-20 style State-Variable Filter (SVF)
//
// Structuur (Chamberlin SVF met tanh BRAM LUT):
//   hp = in - lp - k * tanh(bp)
//   bp = bp + g * hp
//   lp = lp + g * bp
//
// De tanh-LUT in de resonantie-feedback emuleert de diode-saturatie
// van de originele MS-20 — authentieke "scream" bij hoge resonance.
//
// Parameters (Q12.20 fixed-point):
//   g  = 2 * pi * fc / fs     (cutoff frequency)
//   k  = resonance amount      (0..~4, self-oscillatie bij ~4)
//   mode: 0=LP, 1=HP
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
    // tanh BRAM Lookup Table — diode-saturatie emulatie
    //
    // bp (Q12.20, bereik ~[-4.0, +4.0]) → LUT-adres (0..1023) → tanh(bp)
    // De LUT heeft 1-cycle latency: lut_tanh = tanh(bp_previous).
    // Deze kleine vertraging in de feedback-loop is verwaarloosbaar @ 48kHz.
    // ========================================================================
    wire signed [31:0] BP_MAX = 32'sd4194304;   // +4.0 in Q12.20
    wire signed [31:0] BP_MIN = -32'sd4194304;  // -4.0 in Q12.20

    wire [9:0] lut_addr;
    assign lut_addr = (bp > BP_MAX)  ? 10'd1023 :
                      (bp < BP_MIN)  ? 10'd0 :
                      (bp + 32'sd4194304) >>> 13;

    wire signed [31:0] lut_tanh;  // tanh(bp), 1 cycle latency

    tanh_lut u_tanh (
        .clk      (clk),
        .addr     (lut_addr),
        .data_out (lut_tanh)
    );

    // ========================================================================
    // SVF-berekening
    // ========================================================================

    // Stap 1: hp = in - lp - k * tanh(bp)
    wire signed [63:0] prod_k;
    assign prod_k = $signed(k) * $signed(lut_tanh);

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
