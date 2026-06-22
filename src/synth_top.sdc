// ============================================================================
// synth_top.sdc — Timing-constraints (Gowin SDC)
//
// Definieert de systeemklok zodat de timing-analyzer weet op welke frequentie
// hij moet rekenen. Lost op:  WARN (TA1132) 'sys_clk' ... not created.
//
// Tang Primer 20K onboard kristal = 27 MHz  ->  periode 1/27e6 = 37.037 ns.
// (Gebruik je de optionele PLL naar 50 MHz, zie doc/FLASHING.md, dan hier
//  i.p.v. dit een create_clock op de PLL-uitgang van 20 ns zetten.)
// ============================================================================

create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
