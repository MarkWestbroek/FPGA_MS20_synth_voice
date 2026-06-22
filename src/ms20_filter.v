// ============================================================================
// MS20_FILTER — Korg MS-20 style State-Variable Filter (SVF)
//
// Chamberlin SVF met niet-lineaire diode-saturatie (tanh BRAM-LUT) in de
// resonantie-feedback, plus DRIVE en interne OVERSAMPLING. Dit geeft de
// karakteristieke MS-20 "scream" zonder dat de clipping-harmonieken terug-
// aliasen in het hoorbare spectrum.
//
// Per (oversample) sub-stap:
//   hp = in - lp - k * tanh(drive * bp)
//   bp = bp + g * hp
//   lp = lp + g * bp
//
// De filter draait intern op OVERSAMPLE * fs (bijv. 2x = 96 kHz): per audio-
// tick (ce) worden OVERSAMPLE sub-stappen uitgevoerd op dezelfde input
// (zero-order hold), en de sub-stap-outputs worden gemiddeld (eenvoudige
// decimatie) naar één output-sample.
//
// Omdat de tanh-LUT een geklokte BRAM-read is (1-cycle latency) en de filter
// veel sneller loopt dan de audio-rate, voeren we de SVF uit als een kleine
// FSM: per sub-stap eerst de LUT laten settelen, dan rekenen. Dit hergebruikt
// één multiplier-set en één LUT (zuinig met DSP/BSRAM, en klaar voor latere
// time-multiplexing over meerdere stemmen).
//
// Parameters / poorten (Q12.20 fixed-point):
//   g     = Chamberlin cutoff-coeff op de INTERNE rate: 2*sin(pi*fc/(OVERSAMPLE*fs))
//   k     = resonance amount (hoger = meer resonantie / self-oscillatie)
//   drive = tanh input-gain (1.0 = 0x00100000; hoger = eerder/harder satureren)
//   mode  = 0 = Low-Pass, 1 = High-Pass
// ============================================================================

`timescale 1ns / 1ps

module ms20_filter #(
    parameter integer OVERSAMPLE = 2          // 1 = uit, 2 = 2x (96kHz), 4 = 4x ...
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         ce,                   // audio sample-rate tick (48 kHz)

    // Audio I/O — Q12.20
    input  wire signed [31:0] audio_in,
    output reg  signed [31:0] audio_out,

    // Filter parameters — Q12.20
    input  wire signed [31:0] g,              // cutoff-coeff @ interne rate
    input  wire signed [31:0] k,              // resonance
    input  wire signed [31:0] drive,          // tanh drive (1.0 = 0x00100000)
    input  wire         mode                  // 0 = LP, 1 = HP
);

    localparam integer OS_SHIFT = $clog2(OVERSAMPLE);  // 0,1,2 voor 1x,2x,4x

    // ========================================================================
    // State registers — Q12.20
    // ========================================================================
    reg signed [31:0] lp;     // Low-pass integrator
    reg signed [31:0] bp;     // Band-pass integrator
    reg signed [31:0] in_held;// zero-order-hold input over de sub-stappen

    // ========================================================================
    // DRIVE: schaal bp vóór de tanh-LUT zodat de saturatie echt aanslaat
    //   bp_driven = drive * bp   (Q12.20 * Q12.20 -> >>>20)
    // ========================================================================
    wire signed [63:0] bp_drv_full = $signed(drive) * $signed(bp);
    wire signed [31:0] bp_driven   = bp_drv_full >>> 20;

    // ========================================================================
    // tanh BRAM-LUT — diode-saturatie. Adressering identiek aan gen_tables.py:
    //   domein [-4.0,+4.0], 1024 entries, addr = (x + 4.0) >>> 13, geclampt.
    // ========================================================================
    localparam signed [31:0] X_MAX =  32'sd4194304;   // +4.0 in Q12.20
    localparam signed [31:0] X_MIN = -32'sd4194304;   // -4.0 in Q12.20

    wire [9:0] lut_addr = (bp_driven >= X_MAX) ? 10'd1023 :   // >= : grens niet naar 0 laten wrappen
                          (bp_driven <  X_MIN) ? 10'd0    :
                          (bp_driven + X_MAX) >>> 13;

    wire signed [31:0] lut_tanh;   // tanh(drive*bp), 1 cycle latency

    tanh_lut u_tanh (
        .clk      (clk),
        .addr     (lut_addr),
        .data_out (lut_tanh)
    );

    // ========================================================================
    // Combinatorische SVF-stap (gebruikt de huidige lp/bp/lut_tanh/in_held)
    // ========================================================================
    // hp = in - lp - k * tanh(drive*bp)
    wire signed [63:0] prod_k        = $signed(k) * $signed(lut_tanh);
    wire signed [31:0] feedback      = prod_k >>> 20;
    wire signed [31:0] hp            = $signed(in_held) - $signed(lp) - $signed(feedback);

    // bp_next = bp + g*hp
    wire signed [63:0] prod_g_hp     = $signed(g) * $signed(hp);
    wire signed [31:0] bp_next       = $signed(bp) + $signed(prod_g_hp >>> 20);

    // lp_next = lp + g*bp_next
    wire signed [63:0] prod_g_bp     = $signed(g) * $signed(bp_next);
    wire signed [31:0] lp_next       = $signed(lp) + $signed(prod_g_bp >>> 20);

    // Geselecteerde output van deze sub-stap
    wire signed [31:0] sub_out       = (mode == 1'b1) ? hp : lp_next;

    // ========================================================================
    // FSM: per audio-tick OVERSAMPLE sub-stappen uitvoeren
    // ========================================================================
    localparam S_IDLE   = 2'd0;
    localparam S_SETTLE = 2'd1;  // 1 klok: laat tanh-LUT settelen voor huidige bp
    localparam S_COMPUTE= 2'd2;  // lut_tanh geldig -> reken & update integrators
    localparam S_DONE    = 2'd3; // decimatie -> output

    reg [1:0]  state;
    reg [3:0]  step;             // sub-stap teller (genoeg voor OVERSAMPLE<=16)
    reg signed [39:0] acc;       // som van sub-stap-outputs voor middeling

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lp        <= 32'sd0;
            bp        <= 32'sd0;
            in_held   <= 32'sd0;
            audio_out <= 32'sd0;
            state     <= S_IDLE;
            step      <= 4'd0;
            acc       <= 40'sd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (ce) begin
                        in_held <= audio_in;     // zero-order hold
                        acc     <= 40'sd0;
                        step    <= 4'd0;
                        state   <= S_SETTLE;
                    end
                end

                // Wacht 1 klok zodat lut_tanh = tanh(drive*bp_huidig) geldig is
                S_SETTLE: begin
                    state <= S_COMPUTE;
                end

                S_COMPUTE: begin
                    lp   <= lp_next;
                    bp   <= bp_next;
                    acc  <= acc + $signed(sub_out);
                    if (step + 4'd1 >= OVERSAMPLE[3:0]) begin
                        state <= S_DONE;
                    end else begin
                        step  <= step + 4'd1;
                        state <= S_SETTLE;        // bp veranderd -> opnieuw settelen
                    end
                end

                // Decimatie: gemiddelde van de OVERSAMPLE sub-stappen
                S_DONE: begin
                    audio_out <= acc >>> OS_SHIFT;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
