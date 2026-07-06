// ============================================================================
// VOICE_ENGINE — 8 stemmen time-multiplexed: Karplus-Strong + MS-20 SVF
//
// Eén gedeelde rekenkern (KS-datapath + MS-20-datapath + één tanh-LUT) rekent
// per audio-tick (48 kHz) alle 8 stemmen sequentieel door. Zo blijft het
// DSP-gebruik gelijk aan de mono-versie; alleen de state groeit per stem.
// Zie doc/POLY_PLAN.md. Cycle-budget: ~75 van de 562 cycles/tick @27 MHz.
//
// Per stem, per tick:
//   1. KS:  y = damping * 0.5 * (d[ptr] + d[ptr+1]);  d[ptr] = y;  ptr++
//   2. MS-20 (2x oversampled, identiek aan ms20_filter.v, Q12.20):
//        hp = y - lp - k*tanh(drive*bp);  bp += g*hp;  lp += g*bp
//      met saturerende integrators (±16.0).
//   3. Wah-envelope (per stem): trigger opent fg naar env_g_open, daarna
//      sweep naar env_g_end (stap per 64 samples). env_g_step==0 → statisch.
//
// Delay-geheugen: één BRAM 16384×18 — adres {voice[2:0], idx[10:0]}, samples
// als Q1.17 (KS-content is ±1.0; 16 BSRAM-blokken i.p.v. 32 bij 32-bit).
//
// FILL: een trigger zet een fill-request; de volledige 2048-lijn van die stem
// wordt met LFSR-ruis gevuld in de idle-cycles ná het stemmen-werk (~4 ticks;
// de stem is intussen stil). Volledig vullen voorkomt stale/x-reads bij
// latere pitch-verlaging (zie ks_string.v).
//
// Alle parameters Q12.20 zoals in de mono-modules.
// ============================================================================

