# Arty S7-50 poort — bring-up (Fase A)

Zie [doc/ARTY_S7_PLAN.md](../../doc/ARTY_S7_PLAN.md) voor het volledige plan.
Deze map bevat alleen bord-specifieke bestanden; alle RTL blijft in `src/`.

| Bestand | Doel |
|---|---|
| `synth_top_arty.v` | wrapper: MMCM 100→27 MHz, knop/switch-mapping, Pmods |
| `arty_s7.xdc` | pin-constraints (uit het officiële Digilent master-XDC) |
| `build.tcl` | `vivado -mode batch -source build.tcl` → bitstream + rapporten |
| `program.tcl` | flasht de bitstream via de onboard USB-JTAG |

## Eenmalig: software

1. **AMD Vivado ML Standard** (gratis): unified installer van amd.com →
   kies "Vivado ML Standard", vink bij devices alléén **Spartan-7** aan
   (scheelt tientallen GB's; reken alsnog op ~30 GB schijf).
2. Verder niets: geen Digilent-software nodig — de Arty programmeer je via
   Vivado's Hardware Manager over de micro-USB-poort (FTDI zit op het bord).
   Zorg wel voor een micro-USB-**data**kabel.

## Bedrading

**Pmod JA — PCM5102A-breakout (GY-PCM5102)** (bovenste rij; GND=pin 5, 3V3=pin 6):

| JA-pin | Signaal | PCM5102-module |
|---|---|---|
| 1 | `ja_bck` | BCK |
| 2 | `ja_lrck` | LCK |
| 3 | `ja_din` | DIN |
| 4 | `ja_sck` | SCK (FPGA houdt laag → interne PLL) |
| 5 | GND | GND |
| 6 | 3V3 | VIN |

⚠️ **Soldeer-jumpers op de achterkant** (deze modules komen vaak onbebrugd,
dan blijft hij stil): **1→L** (FLT normal), **2→L** (DEMP uit),
**3→H** (XSMT = un-mute — de belangrijkste!), **4→L** (FMT = I2S).

**Pmod JB — SPI vanaf Cortex/Teensy 4.1** (GND doorverbinden!):

| JB-pin | Signaal | Teensy |
|---|---|---|
| 1 | `jb_sclk` | SCK (13) |
| 2 | `jb_mosi` | MOSI (11) |
| 3 | `jb_miso` | MISO (12) |
| 4 | `jb_cs_n` | CS (10) |

**Bediening:** SW0 = demo-arpeggiator aan, SW1 = mute, SW2 = wah aan/uit,
BTN0 = reset, BTN1 = wah-niveau 0..3. LED0 = synth-status, LED1 = MMCM-lock.

## Eerste test

```
cd boards/arty-s7
vivado -mode batch -source build.tcl     # ± enkele minuten
vivado -mode batch -source program.tcl   # bord aan micro-USB
```

SW0 omhoog → zelfde 8-stemmige demo als op de Tang Primer 20K (klank-
pariteitscheck: beide borden draaien identieke RTL op 27 MHz / 48 kHz).
Controleer na de build `build/timing.rpt` (WNS ≥ 0) en `build/utilization.rpt`.
