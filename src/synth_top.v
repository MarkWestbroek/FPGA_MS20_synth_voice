// ============================================================================
// SYNTH_TOP — Karplus-Strong Bass + MS-20 Filter
//
// Signaalketen:
//   Trigger → KS String (Karplus-Strong) → MS-20 SVF → Output
//
// De KS-string modelleert een getokkelde bass-snaar.
// Het MS-20 filter voegt analoge warmte en expressie toe.
// Alles in Q12.20 fixed-point, 48 kHz sample rate.
// ============================================================================

`timescale 1ns / 1ps

module synth_top (
    input  wire         sys_clk,      // 50 MHz systeemklok
    input  wire         sys_rst_n,    // Active-low reset
    output wire         led,          // Status LED
    output wire signed [31:0] audio_out  // Q12.20 audio-uitgang
);

    wire rst = !sys_rst_n;

    // ========================================================================
    // KLOKVERDELER: 50 MHz → ~48 kHz
    // ========================================================================
    reg  [10:0] clk_divider;
    reg         sample_clk_tick;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            clk_divider     <= 0;
            sample_clk_tick <= 0;
        end else begin
            if (clk_divider >= 11'd1041) begin
                clk_divider     <= 0;
                sample_clk_tick <= 1;
            end else begin
                clk_divider     <= clk_divider + 1;
                sample_clk_tick <= 0;
            end
        end
    end

    // ========================================================================
    // BASS-SEQUENCER: 4 noten, elk ~1.5 seconde
    //
    // Noot   Freq     Period (=48kHz/freq)
    //  E1    41.2 Hz  1165
    //  A1    55.0 Hz   873
    //  D2    73.4 Hz   654
    //  G1    49.0 Hz   980
    //
    // Elke noot duurt ~72000 samples (1.5 sec @ 48kHz)
    // ========================================================================
    reg [17:0] seq_timer;        // Timer binnen huidige noot
    reg [1:0]  note_index;       // 0..3
    reg        trigger_pulse;

    // Noot-periodes (lookup)
    wire [10:0] note_periods [0:3];
    assign note_periods[0] = 11'd1165;  // E1
    assign note_periods[1] = 11'd873;   // A1
    assign note_periods[2] = 11'd654;   // D2
    assign note_periods[3] = 11'd980;   // G1

    wire [10:0] current_period = note_periods[note_index];

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            seq_timer     <= 0;
            note_index    <= 0;
            trigger_pulse <= 0;
        end else if (sample_clk_tick) begin
            trigger_pulse <= 0;  // Default laag

            if (seq_timer == 18'd0) begin
                // Start nieuwe noot
                trigger_pulse <= 1;
            end

            if (seq_timer >= 18'd72000) begin  // ~1.5 sec per noot
                seq_timer  <= 0;
                note_index <= note_index + 1;   // Volgende noot (wraps bij 2 bits)
            end else begin
                seq_timer <= seq_timer + 1;
            end
        end
    end

    // ========================================================================
    // KARPLUS-STRONG STRING MODEL
    //
    // Damping: 0.9995 in Q12.20 ≈ 0x000FFF5C
    //   Dit geeft ~2.9 sec decay naar stilte — mooi voor bass.
    // ========================================================================
    wire signed [31:0] ks_damping = 32'h000FFF6A;  // ~0.9995 Q12.20
    wire signed [31:0] string_out;

    ks_string #(
        .MAX_DELAY(2048)
    ) u_string (
        .clk      (sys_clk),
        .rst      (rst),
        .ce       (sample_clk_tick),
        .trigger  (trigger_pulse),
        .period   (current_period),
        .damping  (ks_damping),
        .audio_out(string_out)
    );

    // ========================================================================
    // MS-20 FILTER — met envelope op de cutoff
    //
    // Filter-envelope per noot:
    //   Attack:  cutoff gaat snel open  (200Hz → 1500Hz in ~50ms)
    //   Decay:   cutoff zakt langzaam terug (1500Hz → 400Hz in ~1 sec)
    //
    // Dit geeft de karakteristieke "wah" per aanslag, typisch voor synth bass.
    //
    // LET OP: het filter draait intern op 2x oversampling (96 kHz), dus de
    // Chamberlin cutoff-coeff is g = 2*sin(pi*fc/96000)  (zie gen_tables.py):
    //   g(200Hz)  ≈ 0.01309 → Q12.20: 0x0000359E
    //   g(400Hz)  ≈ 0.02618 → Q12.20: 0x00006B3B
    //   g(1500Hz) ≈ 0.09814 → Q12.20: 0x000191F6
    //
    // Resonance: k ≈ 1.25 ; drive ≈ 3.0 duwt de tanh in saturatie (MS-20 bite)
    // ========================================================================
    reg [15:0] env_timer;
    reg signed [31:0] filter_g;
    reg signed [31:0] filter_k;
    reg        filter_mode;

    // tanh-drive (Q12.20). 1.0 = 0x00100000 (vrijwel lineair). Hoger = meer bite.
    wire signed [31:0] filter_drive = 32'h00400000;  // 4.0 — aggressief

    // Filter g-waarden voor envelope-punten (96 kHz interne rate)
    wire signed [31:0] G_CLOSED = 32'h0000359E;  // ~200 Hz
    wire signed [31:0] G_OPEN   = 32'h000191F6;  // ~1500 Hz
    wire signed [31:0] G_MEDIUM = 32'h00006B3B;  // ~400 Hz

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            env_timer   <= 0;
            filter_g    <= G_CLOSED;
            // k is de DEMPINGSfactor (q=1/Q): LAGER = meer resonantie.
            // ~0.25 = hoge resonantie, tanh begrenst de zelfoscillatie (scream).
            filter_k    <= 32'h00040000;  // ~0.25 — schreeuwerig
            filter_mode <= 1'b0;          // Low-pass
        end else if (sample_clk_tick) begin
            if (trigger_pulse) begin
                // Nieuwe noot: reset envelope, open filter
                env_timer <= 0;
                filter_g  <= G_OPEN;
            end else begin
                if (env_timer < 16'd24000) begin
                    env_timer <= env_timer + 1;

                    // Elke 64 samples: stapje dichter naar G_MEDIUM
                    // (G_OPEN - G_MEDIUM) / (24000/64) = 75451/375 ≈ 0xC9
                    if (env_timer[5:0] == 6'd0 && filter_g > (G_MEDIUM + 32'hC9)) begin
                        filter_g <= filter_g - 32'h000000C9;
                    end
                end
            end
        end
    end

    // ========================================================================
    // MS-20 STATE-VARIABLE FILTER
    // ========================================================================
    wire signed [31:0] filter_out;

    ms20_filter #(
        .OVERSAMPLE(2)
    ) u_filter (
        .clk      (sys_clk),
        .rst      (rst),
        .ce       (sample_clk_tick),
        .audio_in (string_out),
        .audio_out(filter_out),
        .g        (filter_g),
        .k        (filter_k),
        .drive    (filter_drive),
        .mode     (filter_mode)
    );

    // ========================================================================
    // UITGANGEN
    // ========================================================================
    assign audio_out = filter_out;
    assign led = filter_out[31];

endmodule