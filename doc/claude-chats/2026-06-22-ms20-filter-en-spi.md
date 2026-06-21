# Claude-sessie: MS-20 filter naar MS-20-feel + SPI-integratie

- **Datum**: 2026-06-22
- **Model**: Claude Opus 4.8 (Claude Code)
- **Onderwerp**: Fase 1 (filter optillen) + Fase 2 (SPI control) + architectuur op
  MusicBrain afstemmen

> Dit is een samenvattende sessie-log (besluiten + gebouwd werk), geen verbatim
> transcript.

---

## Vertrekpunt
Physical-modeling stem (Karplus-Strong) → MS-20-stijl filter op de Sipeed Tang
Primer 20K (Gowin GW2A-18C), alleen in simulatie (DSim → `make_wave.py` → WAV).
Doel van de gebruiker: plan voor MIDI-in/audio-uit via Teensy, koppeling aan een
bestaand Eurorack-brain, en uitzoeken hoeveel stemmen passen.

## Fase 1 — filter naar MS-20-feel
- Ontdekt: de tanh-LUT diode-saturatie was al aanwezig (klonk al "warm").
  Toegevoegd: **`drive`**-parameter + **2× oversampling** (FSM in `ms20_filter.v`)
  tegen aliasing; g-constanten naar de interne 96 kHz-rate (`2·sin(π·fc/96000)`).
- `gen_tables.py` toegevoegd (genereert `tanh_table.hex` + g-constanten).
- **Belangrijke correctie:** `k` is de *dempingsfactor* — LAGER = meer resonantie.
  De oude aanname ("self-oscillatie bij k≈4") was fout. Scream-preset: k≈0.25,
  drive≈4.0.
- Geverifieerd in DSim: geen overflow/DC-runaway, duidelijke LP-werking; scream-
  versie ringt netjes (tanh begrenst). Presets: `ms20_filter_warm.wav` /
  `ms20_filter_scream.wav`.
- Opruiming: ~19 GB oude `.vcd` weg; `make_wave.py` opgeschoond + UTF-8-fix;
  testbench-VCD achter `+define+DUMP_VCD`.

## Documentatie + visualisatie
- `doc/ROADMAP.md` (backlog), `doc/CHANGELOG.md` (release log),
  `doc/ARCHITECTURE.md` (Mermaid-diagrammen: systeem, hiërarchie, filter-FSM).
- Verilog visualiseren: Mermaid + Gowin Netlist/Schematic Viewer, Yosys `show`,
  netlistsvg, WaveDrom/GTKWave.

## Fase 2 — SPI control, afgestemd op MusicBrain
- MusicBrain gelezen (ADR 0010/0011, SPI-frameprotocol, twee-Teensy-split).
  **Besluit:** de FPGA = SPI-slave "instrument" op de Teensy-4.1-brain bus; de
  brain doet MIDI + voice-allocatie en stuurt per-stem CV/gate. Vastgelegd als
  MusicBrain **ADR 0013**.
- Audio-uit: I2S DAC (analoog de modular in) **én** een Teensy 4.1 (USB-opname).
- `spi_slave.v` (mode-0 byte-ontvanger + CDC) + `spi_frame.v` (MusicBrain frame v1
  decoder met CRC-16/CCITT, opcodes Ping/CvSet/GateSet). Testbench
  `spi_frame_tb.v`: **10/10 PASS** incl. CRC-rejectie (DUT+TB CRC kruisgevalideerd).
- Eerdere tussenstap `spi_control.v` (eigen protocol, 8/8 PASS) vervangen.

## Roadmap / flashen
Flashen naar het bord toegevoegd aan Fase 3: `.cst` pin-constraints → bitstream in
Gowin → `openFPGALoader -b tangprimer20k` of Gowin Programmer (SRAM of flash).

## Nog open
- Wiring in `synth_top`: demo-sequencer vervangen door de SPI-CV's, pitch-CV →
  KS-period (note→period LUT), trigger naar het `ce`-domein tillen.
- MISO Pong; per-voice slot-map; `CvSegment`-interpolatie; multi-voice refactor.

## Hoe deze sim te draaien
Zie memory `run-dsim-sim`: `DSIM_LICENSE` env zetten, `dsim -sv … +acc+b`,
`PYTHONIOENCODING=utf-8 python make_wave.py`.
