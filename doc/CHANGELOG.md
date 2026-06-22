# Changelog

Voortgangslog. Nieuwste bovenaan. Zie [ROADMAP.md](ROADMAP.md) voor wat nog komt.

## 2026-06-22 — Bugfix: filter-CV's unsigned + wah-via-SPI geverifieerd
- **Bug**: cutoff/reson/drive-CV werden in `synth_top` nog *signed* geïnterpreteerd
  (sign-extend + `<=0?0`), terwijl de dCV-conventie **unsigned offset-binary** is.
  Cutoff `0xD000` (MSB=1) werd zo negatief → `g=0` → filter dicht. Gefixt: zero-extend
  (`cutoff_u/reson_u/drive_u`), conform doc/PITCH_CV.md.
- Geverifieerd met een tijdelijke testbench die vanaf de "brain" een dalende reeks
  cutoff-`CvSet`'s stuurt: de wah komt terug via SPI, HF daalt vloeiend van ~1500 → 300 Hz
  (filter start nu op t=0, niet pas na 0.5s). Render: `wav/ms20_filter_spiwah.wav`.

## 2026-06-22 — Synthese-warnings + 27 MHz-render geverifieerd
- `ms20_filter.v`: lut_addr-randbug gefixt (`>= X_MAX`, anders wrapt de grenswaarde
  1024 naar adres 0). De overige width-warnings zijn normale fixed-point/teller-
  truncaties (onschuldig).
- `note_to_period.v`: ROM 12-bit zodat de 3-nibble hex-entries passen (silences EX2526).
- `make_wave.py` schrijft nu naar `wav/`.
- Geverifieerd: SPI → audio op de echte **27 MHz** klok (tijdelijke tb), render in
  `wav/ms20_filter_spi27.wav`.

## 2026-06-22 — Flash-klaar: 27 MHz default + LED-heartbeat
- Board-specs bevestigd uit datasheet (GW2A-LV18PG256C8/I7): 20736 LUT4, 48 DSP,
  **828K BSRAM (46 blokken)**, 4 PLLs, 32Mbit flash. Klok = **27 MHz** (50 was fout).
- `synth_top` default `SYS_CLK_HZ = 27_000_000` (native, geen PLL); testbenches
  overschrijven naar 50 MHz. Sim ongewijzigd (geverifieerd: SPI→audio OK).
- LED-heartbeat (~0.8 Hz) als zichtbaar first-light-levensteken.
- `doc/FLASHING.md` + `src/synth_top.cst` bijgewerkt (27 MHz primair, PLL optioneel).

## 2026-06-22 — Pitch-conventie gecorrigeerd naar uniform dCV-protocol
- Eerdere "256 LSB/semitoon, ref noot 69" was een module-eigen notenconventie en
  brak de protocol-uniformiteit — teruggedraaid. Nu: dCV is **uniform** voor analoge
  én digitale modules. 16-bit **offset-binary, full-scale 2¹⁶** (`0x0000`=range-min,
  `0xFFFF`≈range-max), geïnterpreteerd via range + pitch-type. FPGA = type-1 module.
- Default-config FPGA: 0–10V, 1 V/oct, 0V = MIDI-noot 0 → `note = (code·120)>>16`
  (V/oct ⇒ code lineair in semitonen; daarna de bestaande note_to_period LUT).
- `doc/PITCH_CV.md` herschreven; `synth_top` pitch-mapping aangepast; SPI-render
  geverifieerd (noot 33 = A1).
- MusicBrain: `spi-frame.md`, `doc/tech/spi.md` en ADR 0014 verduidelijkt met de
  offset-binary full-scale-2¹⁶ encoding (vervangt de "i16 −1..+1"-tekst).

## 2026-06-22 — MISO/Pong, pitch-conventie, flash-voorbereiding
- MISO-zendpad in `spi_slave.v` + Pong-respons in `spi_frame.v`: een `Ping` levert
  het Pong-frame `A5 01 01 00 D6 F2` op MISO. `spi_frame_tb`: 11/11 PASS.
  (Bug onderweg: Pong-index resette nu bij frame-einde i.p.v. mid-transactie.)
- Pitch-conventie vastgelegd: 256 LSB = 1 semitoon, ref A4=69 → `doc/PITCH_CV.md`.
  `synth_top` pitch-mapping daarop aangepast. Hz/V/S-Trig (MusicBrain ADR 0014)
  zijn analoog-only en gelden niet voor dit digitale instrument.
