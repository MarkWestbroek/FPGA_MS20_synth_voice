# Roadmap — MS-20 Synth Voice

Physical-modeling stem (Karplus-Strong) + MS-20-stijl filter op de Sipeed Tang
Primer 20K (Gowin `GW2A-LV18PG256C8`, device `GW2A-18C`), gekoppeld aan Teensy's
voor MIDI-in en USB-audio, als extra stemmen-bron voor een Eurorack-brain.

Zie ook [ARCHITECTURE.md](ARCHITECTURE.md) (diagrammen) en
[CHANGELOG.md](CHANGELOG.md) (wat er al gedaan is).

## Doel-architectuur (kort) — afgestemd op MusicBrain
Zie `D:\Git\Muziek\MusicBrain` (ADR 0010/0011, `doc/protocols/spi-frame.md`,
`doc/tech/two-teensy-spi.md`).

- **Brain = Teensy 4.1**, SPI-**master**. Doet MIDI-in → voice-allocatie → stuurt
  per-stem **pitch-CV + gate (+ filter-CV)** over de bestaande SPI-frame-bus.
  (De 3.2 vervalt — niet nodig.)
- **FPGA = SPI-slave "instrument"**: consumeert die CV/gate-frames en zet ze om
  in KS-toonhoogte (period) + filter g/k. Dit is precies de "audio-instrument"-rol
  die MusicBrain al voor de audio-Teensy had bedacht.
- **Audio uit**: FPGA → **onboard PT8211 stereo-DAC** (op de Dock) → 3.5mm jack.
  Geen externe DAC nodig. Optioneel een Teensy 4.1 die meeluistert → USB-opname.

> **Let op (ontwerpbeslissing open):** de huidige Fase-2 SPI gebruikt een eigen
> `[cmd][voice][hi][lo]`-protocol. Voor echte integratie moet dit het MusicBrain
> **frame-protocol** spreken (`[0xA5][VER][OPCODE][LEN][PAYLOAD][CRC16]`,
> CvSet/GateSet, CRC-16/CCITT). Zie Fase 2.

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
- [x] `spi_frame.v` — **MusicBrain frame v1**-decoder: `[0xA5][VER][OPCODE][LEN]
      [PAYLOAD][CRC16]`, CRC-16/CCITT-FALSE, opcodes Ping/CvSet/GateSet. CV-slots →
      pitch/cutoff/reson/drive; GateSet → gate + trigger-puls.
- [x] Zelf-controlerende testbench `spi_frame_tb.v` — **10/10 PASS** (incl.
      CRC-rejectie; DUT+TB berekenen CRC onafhankelijk → kruisgevalideerd).
- [x] Wiring in `synth_top`: SPI-pins + `spi_slave`/`spi_frame`, CV→param-mapping,
      `demo_mode`-mux (interne sequencer behouden), trigger naar `ce`-domein getild.
- [x] Pitch-CV → KS-period via `note_to_period` LUT (`gen_tables.py` → `note_period.hex`).
- [x] End-to-end testbench `synth_top_spi_tb.v`: SPI-frames → audio (geverifieerd,
      `ms20_filter_spi.wav`); demo-pad regressie OK.
- [x] MISO: Pong-antwoord op Ping (`spi_slave` MISO-TX + `spi_frame` Pong-frame
      `A5 01 01 00 D6 F2`); getest in `spi_frame_tb` (11/11 PASS).
- [x] dCV-conventie vastgelegd ([PITCH_CV.md](PITCH_CV.md)): uniform protocol,
      16-bit offset-binary full-scale 2¹⁶, geïnterpreteerd via range + pitch-type
      (FPGA = type-1 module, uitwisselbaar met analoog). Default 0–10V / 1 V/oct /
      0V=MIDI 0 → `note = (code·120)>>16`. Geen module-eigen notenconventie.
- [ ] Muzikale schaling van de cutoff/reson/drive-CV verfijnen met de brain.
- [ ] (later) CvSegment-interpolatie voor vloeiende cutoff bij hoge stem-aantallen.

### 🔶 Fase 3 — Hardware bring-up: bitstream + audio uit — VOORBEREID
- [x] Klok geparametriseerd (`SYS_CLK_HZ`): bord is **27 MHz**, niet 50 MHz —
      PLL→50 MHz of `SYS_CLK_HZ=27_000_000`. Zie [FLASHING.md](FLASHING.md).
- [x] `.cst`-template ([src/synth_top.cst](../src/synth_top.cst)) + flash-handleiding
      ([FLASHING.md](FLASHING.md), incl. `openFPGALoader`/Gowin Programmer).
- [x] **Pin-constraints** ingevuld voor first-light (geverifieerd tegen Sipeed
      PT8211-voorbeeld): `sys_clk`=H11 (27 MHz), `sys_rst_n`=T3, `led`=L16.
      SPI/demo/audio-pinnen volgen later.
- [ ] **Synthese → place&route → bitstream** in Gowin EDA (top = `synth_top`).
- [ ] **Flashen** (SRAM voor testen / embedded flash persistent) via
      `openFPGALoader -b tangprimer20k` of Gowin Programmer. Eerste doel:
      LED-heartbeat zien knipperen.
- [ ] **Onboard PT8211 stereo-DAC gebruiken** (geen externe DAC nodig!): `pt8211_tx.v`
      → HP_BCK(N15)/HP_WS(P16)/HP_DIN(P15)/PA_EN(R16) → 3.5mm jack.
      Protocol: BCK 1.536 MHz, 32 BCK/frame = 48 kHz, 16-bit MSB-first, WS L/R.
      Vereist een kleine PLL (27→6.144 MHz) + /4 voor de 1.536 MHz bit-clock.
- [ ] Optioneel: Teensy 4.1 die I2S meeluistert → USB-audio voor opname.

### ⬜ Fase 4 — Polyfonie & stemmen-telling
- [ ] Refactor naar één time-multiplexed voice-engine + gedeelde BRAM.
- [ ] Echte Gowin-synthese voor resource-baseline (LUT/DSP/BSRAM).
- [ ] Doel: 8 stemmen comfortabel, 16+ met packing/lagere bit-diepte.

## Open vragen / beslissingen
- Bit-diepte audio-pad (24-bit I2S? sample-breedte in delay-lines?).
- Resonance-controle met variabele `k`: 2D coeff-LUT of on-the-fly reciprocal.
- CS-/bus-topologie precies vastleggen met het bestaande Eurorack-brain.
