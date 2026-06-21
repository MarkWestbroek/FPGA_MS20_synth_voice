`timescale 1ns / 1ps

module synth_top (
    input wire sys_clk,      // De vaste klok (50MHz in testbench, 27MHz op board)
    input wire sys_rst_n,    // De ingebouwde resetknop (active low)
    output reg led           // Status LED
);

    // Invert de active-low reset naar active-high voor onze modules
    wire rst = !sys_rst_n;

    // --- TEST SIGNAAL GENERATOR (EXCITER) VOOR SIMULATIE ---
    reg [7:0] pulse_counter;
    reg signed [31:0] f_in;

    always @(posedge sys_clk or posedge rst) begin
        if (rst) begin
            pulse_counter <= 0;
            f_in <= 32'h0;
        end else begin
            if (pulse_counter < 8'hFF) begin
                pulse_counter <= pulse_counter + 1;
            end
            
            // Geef direct een harde tik op tellerstand 10
            if (pulse_counter == 8'd10) begin
                f_in <= 32'h00010000; // Waarde 1.0 in Q16.16
            end else begin
                f_in <= 32'h0;
            end
        end
    end

    // --- COËFFICIËNTEN (Vaste testwaarden in Q16.16) ---
    // Oorspronkelijke tuning (voor referentie, niet gebruikt in deze code)
    /*
    wire signed [31:0] a1 = 32'h0001F6A0; // ~1.963
    wire signed [31:0] a2 = 32'hFFFF0200; // ~-0.992
    wire signed [31:0] b0 = 32'h00000100; 
    */

    // --- COËFFICIËNTEN (Nieuwe tuning: Lagere toon + Lange Sustain in Q16.16) ---
    wire signed [31:0] a1 = 32'h0001FF80; // ~1.998 (Hele lage, diepe basfrequentie)
    wire signed [31:0] a2 = 32'hFFFF0020; // ~-0.9995 (Extreem weinig demping = lange sustain!)
    wire signed [31:0] b0 = 32'h00000100;

    wire signed [31:0] audio_signal;

    // --- INSTANTIATIE VAN JE RESONATOR ---
    mass_spring_resonator u_resonator (
        .clk(sys_clk),
        .rst(rst),
        .f_in(f_in),
        .a1(a1),
        .a2(a2),
        .b0(b0),
        .x_out(audio_signal)
    );

    // Koppel de LED aan het hoogste bit
    always @(posedge sys_clk) begin
        led <= audio_signal[31];
    end

endmodule