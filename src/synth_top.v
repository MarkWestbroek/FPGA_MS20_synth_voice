// ============================================================================
// SYNTH_TOP — 8-stemmige Karplus-Strong Bass + MS-20 Filter (polyfoon)
//
// Signaalketen (per stem, time-multiplexed in voice_engine):
//   Trigger → KS String → MS-20 SVF → mix → PT8211 DAC
//
// Demo (DEMO_ONLY=1): arpeggiator — elke 0,5 s de volgende stem round-robin
// getriggerd met een 8-noten patroon; de ~2,9 s KS-staarten overlappen → je
// hoort de polyfonie. SPI-mode: per stem pitch/cutoff/reson/drive + gate
// (MusicBrain-frames, slot = voice*4+param). Zie doc/POLY_PLAN.md.
//
// Alles in Q12.20 fixed-point, 48 kHz sample rate.
// ============================================================================

`timescale 1ns / 1ps

module synth_top #(
    // Systeemklok-frequentie. Default = 27 MHz = het onboard kristal van de Tang
    // Primer 20K (native draaien, geen PLL nodig). De testbenches klokken op
    // 50 MHz en overschrijven dit naar 50_000_000.
    parameter integer SYS_CLK_HZ = 27_000_000,
    parameter integer SAMPLE_HZ  = 48_000,
    // DEMO_ONLY=1: forceer de interne demo-arpeggiator (negeer de demo_mode-pin).
    parameter integer DEMO_ONLY  = 1
) (
    input  wire         sys_clk,      // systeemklok (zie SYS_CLK_HZ)
    input  wire         sys_rst_n,    // Active-low reset

    // SPI-slave (MusicBrain frame-protocol); de brain (Teensy 4.1) is master
    input  wire         spi_sclk,
    input  wire         spi_mosi,
    output wire         spi_miso,     // slave → master (Pong-respons)
    input  wire         spi_cs_n,

    input  wire         demo_mode,    // 1 = interne demo-arpeggiator, 0 = SPI-CV's
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

    localparam integer NV = 8;        // aantal stemmen (voice_engine is 8 breed)

    wire rst = !sys_rst_n;

    // ========================================================================
    // KLOKVERDELER: sys_clk → ~48 kHz sample-tick
    // ========================================================================
    localparam [15:0] CLK_DIV = (SYS_CLK_HZ / SAMPLE_HZ) - 1;  // 561 @27MHz

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
    // DEMO-ARPEGGIATOR: elke 0,5 s de volgende stem met de volgende noot
    //
    //   stem 0..7 → E1 A1 D2 G1 E2 G2 A2 D3 (period = 48000/freq)
    // KS-decay ~2,9 s → er klinken steeds ~6 stemmen tegelijk.
    // ========================================================================
    function [10:0] arp_period(input [2:0] i);
        case (i)
            3'd0: arp_period = 11'd1165;  // E1  41.2 Hz
            3'd1: arp_period = 11'd873;   // A1  55.0 Hz
            3'd2: arp_period = 11'd654;   // D2  73.4 Hz
            3'd3: arp_period = 11'd980;   // G1  49.0 Hz
            3'd4: arp_period = 11'd582;   // E2  82.4 Hz
            3'd5: arp_period = 11'd490;   // G2  98.0 Hz
            3'd6: arp_period = 11'd436;   // A2 110.0 Hz
            default: arp_period = 11'd327; // D3 146.8 Hz
        endcase
    endfunction

    reg [14:0]  arp_cnt;              // 0..23999 ticks = 0,5 s per stap
    reg [2:0]   arp_v;                // round-robin stem/noot-index
    reg [7:0]   trig_demo;            // per-stem trigger (één tick-gap hoog)
    reg [10:0]  period_demo [0:NV-1];

    integer d;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            arp_cnt   <= 15'd0;
            arp_v     <= 3'd0;
            trig_demo <= 8'd0;
            for (d = 0; d < NV; d = d + 1) period_demo[d] <= arp_period(d[2:0]);
        end else if (sample_clk_tick) begin
            trig_demo <= 8'd0;
            if (arp_cnt == 15'd0) begin
                trig_demo[arp_v]   <= 1'b1;
                period_demo[arp_v] <= arp_period(arp_v);
            end
            if (arp_cnt >= 15'd23999) begin
                arp_cnt <= 15'd0;
                arp_v   <= arp_v + 3'd1;      // wrapt bij 8
            end else
                arp_cnt <= arp_cnt + 15'd1;
        end
    end

    // ========================================================================
    // SPI-CONTROL: brain → per-stem CV/gate (slot = voice*4+param)
    // ========================================================================
    wire [7:0] spi_rx_byte, spi_tx_byte;
    wire       spi_rx_valid, spi_cs_active, spi_tx_load;
    wire       cv_we;
    wire [2:0] cv_voice;
    wire [1:0] cv_param;
    wire [15:0] cv_val;
    wire [7:0] spi_gate, spi_trigger;

    spi_slave u_spi_slave (
        .clk(sys_clk), .rst(rst),
        .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n),
        .rx_byte(spi_rx_byte), .rx_valid(spi_rx_valid), .cs_active(spi_cs_active),
        .tx_byte(spi_tx_byte), .tx_load(spi_tx_load)
    );

    spi_frame u_spi_frame (
        .clk(sys_clk), .rst(rst),
        .rx_byte(spi_rx_byte), .rx_valid(spi_rx_valid), .cs_active(spi_cs_active),
        .cv_we(cv_we), .cv_voice(cv_voice), .cv_param(cv_param), .cv_val(cv_val),
        .gate(spi_gate), .trigger(spi_trigger),
        .pong_req(), .frame_ok(),
        .tx_byte(spi_tx_byte), .tx_load(spi_tx_load)
    );

    // ---- CV-mappings (dCV u16 offset-binary → Q12.20, zie doc/PITCH_CV.md) ----
    // pitch: note = (code*120)>>16 (0..10V, 1 V/oct, 0V = MIDI 0)
    wire [23:0] note_calc = cv_val * 16'd120;
    wire [6:0]  spi_note  = note_calc[22:16];
    // cutoff: 0..0xFFFF → g 0..~0.5
    wire signed [31:0] g_map = $signed({16'd0, cv_val} << 3);
    // resonance: hoger CV = LAGERE demping k (floor 0.125)
    wire signed [31:0] k_sub = $signed({16'd0, cv_val} << 5);
    wire signed [31:0] k_raw = 32'sh00100000 - k_sub;
    wire signed [31:0] k_map = (k_raw < 32'sh00020000) ? 32'sh00020000 : k_raw;
    // drive: 1.0 + CV
    wire signed [31:0] drv_map = 32'sh00100000 + $signed({16'd0, cv_val} << 6);

    // per-stem parameter-arrays (SPI-mode)
    reg [10:0]        period_spi [0:NV-1];
    reg signed [31:0] g_spi_a    [0:NV-1];
    reg signed [31:0] k_spi_a    [0:NV-1];
    reg signed [31:0] drv_spi_a  [0:NV-1];

    // pitch → period via de note_to_period-LUT (sync read): 2-staps pipeline
    reg  [6:0] n2p_note;
    reg  [2:0] n2p_v;
    reg  [1:0] n2p_pend;
    wire [10:0] n2p_period;
    note_to_period u_n2p (.clk(sys_clk), .note(n2p_note), .period(n2p_period));

    integer s;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            n2p_note <= 7'd0; n2p_v <= 3'd0; n2p_pend <= 2'b00;
            for (s = 0; s < NV; s = s + 1) begin
                period_spi[s] <= 11'd654;
                g_spi_a[s]    <= 32'h0000D671;   // ~800 Hz
                k_spi_a[s]    <= 32'h000A0000;   // 0.625
                drv_spi_a[s]  <= 32'h00200000;   // 2.0
            end
        end else begin
            n2p_pend <= {n2p_pend[0], 1'b0};
            if (cv_we) begin
                case (cv_param)
                    2'd0: begin                   // pitch → LUT-lookup starten
                        n2p_note <= spi_note;
                        n2p_v    <= cv_voice;
                        n2p_pend <= 2'b01;
                    end
                    2'd1: g_spi_a[cv_voice]   <= g_map;
                    2'd2: k_spi_a[cv_voice]   <= k_map;
                    2'd3: drv_spi_a[cv_voice] <= drv_map;
                endcase
            end
            if (n2p_pend[1]) period_spi[n2p_v] <= n2p_period;
        end
    end

    // SPI-triggers naar het tick-domein tillen (vector-versie: puls blijft de
    // hele tick-gap hoog zodat de engine 'm op de volgende tick consumeert)
    reg [7:0] trig_pend, spi_trig_tick;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            trig_pend     <= 8'd0;
            spi_trig_tick <= 8'd0;
        end else if (sample_clk_tick) begin
            spi_trig_tick <= trig_pend | spi_trigger;
            trig_pend     <= 8'd0;
        end else
            trig_pend <= trig_pend | spi_trigger;
    end

    // ========================================================================
    // MUX: demo-arpeggiator vs SPI-CV's
    // ========================================================================
    wire       demo_eff  = (DEMO_ONLY != 0) ? 1'b1 : demo_mode;
    wire [7:0] eff_trig  = demo_eff ? trig_demo : spi_trig_tick;

    wire [87:0]  period_flat;
    wire [255:0] g_spi_flat, k_spi_flat, drv_spi_flat;
    genvar gv;
    generate
        for (gv = 0; gv < NV; gv = gv + 1) begin : g_mux
            assign period_flat[gv*11 +: 11] =
                demo_eff ? period_demo[gv] : period_spi[gv];
            assign g_spi_flat  [gv*32 +: 32] = g_spi_a[gv];
            assign k_spi_flat  [gv*32 +: 32] = k_spi_a[gv];
            assign drv_spi_flat[gv*32 +: 32] = drv_spi_a[gv];
        end
    endgenerate

    // ========================================================================
    // WAH-NIVEAUS (T2-drukknop, DIP E9 = master aan/uit) — zie oude synth_top;
    // de envelope zelf loopt per stem in voice_engine.
    //   g = 2*sin(pi*fc/96000) (Q12.20, interne 96 kHz rate)
    // ========================================================================
    localparam signed [31:0] G_FIXED = 32'h0000D671;  // ~800 Hz (statisch/uit)

    // DIP synchroniseren (2-FF). Default hoog = wah aan.
    reg [1:0] wah_s;
    always @(posedge sys_clk or posedge rst)
        if (rst) wah_s <= 2'b11;
        else     wah_s <= {wah_s[0], wah_sw};

    // T2: sync + debounce (~39ms @27MHz); elke druk stapt het niveau (wrapt)
    reg [1:0]  btn_s;
    reg [19:0] btn_db_cnt;
    reg        btn_db, btn_db_d;
    reg [1:0]  wah_level;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            btn_s <= 2'b11; btn_db_cnt <= 20'd0;
            btn_db <= 1'b1; btn_db_d <= 1'b1;
            wah_level <= 2'd2;                 // boot: medium
        end else begin
            btn_s <= {btn_s[0], wah_btn_n};
            if (btn_s[1] == btn_db) btn_db_cnt <= 20'd0;
            else begin
                btn_db_cnt <= btn_db_cnt + 20'd1;
                if (&btn_db_cnt) btn_db <= btn_s[1];
            end
            btn_db_d <= btn_db;
            if (btn_db_d & ~btn_db) wah_level <= wah_level + 2'd1;
        end
    end

    wire [1:0] eff_level = wah_s[1] ? wah_level : 2'd0;

    // Per-niveau envelope-parameters (globaal; envelope per stem in de engine)
    reg signed [31:0] env_g_open, env_g_end, env_g_step, env_k, env_drive;
    always @(*) begin
        case (eff_level)
            2'd1: begin  // licht
                env_g_open = 32'h000191F6;  // ~1500 Hz
                env_g_end  = 32'h00005067;  // ~300 Hz
                env_g_step = 32'h000000DC;
                env_k      = 32'h000C0000;  // 0.75
                env_drive  = 32'h00200000;  // 2.0
            end
            2'd2: begin  // medium (≈ het oude wah-geluid)
                env_g_open = 32'h000322F5;  // ~3000 Hz
                env_g_end  = 32'h00005067;  // ~300 Hz
                env_g_step = 32'h000001EF;
                env_k      = 32'h000A0000;  // 0.625
                env_drive  = 32'h00280000;  // 2.5
            end
            2'd3: begin  // dik
                env_g_open = 32'h00042D45;  // ~4000 Hz
                env_g_end  = 32'h0000359E;  // ~200 Hz
                env_g_step = 32'h000002B5;
                env_k      = 32'h00060000;  // 0.375
                env_drive  = 32'h00300000;  // 3.0
            end
            default: begin  // 0 = uit: statische cutoff
                env_g_open = G_FIXED;
                env_g_end  = G_FIXED;
                env_g_step = 32'sd0;
                env_k      = 32'h000A0000;
                env_drive  = 32'h00200000;
            end
        endcase
    end

    // ========================================================================
    // VOICE ENGINE — 8 stemmen KS + MS-20, time-multiplexed
    // ========================================================================
    wire signed [31:0] ks_damping = 32'h000FFF6A;  // ~0.9995 (decay ~2,9 s)
    wire signed [31:0] string_out, filter_out;     // droge mix / gefilterde mix

    voice_engine u_engine (
        .clk        (sys_clk),
        .rst        (rst),
        .ce         (sample_clk_tick),
        .trig       (eff_trig),
        .period_flat(period_flat),
        .use_env    (demo_eff),
        .env_g_open (env_g_open),
        .env_g_end  (env_g_end),
        .env_g_step (env_g_step),
        .env_k      (env_k),
        .env_drive  (env_drive),
        .g_spi_flat (g_spi_flat),
        .k_spi_flat (k_spi_flat),
        .drive_spi_flat(drv_spi_flat),
        .ks_damping (ks_damping),
        .string_out (string_out),
        .mix_out    (filter_out)
    );

    // ========================================================================
    // UITGANGEN — PT8211. De engine-mix is al ÷4; >>>3 hier geeft een enkele
    // stem ~-10 dBFS en laat akkoorden optellen (saturatie vangt extremen).
    // ========================================================================
    wire signed [31:0] dac_scaled = filter_out >>> 3;
    wire signed [15:0] dac_sample =
        (dac_scaled >  32'sd32767)  ?  16'sd32767  :
        (dac_scaled < -32'sd32768)  ? -16'sd32768  :
        dac_scaled[15:0];

    // ---- Mute via DIP-switch (T4): niveau-gebaseerd, gedebounced.
    reg  [1:0]  key_s;
    reg  [19:0] key_db_cnt;
    reg         key_db, audio_en;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            key_s <= 2'b11; key_db_cnt <= 20'd0; key_db <= 1'b1; audio_en <= 1'b1;
        end else begin
            key_s <= {key_s[0], key_mute_n};
            if (key_s[1] == key_db) key_db_cnt <= 20'd0;
            else begin
                key_db_cnt <= key_db_cnt + 20'd1;
                if (&key_db_cnt) key_db <= key_s[1];
            end
            audio_en <= key_db;
        end
    end

    wire signed [15:0] dac_out = audio_en ? dac_sample : 16'sd0;

    pt8211_tx u_dac (
        .clk      (sys_clk),
        .rst      (rst),
        .sample_in(dac_out),
        .en       (audio_en),
        .hp_bck   (hp_bck),
        .hp_ws    (hp_ws),
        .hp_din   (hp_din),
        .pa_en    (pa_en)
    );

    // LED-heartbeat (~0.8 Hz @27MHz)
    reg [24:0] hb_cnt;
    always @(posedge sys_clk or posedge rst) begin
        if (rst) hb_cnt <= 25'd0;
        else     hb_cnt <= hb_cnt + 25'd1;
    end
    assign led = hb_cnt[24];

endmodule
