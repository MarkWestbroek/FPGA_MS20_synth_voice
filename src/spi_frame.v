// ============================================================================
// SPI_FRAME — MusicBrain SPI-frame decoder (v1) bovenop spi_slave
//
// Decodeert het MusicBrain wire-format (zie MusicBrain doc/protocols/spi-frame.md):
//
//   [MAGIC=0xA5][VERSION=0x01][OPCODE][LEN][PAYLOAD 0..56][CRC16_hi][CRC16_lo]
//
// CRC = CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, geen reflectie/xorout) over
// [MAGIC .. einde PAYLOAD], big-endian verzonden. Slechte CRC → frame stil drop.
//
// De FPGA is een SPI-slave "instrument": de chip-select selecteert dit board, dus
// we kijken alleen naar het lage byte van `channel` (= slotId) om te bepalen welk
// voice-parameter een CvSet/GateSet aanstuurt.
//
// Ondersteunde opcodes (instrument-subset):
//   0x00 Ping     → pong_req puls (MISO-antwoord later)
//   0x10 CvSet    payload: u16 channel, i16 value
//                   slot 0 → pitch_cv   slot 1 → cutoff_cv
//                   slot 2 → reson_cv   slot 3 → drive_cv
//   0x20 GateSet  payload: u16 channel, u8 on   → gate (+ trigger-puls bij 0→1)
//
// De ruwe i16-CV-waarden komen hier uit; synth_top mapt ze naar Q12.20 filter-
// parameters / KS-period (integratie-stap).
// ============================================================================

`timescale 1ns / 1ps

module spi_frame (
    input  wire        clk,
    input  wire        rst,

    // van spi_slave (clk-domein)
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,
    input  wire        cs_active,

    // gedecodeerde CV/gate (i16, −32768..32767 = −1.0..+1.0)
    output reg signed [15:0] pitch_cv,
    output reg signed [15:0] cutoff_cv,
    output reg signed [15:0] reson_cv,
    output reg signed [15:0] drive_cv,
    output reg               gate,
    output reg               trigger,      // 1-klok puls bij gate 0→1
    output reg               pong_req,     // 1-klok puls bij Ping
    output reg               frame_ok      // 1-klok puls bij geldig (CRC-correct) frame
);

    // ----- Opcodes -----
    localparam [7:0] OP_PING   = 8'h00;
    localparam [7:0] OP_CVSET  = 8'h10;
    localparam [7:0] OP_GATESET= 8'h20;

    localparam [7:0] MAGIC = 8'hA5;

    // ----- CRC-16/CCITT-FALSE byte-update -----
    function [15:0] crc16_upd(input [15:0] crc_in, input [7:0] data);
        integer i;
        reg [15:0] c;
        begin
            c = crc_in ^ {data, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc16_upd = c;
        end
    endfunction

    // ----- FSM -----
    localparam S_MAGIC   = 3'd0;
    localparam S_VERSION = 3'd1;
    localparam S_OPCODE  = 3'd2;
    localparam S_LEN     = 3'd3;
    localparam S_PAYLOAD = 3'd4;
    localparam S_CRC_HI  = 3'd5;
    localparam S_CRC_LO  = 3'd6;

    reg [2:0]  state;
    reg [15:0] crc;            // lopende CRC over MAGIC..PAYLOAD
    reg [7:0]  opcode;
    reg [7:0]  len;
    reg [7:0]  pidx;           // payload-index
    reg [7:0]  crc_hi;
    reg [7:0]  payload [0:7];  // instrument-opcodes hebben kleine payloads (≤4)

    // payload-helpers
    wire [15:0] ch     = {payload[0], payload[1]};
    wire [7:0]  slot   = payload[1];                // laag byte = slotId
    wire signed [15:0] val = {payload[2], payload[3]};

    integer j;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_MAGIC;
            crc       <= 16'hFFFF;
            opcode    <= 8'd0;
            len       <= 8'd0;
            pidx      <= 8'd0;
            crc_hi    <= 8'd0;
            pitch_cv  <= 16'sd0;
            cutoff_cv <= 16'sd0;
            reson_cv  <= 16'sd0;
            drive_cv  <= 16'sd0;
            gate      <= 1'b0;
            trigger   <= 1'b0;
            pong_req  <= 1'b0;
            frame_ok  <= 1'b0;
            for (j = 0; j < 8; j = j + 1) payload[j] <= 8'd0;
        end else begin
            // 1-klok pulsen default laag
            trigger  <= 1'b0;
            pong_req <= 1'b0;
            frame_ok <= 1'b0;

            if (!cs_active) begin
                state <= S_MAGIC;          // frame-grens: parser resetten
            end else if (rx_valid) begin
                case (state)
                    S_MAGIC: begin
                        if (rx_byte == MAGIC) begin
                            crc   <= crc16_upd(16'hFFFF, MAGIC);
                            state <= S_VERSION;
                        end
                        // anders: blijf zoeken naar MAGIC
                    end

                    S_VERSION: begin
                        crc   <= crc16_upd(crc, rx_byte);
                        state <= S_OPCODE;     // versie genegeerd (alleen v1 nu)
                    end

                    S_OPCODE: begin
                        opcode <= rx_byte;
                        crc    <= crc16_upd(crc, rx_byte);
                        state  <= S_LEN;
                    end

                    S_LEN: begin
                        len   <= rx_byte;
                        crc   <= crc16_upd(crc, rx_byte);
                        pidx  <= 8'd0;
                        state <= (rx_byte == 8'd0) ? S_CRC_HI : S_PAYLOAD;
                    end

                    S_PAYLOAD: begin
                        if (pidx < 8) payload[pidx[2:0]] <= rx_byte;
                        crc <= crc16_upd(crc, rx_byte);
                        if (pidx + 8'd1 >= len) state <= S_CRC_HI;
                        pidx <= pidx + 8'd1;
                    end

                    S_CRC_HI: begin
                        crc_hi <= rx_byte;         // CRC zelf NIET in crc opnemen
                        state  <= S_CRC_LO;
                    end

                    S_CRC_LO: begin
                        state <= S_MAGIC;
                        if ({crc_hi, rx_byte} == crc) begin
                            frame_ok <= 1'b1;
                            // ----- dispatch -----
                            case (opcode)
                                OP_PING: pong_req <= 1'b1;

                                OP_CVSET: begin
                                    case (slot)
                                        8'd0: pitch_cv  <= val;
                                        8'd1: cutoff_cv <= val;
                                        8'd2: reson_cv  <= val;
                                        8'd3: drive_cv  <= val;
                                        default: ;
                                    endcase
                                end

                                OP_GATESET: begin
                                    // payload[2] = on
                                    if (payload[2][0] && !gate) trigger <= 1'b1;
                                    gate <= payload[2][0];
                                end

                                default: ;   // onbekende opcode: negeren
                            endcase
                        end
                        // bij CRC-mismatch: stil droppen (geen output)
                    end

                    default: state <= S_MAGIC;
                endcase
            end
        end
    end

endmodule
