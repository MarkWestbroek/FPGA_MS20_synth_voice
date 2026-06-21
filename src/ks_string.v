// ============================================================================
// KS_STRING — Karplus-Strong Plucked String Physical Model
//
// Klassiek physical modeling algoritme voor getokkelde snaren:
//   1. Vul een delay line met ruis (de "aanslag")
//   2. Lees, filter (2-punts moving average), en schrijf terug
//   3. De delay-lengte bepaalt de toonhoogte, de demping de sustain
//
// Parameters in Q12.20 fixed-point.
//
// Toonhoogte: period = fs / f0
//   E1 (41.2 Hz): period = 1165
//   A1 (55.0 Hz): period = 873
//   D2 (73.4 Hz): period = 654
//   G2 (98.0 Hz): period = 490
// ============================================================================

`timescale 1ns / 1ps

module ks_string #(
    parameter MAX_DELAY = 2048   // Groot genoeg voor lage bass-noten
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         ce,              // Audio sample rate clock enable

    input  wire         trigger,         // Rising edge = aanslag!
    input  wire [10:0]  period,          // Delay-lijn lengte (48..2047)
    input  wire signed [31:0] damping,   // Q12.20: dempingsfactor (~0.999)

    output reg signed [31:0] audio_out   // Q12.20
);

    // ========================================================================
    // State machine
    // ========================================================================
    localparam S_IDLE    = 3'd0;
    localparam S_FILL    = 3'd1;  // Delay-lijn vullen met ruis
    localparam S_READ1   = 3'd2;  // Lees sample N
    localparam S_READ2   = 3'd3;  // Lees sample N+1 (voor averaging)
    localparam S_COMPUTE = 3'd4;  // Filter + terugschrijven

    reg [2:0] state;

    // ========================================================================
    // Delay line (wordt door Gowin synthesis in BRAM geplaatst)
    // ========================================================================
    (* ram_style = "block" *) reg signed [31:0] delay_line [0:MAX_DELAY-1];

    reg        initialized;  // 1 na eerste FILL (delay-lijn bevat data)
    reg [10:0] ptr;          // Huidige lees/schrijf positie
    reg [10:0] fill_cnt;     // Teller tijdens FILL-fase
    reg signed [31:0] s0;    // Gelezen sample N
    reg signed [31:0] s1;    // Gelezen sample N+1

    // ========================================================================
    // LFSR ruisgenerator (23-bit maximal-length)
    // ========================================================================
    reg  [22:0] lfsr;
    wire        lfsr_fb = lfsr[22] ^ lfsr[17];

    always @(posedge clk or posedge rst) begin
        if (rst)
            lfsr <= 23'h7FFFFF;
        else
            lfsr <= {lfsr[21:0], lfsr_fb};
    end

    // Ruis-sample: Q12.20, bereik ±1.0
    wire signed [31:0] noise_sample = {{11{lfsr[20]}}, lfsr[20:0]};

    // Volgende pointer (circulair)
    wire [10:0] next_ptr = (ptr >= period - 1) ? 11'd0 : ptr + 1;

    // ========================================================================
    // Combinatorische compute-logica (voor S_COMPUTE state)
    // ========================================================================
    wire signed [32:0] comp_sum    = $signed(s0) + $signed(s1);
    wire signed [31:0] comp_avg    = comp_sum >>> 1;
    wire signed [63:0] comp_damped = $signed(comp_avg) * $signed(damping);
    wire signed [31:0] comp_new    = comp_damped[51:20];

    // ========================================================================
    // Hoofd-FSM
    // ========================================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            initialized <= 0;
            ptr         <= 0;
            fill_cnt    <= 0;
            audio_out   <= 0;
            s0          <= 0;
            s1          <= 0;
        end else begin
            case (state)

                // ------------------------------------------------------------
                // IDLE: wacht op audio-tick
                // ------------------------------------------------------------
                S_IDLE: begin
                    if (ce && trigger) begin
                        // Nieuwe aanslag: vul delay-lijn met ruis
                        state    <= S_FILL;
                        fill_cnt <= 0;
                    end else if (ce && initialized) begin
                        // Normale KS-cyclus: lees oudste sample (alleen na init!)
                        state <= S_READ1;
                    end
                end

                // ------------------------------------------------------------
                // FILL: Vul de hele delay-lijn met LFSR-ruis
                // ------------------------------------------------------------
                S_FILL: begin
                    delay_line[fill_cnt] <= noise_sample;
                    if (fill_cnt >= period - 1) begin
                        state       <= S_IDLE;
                        initialized <= 1;
                        ptr         <= 0;
                    end else begin
                        fill_cnt <= fill_cnt + 1;
                    end
                end

                // ------------------------------------------------------------
                // READ1: Lees sample op positie ptr (oudste)
                // ------------------------------------------------------------
                S_READ1: begin
                    s0    <= delay_line[ptr];
                    state <= S_READ2;
                end

                // ------------------------------------------------------------
                // READ2: Lees sample op positie ptr+1 (een-na-oudste)
                // ------------------------------------------------------------
                S_READ2: begin
                    s1    <= delay_line[next_ptr];
                    state <= S_COMPUTE;
                end

                // ------------------------------------------------------------
                // COMPUTE: Moving-average filter + decay + terugschrijven
                //   y[n] = damping * 0.5 * (x[n] + x[n+1])
                // ------------------------------------------------------------
                S_COMPUTE: begin
                    // Gebruik de module-level compute wires
                    delay_line[ptr] <= comp_new;
                    audio_out       <= comp_new;
                    ptr             <= next_ptr;
                    state           <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

endmodule
