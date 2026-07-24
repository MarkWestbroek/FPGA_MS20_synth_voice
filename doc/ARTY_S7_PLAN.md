# Arty S7-50 uitbouwplan — meer stemmen, FDN-reverb, tape-echo

Poort van de MS-20 poly-voice naar het **Digilent Arty S7-50** bord
(Xilinx Spartan-7 `XC7S50-1CSGA324C`), met als doel wat op de Tang Primer 20K
niet past: **16+ stemmen, een FDN-reverb en een tape-echo-emulatie uit DDR3**.

De Tang Primer 20K blijft het huidige, afgeronde instrument aan de Cortex-bus
(zie [ROADMAP.md](ROADMAP.md)); dit plan raakt dat pad niet.

## Waarom dit bord (t.o.v. GW2A-LV18)

| Resource | Tang Primer 20K | Arty S7-50 | Onze huidige benutting |
|---|---|---|---|
| Logica | 20.736 LUT4 | 32.600 LUT6 (≈2–3× effectief) | 13% |
| DSP | 24 (18×18) | 120× DSP48E1 (25×18+acc, ~450 MHz) | 50% |
| Block-RAM | 828 Kb | 2.700 Kb | **81%** ← knelpunt |
| Extern RAM | — (ongebruikt) | 256 MB DDR3L via Xilinx MIG | — |
| ADC | — | XADC 2× 12-bit 1 MSPS | — |
| Audio | PT8211 op dock | **niets** → Pmod nodig | — |

Klok-headroom: fabric 100–200 MHz is realistisch (nu 27 MHz). Fase B mikt op
**≈98,4 MHz** (MMCM ×39,375 ÷4 ÷10): ~2050 cycli per sample i.p.v. 562 — ruimte
voor 32 stemmen bij gelijke kosten per stem, of 16 stemmen met 4× OS plus
effectsectie. 98,4 ≈ 2048×48 kHz houdt óók de I2S-deler rond (BCLK = klok/64);
de resterende +0,1% op de samplerate (~2 cent) is onhoorbaar. Exact 48,000 kHz
kan niet uit 100 MHz met één MMCM — niet naar streven.

## Audio-uitgang (bord heeft geen DAC)

Gekozen: **PCM5102A-breakout (GY-PCM5102, in bezit)** op Pmod JA — standaard
I2S via het bestaande `i2s_tx.v` (`DAC_I2S=1` in `synth_top`), geen MCLK nodig
(SCK laag → interne PLL). Kwalitatief een stap boven de PT8211 (112 dB DAC).

Later optioneel: **Digilent Pmod I2S2** (~€25) heeft naast een DAC ook een
CS5343 **ADC/line-in** — extern signaal (rest van het Cortex-rack!) door de
tape-echo/reverb sturen; dan komt er een `i2s_rx.v` bij.

## Fasen

### Fase A — Toolchain + 1:1 poort
- [ ] Vivado ML Standard (gratis, dekt S7) + Digilent board files.
- [x] Repo-indeling: `src/` blijft vendor-neutraal; nieuw `boards/arty-s7/` met
      `synth_top_arty.v` (dunne wrapper), MMCM-instantie, `arty_s7.xdc`
      (poort van `synth_top.cst`) en `build.tcl`/`program.tcl` voor de
      Vivado-batchflow. Gowin-flow blijft intact.
- [x] MMCM: 100 MHz → **exact 27 MHz** (×13,5 ÷2 ÷25) — Fase A draait 1:1 op
      de Tang-klok, identieke timingmarges; opschalen is Fase B.
- [x] `synth_top` parameter `DAC_I2S`: 0 = PT8211 (Tang), 1 = `i2s_tx` voor de
      **PCM5102A-breakout** (in bezit) op Pmod JA — SCK laag = interne PLL,
      geen MCLK nodig.
- [ ] Audio via Pmod (optie 1 of 2), bitstream, zelfde 8-stemmige demo als op de
      Tang → **klank-pariteitscheck**.
- [ ] SPI-pins naar een tweede Pmod; `spi_frame`-pad ongewijzigd testen met de
      bestaande `synth_top_spi_tb.v` (DSim blijft de sim-flow, vendor-neutraal).

### Fase B — Engine opschalen: 16 stemmen, 4× OS
- [ ] MMCM omzetten naar ≈98,4 MHz (×39,375 ÷4 ÷10) en `SYS_CLK_HZ` mee;
      `i2s_tx` DIV=64 → BCLK ≈1,54 MHz, alles uit één klokdomein.
