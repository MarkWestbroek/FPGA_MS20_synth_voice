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
    // Systeemklok-frequentie. Default = 27 MHz = het onboard kristal van de Tang
    // Primer 20K (native draaien, geen PLL nodig). De testbenches klokken op
    // 50 MHz en overschrijven dit naar 50_000_000. Optioneel kan een PLL 27→50 MHz
    // maken voor exact gelijke rates als de sim (zie doc/FLASHING.md).
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer SAMPLE_HZ  = 48_000,
    // DEMO_ONLY=1: forceer de interne demo-sequencer (negeer de demo_mode-pin).
    // Handig zolang er nog geen brain/SPI is aangesloten — gegarandeerd geluid.
    // Zet op 0 zodra je via SPI wilt spelen (de SPI-testbench doet dat al).
    parameter integer DEMO_ONLY  = 1
) (
    input  wire         sys_clk,      // systeemklok (zie SYS_CLK_HZ)
    input  wire         sys_rst_n,    // Active-low reset

    // SPI-slave (MusicBrain frame-protocol); de brain (Teensy 4.1) is master
    input  wire         spi_sclk,
    input  wire         spi_mosi,
    output wire         spi_miso,     // slave → master (Pong-respons)
    input  wire         spi_cs_n,

    input  wire         demo_mode,    // 1 = interne demo-sequencer, 0 = SPI-CV's
    input  wire         key_mute_n,   // DIP-switch (niveau): audio aan/uit
    input  wire         wah_sw,       // DIP-switch: wah master aan/uit (hoog=aan)
    input  wire         wah_btn_n,    // drukknop (active-low): stapt wah-niveau 0..3 (wrapt)

    output wire         led,          // Status LED

    // Onboard PT8211 stereo-DAC (Tang Primer 20K Dock → 3.5mm jack)
    output wire         hp_bck,
    output wire         hp_ws,
    output wire         hp_din,
    output wire         pa_en
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
                clk_divider     <= clk_divider + 16'd1;
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
                note_index <= note_index + 2'd1;   // Volgende noot (wraps bij 2 bits)
            end else begin
                seq_timer <= seq_timer + 18'd1;
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
    // dCV's: u16 offset-binary (0x0000=min, 0xFFFF=max), zie doc/PITCH_CV.md
    wire [15:0] pitch_cv, cutoff_cv, reson_cv, drive_cv;
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

    // pitch-dCV → MIDI-noot. Uniforme dCV-conventie (zie doc/PITCH_CV.md,
    // MusicBrain ADR 0014): 16-bit offset-binary, full-scale 2^16
    //   (0x0000 = range-min, 0xFFFF ≈ range-max).
    // Default-config: 0..10 V, 1 V/oct, 0 V = MIDI-noot 0 → 10 octaven over 0..0xFFFF.
    // Bij V/oct is de code lineair in semitonen:  note = (code * 120) >> 16.
    wire [23:0] note_calc  = pitch_cv * 16'd120;       // 0 .. ~7.86M
    wire [6:0]  spi_note   = note_calc[22:16];         // /65536 → 0..119 (past in 7 bits)
    wire [10:0] spi_period;
    note_to_period u_n2p (.clk(sys_clk), .note(spi_note), .period(spi_period));

    // CV → Q12.20 filterparameters. dCV is offset-binary UNSIGNED (0x0000=min,
    // 0xFFFF=max), dus zero-extend (NIET sign-extend). Zie doc/PITCH_CV.md.
    wire [31:0] cutoff_u = {16'd0, cutoff_cv};
    wire [31:0] reson_u  = {16'd0, reson_cv};
    wire [31:0] drive_u  = {16'd0, drive_cv};

    // cutoff: 0..0xFFFF → g 0..~0.5
    wire signed [31:0] g_spi = $signed(cutoff_u << 3);
    // resonance: hoger CV = meer resonantie = LAGERE demping k (floor 0.125)
    wire signed [31:0] k_sub     = $signed(reson_u << 5);
    wire signed [31:0] k_spi_raw = 32'sh00100000 - k_sub;
    wire signed [31:0] k_spi     = (k_spi_raw < 32'sh00020000) ? 32'sh00020000 : k_spi_raw;
    // drive: 1.0 + CV
    wire signed [31:0] drive_spi = 32'sh00100000 + $signed(drive_u << 6);

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
    // demo_eff: effectieve demo-keuze. DEMO_ONLY forceert demo (negeert de pin).
    wire               demo_eff    = (DEMO_ONLY != 0) ? 1'b1 : demo_mode;
    wire [10:0]        eff_period  = demo_eff ? current_period : spi_period;
    wire               eff_trigger = demo_eff ? trigger_pulse  : spi_trig_pulse;

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
    // MS-20 FILTER — met envelope op de cutoff, in 4 WAH-NIVEAUS
    //
    // Filter-envelope per noot: attack opent de cutoff, daarna zakt hij in
    // ~0.5 s terug. Dit geeft de karakteristieke "wah" per aanslag.
    //
    // T2 (drukknop) stapt door de niveaus: 0=uit → 1=licht → 2=medium →
    // 3=dik → terug naar 0. Per niveau gaan sweep-breedte, resonantie (lagere
    // k) en drive omhoog. Niveau 2 ≈ het oude vaste wah-geluid.
    //
    // LET OP: het filter draait intern op 2x oversampling (96 kHz), dus de
    // Chamberlin cutoff-coeff is g = 2*sin(pi*fc/96000)  (zie gen_tables.py):
    //   g(200Hz)  ≈ 0.01309 → Q12.20: 0x0000359E
    //   g(300Hz)  ≈ 0.01963 → Q12.20: 0x00005067
    //   g(800Hz)  ≈ 0.05233 → Q12.20: 0x0000D671
    //   g(1500Hz) ≈ 0.09814 → Q12.20: 0x000191F6
    //   g(3000Hz) ≈ 0.19603 → Q12.20: 0x000322F5
    //   g(4000Hz) ≈ 0.26105 → Q12.20: 0x00042D45
    // ========================================================================
    reg [15:0] env_timer;
    reg signed [31:0] filter_g;
    reg        filter_mode;

    localparam signed [31:0] G_FIXED = 32'h0000D671;  // ~800 Hz (statisch, wah uit)

    // wah-schakelaar synchroniseren (schoon niveau, 2-FF). Default hoog = wah aan.
    reg [1:0] wah_s;
    always @(posedge sys_clk or posedge rst)
        if (rst) wah_s <= 2'b11;
        else     wah_s <= {wah_s[0], wah_sw};

    // wah-drukknop: synchroniseren + debouncen (~39ms @27MHz, zoals key_mute_n);
    // elke druk (dalende flank op het gedebouncede niveau) stapt een niveau
    // omhoog: 0=uit → 1=licht → 2=medium → 3=dik → 0=uit → ...
    reg [1:0]  btn_s;
    reg [19:0] btn_db_cnt;
    reg        btn_db, btn_db_d;
    reg [1:0]  wah_level;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            btn_s <= 2'b11; btn_db_cnt <= 20'd0;
            btn_db <= 1'b1; btn_db_d <= 1'b1;
            wah_level <= 2'd2;                 // boot: medium (≈ het oude geluid)
        end else begin
            btn_s <= {btn_s[0], wah_btn_n};
            if (btn_s[1] == btn_db) btn_db_cnt <= 20'd0;
            else begin
                btn_db_cnt <= btn_db_cnt + 20'd1;
                if (&btn_db_cnt) btn_db <= btn_s[1];
            end
            btn_db_d <= btn_db;
            if (btn_db_d & ~btn_db) wah_level <= wah_level + 2'd1;  // druk = trapje (wrapt)
        end
    end

    // Effectief niveau: de DIP (E9) is master-schakelaar — laag = geforceerd uit.
    // Hoog (default via pull-up): de T2-knop bepaalt het niveau.
    wire [1:0] eff_level = wah_s[1] ? wah_level : 2'd0;

    // Per-niveau parameters: open-cutoff (aanslag), eind-cutoff, sweep-stap
    // (per 64 samples; ≈ (open-eind)/375 voor een sweep van ~0.5 s), k, drive.
    reg signed [31:0] wah_g_open, wah_g_end, wah_g_step, wah_k, wah_drive;
    always @(*) begin
        case (eff_level)
            2'd1: begin  // licht: smalle sweep, milde resonantie
                wah_g_open = 32'h000191F6;  // ~1500 Hz
                wah_g_end  = 32'h00005067;  // ~300 Hz
                wah_g_step = 32'h000000DC;
                wah_k      = 32'h000C0000;  // 0.75
                wah_drive  = 32'h00200000;  // 2.0
            end
            2'd2: begin  // medium: ≈ het oude wah-geluid, iets meer drive
                wah_g_open = 32'h000322F5;  // ~3000 Hz
                wah_g_end  = 32'h00005067;  // ~300 Hz
                wah_g_step = 32'h000001EF;
                wah_k      = 32'h000A0000;  // 0.625
                wah_drive  = 32'h00280000;  // 2.5
            end
            2'd3: begin  // dik: brede sweep, hoge resonantie, harde drive
                wah_g_open = 32'h00042D45;  // ~4000 Hz
                wah_g_end  = 32'h0000359E;  // ~200 Hz
                wah_g_step = 32'h000002B5;
                wah_k      = 32'h00060000;  // 0.375 (scream, tanh begrenst)
                wah_drive  = 32'h00300000;  // 3.0
            end
            default: begin  // 0 = uit: statische cutoff, neutraal
                wah_g_open = G_FIXED;
                wah_g_end  = G_FIXED;
                wah_g_step = 32'sd0;
                wah_k      = 32'h000A0000;  // 0.625
                wah_drive  = 32'h00200000;  // 2.0
            end
        endcase
    end

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            env_timer   <= 0;
            filter_g    <= G_FIXED;
            filter_mode <= 1'b0;          // Low-pass
        end else if (sample_clk_tick) begin
            if (trigger_pulse) begin
                // Nieuwe noot: open naar het niveau-afhankelijke startpunt
                // (niveau 0: wah_g_open = G_FIXED → statisch, geen sweep)
                env_timer <= 0;
                filter_g  <= wah_g_open;
            end else if (eff_level != 2'd0) begin
                if (env_timer < 16'd24000) begin
                    env_timer <= env_timer + 16'd1;
                    // Elke 64 samples een stapje richting wah_g_end (~0.5 s sweep)
                    if (env_timer[5:0] == 6'd0 && filter_g > wah_g_end + wah_g_step)
                        filter_g <= filter_g - wah_g_step;
                end
            end else begin
                filter_g <= G_FIXED;       // wah uit: statische cutoff
            end
        end
    end

    // ========================================================================
    // MS-20 STATE-VARIABLE FILTER  (demo-envelope vs SPI-CV's via mux)
    // ========================================================================
    wire signed [31:0] eff_g     = demo_eff ? filter_g  : g_spi;
    wire signed [31:0] eff_k     = demo_eff ? wah_k     : k_spi;
    wire signed [31:0] eff_drive = demo_eff ? wah_drive : drive_spi;

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
    // (audio_out-poort verwijderd: was alleen voor sim; testbenches lezen
    //  uut.filter_out hierarchisch. Scheelt 32 togglende pinnen → minder ruis.)

    // ---- Onboard PT8211 DAC: 32-bit Q12.20 → 16-bit signed (gain ~2 + saturatie)
    // >>>4: een signaal van 0.5 (Q12.20) bereikt full-scale; filter-pieken ~0.2-0.25
    // → ~-6 dBFS. Pas de shift aan voor meer/minder volume.
    // Gain: door de resonante wah zijn de pieken groter (~0.32), dus >>>4 geeft al
    // een luide ~-4 dBFS piek zónder clipping (beste SNR uit de PT8211). Saturatie
    // vangt restuitschieters. Minder resonantie? Dan kan de gain weer omhoog.
    wire signed [31:0] dac_scaled = filter_out >>> 4;
    wire signed [15:0] dac_sample =
        (dac_scaled >  32'sd32767)  ?  16'sd32767  :
        (dac_scaled < -32'sd32768)  ? -16'sd32768  :
        dac_scaled[15:0];

    // ---- Mute via DIP-switch (T4): niveau-gebaseerd, gedebounced.
    // audio_en volgt de DIP-stand: 1 (pull-up) = geluid aan, 0 = stil.
    // Default audio_en = 1, zodat de demo speelt bij verkeerde/niet-bedrade pin.
    reg  [1:0]  key_s;
    reg  [19:0] key_db_cnt;
    reg         key_db, audio_en;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            key_s <= 2'b11; key_db_cnt <= 20'd0; key_db <= 1'b1; audio_en <= 1'b1;
        end else begin
            key_s <= {key_s[0], key_mute_n};           // synchroniseer
            if (key_s[1] == key_db) key_db_cnt <= 20'd0;
            else begin
                key_db_cnt <= key_db_cnt + 20'd1;
                if (&key_db_cnt) key_db <= key_s[1];   // ~39ms stabiel → accepteer stand
            end
            audio_en <= key_db;                        // niveau = aan/uit
        end
    end

    wire signed [15:0] dac_out = audio_en ? dac_sample : 16'sd0;

    pt8211_tx u_dac (
        .clk      (sys_clk),
        .rst      (rst),
        .sample_in(dac_out),
        .en       (audio_en),     // mute (T4) zet ook de versterker uit → echt stil
        .hp_bck   (hp_bck),
        .hp_ws    (hp_ws),
        .hp_din   (hp_din),
        .pa_en    (pa_en)
    );

    // LED-heartbeat (~0.8 Hz @27MHz): zichtbaar levensteken bij de eerste flash —
    // bewijst dat klok + bitstream draaien, los van audio.
    reg [24:0] hb_cnt;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) hb_cnt <= 25'd0;
        else     hb_cnt <= hb_cnt + 25'd1;
    end
    assign led = hb_cnt[24];

endmodule