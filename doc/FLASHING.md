# Flashen naar de Tang Primer 20K

Stappenplan om het synth-ontwerp van simulatie naar het echte bord te brengen.
Doe het **incrementeel** — eerst een levensteken, dan pas audio.

## 0. Klok: 27 MHz (al geregeld)
Het onboard kristal van de Tang Primer 20K is **27 MHz** (niet 50 — dat was een
foutje uit een eerdere chat). `synth_top` heeft nu **default `SYS_CLK_HZ = 27_000_000`**,
dus native draaien werkt direct: de klokdeler rekent `27e6/48000` → sample-rate
~48.04 kHz (0.09% af, onhoorbaar). **Geen PLL nodig** voor first-light.

> De testbenches klokken op 50 MHz en overschrijven de parameter
> (`synth_top #(.SYS_CLK_HZ(50_000_000))`); de sim blijft dus exact 48 kHz.

**Optioneel — exact 50 MHz via PLL:** wil je hardware identiek aan de sim, maak dan
met de Gowin IP-wizard (Clock → rPLL) een `27 MHz → 50 MHz` PLL (params komen op
≈ IDIV=27, FBDIV=50, ODIV zodat VCO 400–1200 MHz), voed de PLL-uitgang als `sys_clk`
en laat `SYS_CLK_HZ` op 50 MHz. Niet nodig om te beginnen.

## 1. Pin-constraints (`.cst`)
[`src/synth_top.cst`](../src/synth_top.cst) is al ingevuld voor de eerste flash
(geverifieerd tegen het Sipeed PT8211-voorbeeld): **`sys_clk`=H11** (27 MHz),
**`sys_rst_n`=T3** (knop), **`led`=L16**. De SPI- en PT8211-audiopinnen staan er
als commentaar bij en worden later geactiveerd. `spi_*`/`demo_mode`/`audio_out`
mogen tijdens de LED-test unconstrained blijven (Gowin plaatst ze automatisch).

## 2. Bitstream bouwen (Gowin EDA)
- Project: `MS20_Synth_Voice.gprj`, top = `synth_top`.
- Zorg dat de testbenches op `enable="0"` staan (al zo) en de `.cst`/`.hex`
  (`tanh_table.hex`, `note_period.hex`) gevonden worden vanuit de projectroot.
- Timing: `src/synth_top.sdc` definieert `sys_clk` op 27 MHz (`create_clock`,
  periode 37.037 ns). Lost de P&R-warning *"'sys_clk' ... not created" (TA1132)* op.
- **Synthesize → Place & Route** → genereert `*.fs` (de bitstream) in `impl/pnr/`.

## 3. Flashen
Twee tools werken voor de Tang Primer 20K (GW2A-18C):

- **Gowin Programmer** (GUI, hoort bij Gowin EDA): kies de `.fs`, target SRAM of
  embedded flash.
- **openFPGALoader** (open source, CLI):
  ```bash
  # vluchtig (verdwijnt na power-cycle) — snel testen:
  openFPGALoader -b tangprimer20k impl/pnr/MS20_Synth_Voice.fs
  # persistent in flash:
  openFPGALoader -b tangprimer20k -f impl/pnr/MS20_Synth_Voice.fs
  ```

## 4. Bring-up volgorde (van simpel naar audio)
1. **LED-heartbeat**: `led` knippert nu met ~0.8 Hz (een teller op `sys_clk`).
   Knippert de LED rustig, dan draaien klok + bitstream — het allereerste doel.
2. **demo_mode = 1**: de interne sequencer speelt — meet `audio_out`/I2S of zie de
   LED bewegen. Bewijst dat KS + filter op hardware draaien.
3. **SPI-levensteken**: stuur vanaf de brain een `Ping`; controleer dat de FPGA
   `Pong` (`A5 01 01 00 D6 F2`) op MISO teruggeeft. Bewijst de SPI-link.
4. **demo_mode = 0**: stuur CvSet/GateSet vanaf de brain → noten/filter via SPI
   (zie [PITCH_CV.md](PITCH_CV.md) voor de getallen-afspraak).
5. **Audio uit** (Fase 3): `pt8211_tx.v` → **onboard PT8211 stereo-DAC** (HP_BCK=N15,
   HP_WS=P16, HP_DIN=P15, PA_EN=R16) → 3.5mm jack. Geen externe DAC nodig.
   Vereist een kleine PLL (27→6.144 MHz) + /4 → 1.536 MHz bit-clock (Gowin IP-wizard).

## Tips
- De huidige `audio_out` is een 32-bit bus voor simulatie. Voor echt geluid komt
  `pt8211_tx.v` ertussen (Fase 3) → de onboard PT8211 — pas dan zijn die audio-pinnen nodig.
- Begin met SRAM-flashen (snel, niet-persistent) tijdens het debuggen; schrijf pas
  naar embedded flash als het werkt.
