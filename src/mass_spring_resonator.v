`timescale 1ns / 1ps
module mass_spring_resonator (
    input wire clk,                  // De oversampled klok (bijv. 12 MHz)
    input wire rst,                  // Reset-signaal
    input wire signed [31:0] f_in,   // Externe kracht / Exciter puls (Q16.16)
    input wire signed [31:0] a1,     // Filtercoëfficiënt a1 (Q16.16)
    input wire signed [31:0] a2,     // Filtercoëfficiënt a2 (Q16.16)
    input wire signed [31:0] b0,     // Filtercoëfficiënt b0 (Q16.16)
    output reg signed [31:0] x_out   // Positie van het deeltje / Audio-uit (Q16.16)
);

    // Registers voor de geschiedenis (toestanden: x[n-1] en x[n-2])
    reg signed [31:0] x_z1;
    reg signed [31:0] x_z2;

    // Tussenproducten van de vermenigvuldigingen (64-bit signed vanwege Q16.16 * Q16.16)
    wire signed [63:0] p1 = a1 * x_z1;
    wire signed [63:0] p2 = a2 * x_z2;
    wire signed [63:0] p3 = b0 * f_in;

    // Schalen naar Q16.16 (pak bits 47 t/m 16) en tel ze bij elkaar op
    wire signed [31:0] x_next = p1[47:16] + p2[47:16] + p3[47:16];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_out <= 32'h0;
            x_z1  <= 32'h0;
            x_z2  <= 32'h0;
        end else begin
            x_out <= x_next;
            x_z1  <= x_next; // Schuif het verleden door
            x_z2  <= x_z1;
        end
    end

endmodule