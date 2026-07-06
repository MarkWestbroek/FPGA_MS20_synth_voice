# Het slot-contract van de FPGA-voice (v2)

De brain praat met de FPGA via het MusicBrain frame-protocol
(`doc/protocols/spi-frame.md` in de MusicBrain-repo). In elk CvSet-frame zit
één adresbyte: het **slot** — zie het als een genummerde CV-ingang op de
module. Dit document is het contract: welke betekenis elk nummer heeft.

De FPGA is één 8-stemmige module ("MS20 poly voice") achter zijn eigen
chip-select. De brain hoeft dus alleen dit contract te kennen; hoe-veel-stemmig
de module is (8) hoort thuis in de module-definitie in de MusicBrain-catalog.

## Hoe het adres is opgebouwd

Elke **per-stem parameter krijgt een blok van 8 opeenvolgende slots**, één per
stem. Het slot voor "parameter X van stem V" is dus: *beginnummer van blok X,
plus V*. Dit sluit aan op hoe de brain één kabel in de editor uitwaaiert naar
N stemmen (MusicBrain ADR 0010: stem v krijgt beginnummer + v).

## CvSet (opcode 0x10) — de CV-ingangen

Waarden zijn dCV: u16 offset-binary, 0x0000 = onderkant van de range,
0xFFFF = bovenkant (zie doc/PITCH_CV.md).

| Slots | Parameter (per stem 0..7) | Betekenis van de waarde |
|---|---|---|
| 0–7   | **pitch**  | 0..10 V @ 1 V/oct, 0 V = MIDI-noot 0 → `note = (code·120)>>16` |
| 8–15  | **cutoff** | lineair naar filter-g, 0..~0.5 (v1-mapping) |
| 16–23 | **resonantie** | hoger = meer resonantie (k = 1.0 − code·2⁵, floor 0.125) |
| 24–31 | **drive**  | tanh-drive 1.0..~5.0 (1.0 + code·2⁶) |
| 32–39 | **exciter/morph** | < 0x4000 = Karplus-Strong-pluk; ≥ 0x4000 = wavetable. Binnen het wavetable-bereik kiest de waarde de golfvorm (nu: < 0xA000 saw, ≥ 0xA000 square); wordt later de glijdende morph-positie. |
| 40–47 | *gereserveerd* | per-stem expressie (pressure/velocity — Osmose/MPE), nog niet geïmplementeerd |

Per-noot pitchbend heeft geen eigen slot nodig: pitch is al een continue CV
per stem — de brain moduleert gewoon het pitch-slot.

## Globale controls ("de knoppen van het paneel")

Eén slot per control, vanaf slot 48. De brain "draait aan een knop" door een
CvSet naar dat slot te sturen (het ControllerBreakIn-mechanisme uit ADR 0009).

| Slot | Control | Betekenis |
|---|---|---|
| 48 | **snaar-damping** | uitsterftijd van de KS-pluk: 0x0000 = kort plukje (~0.996/omloop), 0xFFFF = bijna oneindige sustain. Default ≈ 2,9 s decay. |
| 49+ | *vrij* | toekomstige globale instellingen |

## GateSet (opcode 0x20) — gate per stem

Slot = stemnummer (0..7). De aan/uit-byte is het gate-niveau. Een 0→1-flank
triggert de stem (KS: nieuwe pluk; wavetable: fase-reset). De amp-envelope van
de wavetable volgt het gate-niveau (attack 0,7 ms / release 85 ms). Let op:
een klinkende stem opnieuw aanslaan vereist gate 0 → 1 — de voice-allocator
moet dus note-off sturen vóór hij een stem hergebruikt.

## Niet (of nog niet) ondersteund

- `CvSegment` (0x11): FPGA-side interpolatie — later, bij hoge update-rates
  (per-stem expressie); tot die tijd volstaat CvSet (ADR 0013).
- `TriggerPulse` (0x21): GateSet volstaat.
- `CvInRequest/Report`: n.v.t. — de module heeft geen CV-uitgangen.
- Status/display richting brain: hoort bij de "management messages"-laag die
  MusicBrain (ADR 0009) nog moet definiëren. `Ping`→`Pong` werkt al.

## Elektrisch / timing

- SCLK ≤ ~4–5 MHz bij 27 MHz sys_clk (testbenches draaien 5 MHz).
- CS omkadert elk frame; CS hoog reset de parser. MISO is hi-Z buiten CS.
- Pong wordt in de transactie ná de Ping uitgeklokt (6 bytes lezen).
- SPI-pinnen op de Tang Primer 20K Dock: nog te kiezen (PMOD; unconstrained
  in synth_top.cst).

## Nog vast te leggen aan de brain-kant

1. Deze slotmap overnemen in de catalog (`ModuleDefinition`: poorten met
   eventKind voice/global, voiceCount 8) en in ADR 0013 (sluit de twee open
   questions: slotmap + pitch-schaal).
2. Bevestigen dat de voice-allocator gate-off stuurt vóór stem-hergebruik.
3. Een tweede module in dezelfde FPGA (bijv. een resonator-bank) krijgt later
   gewoon een eigen blok, beginnend bij slot 128.