- [ ] `voice_engine` time-multiplex van 8 → 16 stemmen (cycli zijn er ruim).
- [ ] `ms20_filter` van 2× naar 4× oversampling (FSM-uitbreiding; de tanh-LUT en
      coëfficiëntenpaden blijven gelijk).
- [ ] Wavetable-exciter: banken verruimen (BRAM-budget: onze huidige 666 Kb aan
      tabellen is op de S7-50 maar ~25%).
- [ ] Slot-contract v2 zegt al "blokken van 8 per parameter" → uitbreiden naar
      2 blokken (stem 0..15); afstemmen met Cortex ADR 0015.

### Fase C — Tape-echo
Architectuur (klassiek Space-Echo-model):
- **Schrijfkop** op vaste 48 kHz; **1–3 leeskoppen** op fractionele, variabele
  afstand (lineaire interpolatie eerst, 4-punts Lagrange later).
- **Delay-tijd-knop verschuift de leeskop met slew** → de karakteristieke
  pitch-zwiep van echte tape bij het draaien aan de tijd.
- **Wow/flutter**: langzame LFO (~0,8 Hz) + snelle (~8 Hz) + wat ruis op de
  leespositie.
- **Feedbackpad**: som koppen → tanh-saturatie (hergebruik `tanh_lut.v`) →
  verdonkerings-LP (één-pool, ~4 kHz) → terug de band op. Feedback >1 mag:
  zelf-oscillatie is het halve instrument.

Stappen:
- [ ] **C1 — BRAM-versie**: mono, één kop, max ~1 s (768 Kb). Bewijst het
      audio-pad en de interpolatie zonder DDR3-complexiteit; sim in DSim met
      WAV-render.
- [ ] **C2 — DDR3-versie**: MIG-IP + simpele FIFO-poorten (read-ahead burst,
      audio vraagt maar ~384 KB/s stereo — de MIG verveelt zich). Minuten aan
      band, 3 koppen, stereo. CDC tussen MIG `ui_clk` en audio-domein via
      async-FIFO's. Voor DSim: gedrags-model achter dezelfde poort-interface.

### Fase D — FDN-reverb
- [ ] 8×8 feedback-delay-network, Hadamard-matrix (shift/add, geen DSP),
      priemgetal-lengtes, per lijn één-pool damping, 2 allpass-diffusers aan de
      ingang. Budget: ~32k samples totaal ≈ 16 RAMB36 — past naast wavetables
      en C1-echo; groeit desgewenst mee naar DDR3.
- [ ] Send-architectuur: per stem een reverb/echo-send (slot in het contract),
      FX-return op de mix.

### Fase E — Cortex-integratie + extra's
- [ ] FX-parameters als extra CV-slotblok (echo-tijd, feedback, wow-diepte,
      reverb-size, damping, sends) — zelfde frame-protocol, alleen slotmap-groei.
- [ ] Optioneel: **XADC als directe CV-in** (2 kanalen, 1 V-bereik → deler/offset
      vanaf Eurorack-niveaus nodig). Maakt de Arty ook standalone bespeelbaar.
- [ ] Optioneel: line-in (Pmod I2S2 ADC) als externe FX-send vanuit het rack.

## Resource-raming S7-50 (16 stemmen + FX)

| Blok | DSP48 | RAMB36 (van 75) |
|---|---|---|
| 16 stemmen KS/WT/exciter + MS-20 4×OS | ~25 | ~22 (wavetables + states) |
| Tape-echo C1 (BRAM, 1 s) | ~4 | ~22 |
| FDN-reverb | ~6 | ~16 |
| MIG DDR3 (C2) | 0 | ~5 |
| Marge | — | ~10 |

Alles blijft ruim onder de helft van de DSP's; BRAM wordt pas krap als C1-echo
én grote wavetable-banken samen moeten — dan verhuist de echo naar DDR3 (C2).

## Risico's / aandachtspunten
- **Vivado-leercurve + MIG**: de DDR3-controller is het enige echt nieuwe stuk
  infrastructuur; daarom eerst C1 in BRAM.
- **CDC**: drie klokdomeinen (audio ≈98,4 MHz, MIG ui_clk ~100 MHz, SPI) —
  zelfde discipline als de bestaande 2-FF-sync in `spi_slave.v`.
- **Timing**: 96 MHz is comfortabel voor S7, maar de tanh-LUT-feedbacklus in
  `ms20_filter` wordt de kritieke pad-kandidaat; zo nodig pipelinen binnen de
  OS-FSM (cycli genoeg).