`timescale 1ns / 1ps

module voice_engine (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,                    // 48 kHz sample-tick

    // per-stem trigger (hele tick-gap hoog, zoals ks_string verwacht)
    input  wire [7:0]  trig,
    // per-stem KS-period (8 × 11 bit, stem 0 = bits [10:0])
    input  wire [87:0] period_flat,

    // ---- wavetable-oscillator (exciter-keuze per stem) ----
    input  wire [7:0]   wt_en,        // 1 = wavetable, 0 = Karplus-Strong
    input  wire [7:0]   wt_wave,      // golfvorm per stem: 0 = saw, 1 = square
    input  wire [7:0]   gate,         // amp-envelope gate per stem (voor WT)
    input  wire [255:0] phinc_flat,   // fase-increment per stem (8 × 32 bit)

    // 1 = interne wah-envelope per stem (demo); 0 = SPI: statische per-stem params
    input  wire        use_env,
    // globale wah-niveau parameters (Q12.20; env_g_step==0 → statisch env_g_open)
    input  wire signed [31:0] env_g_open,
    input  wire signed [31:0] env_g_end,
    input  wire signed [31:0] env_g_step,
    input  wire signed [31:0] env_k,
    input  wire signed [31:0] env_drive,
    // SPI per-stem filterparameters (alleen gebruikt als use_env=0)
    input  wire [255:0] g_spi_flat,
    input  wire [255:0] k_spi_flat,
    input  wire [255:0] drive_spi_flat,

    input  wire signed [31:0] ks_damping,     // Q12.20, ~0.9995

    output reg signed [31:0] string_out,      // droge KS-mix  (som/4, Q12.20)
    output reg signed [31:0] mix_out          // gefilterde mix (som/4, Q12.20)
);

    localparam integer NV = 8;

    // ========================================================================
    // Per-stem state
    // ========================================================================
    reg [10:0]        ptr        [0:NV-1];
    reg               initialized[0:NV-1];
    reg signed [31:0] lp_r       [0:NV-1];
    reg signed [31:0] bp_r       [0:NV-1];
    reg [15:0]        env_t      [0:NV-1];
    reg signed [31:0] fg         [0:NV-1];    // per-stem envelope-cutoff
    reg signed [31:0] lastout    [0:NV-1];    // laatste filteroutput (debug/tb)
    reg [31:0]        phase      [0:NV-1];    // WT fase-accumulator
    reg [16:0]        amp        [0:NV-1];    // WT amp-envelope (Q1.16, 0..65536)

    // flat inputs → per-stem views
    wire [10:0]        period_v [0:NV-1];
    wire signed [31:0] g_spi_v  [0:NV-1];
    wire signed [31:0] k_spi_v  [0:NV-1];
    wire signed [31:0] drv_spi_v[0:NV-1];
    genvar gi;
    generate
        for (gi = 0; gi < NV; gi = gi + 1) begin : g_flat
            assign period_v[gi] = period_flat[gi*11 +: 11];
            assign g_spi_v[gi]  = g_spi_flat [gi*32 +: 32];
            assign k_spi_v[gi]  = k_spi_flat [gi*32 +: 32];
            assign drv_spi_v[gi]= drive_spi_flat[gi*32 +: 32];
        end
    endgenerate

    // ========================================================================
    // Delay-BRAM: 8 × 2048 × 18 bit (Q1.17)
    //
    // Strikt semi-dual-port (één schrijf- en één geregistreerde leespoort)
    // zodat Gowin dit op BSRAM mapt: de FSM zet alléén d_raddr/d_waddr/
    // d_wdata/d_we; alle geheugentoegang zit in dit ene proces.
    // ========================================================================
    (* ram_style = "block" *) reg signed [17:0] dmem [0:16383];

    reg  [13:0]        d_raddr, d_waddr;
    reg                d_we;
    reg signed [17:0]  d_wdata;
    reg signed [17:0]  d_q;

    always @(posedge clk) begin
        if (d_we) dmem[d_waddr] <= d_wdata;
        d_q <= dmem[d_raddr];
    end

    // ========================================================================
    // LFSR-ruis (vrijlopend), 18-bit Q1.17 sample ±1.0
    // ========================================================================
    reg [22:0] lfsr;
    always @(posedge clk or posedge rst)
        if (rst) lfsr <= 23'h7FFFFF;
        else     lfsr <= {lfsr[21:0], lfsr[22] ^ lfsr[17]};
    wire signed [17:0] noise18 = lfsr[17:0];

    // ========================================================================
    // Wavetable-ROM: 2 golfvormen × 8 mips × 1024 × 16 bit (wavetable.hex)
    // Eén geregistreerde leespoort (pROM in BSRAM), zelfde recept als dmem.
    // ========================================================================
    (* ram_style = "block" *) reg signed [15:0] wrom [0:16383];
    initial begin
        $readmemh("wavetable.hex", wrom);
    end

    reg  [13:0]        w_raddr;
    reg signed [15:0]  w_q;

    always @(posedge clk) begin
        w_q <= wrom[w_raddr];
    end

    // ========================================================================
    // Gedeelde datapath — combinatorisch rond de cur_* werkregisters
    // ========================================================================
    reg [2:0]         v;          // huidige stem
    reg signed [17:0] s0;         // eerste delay-sample (tweede komt uit d_q)
    reg signed [15:0] s0w;        // eerste wavetable-sample (tweede uit w_q)
    reg signed [31:0] cur_lp, cur_bp, cur_in;
    reg signed [32:0] vsum;       // som van de 2 oversample-suboutputs
    reg signed [31:0] sub0;

    // ---- WT-oscillator: mip-keuze uit de MSB-positie van de fase-increment
    // (mip m dekt inc in [2^(19+m), 2^(20+m)); conservatief clampen op 7)
    function [2:0] mip_of(input [31:0] inc);
        casez (inc[30:20])
            11'b1zzzzzzzzzz: mip_of = 3'd7;
            11'b01zzzzzzzzz: mip_of = 3'd7;
            11'b001zzzzzzzz: mip_of = 3'd7;
            11'b0001zzzzzzz: mip_of = 3'd7;
            11'b00001zzzzzz: mip_of = 3'd7;
            11'b000001zzzzz: mip_of = 3'd6;
            11'b0000001zzzz: mip_of = 3'd5;
            11'b00000001zzz: mip_of = 3'd4;
            11'b000000001zz: mip_of = 3'd3;
            11'b0000000001z: mip_of = 3'd2;
            11'b00000000001: mip_of = 3'd1;
            default:         mip_of = 3'd0;
        endcase
    endfunction

    wire [31:0] cur_phinc = phinc_flat[v*32 +: 32];
    wire [2:0]  cur_mip   = mip_of(cur_phinc);
    wire [9:0]  wt_idx    = phase[v][31:22];
    wire [7:0]  wt_frac   = phase[v][21:14];
    wire [13:0] wt_addr0  = {wt_wave[v], cur_mip, wt_idx};
    wire [13:0] wt_addr1  = {wt_wave[v], cur_mip, wt_idx + 10'd1};  // wrapt in 10 bit

    // lineaire interpolatie + amp-envelope (Q1.16) → Q12.20.
    // <<3 i.p.v. <<5: WT-amplitude ~0.25 — in balans met de KS-pluk (~0.3),
    // en houdt de mix ruim binnen bereik bij meerdere sustained stemmen.
    // (tweede sample komt rechtstreeks uit de geregistreerde leespoort w_q)
    wire signed [16:0] wt_diff  = w_q - s0w;
    wire signed [25:0] wt_dprod = wt_diff * $signed({1'b0, wt_frac});
    wire signed [18:0] wt_sum   = s0w + $signed(wt_dprod[25:8]);
    wire signed [16:0] wt_lerp  = wt_sum[16:0];   // waarde ligt tussen s0w en w_q
    wire signed [31:0] wt_q20   = {{13{wt_lerp[15]}}, wt_lerp[15:0], 3'b000};
    wire signed [49:0] wt_aprod = wt_q20 * $signed({1'b0, amp[v]});
    wire signed [31:0] wt_out   = wt_aprod[47:16];

    // KS: Q1.17 → Q12.20 (<<3), moving average + damping
    // (s1 komt rechtstreeks uit de geregistreerde leespoort d_q)
    wire signed [31:0] s0_q20     = {{11{s0[17]}}, s0, 3'b000};
    wire signed [31:0] s1_q20     = {{11{d_q[17]}}, d_q, 3'b000};
    wire signed [32:0] comp_sum   = s0_q20 + s1_q20;
    wire signed [31:0] comp_avg   = comp_sum >>> 1;
    wire signed [63:0] comp_damped= $signed(comp_avg) * $signed(ks_damping);
    wire signed [31:0] comp_new   = comp_damped[51:20];
    // terug naar Q1.17 (|y| < 1.0 dus dit past; saturatie als vangnet)
    wire signed [28:0] comp_sh    = comp_new >>> 3;
    wire signed [17:0] comp_18    =
        (comp_sh >  29'sd131071) ?  18'sd131071 :
        (comp_sh < -29'sd131072) ? -18'sd131072 : comp_sh[17:0];

    wire [10:0] cur_ptr  = ptr[v];
    wire [10:0] next_ptr = (cur_ptr >= period_v[v] - 11'd1) ? 11'd0 : cur_ptr + 11'd1;

    // Effectieve filterparameters voor stem v
    wire signed [31:0] eff_g   = use_env ? fg[v]     : g_spi_v[v];
    wire signed [31:0] eff_k   = use_env ? env_k     : k_spi_v[v];
    wire signed [31:0] eff_drv = use_env ? env_drive : drv_spi_v[v];

    // MS-20 SVF-stap (identiek aan ms20_filter.v, incl. saturatie ±16.0)
    localparam signed [31:0] SAT_MAX =  32'sh00FFFFFF;
    localparam signed [31:0] SAT_MIN = -32'sh01000000;
    localparam signed [31:0] X_MAX   =  32'sd4194304;   // +4.0
    localparam signed [31:0] X_MIN   = -32'sd4194304;   // -4.0

    wire signed [63:0] bp_drv_full = $signed(eff_drv) * $signed(cur_bp);
    wire signed [43:0] bp_driven   = bp_drv_full[63:20];
    wire signed [43:0] lut_sum     = bp_driven + X_MAX;
    wire [9:0] lut_addr = (bp_driven >= X_MAX) ? 10'd1023 :
                          (bp_driven <  X_MIN) ? 10'd0    :
                          lut_sum[22:13];
    wire signed [31:0] lut_tanh;
    tanh_lut u_tanh (.clk(clk), .addr(lut_addr), .data_out(lut_tanh));

    wire signed [63:0] prod_k    = $signed(eff_k) * $signed(lut_tanh);
    wire signed [31:0] feedback  = prod_k[51:20];
    wire signed [31:0] hp        = $signed(cur_in) - $signed(cur_lp) - $signed(feedback);

    wire signed [63:0] prod_g_hp = $signed(eff_g) * $signed(hp);
    wire signed [44:0] bp_sum    = $signed(cur_bp) + $signed(prod_g_hp[63:20]);
    wire signed [31:0] bp_next   = (bp_sum > SAT_MAX) ? SAT_MAX :
                                   (bp_sum < SAT_MIN) ? SAT_MIN : bp_sum[31:0];

    wire signed [63:0] prod_g_bp = $signed(eff_g) * $signed(bp_next);
    wire signed [44:0] lp_sum    = $signed(cur_lp) + $signed(prod_g_bp[63:20]);
    wire signed [31:0] lp_next   = (lp_sum > SAT_MAX) ? SAT_MAX :
                                   (lp_sum < SAT_MIN) ? SAT_MIN : lp_sum[31:0];

    wire signed [31:0] sub_out   = lp_next;    // low-pass output

    // ========================================================================
    // Sequencer-FSM
    // ========================================================================
    localparam S_WAIT = 4'd0;   // wacht op ce
    localparam S_VST  = 4'd1;   // stem-start: state laden / skip-beslissing
    localparam S_R1   = 4'd2;   // lees d[ptr]
    localparam S_R2   = 4'd3;   // lees d[ptr+1]
    localparam S_KS   = 4'd4;   // KS compute + writeback
    localparam S_FS1  = 4'd5;   // tanh-LUT settle (substap 1)
    localparam S_FC1  = 4'd6;   // SVF substap 1
    localparam S_FS2  = 4'd7;   // tanh-LUT settle (substap 2)
    localparam S_FC2  = 4'd8;   // SVF substap 2
    localparam S_ENV  = 4'd9;   // mix-acc + state-writeback + envelope
    localparam S_MIX  = 4'd10;  // outputs bijwerken
    localparam S_FILL = 4'd11;  // achtergrond-fill van delay-lijnen
    localparam S_W1   = 4'd12;  // WT: lees sample[idx]
    localparam S_W2   = 4'd13;  // WT: lees sample[idx+1]
    localparam S_WC   = 4'd14;  // WT: lerp + amp → cur_in, fase-update

    reg [3:0]  state;
    reg [7:0]  trig_l;          // triggers gelatcht op de tick
    reg [7:0]  fill_req;
    reg        fill_busy;
    reg [2:0]  fill_v;
    reg [10:0] fill_idx;
    reg signed [35:0] mix_acc, str_acc;
    wire signed [35:0] mix_sh = mix_acc >>> 2;   // mix = som van 8 stemmen ÷ 4
    wire signed [35:0] str_sh = str_acc >>> 2;
    reg        skip;            // huidige stem niet actief (fill/uninitialized)

    // laagste gezette bit (prioriteits-encoder voor de fill-wachtrij)
    function [2:0] lowest_bit(input [7:0] b);
        casez (b)
            8'bzzzzzzz1: lowest_bit = 3'd0;
            8'bzzzzzz10: lowest_bit = 3'd1;
            8'bzzzzz100: lowest_bit = 3'd2;
            8'bzzzz1000: lowest_bit = 3'd3;
            8'bzzz10000: lowest_bit = 3'd4;
            8'bzz100000: lowest_bit = 3'd5;
            8'bz1000000: lowest_bit = 3'd6;
            default:     lowest_bit = 3'd7;
        endcase
    endfunction

    integer k;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_WAIT;
            v          <= 3'd0;
            trig_l     <= 8'd0;
            fill_req   <= 8'd0;
            fill_busy  <= 1'b0;
            fill_v     <= 3'd0;
            fill_idx   <= 11'd0;
            mix_acc    <= 36'sd0;
            str_acc    <= 36'sd0;
            string_out <= 32'sd0;
            mix_out    <= 32'sd0;
            skip       <= 1'b0;
            s0 <= 18'sd0; s0w <= 16'sd0;
            cur_lp <= 32'sd0; cur_bp <= 32'sd0; cur_in <= 32'sd0;
            vsum <= 33'sd0; sub0 <= 32'sd0;
            d_raddr <= 14'd0; d_waddr <= 14'd0; d_wdata <= 18'sd0; d_we <= 1'b0;
            w_raddr <= 14'd0;
            for (k = 0; k < NV; k = k + 1) begin
                ptr[k]         <= 11'd0;
                initialized[k] <= 1'b0;
                lp_r[k]        <= 32'sd0;
                bp_r[k]        <= 32'sd0;
                env_t[k]       <= 16'd0;
                fg[k]          <= 32'sd0;
                lastout[k]     <= 32'sd0;
                phase[k]       <= 32'd0;
                amp[k]         <= 17'd0;
            end
        end else begin
            d_we <= 1'b0;      // default: geen write (states zetten 'm expliciet)

            // ---- tick-start (vanuit WAIT of FILL): stemmen-ronde beginnen ----
            if (ce) begin
                trig_l  <= trig;
                mix_acc <= 36'sd0;
                str_acc <= 36'sd0;
                v       <= 3'd0;
                state   <= S_VST;
                // triggers: KS → fill-request (stem stil tot de lijn vol is);
                //           WT → fase-reset (amp-attack loopt via gate)
                for (k = 0; k < NV; k = k + 1) begin
                    if (trig[k]) begin
                        if (wt_en[k]) begin
                            phase[k] <= 32'd0;
                        end else begin
                            fill_req[k]    <= 1'b1;
                            initialized[k] <= 1'b0;
                            ptr[k]         <= 11'd0;
                            if (fill_busy && fill_v == k[2:0])
                                fill_idx <= 11'd0;  // her-trigger tijdens fill: opnieuw
                        end
                    end
                end
            end else begin
                case (state)
                    S_WAIT: ;   // wachten op ce

                    // ---- stem v ----
                    // Geheugentiming: leesadres in cyclus N gezet → d_q/w_q
                    // geldig in cyclus N+2 (adres- én dataregister in de BRAM).
                    S_VST: begin
                        cur_lp <= lp_r[v];
                        cur_bp <= bp_r[v];
                        if (wt_en[v]) begin
                            skip    <= 1'b0;
                            w_raddr <= wt_addr0;       // schedule read sample[idx]
                            state   <= S_W1;
                        end else if (!initialized[v]) begin
                            // stil (wordt gevuld of nooit getriggerd): filter overslaan
                            skip   <= 1'b1;
                            vsum   <= 33'sd0;
                            cur_in <= 32'sd0;
                            state  <= S_ENV;
                        end else begin
                            skip    <= 1'b0;
                            d_raddr <= {v, cur_ptr};   // schedule read d[ptr]
                            state   <= S_R1;
                        end
                    end

                    // ---- WT-oscillator: 2 reads + lerp/amp ----
                    S_W1: begin
                        w_raddr <= wt_addr1;           // schedule read sample[idx+1]
                        state   <= S_W2;
                    end

                    S_W2: begin
                        s0w   <= w_q;                  // sample[idx] binnen
                        state <= S_WC;
                    end

                    S_WC: begin                        // w_q = sample[idx+1]
                        cur_in   <= wt_out;
                        str_acc  <= str_acc + $signed(wt_out);
                        phase[v] <= phase[v] + cur_phinc;
                        state    <= S_FS1;
                    end

                    S_R1: begin
                        d_raddr <= {v, next_ptr};      // schedule read d[ptr+1]
                        state   <= S_R2;
                    end

                    S_R2: begin
                        s0    <= d_q;                  // d[ptr] binnen
                        state <= S_KS;
                    end

                    S_KS: begin                        // d_q = d[ptr+1]
                        d_we    <= 1'b1;               // writeback d[ptr] = comp
                        d_waddr <= {v, cur_ptr};
                        d_wdata <= comp_18;
                        cur_in  <= comp_new;
                        str_acc <= str_acc + $signed(comp_new);
                        ptr[v]  <= next_ptr;
                        state   <= S_FS1;
                    end

                    S_FS1: state <= S_FC1;          // lut_tanh geldig maken

                    S_FC1: begin
                        cur_lp <= lp_next;
                        cur_bp <= bp_next;
                        sub0   <= sub_out;
                        state  <= S_FS2;
                    end

                    S_FS2: state <= S_FC2;

                    S_FC2: begin
                        cur_lp <= lp_next;
                        cur_bp <= bp_next;
                        vsum   <= $signed(sub0) + $signed(sub_out);
                        state  <= S_ENV;
                    end

                    S_ENV: begin
                        // decimatie (gemiddelde van 2 substappen) + mix
                        mix_acc    <= mix_acc + $signed(vsum >>> 1);
                        lastout[v] <= vsum >>> 1;
                        if (!skip) begin
                            lp_r[v] <= cur_lp;
                            bp_r[v] <= cur_bp;
                        end
                        // wah-envelope per stem (1× per tick per stem)
                        if (trig_l[v]) begin
                            env_t[v] <= 16'd0;
                            fg[v]    <= env_g_open;
                        end else if (env_g_step == 32'sd0) begin
                            fg[v] <= env_g_open;             // statisch niveau
                        end else if (env_t[v] < 16'd24000) begin
                            env_t[v] <= env_t[v] + 16'd1;
                            if (env_t[v][5:0] == 6'd0 && fg[v] > env_g_end + env_g_step)
                                fg[v] <= fg[v] - env_g_step;
                        end
                        // WT amp-envelope: attack ~0,7 ms, release ~85 ms
                        if (gate[v])
                            amp[v] <= (amp[v] >= 17'd63488) ? 17'd65536
                                                            : amp[v] + 17'd2048;
                        else
                            amp[v] <= (amp[v] <= 17'd16) ? 17'd0
                                                         : amp[v] - 17'd16;
                        if (v == NV-1) state <= S_MIX;
                        else begin v <= v + 3'd1; state <= S_VST; end
                    end

                    // ---- ronde klaar: outputs + evt. fill-werk ----
                    // (÷4; waarden zijn door de filter-clamps begrensd op ±16/stem,
                    //  dus de som/4 past ruim in 32 bit — slice is expliciet)
                    S_MIX: begin
                        mix_out    <= mix_sh[31:0];
                        string_out <= str_sh[31:0];
                        state      <= (fill_busy || fill_req != 8'd0) ? S_FILL : S_WAIT;
                    end

                    S_FILL: begin
                        if (fill_busy) begin
                            d_we    <= 1'b1;
                            d_waddr <= {fill_v, fill_idx};
                            d_wdata <= noise18;
                            if (fill_idx == 11'd2047) begin
                                fill_busy           <= 1'b0;
                                initialized[fill_v] <= 1'b1;
                            end else
                                fill_idx <= fill_idx + 11'd1;
                        end else if (fill_req != 8'd0) begin
                            // laagste stem met request eerst
                            fill_v                       <= lowest_bit(fill_req);
                            fill_req[lowest_bit(fill_req)] <= 1'b0;
                            fill_idx  <= 11'd0;
                            fill_busy <= 1'b1;
                        end else
                            state <= S_WAIT;
                    end

                    default: state <= S_WAIT;
                endcase
            end
        end
    end

endmodule
