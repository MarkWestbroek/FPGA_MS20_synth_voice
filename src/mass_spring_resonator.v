`timescale 1ns / 1ps

module mass_spring_resonator (
    input wire clk,
    input wire rst,
    input wire ce,                    // <--- NIEUW: Clock Enable poort
    input wire signed [31:0] f_in,     // Externe excitatiekracht (Q16.16)
    input wire signed [31:0] a1,       // Coëfficiënt 1 (Q16.16)
    input wire signed [31:0] a2,       // Coëfficiënt 2 (Q16.16)
    input wire signed [31:0] b0,       // Input gain (Q16.16)
    output wire signed [31:0] x_out    // Huidige positie / audio out
);

    // Interne registers voor de delay-lines (geschiedenis)
    reg signed [31:0] x;
    reg signed [31:0] x_prev;

    // Output koppelen aan de huidige status
    assign x_out = x;

    // Tijdelijke 64-bit registers voor de fixed-point vermenigvuldigingen
    reg signed [63:0] prod_a1;
    reg signed [63:0] prod_a2;
    reg signed [63:0] prod_b0;
    
    wire signed [31:0] next_x;

    // Berekening van het mass-spring model: x[n] = a1*x[n-1] + a2*x[n-2] + b0*f_in[n]
    always @(*) begin
        prod_a1 = ($signed(a1) * $signed(x));
        prod_a2 = ($signed(a2) * $signed(x_prev));
        prod_b0 = ($signed(b0) * $signed(f_in));
    end

    // Schuif het resultaat terug van Q32.32 naar ons Q16.16 formaat
    assign next_x = (prod_a1[47:16]) + (prod_a2[47:16]) + (prod_b0[47:16]);

    // Synchroon blok met clock enable
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 32'h0;
            x_prev <= 32'h0;
        end else if (ce) begin        // <--- ALTHANS HIER: Bereken alleen bij audio-tick!
            x_prev <= x;
            x <= next_x;
        end
    end

endmodule