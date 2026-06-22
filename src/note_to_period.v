// ============================================================================
// NOTE_TO_PERIOD — MIDI-note → Karplus-Strong delay-lengte (period) ROM
//
// 128 entries (noot 0..127) → 11-bit period (= fs/freq, geclampt op de delay-
// lijn). Tabel voorberekend door gen_tables.py → note_period.hex.
// Geklokte BRAM-read (1-cycle latency), net als tanh_lut.
// ============================================================================

`timescale 1ns / 1ps

module note_to_period (
    input  wire        clk,
    input  wire [6:0]  note,        // 0..127
    output reg  [10:0] period       // KS delay-lengte
);

    // 12-bit breed zodat de 3-nibble hex-entries exact passen (waarden ≤ 0x7FF);
    // we nemen de onderste 11 bits als period.
    (* ram_style = "block" *) reg [11:0] rom [0:127];

    initial begin
        $readmemh("note_period.hex", rom);
    end

    always @(posedge clk) begin
        period <= rom[note][10:0];
    end

endmodule
