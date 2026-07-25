set_property SRC_FILE_INFO {cfile:E:/Dev/Gowin/MS20_synth_voice/boards/arty-s7/arty_s7.xdc rfile:../boards/arty-s7/arty_s7.xdc id:1} [current_design]
set_property src_info {type:XDC file:1 line:15 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN R2 IOSTANDARD SSTL135 } [get_ports clk100]
set_property src_info {type:XDC file:1 line:19 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}] ;# BTN0 = reset
set_property src_info {type:XDC file:1 line:20 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN K16 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}] ;# BTN1 = wah-niveau
set_property src_info {type:XDC file:1 line:21 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H14 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]  ;# SW0 = demo_mode
set_property src_info {type:XDC file:1 line:22 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]  ;# SW1 = mute
set_property src_info {type:XDC file:1 line:23 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]  ;# SW2 = wah aan/uit
set_property src_info {type:XDC file:1 line:26 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports {led[0]}] ;# synth-status
set_property src_info {type:XDC file:1 line:27 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports {led[1]}] ;# MMCM-lock
set_property src_info {type:XDC file:1 line:32 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports ja_bck]   ;# JA1 → BCK
set_property src_info {type:XDC file:1 line:33 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports ja_lrck]  ;# JA2 → LCK
set_property src_info {type:XDC file:1 line:34 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports ja_din]   ;# JA3 → DIN
set_property src_info {type:XDC file:1 line:35 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports ja_sck]   ;# JA4 → SCK (laag)
set_property src_info {type:XDC file:1 line:38 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN P17 IOSTANDARD LVCMOS33 } [get_ports jb_sclk]  ;# JB1 ← SCLK
set_property src_info {type:XDC file:1 line:39 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports jb_mosi]  ;# JB2 ← MOSI
set_property src_info {type:XDC file:1 line:40 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports jb_miso]  ;# JB3 → MISO
set_property src_info {type:XDC file:1 line:41 export:INPUT save:INPUT read:READ} [current_design]
set_property -dict { PACKAGE_PIN T18 IOSTANDARD LVCMOS33 } [get_ports jb_cs_n]  ;# JB4 ← CS
