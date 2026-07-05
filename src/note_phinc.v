// ============================================================================
// NOTE_PHINC — MIDI-note → wavetable fase-increment ROM
//
// 128 entries (noot 0..127) → 32-bit increment (= f0 · 2^32 / 48000).
// Tabel voorberekend door gen_tables.py → note_phinc.hex.
// Geklokte BRAM-read (1-cycle latency), net als note_to_period.
// ============================================================================

`timescale 1ns / 1ps

module note_phinc (
    input  wire        clk,
    input  wire [6:0]  note,        // 0..127
    output reg  [31:0] phinc        // fase-increment per sample
);

    (* ram_style = "block" *) reg [31:0] rom [0:127];

    initial begin
        $readmemh("note_phinc.hex", rom);
    end

    always @(posedge clk) begin
        phinc <= rom[note];
    end

endmodule
