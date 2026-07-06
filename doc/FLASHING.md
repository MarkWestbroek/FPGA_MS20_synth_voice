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

> **⚠ Bekende situatie op dit bord (2026-07-06):** SRAM-programmeren via JTAG
> komt niet meer door de wakeup (User Code blijft 0x00000000, status 0x20) —
> voor zowel oude als nieuwe bitstreams, GUI én CLI, elke frequentie. Booten
> uit de externe flash werkt wél altijd. **De betrouwbare route is dus: de
> externe flash schrijven via boundary-scan en power-cyclen.** Symptoom van
> het probleem: "User code mismatch" + de oude demo blijft spelen (de FPGA
> valt na elke mislukte JTAG-load terug op de flash-image).

**Werkend recept (headless, zonder GUI — sluit IDE/Programmer eerst):**
```powershell
# bouwen (vanuit projectroot):
& "C:\Gowin\Gowin_V1.9.12.02_SP2_x64\IDE\bin\gw_sh.exe" build.tcl
#   build.tcl = twee regels: open_project <pad>.gprj  /  run all

# flash schrijven via boundary-scan (~7,5 min) + daarna USB power-cycle:
& "C:\Gowin\Gowin_V1.9.12.02_SP2_x64\Programmer\bin\programmer_cli.exe" `
    --device GW2A-18C --run 12 `
    --fsFile "E:\Dev\Gowin\MS20_synth_voice\impl\pnr\MS20_Synth_Voice.fs" `
    --spiaddr 0x000000 --location 625
```
(`--run 12` = "exFlash Erase,Program in bscan" — heeft géén werkende
SRAM-configuratie nodig. `--location` = USB-locatie uit `--scan-cables`.
Een write die in ~5 s "klaar" is, is NIET gelukt; een echte duurt minuten.)

Alternatieven (werkten hier tot 2026-07-05, nu niet meer voor SRAM):
- **Gowin Programmer** (GUI): SRAM Program / External Flash Mode.
- **openFPGALoader** (niet geïnstalleerd; vereist WinUSB-driver via Zadig,
  wat de Gowin-tools blokkeert tot je de driver terugzet):
  ```bash
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
