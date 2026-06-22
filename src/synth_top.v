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

module synth_top #(
    // Systeemklok-frequentie. Sim/default = 50 MHz. Op de Tang Primer 20K is het
    // onboard kristal 27 MHz: gebruik óf een PLL naar 50 MHz (sim == hardware),
    // óf zet SYS_CLK_HZ = 27_000_000 (zie doc/FLASHING.md).
    parameter integer SYS_CLK_HZ = 50_000_000,
    parameter integer SAMPLE_HZ  = 48_000
) (
    input  wire         sys_clk,      // systeemklok (zie SYS_CLK_HZ)
    input  wire         sys_rst_n,    // Active-low reset

    // SPI-slave (MusicBrain frame-protocol); de brain (Teensy 4.1) is master
    input  wire         spi_sclk,
    input  wire         spi_mosi,
    output wire         spi_miso,     // slave → master (Pong-respons)
    input  wire         spi_cs_n,

    input  wire         demo_mode,    // 1 = interne demo-sequencer, 0 = SPI-CV's

    output wire         led,          // Status LED
    output wire signed [31:0] audio_out  // Q12.20 audio-uitgang
);

    wire rst = !sys_rst_n;

    // ========================================================================
    // KLOKVERDELER: 50 MHz → ~48 kHz
    // ========================================================================
    localparam [15:0] CLK_DIV = (SYS_CLK_HZ / SAMPLE_HZ) - 1;  // 1041 @50MHz, 561 @27MHz

    reg  [15:0] clk_divider;
    reg         sample_clk_tick;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            clk_divider     <= 0;
            sample_clk_tick <= 0;
        end else begin
            if (clk_divider >= CLK_DIV) begin
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
    // SPI-CONTROL: brain → CV/gate → synth-parameters
    //
    // De brain stuurt per-stem pitch/cutoff/reson/drive als CV (i16) en gate.
    // pitch-CV → MIDI-noot → KS-period (via note_to_period LUT). De CV→Q12.20
    // filter-mappings hieronder zijn voorlopig (vaste shifts, zie ROADMAP).
    // ========================================================================
    wire [7:0] spi_rx_byte, spi_tx_byte;
    wire       spi_rx_valid, spi_cs_active, spi_tx_load;
    wire signed [15:0] pitch_cv, cutoff_cv, reson_cv, drive_cv;
    wire       spi_gate, spi_trigger;

    spi_slave u_spi_slave (
        .clk(sys_clk), .rst(rst),
        .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n),
        .rx_byte(spi_rx_byte), .rx_valid(spi_rx_valid), .cs_active(spi_cs_active),
        .tx_byte(spi_tx_byte), .tx_load(spi_tx_load)
    );

    spi_frame u_spi_frame (
        .clk(sys_clk), .rst(rst),
        .rx_byte(spi_rx_byte), .rx_valid(spi_rx_valid), .cs_active(spi_cs_active),
        .pitch_cv(pitch_cv), .cutoff_cv(cutoff_cv), .reson_cv(reson_cv),
        .drive_cv(drive_cv), .gate(spi_gate), .trigger(spi_trigger),
        .pong_req(), .frame_ok(),
        .tx_byte(spi_tx_byte), .tx_load(spi_tx_load)
    );

    // pitch-CV (i16) → MIDI-noot. Conventie (zie doc/PITCH_CV.md, MusicBrain ADR 0014):
    //   digitale "V/oct": 256 LSB = 1 semitoon, referentienoot 69 (A4 = 440 Hz).
    //   note = 69 + pitch_cv/256, geclampt 0..127.
    wire signed [15:0] note_raw = 16'sd69 + (pitch_cv >>> 8);
    wire [6:0] spi_note = (note_raw < 0)   ? 7'd0   :
                          (note_raw > 127) ? 7'd127 : note_raw[6:0];
    wire [10:0] spi_period;
    note_to_period u_n2p (.clk(sys_clk), .note(spi_note), .period(spi_period));

    // CV → Q12.20 filter-parameters (sign-extend naar 32-bit eerst)
    wire signed [31:0] cutoff32 = {{16{cutoff_cv[15]}}, cutoff_cv};
    wire signed [31:0] reson32  = {{16{reson_cv[15]}},  reson_cv};
    wire signed [31:0] drive32  = {{16{drive_cv[15]}},  drive_cv};

    // cutoff: 0..+1 → g 0..~0.25
    wire signed [31:0] g_spi = (cutoff32 <= 0) ? 32'sd0 : (cutoff32 <<< 3);
    // resonance: hoger CV = meer resonantie = LAGERE demping k (floor 0.125)
    wire signed [31:0] k_sub     = (reson32 < 0) ? 32'sd0 : (reson32 <<< 5);
    wire signed [31:0] k_spi_raw = 32'sh00100000 - k_sub;
    wire signed [31:0] k_spi     = (k_spi_raw < 32'sh00020000) ? 32'sh00020000 : k_spi_raw;
    // drive: 1.0 + positief CV
    wire signed [31:0] drive_add = (drive32 < 0) ? 32'sd0 : (drive32 <<< 6);
    wire signed [31:0] drive_spi = 32'sh00100000 + drive_add;

    // trigger naar het audio-tick (ce) domein tillen.
    // Net als de demo's trigger_pulse: alleen op ticks bijwerken, zodat de puls
    // de héle tick-gap hoog blijft en ks_string 'm op de volgende tick consumeert
    // (ks checkt `ce && trigger`). spi_trigger kan op elk moment binnenkomen en
    // wordt in trig_pending vastgehouden tot de eerstvolgende tick.
    reg trig_pending, spi_trig_pulse;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            trig_pending   <= 1'b0;
            spi_trig_pulse <= 1'b0;
        end else if (sample_clk_tick) begin
            spi_trig_pulse <= trig_pending | spi_trigger;  // ook bij gelijktijdigheid
            trig_pending   <= 1'b0;
        end else if (spi_trigger) begin
            trig_pending <= 1'b1;
        end
    end

    // ========================================================================
    // MUX: demo-sequencer vs SPI-CV's
    // ========================================================================
    wire [10:0]        eff_period  = demo_mode ? current_period : spi_period;
    wire               eff_trigger = demo_mode ? trigger_pulse  : spi_trig_pulse;

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
        .trigger  (eff_trigger),
        .period   (eff_period),
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
    // MS-20 STATE-VARIABLE FILTER  (demo-envelope vs SPI-CV's via mux)
    // ========================================================================
    wire signed [31:0] eff_g     = demo_mode ? filter_g     : g_spi;
    wire signed [31:0] eff_k     = demo_mode ? filter_k     : k_spi;
    wire signed [31:0] eff_drive = demo_mode ? filter_drive : drive_spi;

    wire signed [31:0] filter_out;

    ms20_filter #(
        .OVERSAMPLE(2)
    ) u_filter (
        .clk      (sys_clk),
        .rst      (rst),
        .ce       (sample_clk_tick),
        .audio_in (string_out),
        .audio_out(filter_out),
        .g        (eff_g),
        .k        (eff_k),
        .drive    (eff_drive),
        .mode     (filter_mode)
    );

    // ========================================================================
    // UITGANGEN
    // ========================================================================
    assign audio_out = filter_out;
    assign led = filter_out[31];

endmodule