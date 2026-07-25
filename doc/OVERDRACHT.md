# Overdracht — werken op een andere machine

Geschreven 2026-07-24, bij de overstap desktop → laptop. Bevat (1) waar het
project staat, (2) wat een nieuwe machine nodig heeft, (3) hoe je verifieert
dat alles werkt, en (4) de valkuilen die ons al tijd gekost hebben.

## 1. Stand van zaken

**Twee borden, één codebase.** `src/` is vendor-neutraal; bord-specifieke
dingen staan in `boards/<bord>/`. Effecten hangen achter `generate`-
parameters, dus per bord kies je wat er meegebouwd wordt.

| | Tang Primer 20K (Gowin GW2A-18) | Arty S7-50 (Xilinx XC7S50) |
|---|---|---|
| Rol | het afgeronde MS-20-instrument | uitbouwbord: meer stemmen + FX |
| Build | Gowin EDA (`impl/`) | `boards/arty-s7/build.tcl` (Vivado) |
| Audio | PT8211 op de dock | PCM5102A op Pmod JA — **nog te solderen** |
| FX | uit (past niet: 9/46 BSRAM vrij) | echo + FDN-reverb aan |
| Status | werkend, ongewijzigd | geflasht, wacht op DAC |

**Branches** (alles op `origin`, https://github.com/MarkWestbroek/FPGA_MS20_synth_voice):

- `main` — t/m de Arty-poort + SVF-pijplijnfix (`ecac3ab`).
  ⚠️ **origin/main loopt 1 commit achter**; `git push origin main` maakt dat recht.
- `fx-echo-reverb` — **hier ligt het actuele werk**, 5 commits bovenop main,
  volledig gepusht. Begin hier op de laptop.

**Wat er op `fx-echo-reverb` af is** (alles met groene, zelf-checkende sims):

- `src/tape_echo.v` — bandecho, 0,68 s in BRAM, fractionele leeskop met slew
  (pitch-zwiep), wow-LFO, tanh-bandsaturatie + damping in de feedback. tb 4/4.
- `src/fdn_reverb.v` — 8×8 FDN, Hadamard via optellers, priemlengtes, per
  lijn damping. tb 5/5 (RT ≈ 2 s, dichte staart).
- `src/fft2048.v` — vendor-neutrale radix-2 FFT, 18-bit, block-floating-point.
  Geverifieerd tegen numpy: forward 79,0 dB, roundtrip 74,4 dB SNR.
  Kost 3 BRAM + 1 DSP; bewust géén Xilinx-IP, zodat hij ook naar Gowin kan.
- Integratie in `synth_top` achter `FX_ECHO` / `FX_REVERB` (default 0 →
  Tang-build bewezen bit-identiek over 144k samples).
- Volle Arty-build: WNS +4,5 ns, 46/75 BRAM, 46/120 DSP.

## 2. Wat de laptop nodig heeft

### Vivado 2026.1 — let op de licentie!

1. Installeer **Vivado ML Standard 2026.1**; kies bij devices alléén
   *Spartan-7* (≈30 GB i.p.v. 100+). Model Composer en DocNav uit.
   Cable drivers aan.
2. **De licentie is node-locked aan het MAC-adres van de machine.** De
   desktop-licentie (`60CF84BF62E7`, geldig t/m 24-jul-2027) werkt dus
   **niet** op de laptop. Genereer een tweede, ook gratis:
   [AMD Product Licensing](https://www.xilinx.com/getlicense) → *Vivado Basic
   Tier License, Node Locked* → Host ID = het MAC van de laptop-NIC
   (`Get-NetAdapter -Physical` → MacAddress, zonder streepjes).
3. Leg de `Xilinx.lic` in `%USERPROFILE%\.Xilinx` en zet
   `XILINXD_LICENSE_FILE` naar díe map (niet naar het bestand).
   Zonder dit start Vivado 2026.1 helemaal niet — ook de GUI niet.

Bouwen en flashen (werkt vanuit de repo-root):

```
vivado -mode batch -source boards/arty-s7/build.tcl     # ~4 min
vivado -mode batch -source boards/arty-s7/program.tcl   # bord aan micro-USB
```

`build.tcl` stopt hard bij CRITICAL WARNINGS of negatieve slack — zie valkuil 1.

### DSim (simulatie)

Altair DSim 2026 + de gratis licentie-JSON. Op de desktop:
`C:\Program Files\Altair\DSim\2026` en
`C:\Users\User\AppData\Local\metrics-ca\dsim-license.json`.

```powershell
. "C:\Program Files\Altair\DSim\2026\shell_activate.ps1"
$env:DSIM_LICENSE = "<pad naar>\dsim-license.json"
dsim -sv src/tanh_lut.v src/tape_echo.v src/tape_echo_tb.v -work dsim_work_fx +acc+b
```

⚠️ De gratis licentie geeft **één lease**: nooit twee sims tegelijk starten
(je krijgt dan `maxLeases (1)` en de tweede faalt).

### Python

`.venv` in de repo-root; `numpy` is nodig voor het conv-golden-model en de
FFT-check (`pip install numpy`). De WAV-renderscripts hebben niets nodig.

### Gowin EDA

Alleen nodig als je de Tang-bitstream opnieuw bouwt. Zie `doc/FLASHING.md`.

### Niet in git (handmatig meenemen)

- **`site.env`** — bevat `INGEST_TOKEN` + `IMPRINT_BASE` voor het publiceren
  naar musicbrain.nl. Bewust gitignored. Zonder dit bestand kun je alleen
  lokaal (`localhost:3000`, token `test-ingest-token-123`) publiceren.
- De zusterrepo's, als je daar ook aan werkt: `D:\Git\Muziek\MusicBrain`
  (Cortex/firmware + publicatiescripts) en `D:\Git\Web\Imprint-engine` (de
  site zelf; `npm run db:up` + `npm run dev`).

## 3. Verificatie na het opzetten (ca. 10 min)

Draai deze vier; alles hoort groen te zijn. Dan weet je dat de hele keten
(sim, tabellen, Python, Vivado) op de nieuwe machine klopt.

```powershell
# 1. Synth-regressie (poly)
dsim -sv src/tanh_lut.v src/ks_string.v src/mass_spring_resonator.v `
  src/ms20_filter.v src/note_to_period.v src/note_phinc.v src/voice_engine.v `
  src/spi_slave.v src/spi_frame.v src/pt8211_tx.v src/i2s_tx.v `
  src/synth_top.v src/poly_tb.v -work dsim_work +acc+b      # → 4/4 PASS

# 2. Tape-echo               → 4/4 PASS
dsim -sv src/tanh_lut.v src/tape_echo.v src/tape_echo_tb.v -work dsim_work_fx +acc+b

# 3. FDN-reverb              → 5/5 PASS
dsim -sv src/fdn_reverb.v src/fdn_reverb_tb.v -work dsim_work_fx +acc+b

# 4. FFT + numpy-vergelijking → forward 79 dB, roundtrip 74 dB, PASS
dsim -sv src/fft2048.v src/fft2048_tb.v -work dsim_work_fft +acc+b
.venv\Scripts\python.exe scripts\fft_check.py
```

Audio beluisteren: `python scripts/cols2wav.py <simuitvoer.txt> <prefix> dry wet`
schrijft naar `wav/`. De laatste renders staan al in de repo.

Tabellen zijn gegenereerd en gecommit (`*.hex`); opnieuw maken kan met
`scripts/gen_tables.py` (synth) en `scripts/gen_fft_tables.py` (FFT).

## 4. Valkuilen die ons al tijd gekost hebben

1. **Vivado project-flow vindt `$readmemh`-bestanden niet.** `launch_runs`
   draait synthese in een eigen map, waardoor `wavetable.hex` c.s. stilletjes
   leeg bleven — alleen een CRITICAL WARNING, gewoon een bitstream als
   resultaat. Alle Arty-bitstreams van vóór commit `0998d17` hadden lege
   ROM's. `build.tcl` gebruikt nu de non-project flow met cwd=repo-root en
   faalt hard op zulke warnings. **Nooit terug naar de project-flow.**
2. **Drie geketende vermenigvuldigingen halen 27 MHz niet.** De SVF-stap
   faalde timing (Vivado −5,3 ns; Gowin zat al op −1,6 ns en werkte op
   silicium-geluk). Vandaar de 3-staps pijplijn in `voice_engine`. Vuistregel
   voor nieuwe DSP: **max één mult per FSM-cyclus** — de FX-modules volgen dat.
3. **Gain-staging tussen synth en FX.** De FX werken intern op ±4.0 terwijl de
   droge mix rond 0,1–0,25 leeft. Wet-sends staan daarom op ÷16 (echo) en ÷8
   (reverb); op ÷2 clipte 0,8% van de samples hard.
4. **Leeslatency in de eigen BRAM-wrappers is 2 cycli** (adres- én
   dataregister), bij `fft2048` zelfs 3 door de idle-mux — en samplen op
   dezelfde klokflank geeft een NBA-race in sim. Testbenches lezen op de
   negedge.
5. **De bitstream staat niet in QSPI-flash.** Na een power-cycle is de Arty
   leeg; opnieuw `program.tcl` draaien. (QSPI-boot staat op de todo.)
6. **PCM5102-breakouts komen vaak met open soldeerjumpers** en blijven dan
   stil. Brug: 1→L (FLT), 2→L (DEMP), **3→H (XSMT = un-mute, de cruciale)**,
   4→L (FMT = I2S).

## 5. Openstaande draden

**Direct oppakbaar:**

- **DAC solderen + luistertest** — het bord draait de FX-build; dit is de
  eerste keer dat er echt geluid uit komt. Bedrading: `boards/arty-s7/README.md`.
- **Conv-reverb stap 3**: spectrale MAC + frequency-delay-line met een
  gedrags-DDR3 achter dezelfde poort-interface als de latere MIG. Ontwerp en
  budgetten staan in `doc/CONV_REVERB_DESIGN.md`; `scripts/conv_golden.py` is
  het referentiemodel om tegen te verifiëren (83 dB SNR).
- **QSPI-boot** zodat het bord na power-on vanzelf speelt.

**Afstemmen met Cortex (Teensy-kant):**

- **Cutoff is pitch-equivalent** (besluit brain-kant). Aan FPGA-zijde betekent
  dat een *exponentiële* cutoff-mapping (tabel zoals `note_phinc`) i.p.v. de
  huidige quasi-lineaire — en dat geeft meteen filter-keytracking.
- **Globale FX-parameters passen niet in de per-stem blokken van 8**
  (echo-tijd, feedback, reverb-size, sends). Er moet een slotconventie komen;
  ADR 0015 dekt dit nog niet.

**Verder weg:** Fase B (16 stemmen, 4× oversampling, klok naar ~98 MHz),
tape-echo naar DDR3 voor minutenlange band, en een FX-only build voor een
Tang Nano 20K als losse Cortex-effectmodule (zie `doc/CONV_REVERB_DESIGN.md`
§ modulariteit).

## 6. Kaart van de repo

| Pad | Wat |
|---|---|
| `src/` | alle RTL + testbenches, vendor-neutraal |
| `boards/arty-s7/` | wrapper, XDC, build/program/synth-check-scripts, README |
| `impl/` | Gowin-buildoutput (Tang), gitignored |
| `doc/ROADMAP.md` | fasen + wat af is |
| `doc/ARTY_S7_PLAN.md` | uitbouwplan Arty (stemmen, echo, reverb) |
| `doc/CONV_REVERB_DESIGN.md` | convolutie-galm: architectuur, budgetten, volgorde |
| `doc/SPI_SLOTMAP.md`, `doc/PITCH_CV.md` | contract met Cortex |
| `doc/FLASHING.md` | Tang-bitstream bouwen en flashen |
| `scripts/` | tabelgeneratoren, WAV-renderer, golden models |
| `wav/` | gerenderde audio uit de sims (in git) |
