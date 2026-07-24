# Convolution reverb — ontwerp (Fase D+, Arty S7-50)

Echte ruimtes via impulse-response-bestanden (IR-WAV's; OpenAIR, EchoThief,
eigen metingen). Dit doc legt de architectuur en de getallen vast; het
golden model staat in `scripts/conv_golden.py`.

## Waarom niet direct (FIR)

4 s IR @48 kHz = 192.000 taps → 9,2 GMAC/s per kanaal én ~19 GB/s aan
coëfficiënten-verkeer. DDR3 levert ~1,3 GB/s. Einde verhaal.

## Architectuur: uniform gepartitioneerde overlap-save

Klassieke frequency-delay-line (FDL):

```
in ──[blok 1024]──FFT2048──►  X[k] ──► FDL: X_0 X_1 … X_93   (DDR3)
                                          │   │       │
                             IR-spectra:  H_0 H_1 …  H_93     (DDR3)
                                          ▼   ▼       ▼
                              acc[bin] = Σ  X_i · H_i         (complex MAC)
                                          │
out ◄──[blok 1024]◄─IFFT2048◄─────────────┘   (2e helft = geldige samples)
```

- **Blok B = 1024** samples (21,3 ms), FFT-lengte 2N = 2048.
- IR ≤ 4 s → **94 partities** van 1024.
- Per blok: 1 FFT + 94×1025 complexe MAC's + 1 IFFT.

## De getallen (per blok van 21,3 ms)

| Post | Waarde | Budget |
|---|---|---|
| Complexe MAC's | 94×1025 ≈ 96k → 4,5 M cmult/s ≈ **18 MMAC/s** | 120 DSP's @100 MHz = 12 GMAC/s → verwaarloosbaar |
| FFT+IFFT | 2×11×1024 butterflies ≈ 22,5k → ~1,1 M bfly/s | 1 butterfly/cyclus streaming-FFT: ruim |
| DDR3-lezen | (X- + H-spectra) 94×1025×8 B ×2 ≈ 1,5 MB → **~72 MB/s** | ~1,3 GB/s → 6% |
| DDR3-schrijven | 1 nieuw X-spectrum ≈ 8 kB → verwaarloosbaar | |
| IR-opslag | 94×1025×8 B ≈ 0,77 MB per 4s-IR | 256 MB: honderden IR's resident |
| Latency | 1 blok ≈ **21 ms** | prima voor een galm-send; later non-uniform partities |

## Fixed-point-plan

- Datapad **18 bit** per re/im (DSP-vriendelijk, 2×18b = 4 B per bin in DDR3).
- FFT met **block-floating-point**: per stage een gezamenlijke exponent-shift
  bij overflow-gevaar (teller bijhouden, aan het eind compenseren). Dit houdt
  de SNR ver boven de 16-bit DAC.
- Accumulator per bin: 48 bit (DSP48-accumulator native) over de 94 partities.
- Golden model simuleert deze kwantisatie exact → RTL-verificatie wordt
  "vergelijk tegen golden", zoals bij de SVF-pijplijn.

## Bouwvolgorde

1. [x] Golden model (`scripts/conv_golden.py`): float-referentie vs
       gekwantiseerd model, SNR-rapport, synthetische IR + echte IR-WAV.
2. [ ] `fft2048.v` — iteratieve radix-2 streaming-FFT, BRAM ping-pong,
       block-floating-point; tb vergelijkt tegen numpy (via hex-vectoren).
3. [ ] Spectrale MAC + FDL-beheer met gedrags-DDR3 (zelfde poort-interface
       als de MIG-wrapper van Fase C2 — één abstractie voor beide).
4. [ ] Overlap-save rondmaken: impuls door synthetische IR = de IR zelf
       (bit-exact vs golden) — hét integratiebewijs.
5. [ ] IR-upload: SPI-opcode (Cortex) of UART-loader (PC) → DDR3; on-the-fly
       FFT van de partities bij laden (hergebruik fft2048).
6. [ ] In synth_top achter `FX_CONV`-generate, als derde send.

## Modulariteit / losse hardware (vooruitblik)

Alle FX hangen achter `generate`-parameters (`FX_ECHO`, `FX_REVERB`, straks
`FX_CONV`) → per bord kies je een bitstream-variant:

- **Arty S7-50**: alles aan (dev-platform, DDR3 voor conv + lange echo C2).
- **Tang Primer 20K**: synth zoals nu (9/46 BSRAM vrij → hooguit een
  ~130 ms slapback-variant van tape_echo, MAX_LOG2=12).
- **Tang Nano 20K (~€30, Teensy-formaat)**: FX-only build als losse
  Cortex-effectmodule — zónder de 8 stemmen is er BSRAM zat voor echo+FDN,
  en de **8 MB on-die PSRAM** (~300 MB/s) kan een lange echoband én
  IR-spectra hosten: conv tot ~2 s IR is daar realistisch. Vereist een
  Gowin-poort van de FFT (geen Xilinx-IP gebruiken → eigen fft2048.v is
  bewust vendor-neutraal).
