# Plan: polyfonie + wavetable op de Tang Primer 20K

Uitbreidingsplan (2026-07-06) op basis van de P&R-cijfers van de mono-versie:
Logic 5%, Registers 4%, BSRAM 10/46 (22%), **DSP 10/24 (42%)**, 4 PLL's en de
128 MB DDR3 onaangeraakt.

## Kerninzichten

1. **DSP is de schaarse resource, niet logic.** De ene stem gebruikt al 42% van
   de multipliers → de voice 8× instantiëren past niet.
2. **Tijd is de goudmijn**: op 27 MHz zijn er **562 klokcycles per sample**
   (48 kHz); de huidige voice gebruikt er ~10. Eén gedeelde rekenkern die per
   sample alle stemmen sequentieel doorrekent (time-multiplexing) houdt het
   DSP-gebruik constant; alleen de state groeit per stem. Een PLL naar 108 MHz
   kan later 4× meer budget geven — nu niet nodig.

## Stappen

### Stap 1 — `voice_engine.v`: 8 stemmen time-multiplexed  ✅ = tag `0.2-poly8`
- Eén gedeelde KS + MS-20 datapath (incl. één tanh-LUT), Q12.20 identiek aan de
  mono-versie → zelfde klankkarakter per stem.
- **Delay-geheugen**: één BRAM 16384×18 (adres = {voice[2:0], idx[10:0]}),
  samples in de KS-lus als Q1.17 (18-bit; KS-content is ±1.0, klassiek KS
  gebruikte 8 bit — 18 is royaal). Kost 16 BSRAM-blokken; laat ~25 vrij voor de
  wavetables van stap 2. (8 stemmen × 32-bit zou 32 blokken kosten → te krap.)
- **Per-stem state**: ptr/period/initialized, lp/bp (filter), env_timer/fg
  (wah-envelope per stem — elke aanslag opent zíjn filter), in registers.
- **FILL in de achtergrond**: een trigger zet een fill-request; de engine vult
  de delay-lijn van die stem in de idle-cycles ná het stemmen-werk (~490
  cycles/tick → een fill duurt ~4 ticks, onhoorbaar; de stem zwijgt intussen).
- **Cycle-budget**: 8 stemmen × ~9 cycles + mix ≈ 75 van de 562 per tick.
- **Mix**: som van 8 stemmen ÷ 4 → bestaand DAC-pad (>>>4 + saturatie)
  ongewijzigd. `filter_out`/`string_out` blijven bestaan (nu de mix) zodat
  make_wave.py en de testbenches blijven werken.
- **Demo** (DEMO_ONLY=1): arpeggiator — elke 0,5 s de volgende stem round-robin
  getriggerd met een 8-noten patroon; overlappende KS-staarten (~2,9 s decay)
  bewijzen de polyfonie hoorbaar. Wah-niveaus (T2/E9) blijven werken en gelden
  globaal; de envelope loopt per stem.
- **SPI per stem** (MusicBrain-frames): CvSet-slot = `voice*4 + param`
  (param 0=pitch, 1=cutoff, 2=reson, 3=drive; stem 0 = slots 0–3 →
  backwards-compatible met de mono-versie). GateSet-slot = voice (0–7).
  spi_frame levert een schrijf-poort (cv_we/voice/param/val) + gate-vector +
  trigger-pulsen; synth_top houdt de per-stem arrays bij (pitch → period via de
  gedeelde note_to_period-LUT).
- `ks_string.v`/`ms20_filter.v` blijven bestaan als mono-referentie en voor de
  unit-testbenches; de engine heeft een eigen (equivalente) datapath.

### Stap 2 — wavetable-oscillator per stem  ✅ = tag `0.3-wavetable`
- Per stem een 32-bit fase-accumulator; phase-increment per MIDI-noot uit een
  nieuwe LUT (`note_phinc.hex`, 128×32, `inc = f0 · 2^32 / 48000`).
- **Wavetables met mipmaps** (anti-aliasing): per golfvorm 8 octaaf-niveaus ×
  1024×16-bit, bandgelimiteerd gegenereerd (additief) door `gen_tables.py` →
  `wavetable.hex`. Start: 2 golfvormen (saw, square) = 16 BSRAM-blokken.
  Adres = {wave, mip[2:0], idx[9:0]}.
- Lineaire interpolatie tussen twee samples (1 mult op de gedeelde kern);
  mip-keuze per stem uit de noot (octaaf), vastgelegd bij de pitch-set.
- **Amp-envelope per stem** (de KS heeft z'n eigen decay, een wavetable niet):
  lineaire attack/release op gate aan/uit.
- Per stem een exciter-keuze KS / wavetable; demo laat beide horen.
- Signaalpad blijft: exciter → MS-20 (per stem) → mix → PT8211.

### Later (niet nu)
- Meer golfvormen + morphing (crossfade tussen twee tabellen, 1 extra mult).
- DDR3 voor grote wavetable-banken (Gowin DDR3-IP).
- Modale bank uit `mass_spring_resonator.v` (64–128 modes op de gedeelde MAC).
- Fractional tuning (allpass in de KS-lus) — vóór serieus polyfoon stemwerk.
- Ladder-filter als tweede filtermode; PLL 108 MHz voor 16–32 stemmen.

## Budget-check (na stap 2, verwacht)
| Resource | schatting |
|---|---|
| BSRAM | KS 16 + tanh 2 + note/phinc 2 + wavetable 16 ≈ 36/46 |
| DSP | ~10–14/24 (gedeelde kern + 1 lerp + 1 amp) |
| Cycles/tick | ~120 van 562 |
