// ============================================================================
// SPI_SLAVE — SPI mode 0 (CPOL=0, CPHA=0), MSB-first, byte-ontvanger
//
// De FPGA is slave op de Eurorack-brain SPI-bus (Teensy = master). Dit blok
// vangt bytes op en levert ze in het sys_clk-domein af. SCLK/MOSI/CS_N worden
// gesynchroniseerd (2-FF) naar sys_clk en SCLK-flanken worden gedetecteerd —
// zo is er geen aparte SCLK-klokdomein nodig (eenvoudig en timing-veilig zolang
// SCLK << sys_clk; bijv. SCLK ≤ ~10 MHz bij 50 MHz sys_clk).
//
// Mode 0: MOSI is geldig rond de stijgende SCLK-flank; sample op stijgende flank.
// CS_N actief-laag omkadert een frame; bij CS_N hoog reset de bit-teller.
// ============================================================================

`timescale 1ns / 1ps

module spi_slave (
    input  wire       clk,        // sys_clk (bijv. 50 MHz)
    input  wire       rst,        // active-high

    // SPI-pinnen (asynchroon t.o.v. clk)
    input  wire       sclk,
    input  wire       mosi,
    output reg        miso,       // slave → master (data out)
    input  wire       cs_n,

    // Ontvangen byte (clk-domein)
    output reg [7:0]  rx_byte,
    output reg        rx_valid,   // 1-klok puls wanneer rx_byte geldig is
    output reg        cs_active,  // gesynchroniseerd ~cs_n (frame bezig)

    // Zend-pad (MISO): de bovenlaag biedt tx_byte aan; tx_load pulst telkens
    // wanneer een nieuwe byte in de shifter wordt geladen (frame-start + elke
    // byte-grens) zodat de bovenlaag z'n byte-index kan ophogen.
    input  wire [7:0] tx_byte,
    output reg        tx_load
);

    // ----- Synchronisatie naar clk-domein -----
    reg [2:0] sclk_s;
    reg [1:0] mosi_s;
    reg [1:0] cs_s;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sclk_s <= 3'b000;
            mosi_s <= 2'b00;
            cs_s   <= 2'b11;     // idle = CS hoog
        end else begin
            sclk_s <= {sclk_s[1:0], sclk};
            mosi_s <= {mosi_s[0],  mosi};
            cs_s   <= {cs_s[0],    cs_n};
        end
    end

    wire sclk_rise = (sclk_s[2:1] == 2'b01);
    wire sclk_fall = (sclk_s[2:1] == 2'b10);
    wire cs_n_sync = cs_s[1];

    // CS-assert detectie (hoog → laag) voor het laden van de eerste TX-byte
    reg  cs_n_d;
    always @(posedge clk or posedge rst)
        if (rst) cs_n_d <= 1'b1;
        else     cs_n_d <= cs_n_sync;
    wire cs_assert = cs_n_d & ~cs_n_sync;

    // ----- Bit-shift / byte-assemblage -----
    reg [7:0] shreg;
    reg [2:0] bitcnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            shreg     <= 8'd0;
            bitcnt    <= 3'd0;
            rx_byte   <= 8'd0;
            rx_valid  <= 1'b0;
            cs_active <= 1'b0;
        end else begin
            rx_valid  <= 1'b0;            // default: geen puls
            cs_active <= ~cs_n_sync;

            if (cs_n_sync) begin
                bitcnt <= 3'd0;          // frame inactief: opnieuw uitlijnen
            end else if (sclk_rise) begin
                shreg <= {shreg[6:0], mosi_s[1]};
                if (bitcnt == 3'd7) begin
                    bitcnt   <= 3'd0;
                    rx_byte  <= {shreg[6:0], mosi_s[1]};
                    rx_valid <= 1'b1;
                end else begin
                    bitcnt <= bitcnt + 3'd1;
                end
            end
        end
    end

    // ----- MISO zend-pad (mode 0: MSB op CS-assert / op dalende flank) -----
    reg [7:0] tx_sh;
    reg [2:0] tx_bit;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_sh   <= 8'd0;
            tx_bit  <= 3'd0;
            miso    <= 1'b0;
            tx_load <= 1'b0;
        end else begin
            tx_load <= 1'b0;
            if (cs_assert) begin
                tx_sh   <= tx_byte;       // laad eerste byte vóór de eerste flank
                tx_bit  <= 3'd0;
                tx_load <= 1'b1;          // bovenlaag: ga naar volgende byte
            end else if (!cs_n_sync && sclk_fall) begin
                if (tx_bit == 3'd7) begin
                    tx_sh   <= tx_byte;   // byte-grens: laad volgende byte
                    tx_bit  <= 3'd0;
                    tx_load <= 1'b1;
                end else begin
                    tx_sh  <= {tx_sh[6:0], 1'b0};
                    tx_bit <= tx_bit + 3'd1;
                end
            end
            miso <= tx_sh[7];             // MSB-first
        end
    end

endmodule
