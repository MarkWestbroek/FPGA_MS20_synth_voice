// ============================================================================
// SPI_CONTROL — pakket-decoder bovenop spi_slave
//
// Zet binnenkomende bytes om in synth-parameters. Eén pakket = 4 bytes:
//
//   [cmd] [voice] [param_hi] [param_lo]
//
// param16 = {param_hi, param_lo}. De byte-index reset wanneer CS deassert
// (elk CS-frame = één pakket), zodat we altijd uitgelijnd blijven.
//
// Commando's (param-mapping naar Q12.20 gedocumenteerd; muzikale schaling kan
// later verfijnd worden — voor nu vaste, geteste shifts):
//   0x90 NOTE_ON   note_period = param16[10:0] ; trigger-puls
//   0x80 NOTE_OFF  gate <= 0            (KS dempt vanzelf uit)
//   0xB0 CUTOFF    cf_g     = param16 << 2     (g, 0..~0.25)
//   0xB1 RESON     cf_k     = param16 << 7     (k = demping, 0..~8; LAGER=meer reso)
//   0xB2 DRIVE     cf_drive = param16 << 8     (0..~16.0)
//   0xB3 MODE      mode     = param16[0]       (0=LP, 1=HP)
//
// trigger is een 1-klok puls in clk-domein; synth_top moet die vasthouden tot
// de volgende audio-tick (ce) — zie integratie-notitie in ROADMAP.
// ============================================================================

`timescale 1ns / 1ps

module spi_control (
    input  wire        clk,
    input  wire        rst,

    // van spi_slave
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,
    input  wire        cs_active,

    // gedecodeerde parameters
    output reg [10:0]  note_period,
    output reg         trigger,       // 1-klok puls bij NOTE_ON
    output reg         gate,
    output reg signed [31:0] cf_g,
    output reg signed [31:0] cf_k,
    output reg signed [31:0] cf_drive,
    output reg         mode
);

    // Commando-codes
    localparam [7:0] CMD_NOTE_ON  = 8'h90;
    localparam [7:0] CMD_NOTE_OFF = 8'h80;
    localparam [7:0] CMD_CUTOFF   = 8'hB0;
    localparam [7:0] CMD_RESON    = 8'hB1;
    localparam [7:0] CMD_DRIVE    = 8'hB2;
    localparam [7:0] CMD_MODE     = 8'hB3;

    reg [1:0] idx;            // byte-index binnen pakket (0..3)
    reg [7:0] b_cmd;
    reg [7:0] b_hi;          // param_hi vastgehouden tot param_lo binnen is
    // b_voice negeren we nu (mono); klaar voor multi-voice later.

    wire [15:0] param16 = {b_hi, rx_byte};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            idx         <= 2'd0;
            b_cmd       <= 8'd0;
            b_hi        <= 8'd0;
            trigger     <= 1'b0;
            gate        <= 1'b0;
            note_period <= 11'd654;             // D2 default
            cf_g        <= 32'h000191F6;        // ~1500 Hz @96k
            cf_k        <= 32'h00040000;        // ~0.25 (hoge resonantie)
            cf_drive    <= 32'h00400000;        // 4.0
            mode        <= 1'b0;                // LP
        end else begin
            trigger <= 1'b0;                    // default geen puls

            if (!cs_active) begin
                idx <= 2'd0;                    // frame-einde: opnieuw uitlijnen
            end else if (rx_valid) begin
                case (idx)
                    2'd0: b_cmd <= rx_byte;
                    2'd1: ;                      // voice-byte (genegeerd, mono)
                    2'd2: b_hi  <= rx_byte;
                    2'd3: begin                  // param_lo -> pakket compleet
                        case (b_cmd)
                            CMD_NOTE_ON: begin
                                note_period <= param16[10:0];
                                gate        <= 1'b1;
                                trigger     <= 1'b1;
                            end
                            CMD_NOTE_OFF: gate     <= 1'b0;
                            CMD_CUTOFF:   cf_g     <= param16 << 2;
                            CMD_RESON:    cf_k     <= param16 << 7;
                            CMD_DRIVE:    cf_drive <= param16 << 8;
                            CMD_MODE:     mode     <= param16[0];
                            default: ;           // onbekend commando: negeren
                        endcase
                    end
                endcase
                idx <= idx + 2'd1;
            end
        end
    end

endmodule
