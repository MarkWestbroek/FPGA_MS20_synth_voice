# SPI-slotmap FPGA-voice (voorstel v1)

Voorstel voor de "final slot map" die MusicBrain ADR 0013 als open question
markeert. Dit is wat de FPGA (tag `0.3-wavetable`+) **implementeert**; de
brain-kant moet dit overnemen in ADR 0013 / de editor-adressering.

Frame-protocol: MusicBrain spi-frame v1 (`doc/protocols/spi-frame.md`).
De FPGA kijkt alleen naar het lage byte van `channel` (= slotId); CS
selecteert het board, caseId is voor de bridge.

## CvSet (0x10) — slotId = voice·4 + param, voices 0..7

| param | betekenis | dCV-mapping (offset-binary u16, zie PITCH_CV.md) |
|---|---|---|
| 0 | pitch  | note = (code·120)>>16 — 0..10 V, 1 V/oct, 0 V = MIDI 0 |
| 1 | cutoff | g = code·2³ (Q12.20) → 0..~0.5 (lineair, v1) |
| 2 | reson  | k = 1.0 − code·2⁵, floor 0.125 (hoger CV = meer resonantie) |
| 3 | drive  | drive = 1.0 + code·2⁶ → 1.0..~5.0 |

Stem 0 = slots 0..3: backwards-compatible met de mono-versie.

**Voorstel-uitbreiding (nog niet geïmplementeerd): slots 32..39 =
exciter/morph per stem** — één CV die de exciter kiest én later de
wavetable-morph wordt:
`0x0000..0x3FFF` = Karplus-Strong (pluk), `0x4000..0xFFFF` = wavetable,
waarbij de positie binnen dat bereik later de morph-positie (saw→square→…)
aanstuurt. Modulair-idiomatisch: gewoon een extra CV-bestemming, geen nieuw
opcode of versie-bump nodig.

## GateSet (0x20) — slotId = voice (0..7)

`on`-byte: gate-niveau per stem. 0→1 flank = trigger (KS-pluk / WT-fase-reset);
de amp-envelope van de wavetable volgt het gate-niveau (attack 0,7 ms /
release 85 ms in de FPGA). Retrigger van een klinkende stem vereist dus
gate 0 → 1 (de voice-allocator van de brain doet note-off vóór hergebruik,
ADR 0011 — bevestigen).

## Nog niet ondersteund (bewust, v1)

- `CvSegment` (0x11): FPGA-side interpolatie komt later (ADR 0013 stelt dit
  ook pas nodig bij hoge stemaantallen); tot die tijd `CvSet`.
- `TriggerPulse` (0x21): GateSet volstaat voor de huidige exciters.
- `CvInRequest/Report`: n.v.t., instrument heeft geen CV-uitgangen.

## Pitch-afspraak (sluit ADR 0013 open question)

De regel in ADR 0013 "reference note 69, 256 LSB = 1 semitoon" is verouderd.
Geldend is doc/PITCH_CV.md (conform ADR 0014): dCV offset-binary, default-
range 0..10 V @ 1 V/oct met 0 V = MIDI-noot 0, dus `note = (code·120)>>16`
(≈546 LSB per semitoon). Brain moet deze map hanteren (of de range-config
meesturen zodra die bestaat).

## Elektrisch / timing

- SCLK ≤ ~4–5 MHz bij 27 MHz sys_clk (2-FF sync + flankdetectie; testbenches
  draaien 5 MHz). CS omkadert elk frame; CS hoog reset de parser.
- MISO is hi-Z buiten CS (deelbaar); Pong-respons wordt in de vólgende
  transactie uitgeklokt (eerst Ping-frame, dan 6 bytes lezen).
- SPI-pinnen op de Tang Primer 20K Dock: nog te kiezen (PMOD) — zie
  synth_top.cst, nu unconstrained.
