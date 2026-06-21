`timescale 1ns / 1ps

module mass_spring_resonator (
    input wire clk,
    input wire rst,
    input wire ce,
    input wire signed [31:0] f_in,     // Excitatie (Nu ingelezen als Q12.20)
    input wire signed [31:0] a1,       // Coëfficiënt 1 (Q12.20)
    input wire signed [31:0] a2,       // Coëfficiënt 2 (Q12.20)
    input wire signed [31:0] b0,       // Input gain (Q12.20)
    output wire signed [31:0] x_out    // Output (Q12.20)
);

    reg signed [31:0] x;
    reg signed [31:0] x_prev;

    assign x_out = x;

    reg signed [63:0] prod_a1;
    reg signed [63:0] prod_a2;
    reg signed [63:0] prod_b0;
    
    wire signed [31:0] next_x;

    always @(*) begin
        prod_a1 = ($signed(a1) * $signed(x));
        prod_a2 = ($signed(a2) * $signed(x_prev));
        prod_b0 = ($signed(b0) * $signed(f_in));
    end

    // VERANDERD: We tellen 0.5 op voor Q12.20 (een 1 op bitpositie 19)
    // En we shiften met [51:20] in plaats van [47:16]!
    wire signed [63:0] full_sum = prod_a1 + prod_a2 + prod_b0 + 64'h80000;
    assign next_x = full_sum[51:20];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 32'h0;
            x_prev <= 32'h0;
        end else if (ce) begin
            x_prev <= x;
            x <= next_x;
        end
    end

endmodule