- Flash-voorbereiding: klok geparametriseerd (`SYS_CLK_HZ`, bord = 27 MHz),
  `src/synth_top.cst`-template + `doc/FLASHING.md` (bring-up volgorde, openFPGALoader).
- MusicBrain ADR 0013: repo-referentie via GitHub-URL; pitch-open-vraag gekoppeld
  aan ADR 0014.

## 2026-06-22 — Fase 2: synth_top wiring (SPI → audio end-to-end)
- `synth_top.v`: SPI-pins + `spi_slave`/`spi_frame` ingebouwd; CV→param-mapping
  (pitch→KS-period, cutoff→g, reson→k, drive); `demo_mode`-mux houdt de interne
  demo-sequencer als optie; trigger naar het audio-tick (`ce`) domein getild.
- `note_to_period.v` + `note_period.hex` (gen_tables.py): MIDI-noot → KS-period.
- `synth_top_spi_tb.v`: end-to-end test — SPI-frames sturen cutoff/reson/drive/pitch
  + GateSet, audio komt eruit (`ms20_filter_spi.wav`). Demo-pad regressie OK.
- Bugfix: SPI-trigger moet (net als de demo) de héle tick-gap hoog blijven zodat
  `ks_string` 'm op de volgende `ce` consumeert.

## 2026-06-22 — Fase 2: SPI afgestemd op MusicBrain
- MusicBrain-project gelezen (ADR 0010/0011, frame-protocol, twee-Teensy-split).
  Besluit: FPGA = SPI-slave "instrument" op de Teensy-4.1-brain bus; audio uit via
  I2S DAC (analoog) **en** een Teensy 4.1 (USB-opname).
- `spi_frame.v`: **MusicBrain frame v1**-decoder met CRC-16/CCITT-FALSE; opcodes
  Ping/CvSet/GateSet → pitch/cutoff/reson/drive-CV + gate/trigger.
- `spi_frame_tb.v`: zelf-controlerende testbench, **10/10 PASS** (incl. CRC-rejectie).
- `spi_slave.v` (mode-0 byte-ontvanger + CDC) blijft de onderlaag.
- Tussenstap `spi_control.v` (eigen `[cmd][voice][hi][lo]`-protocol, 8/8 PASS)
  vervangen door bovenstaande frame-decoder.
- Roadmap: flashen naar bord (.cst → bitstream → openFPGALoader/Gowin Programmer)
  expliciet toegevoegd aan Fase 3.

## 2026-06-22 — Fase 1: filter naar MS-20-feel
- `ms20_filter.v` herschreven als FSM met **2× oversampling** en een **`drive`**-
  ingang; tanh-LUT diode-saturatie in de resonantie-feedback.
- `gen_tables.py` toegevoegd: genereert `tanh_table.hex` (Q12.20) en print de
  prewarped Chamberlin g-constanten (96 kHz interne rate).
- `synth_top.v`: g-constanten naar 96 kHz, envelope-stap herschaald, `filter_drive`
  toegevoegd, filter met `OVERSAMPLE(2)`.
- Ontdekt: `k` is de **dempingsfactor** (lager = meer resonantie); oude comment
  ("self-oscillatie bij k≈4") was fout. Scream-preset: k≈0.25, drive≈4.0.
- Testbench: VCD-dump achter `+define+DUMP_VCD` (voorkomt 10+ GB bestand).
- `make_wave.py`: UTF-8 console-fix + dode code verwijderd.
- Geverifieerd in DSim: geen overflow/DC-runaway; LP-werking (HF-ratio 0.03);
  scream-versie ringt netjes (tanh begrenst, geen overflow).
- Audio-presets ter vergelijking: `ms20_filter_warm.wav` (k=1.25, drive=3.0) en
  `ms20_filter_scream.wav` (k=0.25, drive=4.0).
- Opruiming: ~19 GB oude `.vcd`-bestanden verwijderd.

## Eerder (vóór deze log)
- Karplus-Strong string (`ks_string.v`) + eerste Chamberlin SVF; signed/CDC-bugs
  gefixt; Q12.20 fixed-point; DSim-simulatieflow + `make_wave.py` → WAV.
