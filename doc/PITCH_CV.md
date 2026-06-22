# Pitch- en parameter-CV conventie (FPGA-instrument)

Gedeelde afspraak tussen de **brain** (MusicBrain, SPI-master) en deze **FPGA**
(SPI-slave instrument). De brain en de FPGA moeten exact dezelfde getallen
hanteren, anders speelt de FPGA de verkeerde toonhoogte / filterstand.

> **Belangrijk:** de FPGA is een *digitaal* instrument. De analoge pitch-standaarden
> uit MusicBrain [ADR 0014](https://github.com/MarkWestbroek/MusicBrain/blob/main/doc/adr/0014-pitch-formats-and-cv-ranges.md)
> (1 V/oct, 1.2 V/oct, **Hz/V**, **S-Trig**) gelden voor de *analoge* DAC-uitgangen
> (AD5754R) die echte modules zoals de Korg MS-20 aansturen. Ze gelden **niet** voor
> de FPGA: die werkt intern in noot/semitoon-ruimte. De FPGA heeft alleen een
> lineaire ("V/oct-achtige") afbeelding `i16 → semitoon` nodig.

## Transport
Alle CV's komen binnen via het MusicBrain SPI-frame (`CvSet`, opcode 0x10):
`i16 value`, `−32768..+32767`. Het lage byte van `channel` is de slot (de
chip-select selecteert dit board al).

## Slot-map (huidig, mono — uitbreidbaar per stem)
| slot | opcode | betekenis | FPGA-mapping |
|---|---|---|---|
| 0 | CvSet | pitch | `note = 69 + value/256`, geclampt 0..127 → KS-period (LUT) |
| 1 | CvSet | cutoff | `g = value << 3` (Q12.20), value ≤ 0 → 0 |
| 2 | CvSet | resonance | `k = 1.0 − (value<<5)`, floor 0.125 (hoger CV = meer resonantie) |
| 3 | CvSet | drive | `drive = 1.0 + (value<<6)` (Q12.20) |
| 0 | GateSet (0x20) | gate | gate + trigger-puls bij 0→1 |

## Pitch (de belangrijkste afspraak)
**Digitale V/oct:** lineair in semitonen, geen Hz/V.
- **256 LSB = 1 semitoon** (een octaaf = 3072 LSB).
- **Referentie: noot 69 (A4 = 440 Hz) bij CV = 0.**
- `note = 69 + (value / 256)` → `value = (note − 69) · 256`.
- Bereik: ±32767 ≈ ±128 semitonen (ruim 10 octaven); geclampt op MIDI 0..127.
- De FPGA gebruikt nu alleen het hele-semitoon-deel (de `note_to_period` LUT is
  per MIDI-noot). De onderste 8 bits (fractie) zijn gereserveerd voor latere
  glide/pitch-bend/microtuning.

Voorbeeld: noot 33 (A1) → `value = (33−69)·256 = −9216` (`0xDC00`).

## Param-CV's (cutoff/reson/drive)
Voorlopige lineaire shifts (zie tabel). Deze schaling mag nog verfijnd worden;
leg de definitieve keuze hier vast zodra de brain ze gaat sturen.

## Status
Vastgelegd aan FPGA-zijde in [`src/synth_top.v`](../src/synth_top.v). De brain moet
dezelfde `value = (note−69)·256` hanteren voor pitch naar dit instrument.
