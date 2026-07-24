# ============================================================================
# arty_s7.xdc — pin-constraints Digilent Arty S7-50 (rev. E) voor synth_top_arty
#
# Pinnen uit het officiële Digilent master-XDC:
#   github.com/Digilent/digilent-xdc → Arty-S7-50-Master.xdc
# Let op: de 100 MHz-oscillator zit op R2 in de DDR3-bank → IOSTANDARD SSTL135
# (dat hoort zo op dit bord). SW3 (M5) zit óók in die bank en gebruiken we niet.
# ============================================================================

# ---- Configuratie-bank instellingen (vereist voor Arty S7) -----------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ---- Klok: 100 MHz onboard oscillator ---------------------------------------
set_property -dict { PACKAGE_PIN R2 IOSTANDARD SSTL135 } [get_ports clk100]
create_clock -name clk100 -period 10.000 -waveform {0 5.000} [get_ports clk100]

# ---- Knoppen (active-high) & switches ---------------------------------------
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}] ;# BTN0 = reset
set_property -dict { PACKAGE_PIN K16 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}] ;# BTN1 = wah-niveau
set_property -dict { PACKAGE_PIN H14 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]  ;# SW0 = demo_mode
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]  ;# SW1 = mute
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]  ;# SW2 = wah aan/uit

# ---- LED's -------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports {led[0]}] ;# synth-status
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports {led[1]}] ;# MMCM-lock

# ---- Pmod JA: PCM5102A DAC-breakout (GY-PCM5102, I2S) ------------------------
# Fysiek: JA pin 1..4 = bovenste rij; pin 5/11 = GND, pin 6/12 = 3V3.
# Module: VIN→3V3, GND→GND, SCK→JA4 (FPGA houdt hem laag → interne PLL).
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports ja_bck]   ;# JA1 → BCK
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports ja_lrck]  ;# JA2 → LCK
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports ja_din]   ;# JA3 → DIN
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports ja_sck]   ;# JA4 → SCK (laag)

# ---- Pmod JB: SPI-slave van de Cortex-brain (Teensy 4.1) ---------------------
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports jb_sclk]  ;# JB1 ← SCLK
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports jb_mosi]  ;# JB2 ← MOSI
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports jb_miso]  ;# JB3 → MISO
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports jb_cs_n]  ;# JB4 ← CS

# SPI-klok is asynchroon t.o.v. clk27 (2-FF-sync in spi_slave) — geen timing:
set_false_path -from [get_ports {jb_sclk jb_mosi jb_cs_n}]
set_false_path -to   [get_ports jb_miso]
