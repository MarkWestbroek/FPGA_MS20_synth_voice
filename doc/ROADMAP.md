# Roadmap — MS-20 Synth Voice

Physical-modeling stem (Karplus-Strong) + MS-20-stijl filter op de Sipeed Tang
Primer 20K (Gowin `GW2A-LV18PG256C8`, device `GW2A-18C`), gekoppeld aan Teensy's
voor MIDI-in en USB-audio, als extra stemmen-bron voor een Eurorack-brain.

Zie ook [ARCHITECTURE.md](ARCHITECTURE.md) (diagrammen) en
[CHANGELOG.md](CHANGELOG.md) (wat er al gedaan is).

## Doel-architectuur (kort)
- **Teensy 3.2** = control-brain / SPI-master (USB-MIDI → SPI, CV). De FPGA wordt
  een extra **SPI-slave** op de bestaande Eurorack-bus.
- **Teensy 4.1** = USB-audio-bridge: leest I2S van de FPGA en stuurt door als
  USB-audio (de 3.2 z'n USB-audio is daarvoor te zwak).
- **FPGA** = oscillatoren (KS) + MS-20 filters, polyfoon.

## Fasen

### ✅ Fase 1 — Filter naar MS-20-feel (simulatie)
- [x] tanh-LUT diode-saturatie in de resonantie-feedback (`tanh_lut.v`, `gen_tables.py`).
- [x] `drive`-parameter (tanh in saturatie duwen).
- [x] 2× oversampling via FSM in `ms20_filter.v` (anti-aliasing).
- [x] Chamberlin g-coeff op interne 96 kHz (`2·sin(π·fc/96000)`).
- [x] Geverifieerd in DSim: geen overflow/DC-runaway; duidelijke LP + resonantie.
- ⏭️ Optioneel later: TPT/Zavalishin SVF; echte 2D (g×k) coeff-LUT; 4× OS.

### 🔶 Fase 2 — SPI control-interface (FPGA als slave) — IN UITVOERING
- [x] `spi_slave.v` (mode 0, MSB-first) met CDC (2-FF sync + flankdetectie).
- [x] `spi_control.v` command-decoder, protocol `[cmd][voice][param_hi][param_lo]`:
      NOTE_ON (→period), NOTE_OFF, CUTOFF, RESON, DRIVE, MODE.
- [x] Zelf-controlerende testbench `spi_control_tb.v` — 8/8 PASS in DSim.
- [ ] Wiring in `synth_top`: demo-sequencer vervangen door SPI-parameters
      (sequencer behouden als optionele demo-mode). **Integratie-notitie:**
      `trigger` is een sys_clk-puls → in `synth_top` vasthouden tot de volgende
      `sample_clk_tick` (ce) voordat hij naar `ks_string` gaat.
- [ ] Muzikale schaling van de param-mappings verfijnen (nu vaste shifts).

### ⬜ Fase 3 — Audio naar Teensy → USB
- [ ] `i2s_tx.v` (BCLK/LRCLK/DATA, 24-bit, master).
- [ ] PMOD-pinnen + `.cst` constraints; hardware bring-up op het bord.
- [ ] Teensy 4.1 firmware: I2S-in → USB-audio-out.

### ⬜ Fase 4 — Polyfonie & stemmen-telling
- [ ] Refactor naar één time-multiplexed voice-engine + gedeelde BRAM.
- [ ] Echte Gowin-synthese voor resource-baseline (LUT/DSP/BSRAM).
- [ ] Doel: 8 stemmen comfortabel, 16+ met packing/lagere bit-diepte.

## Open vragen / beslissingen
- Bit-diepte audio-pad (24-bit I2S? sample-breedte in delay-lines?).
- Resonance-controle met variabele `k`: 2D coeff-LUT of on-the-fly reciprocal.
- CS-/bus-topologie precies vastleggen met het bestaande Eurorack-brain.
