# dCV-conventie (FPGA = type-1 MMB-module)

Gedeelde afspraak tussen de **brain** (MusicBrain, SPI-master) en deze **FPGA**
(SPI-slave instrument). Kernprincipe: **het dCV-protocol is uniform — of een module
analoog of digitaal is, maakt niet uit.** De FPGA is een *type-1* MMB-module
(eigen module die het protocol snapt), uitwisselbaar met analoge modules. Hij
*emuleert* digitaal wat een analoge module + zijn DAC + VCO zouden doen.

> Zie MusicBrain [ADR 0013](https://github.com/MarkWestbroek/MusicBrain/blob/main/doc/adr/0013-fpga-synth-instrument.md)
> (FPGA als instrument) en [ADR 0014](https://github.com/MarkWestbroek/MusicBrain/blob/main/doc/adr/0014-pitch-formats-and-cv-ranges.md)
> (pitch-formaten & ranges).

## dCV-codeconventie (16-bit)
Eén afspraak voor álle CV's, geleverd via het MusicBrain-frame (`CvSet`, opcode 0x10):

- **16-bit, offset-binary, full-scale = 2¹⁶**:
  `0x0000` = onderkant van de range, `0xFFFF` = één LSB onder de bovenkant.
  `value = code / 65536 · (Vmax − Vmin) + Vmin`.
- Full-scale 2¹⁶ (niet /65535) → de code↔waarde-rekensom is een pure macht-van-2
  (multiply + bit-shift, geen afronding), en matcht hoe de echte 16-bit DAC
  (AD5754R) werkt: de maximale code zit één LSB onder full-scale.
- Werkt uniform voor unipolair (0–10V: `0x0000`=0V) én bipolair (±10V:
  `0x8000`=0V).

De **range** (0–5 / 0–10 / 0–10.8 / ±5 / ±10 / ±10.8 V) en het **pitch-type**
(1 V/oct, 1.2 V/oct, Hz/V) zijn per-uitgang config (ADR 0014). Brain en module
gebruiken dezelfde instelling.

## Pitch: van dCV-code naar toonhoogte
De FPGA emuleert "DAC(code, range) → VCO(spanning, wet) → frequentie". Default-config
voor dit instrument:

- **Range 0–10 V, type 1 V/oct, 0 V = MIDI-noot 0** (= C-1 ≈ 8.18 Hz). Dit is de
  gangbare afspraak voor 0–10V-converters. 0–10 V = 10 octaven = MIDI 0..120.
- Mooie eigenschap: bij V/oct is de code **lineair** in semitonen (spanning lineair
  in de code, semitonen lineair in spanning). Dus geen exponentiële som nodig:

  ```
  note = (code · 120) >> 16        // 0..119, lineair over 10 octaven
  ```
  De enige exponentiële stap (semitoon → frequentie → period) zit in de
  `note_to_period` BRAM-LUT (`gen_tables.py` → `note_period.hex`).

Een code voor een doelnoot N kies je in het **midden van de bin** (≈546 codes per
noot): `code = round((N + 0.5)·65536/120)`. Bijv. MIDI-noot 33 (A1) → `18295`
(`0x4777`). (Let op: `round(N·65536/120)` kan door de `>>16`-floor net in bin N−1
vallen — vandaar het bin-midden.)

### Beperking onderaan (KS-delaylijn)
De Karplus-Strong delaylijn is 2048 diep, dus de laagste ~2 octaven (onder ±MIDI 26,
period > 2047) clampen op dezelfde period. Voor bas vanaf ±E1 is dat geen probleem;
voor de allerlaagste tonen moet de delaylijn later groter (of een andere oscillator).

## Param-CV's (cutoff/reson/drive)
Volgen dezelfde 16-bit offset-binary conventie (`0x0000`=min … `0xFFFF`=max van hun
betekenis). De exacte schaling naar de Q12.20 filterparameters wordt nog afgestemd
met de brain (nu voorlopige shifts in `synth_top.v`).

## Status
Vastgelegd aan FPGA-zijde in [`src/synth_top.v`](../src/synth_top.v). De brain moet
voor pitch naar dit instrument dezelfde code↔noot-afbeelding hanteren (0–10V, 1 V/oct,
0V = MIDI 0).
