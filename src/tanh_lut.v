// ============================================================================
// TANH_LUT — Hyperbolic Tangent Lookup Table in Block RAM
//
// 1024 entries × 32-bit Q12.20, geladen vanuit tanh_table.hex.
// Bedekt bp-bereik [-4.0, +4.0] → tanh(bp) [-0.999, +0.999].
//
// Gebruikt 2 Gowin BSRAM-blokken (elk 18 Kbit).
// 1-klok leeslatency: data_out verschijnt 1 cycle na addr.
// ============================================================================

`timescale 1ns / 1ps

module tanh_lut (
    input  wire         clk,
    input  wire [9:0]   addr,       // 0..1023
    output reg signed [31:0] data_out  // Q12.20 tanh(addr)
);

    (* ram_style = "block" *) reg signed [31:0] rom [0:1023];

    // Laad de tabel vanuit hex-bestand (werkt in DSim én Gowin EDA)
    initial begin
        $readmemh("tanh_table.hex", rom);
    end

    // Synchrone read (1-cycle latency, standaard voor BRAM)
    always @(posedge clk) begin
        data_out <= rom[addr];
    end

endmodule
