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
// Ondersteunde opcodes (instrument-subset, 8 stemmen):
//   0x00 Ping     → pong_req puls (Pong-antwoord op MISO)
//   0x10 CvSet    payload: u16 channel, u16 value (dCV, offset-binary)
//                   slotId = voice*4 + param  (voices 0..7 → slots 0..31)
//                   param: 0=pitch, 1=cutoff, 2=reson, 3=drive
//                   (stem 0 = slots 0..3: backwards-compatible met mono)
//   0x20 GateSet  payload: u16 channel, u8 on
//                   slotId = voice (0..7) → gate[v] (+ trigger[v]-puls bij 0→1)
//
// CV-waarden komen er als schrijf-poort uit (cv_we/voice/param/val); synth_top
// houdt de per-stem arrays bij en mapt naar Q12.20 / KS-period.
// ============================================================================

`timescale 1ns / 1ps

module spi_frame (
    input  wire        clk,
    input  wire        rst,

    // van spi_slave (clk-domein)
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,
    input  wire        cs_active,

    // CV-schrijfpoort — dCV: u16 offset-binary, 0x0000 = range-min,
    // 0xFFFF = range-max (zie doc/PITCH_CV.md / MusicBrain ADR 0014)
    output reg        cv_we,        // 1-klok puls: cv_voice/cv_param/cv_val geldig
    output reg [2:0]  cv_voice,     // stem 0..7
    output reg [1:0]  cv_param,     // 0=pitch, 1=cutoff, 2=reson, 3=drive
    output reg [15:0] cv_val,
    output reg [7:0]  gate,         // gate-niveau per stem
    output reg [7:0]  trigger,      // 1-klok puls per stem bij gate 0→1
    output reg        pong_req,     // 1-klok puls bij Ping
    output reg        frame_ok,     // 1-klok puls bij geldig (CRC-correct) frame

    // MISO-zendpad naar spi_slave: na een Ping wordt het Pong-frame uitgeschoven
    output wire [7:0]        tx_byte,
    input  wire              tx_load       // spi_slave laadde net een byte → idx++
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

    // ----- Pong-respons (MISO) -----
    // Pong-frame = A5 01 01 00 D6 F2  (D6F2 = CRC-16/CCITT over A5 01 01 00)
    reg        pong_pending;
    reg [2:0]  tx_idx;
    function [7:0] pong_byte(input [2:0] i);
        case (i)
            3'd0: pong_byte = 8'hA5;
            3'd1: pong_byte = 8'h01;
            3'd2: pong_byte = 8'h01;
            3'd3: pong_byte = 8'h00;
            3'd4: pong_byte = 8'hD6;
            default: pong_byte = 8'hF2;   // i = 5
        endcase
    endfunction
    assign tx_byte = pong_pending ? pong_byte(tx_idx) : 8'h00;

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
    wire [15:0] val    = {payload[2], payload[3]};  // dCV, big-endian

    integer j;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= S_MAGIC;
            crc       <= 16'hFFFF;
            opcode    <= 8'd0;
            len       <= 8'd0;
            pidx      <= 8'd0;
            crc_hi    <= 8'd0;
            cv_we     <= 1'b0;
            cv_voice  <= 3'd0;
            cv_param  <= 2'd0;
            cv_val    <= 16'd0;
            gate      <= 8'd0;
            trigger   <= 8'd0;
            pong_req  <= 1'b0;
            frame_ok  <= 1'b0;
            pong_pending <= 1'b0;
            tx_idx       <= 3'd0;
            for (j = 0; j < 8; j = j + 1) payload[j] <= 8'd0;
        end else begin
            // 1-klok pulsen default laag
            cv_we    <= 1'b0;
            trigger  <= 8'd0;
            pong_req <= 1'b0;
            frame_ok <= 1'b0;

            // Pong-byte-index ophogen wanneer spi_slave een byte laadde
            if (tx_load && pong_pending) begin
                if (tx_idx == 3'd5) begin
                    pong_pending <= 1'b0;     // hele Pong-frame uitgeschoven
                    tx_idx       <= 3'd0;
                end else begin
                    tx_idx <= tx_idx + 3'd1;
                end
            end

            if (!cs_active) begin
                state  <= S_MAGIC;         // frame-grens: parser resetten
                tx_idx <= 3'd0;            // Pong-respons begint volgende frame bij byte 0
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
                                OP_PING: begin
                                    pong_req     <= 1'b1;
                                    pong_pending <= 1'b1;   // queue Pong op MISO
                                    tx_idx       <= 3'd0;
                                end

                                OP_CVSET: begin
                                    // slot = voice*4 + param; alleen slots 0..31
                                    if (slot < 8'd32) begin
                                        cv_we    <= 1'b1;
                                        cv_voice <= slot[4:2];
                                        cv_param <= slot[1:0];
                                        cv_val   <= val;
                                    end
                                end

                                OP_GATESET: begin
                                    // slot = voice (0..7); payload[2] = on
                                    if (slot < 8'd8) begin
                                        if (payload[2][0] && !gate[slot[2:0]])
                                            trigger[slot[2:0]] <= 1'b1;
                                        gate[slot[2:0]] <= payload[2][0];
                                    end
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
