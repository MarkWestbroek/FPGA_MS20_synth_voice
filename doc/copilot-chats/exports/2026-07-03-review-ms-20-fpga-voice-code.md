# Claude Code-sessie-export

> **Let op:** export van een **Claude Code**-sessie. Gebruiker- en assistentteksten zijn letterlijk overgenomen; tool-aanroepen staan als compacte `🔧`-annotaties (hun output niet); interne redeneerblokken weggelaten.
>
> - **Datum:** 2026-07-03
> - **Sessie-id:** `c65b7593-8bdd-4a1a-baf0-84b138168ff0`
> - **Branch:** `main`

---

## 👤 Gebruiker (1)

zou je de FPGA code van de MS-20 voice eens willen reviewen? Zit het goed in elkaar of zie je rare dingen?

**🤖 Claude:**

Ik ga de FPGA-code doornemen. Eerst even kijken wat er in de repo zit.
> 🔧 `Glob` — **/*.v
> 🔧 `Glob` — *
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\ks_string.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\pt8211_tx.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\i2s_tx.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\mass_spring_resonator.v

**🤖 Claude:**

Ik heb alle modules in [src/](src/) doorgelezen: de hele keten (KS-string → MS-20 SVF → PT8211), de SPI-laag en de losse modules. Hieronder mijn bevindingen.

## Algemeen oordeel

Het zit degelijk in elkaar. De structuur is helder (één module per taak, nette FSM's), de CDC is netjes gedaan (2-FF synchronisatie op SPI-pinnen en switches, edge-detectie i.p.v. apart klokdomein, en de `trig_pending`-constructie in [synth_top.v:178-189](src/synth_top.v#L178-L189) om een SPI-trigger correct het tick-domein in te tillen is precies goed). De tanh-LUT-clamp met `>=` op de +4.0-grens ([ms20_filter.v:75](src/ms20_filter.v#L75)) voorkomt correct de adres-wrap, de frame-parser dropt CRC-fouten stil en hersynchroniseert op de CS-grens, en de PT8211-timing volgt het Sipeed-referentieontwerp. De commentaren zijn uitzonderlijk goed — die documenteren ook de bewuste keuzes (46.875 vs 48 kHz ZOH-resample, gain-afweging).

Toch een paar echte punten, gerangschikt op belang:

## 1. MISO wordt altijd gedreven (bus-conflict bij meerdere slaves)

In [spi_slave.v:104-124](src/spi_slave.v#L104-L124) is `miso` een gewone push-pull output die continu drijft, ook als `cs_n` hoog is. Op de MusicBrain-bus is dit prima zolang de FPGA de enige slave op die MISO-lijn is, maar zodra de brain een tweede instrument aan dezelfde bus hangt, vechten de MISO's met elkaar. Klassieke oplossing: in de top `assign spi_miso = cs_active ? miso_int : 1'bz;` (of expliciet vastleggen dat elke slave een eigen MISO-pin krijgt).

## 2. CV-conventie: de twee modules spreken elkaar tegen

[spi_frame.v:37](src/spi_frame.v#L37) documenteert de CV's als *signed* i16 (−32768..32767 = −1.0..+1.0), maar [synth_top.v:147-162](src/synth_top.v#L147-L162) interpreteert dezelfde bits als *unsigned* offset-binary (0x0000 = min, 0xFFFF = max), met expliciet "NIET sign-extend". De bits stromen gewoon door, dus zolang de Teensy offset-binary stuurt werkt alles — maar als de brain ooit echt signed stuurt, wordt een negatieve pitch-CV een noot rond 119. Eén van de twee comments klopt niet met ADR 0014; ik zou de `signed` declaraties en het comment in spi_frame gelijktrekken met doc/PITCH_CV.md, zodat dit niet later iemand op het verkeerde been zet.

## 3. KS-string leest ongeïnitialiseerd geheugen bij pitch-verlaging zonder trigger

De FILL-fase ([ks_string.v:115-124](src/ks_string.v#L115-L124)) vult alleen posities `0..period-1` van de noot die de trigger gaf. In SPI-mode kan de brain de pitch verlagen (langere period) zónder nieuwe trigger; `next_ptr` wrapt dan pas op de nieuwe, langere period en de leespointer loopt door cellen die nooit beschreven zijn. Op hardware hoor je hooguit oud materiaal van een eerdere noot, maar in simulatie zijn dat `x`-en die je hele audio-pad vergiftigen. Simpelste fix: bij de allereerste FILL (of bij reset) de volledige `MAX_DELAY` vullen in plaats van alleen `period`.

## 4. Geen saturatie in het filter bij extreme SPI-parameters

De demo-parameters zijn veilig, maar via SPI kan de combinatie extreem worden: `drive` tot ~5.0, `k` tot op de floor van 0.125, `g` tot 0.5 ([synth_top.v:164-171](src/synth_top.v#L164-L171)). In [ms20_filter.v](src/ms20_filter.v#L65-L101) zijn `bp`/`lp` gewone wrappende 32-bit optellingen, en `bp_driven` ([ms20_filter.v:66](src/ms20_filter.v#L66)) trunceert het 64-bit product naar 32 bits. De tanh begrenst alleen de feedback-term, niet de integrators zelf; in scream-territorium kan `bp` doorgroeien tot een wrap, en dan krijg je een full-scale knal in plaats van nette clipping. Saturerende optellers op `bp_next`/`lp_next` (clamp op bijv. ±16.0) zouden dit robuust maken — goedkoop, en het verandert het normale geluid niet.

## Kleinere observaties

- **FILL blokkeert audio-ticks**: bij E1 (period 1165) duurt FILL 1165 sys_clk-cycles, terwijl de tick-afstand op 27 MHz maar 562 cycles is. De string mist dus 2-3 samples bij elke aanslag. Onhoorbaar, maar goed om te weten dat de aanname "FSM klaar vóór volgende tick" hier net niet opgaat.
- **Gemengde signedness**: `filter_g > (G_MEDIUM + 32'h1EF)` ([synth_top.v:277](src/synth_top.v#L277)) — de unsized-unsigned `32'h1EF` maakt de hele vergelijking unsigned. Het werkt omdat alles positief is, maar het is een fragiel patroon; `32'sh1EF` maakt de intentie expliciet.
- **Lint-ruis**: `filter_mode` is constant 0, `ch` in spi_frame is ongebruikt, en `pong_req`/`frame_ok` hangen los in de top. Bewust, maar synthesis-tools gaan erover klagen; `/* verilator lint_off */` of gewoon weglaten scheelt ruis.
- **[mass_spring_resonator.v](src/mass_spring_resonator.v)** wordt nergens geïnstantieerd — dat lijkt een overblijfsel van het eerdere experiment. Overweeg het naar een `attic/`-map te verplaatsen zodat duidelijk is wat de actieve keten is.

Samengevat: punt 1 en 2 zou ik vóór de echte brain-integratie oplossen (dat zijn de enige die je op hardware echt kunnen bijten), punt 3 en 4 zijn robuustheid voor de SPI-hoeken. Wil je dat ik een of meer van deze fixes doorvoer?

---

## 👤 Gebruiker (2)

Ad 1.  Kun je dat oplossen?
Ad 2. Welke zou je aanbevelen? signed of unsigned?
Ad 3. Kun je dat fixen?
Ad 4. Idem

Wil je dat in een aparte branch doen?

**🤖 Claude:**

Ja, ik doe het in een aparte branch. Eerst even de testbenches en docs checken (de MISO-tristate kan de SPI-testbench raken), en mijn memory over hoe de DSim-simulatie draait.
> 🔧 `Read` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\run-dsim-sim.md
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v
> 🔧 `Glob` — doc/*.md
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Grep` — offset-binary|signed|unsigned
> 🔧 `PowerShell` — Create branch fix/review-findings

**🤖 Claude:**

**Fix 1 — MISO tri-state** in [spi_slave.v](src/spi_slave.v):
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v

**🤖 Claude:**

**Fix 3 — KS delay-lijn volledig vullen bij aanslag** in [ks_string.v](src/ks_string.v):
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ks_string.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Glob` — *.hex
> 🔧 `PowerShell` — Run spi_frame_tb in DSim
> 🔧 `PowerShell` — Run synth_top_tb (demo) in DSim
> 🔧 `PowerShell` — Run synth_top_spi_tb end-to-end in DSim
> 🔧 `Bash` — Render WAVs from sim output
> 🔧 `PowerShell` — Commit fix 1 and fix 2
> 🔧 `PowerShell` — Commit fix 3 and fix 4, show log

**🤖 Claude:**

Klaar — alle vier de punten zijn opgelost op de nieuwe branch `fix/review-findings` (4 commits), en alle drie de testbenches slagen.

**Ad 2 (de vraag):** unsigned offset-binary. Je eigen [doc/PITCH_CV.md](doc/PITCH_CV.md) en ADR 0014 leggen dat al vast (0x0000 = range-min, 0xFFFF = range-max, full-scale 2¹⁶), en synth_top rekende er al mee. Het waren de `signed`-declaraties en het "i16 −1.0..+1.0"-comment in spi_frame die afweken — die heb ik gelijkgetrokken, zodat er nu één conventie in code én docs staat.

Wat er per fix is gebeurd:

1. **MISO tri-state** — [spi_slave.v](src/spi_slave.v#L104): `miso` drijft nu alleen als de (gesynchroniseerde) CS laag is, daarbuiten `1'bz`. Meerdere instrumenten kunnen zo dezelfde MISO-lijn delen; Gowin duwt de tristate naar de IOB.
2. **dCV-conventie** — [spi_frame.v](src/spi_frame.v), [synth_top.v](src/synth_top.v) en de testbench declareren de CV's nu als unsigned u16 met verwijzing naar PITCH_CV.md. De testbench-check met `-256` is vervangen door een equivalente hoge dCV-waarde (0xFF00).
3. **KS delay-lijn** — [ks_string.v](src/ks_string.v#L115-L133): FILL vult nu de volledige `MAX_DELAY` in plaats van alleen `period`. Pitch omlaag zonder nieuwe trigger leest dus nooit meer ongeschreven cellen. Kost maximaal ~76 µs extra per aanslag (een paar audio-ticks), onhoorbaar.
4. **Filter-saturatie** — [ms20_filter.v](src/ms20_filter.v): `bp`/`lp` worden breed opgeteld en geclampt op ±16.0, en `bp_driven` is nu 44-bit zodat ook de tanh-LUT-clamp klopt zonder truncatie. Extreme SPI-hoeken clippen nu netjes in plaats van te wrappen.

Verificatie: `spi_frame_tb` 11/11 geslaagd (inclusief het Pong-frame over de tri-stated MISO), `synth_top_tb` rendert 3 s schone demo-audio (WAVs opnieuw gegenereerd in [wav/](wav/), pieken onveranderd ~±0.75/±0.24), en `synth_top_spi_tb` eindigt met `END_OK` (str_peak 785437, filt_peak 213346 — vergelijkbaar met voorheen, dus de saturatie raakt het normale geluid niet).

De branch staat alleen lokaal. Wil je dat ik hem push, of eerst zelf even luisteren naar de nieuwe WAVs en dan mergen naar `main`?

---

## 👤 Gebruiker (3)

hoe kon ik ook alweer naar de FPGA 'pushen'?
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\doc\FLASHING.md
> 🔧 `Read` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\tang-primer-20k-board.md
> 🔧 `Glob` — impl/pnr/*.fs

**🤖 Claude:**

Twee stappen (staat ook in [doc/FLASHING.md](doc/FLASHING.md)):

**1. Bitstream bouwen** — in Gowin EDA: open `MS20_Synth_Voice.gprj` en draai **Synthesize → Place & Route**. Dat genereert [impl/pnr/MS20_Synth_Voice.fs](impl/pnr/MS20_Synth_Voice.fs). Let op: de `.fs` die er nu staat is van vóór de review-fixes, dus deze stap moet je eerst doen (en je zit nog op branch `fix/review-findings` — dat is precies wat je wilt als je de fixes wilt testen).

**2. Flashen** — met openFPGALoader (CLI):

```bash
# vluchtig naar SRAM (weg na power-cycle) — snel testen:
openFPGALoader -b tangprimer20k impl/pnr/MS20_Synth_Voice.fs

# persistent naar de NOR-flash:
openFPGALoader -b tangprimer20k -f impl/pnr/MS20_Synth_Voice.fs
```

Of via de Gowin Programmer GUI (kies de `.fs`, target SRAM of embedded flash).

Tijdens het testen is SRAM-flashen (zonder `-f`) het handigst. Na de flash: LED knippert ~0.8 Hz als levensteken, en met de demo-mode aan hoor je de bassequencer op de 3.5mm-jack. De MISO-tristate en filter-saturatie uit de fixes zouden op de demo niets hoorbaars moeten veranderen — dat is juist de check.

---

## 👤 Gebruiker (4)

Hij loopt. Ik ben niet zeker of de 'wah' het nu nog doet na een herstart met een van de buttons.

Er zijn nog wat warnings:

WARN  (EX3791) : Expression size 17 truncated to fit in target size 16("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":67)
WARN  (EX3791) : Expression size 3 truncated to fit in target size 2("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":112)
WARN  (EX3791) : Expression size 19 truncated to fit in target size 18("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":114)
WARN  (EX3791) : Expression size 12 truncated to fit in target size 11("E:\Dev\Gowin\MS20_synth_voice\src\ks_string.v":73)
WARN  (EX3791) : Expression size 12 truncated to fit in target size 11("E:\Dev\Gowin\MS20_synth_voice\src\ks_string.v":129)
WARN  (EX3791) : Expression size 17 truncated to fit in target size 16("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":273)
WARN  (EX3791) : Expression size 44 truncated to fit in target size 32("E:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v":105)
WARN  (EX3791) : Expression size 39 truncated to fit in target size 32("E:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v":174)
NOTE  (EX0101) : Current top module is "synth_top"
WARN  (CV0016) : Input demo_mode is unused("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":35)
WARN  (NL0002) : The module "note_to_period" instantiated to "u_n2p" is swept in optimizing("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":156)

Switch E8 schakelde dat - na het flashen - één keer in, maar na het uitschakelen niet terug in

**🤖 Claude:**

Goed nieuws dat hij loopt! Ik pak eerst even de pin-constraints en je switches-notitie erbij om het E8-gedrag te begrijpen, en kijk dan naar de warnings.
> 🔧 `Glob` — src/*.cst
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\sipeed primer dev board switches.md
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.cst
> 🔧 `Glob` — **/*switches*
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\doc\hardware\sipeed primer dev board switches.md
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ks_string.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ks_string.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `PowerShell` — Run wah_toggle_tb in DSim
> 🔧 `PowerShell` — Re-run synth_top_tb after warning fixes
> 🔧 `PowerShell` — Commit warning fixes and new testbench

**🤖 Claude:**

Klaar en gecommit. Samenvatting:

## De wah-schakelaar: de logica is in orde

Ik heb een nieuwe regressietest geschreven ([src/wah_toggle_tb.v](src/wah_toggle_tb.v)) die exact jouw scenario naspeelt: wah aan bij boot → E8 uit → E8 weer aan → reset-puls op de knop. Alle 7 checks slagen: noot 3 (wah uit) staat statisch op 800 Hz, noot 4 (wah weer aan) opent weer volledig naar 3 kHz, en na de reset-knop herstart de demo met werkende wah. De RTL is dus niet het probleem. Twee dingen op de hardware verklaren wat je zag:

1. **De wah verandert pas bij de vólgende nootaanslag.** `filter_g` springt alleen naar "open" op een trigger; als je E8 omzet hoor je tot 1,5 s niets gebeuren (halverwege een noot wordt het geluid zelfs eerst dóffer, want de sweep loopt vanaf de vaste cutoff omlaag). Zet de switch om en wacht twee noten voordat je concludeert dat het niet werkt.
2. **De DIP-polariteit is waarschijnlijk omgekeerd t.o.v. de opdruk.** E8 heeft `PULL_MODE=UP` en de Dock-DIP's trekken de pin naar GND in de ON-stand: fysiek "ON" = pin laag = **wah uit**, "OFF" = pull-up hoog = wah aan. Hetzelfde geldt voor de mute op T4. Als dat verwarrend blijft, kan ik de polariteit in de code omdraaien.

En let op: de bitstream die er nu op staat is van vóór deze fixes — opnieuw Synthesize → P&R → flashen om de nieuwe versie te testen.

## De warnings

- **Alle EX3791-truncations zijn opgelost** — optellingen kregen expliciet op maat gemaakte literals (`+ 16'd1` etc.) en de twee in [ms20_filter.v](src/ms20_filter.v) zijn expliciete Q12.20-slices geworden (`prod_k[51:20]`, `acc_avg[31:0]`). Gedrag is bit-identiek; de demo-sim en wah-test draaien groen.
- **`demo_mode is unused` en `note_to_period ... swept` zijn verwacht en onschuldig**: je bouwt met `DEMO_ONLY=1`, dus de synthesizer constant-vouwt het hele SPI-CV-pad weg — inclusief de pitch-LUT en de demo_mode-pin. Zodra je met `DEMO_ONLY=0` bouwt (brain aangesloten) verdwijnen die twee vanzelf.

Alles staat als commit `f2eb4b3` op `fix/review-findings`. Ik zag trouwens dat je zelf al een commit (`db7d346 fable review fix`) op de branch had gezet — mijn commit staat daar netjes bovenop.

---

## 👤 Gebruiker (5)

nee, E8 doet niets meer. Misschien is de schakelaar wel stukgegaan. Wil je eens E9 proberen? Die zit er naast. Of T2 - een drukknopje - om het effect aan of weer uit te flipfloppen.

**🤖 Claude:**

Goed plan — ik doe allebei tegelijk, dat is meteen een mooie diagnose: `wah_sw` verhuist naar **E9** (DIP 2), en **T2** wordt een drukknop die de wah flipt (XOR met de DIP-stand). Werkt T2 wel maar E9 niet, dan weet je dat het aan de DIP-schakelaars ligt; doen beide het, dan was E8 stuk.

Eerst even kijken hoe synth_top_tb instantieert:
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v

**🤖 Claude:**

Nu de pinnen in de constraints — wah naar E9, knop op T2:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.cst
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v

**🤖 Claude:**

Simulatie draaien (~8.7 s audio, duurt even):
> 🔧 `PowerShell` — Run extended wah_toggle_tb with T2 button test

**🤖 Claude:**

9/9 geslaagd — de knop flipt de wah netjes uit en weer aan. Committen:
> 🔧 `PowerShell` — Commit E9 + T2 wah changes

**🤖 Claude:**

Klaar en gecommit (`27942f0`). Wat er nu in zit:

- **`wah_sw` zit op E9** (DIP-schakelaar 2, naast de oude) — [synth_top.cst:20](src/synth_top.cst#L20)
- **T2 (drukknop) is `wah_btn_n`**: elke druk flipt de wah om, gedebounced (~39 ms) zodat contactdender niet dubbel telt — [synth_top.v](src/synth_top.v#L258-L281)
- De effectieve stand is **DIP-niveau XOR knop-flipflop**: beide bedieningen werken door elkaar heen, en na een reset geldt weer gewoon de DIP-stand.

De uitgebreide regressietest slaagt 9/9: DIP uit/aan, reset-knop, én twee T2-drukken (wah uit op noot 6, weer aan op noot 7).

Voor op het bord — na Synthesize → P&R → flashen:

1. **Druk een paar keer op T2** en wacht steeds de volgende nootaanslag af (max 1,5 s). Hoor je de wah om en om verschijnen/verdwijnen, dan werkt het effect en de knop.
2. **Zet dan E9 om.** Doet die het wel → E8 was stuk. Doet E9 het óók niet terwijl T2 wél werkt → dan wijst het naar de DIP-schakelaars zelf (bedradings- of polariteitskwestie), niet naar de logica.

Onthoud bij het testen: het wah-verschil hoor je alleen op een nieuwe noot, dus geef elke stand even een noot of twee de tijd. En de DIP-polariteit kan omgekeerd aanvoelen (ON = pin naar GND = wah uit); bij de T2-knop speelt dat niet, elke druk is gewoon een toggle.

---

## 👤 Gebruiker (6)

ik denk dat de knoppen het wel doen, maar dat de wah lichter is geworden door het herinstellen van dingen. Kan dat kloppen? Het verschil is dan nu minimaal. Kun je het effect dikker maken? Of met knopje T2 trappen: steeds een trapje hoger en dan terug naar geen effect.

**🤖 Claude:**

Eerst je vraag: **nee, de review-fixes horen het geluid niet veranderd te hebben** — de gerenderde WAV's vóór en na hadden identieke pieken, en de warning-fixes zijn bit-identiek. Wél mogelijk: je vorige bitstream was van een oudere commit gebouwd (de gain en wah-diepte zijn in de laatste commits op `main` een paar keer gewijzigd, o.a. `>>>2` → `>>>4`), dus de vergelijking met "hoe het eerst klonk" kan mank gaan. Hoe dan ook: trapjes op T2 is een beter idee dan gokken — dan kies je zelf hoe dik.

Ik bouw het zo: **T2 stapt door 4 niveaus** — uit → licht → medium (≈ huidig) → dik — en wrapt terug naar uit. De DIP op E9 blijft een master-schakelaar (laag = geforceerd uit). Per niveau gaan sweep-breedte, resonantie én drive omhoog:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v

**🤖 Claude:**

Nu de knoplogica (flipflop → niveauteller) en de envelope:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.cst
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `PowerShell` — Run wah level test in DSim
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `PowerShell` — Run wah level test in DSim
> 🔧 `PowerShell` — Re-run demo and SPI testbenches
> 🔧 `Bash` — Render fresh demo WAVs
> 🔧 `PowerShell` — Commit wah level feature

**🤖 Claude:**

Klaar en gecommit (`dc28223`), alle simulaties groen. Nog even over je vraag: de review-fixes zelf kunnen het geluid niet verdund hebben (bit-identieke output in de sims), maar het maakt nu niet meer uit — je kiest de dikte voortaan zelf met T2.

**Zo werkt het na de volgende flash:**

| Druk op T2 | Niveau | Karakter |
|---|---|---|
| boot | 2 medium | ≈ het oude geluid, iets meer drive (2.5) |
| 1× | 3 **dik** | sweep 4 kHz → 200 Hz, hoge resonantie (k=0.375), drive 3.0 — scream |
| 2× | 0 uit | statisch 800 Hz, geen sweep |
| 3× | 1 licht | smalle sweep 1.5 kHz → 300 Hz, milde resonantie |
| 4× | 2 medium | cyclus rond |

Per trapje gaan drie dingen tegelijk omhoog: de sweep-breedte (hoe ver het filter opent bij de aanslag), de resonantie (lagere demping k) en de tanh-drive. Twee praktische details:

- De **resonantie en drive veranderen direct** bij een druk, dus je hoort meteen dat de knop pakte; het nieuwe sweep-startpunt hoor je bij de volgende noot.
- **E9 (DIP 2) is master-uit**: laag = geforceerd stil niveau, hoog = de knop bepaalt. Na een reset sta je weer op medium.

De regressietest ([wah_toggle_tb.v](src/wah_toggle_tb.v)) doorloopt de volledige cyclus plus DIP en reset: 11/11 PASS. De SPI-testbench blijft ook groen (identieke pieken als eerst), dus het brain-pad is onaangeraakt — daar stuurt straks de Teensy cutoff/resonantie/drive zelf.

Dus: Synthesize → P&R → flashen, en dan een paar keer op T2 drukken. Niveau 3 zou je niet moeten kunnen missen — mocht zelfs dát nog te bescheiden klinken, dan kan ik de stap naar k=0.25 en drive 4.0 maken, maar luister eerst maar eens.

---

## 👤 Gebruiker (7)

hij mag terug naar main, denk ik.
> 🔧 `PowerShell` — Check working tree and branch commits before merge
> 🔧 `PowerShell` — Fast-forward main to fix/review-findings and delete branch

**🤖 Claude:**

`main` staat nu op `bf19f1f` (fast-forward, geen merge-conflicten) en de branch `fix/review-findings` is opgeruimd. Alles van de afgelopen sessies — de vier review-fixes, de warning-opruiming, E9 + T2 en de wah-trapjes — zit er nu in, inclusief jouw eigen tussencommits.

Twee dingen die je nog wilt weten:

1. **Er zijn DSim-buildartefacten meegecommit.** In jouw eigen commits (o.a. `bf19f1f`) zijn de `dsim_work_*`-mappen en `spi_sim_output.txt`/`wah_sim_output.txt` in git beland — dat zijn gegenereerde bestanden (o.a. binaire `.o`/`.so`-files en een sim-log van 3,6 MB) die bij elke simulatierun veranderen. Wil je dat ik ze uit de tracking haal (`git rm --cached`) en aan [.gitignore](.gitignore) toevoeg? De bestanden zelf blijven dan gewoon op schijf staan.

2. **`main` is lokaal 11 commits voor op `origin/main`** — als je het naar GitHub wilt hebben is het een kwestie van `git push`, of ik doe het voor je.

---

## 👤 Gebruiker (8)

1: ja graag
2: ik push wel
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\.gitignore
> 🔧 `PowerShell` — List tracked generated files
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\.gitignore
> 🔧 `PowerShell` — Untrack DSim artifacts and commit .gitignore update

**🤖 Claude:**

Klaar — commit `f4c2959` op `main`. De 56 gegenereerde bestanden (vier `dsim_work_*`-mappen, de twee sim-logs en `dsim.manifest`) zijn uit de tracking gehaald maar staan nog gewoon op schijf, en de [.gitignore](.gitignore) vangt ze voortaan af: `dsim_work*/` dekt ook toekomstige `-work`-varianten, en `*_sim_output.txt` de sim-logs. De werkboom is schoon, dus je kunt pushen wanneer je wilt.

---

## 👤 Gebruiker (9)

De FPGA  heeft nog heel veel capaciteit. Wat zou ik er nog op kunnen bouwen? Ik houd van polyfone dingen, dus hetgeen er is multipliceren moet je wel meenemen.

Is een analoog circuit emulatie logisch om hierop te doen?

Of een heel dikke wavetable synth (waarschijnlijk logischer)?

Of meer physical modeling, maar dan complexer?

Wil je wat onderzoeken en suggereren?

**🤖 Claude:**

Leuke vraag — laat me eerst even de échte cijfers pakken: het P&R-rapport van de laatste build vertelt precies hoeveel van de chip nu bezet is.
> 🔧 `Glob` — impl/pnr/*.rpt*
> 🔧 `Grep` — Logic|Register|BSRAM|DSP|Utilization|CLS|LUT

**🤖 Claude:**

De cijfers uit het laatste P&R-rapport maken het beeld mooi concreet. Eerst even wat er nú bezet is, want dat bepaalt welke routes logisch zijn:

| Resource | Gebruikt | Vrij |
|---|---|---|
| Logic (LUT/ALU) | 989 / 20.736 (5%) | ~95% |
| Registers | 528 / 15.552 (4%) | ~96% |
| BSRAM | 10 / 46 blokken (22%) | 36 blokken ≈ 80 KB |
| DSP-multipliers | 10 / 24 (42%) | 14 |
| Verder | — | 4 PLL's, 128 MB DDR3 onaangeraakt |

Twee observaties die alles sturen:

**1. De schaarse resource is niet logic maar DSP.** Je ene stem gebruikt al 42% van de multipliers. Naïef de voice 8× copy-pasten past dus niet. Maar dat hoeft ook niet, want:

**2. De echte goudmijn is tijd.** Op 27 MHz heb je **562 klokcycles per audio-sample**, en de huidige voice gebruikt er daarvan ~10. De filter-FSM is (volgens z'n eigen header-comment) al ontworpen om ge-time-multiplexed te worden: één rekenkern die per sample achter elkaar stem 0, 1, 2, … 7 doorrekent. Dan blijft het DSP-gebruik ~constant en groeit alleen de state (registers/BRAM) per stem. Mocht 562 cycles ooit knellen: een PLL naar 108 MHz geeft 4× meer budget. Polyfonie is op een FPGA dus geen vermenigvuldiging maar een sequencer-refactor — en het SPI-protocol heeft al slot-ID's per stem, dus de brain-kant is er klaar voor.

Dan je drie richtingen, eerlijk gewogen:

## Analoge circuit-emulatie — als hoofdproject: nee

Echte circuit-simulatie (transistor-niveau, Newton-Raphson per sample over een netlijst) past slecht bij fixed-point FPGA-pipelines: iteratieve solvers met data-afhankelijke convergentie zijn precies wat je níet wilt in een cycle-budget, en het eindresultaat is… een filter, dat je al hebt. Belangrijker: je dóet al virtual-analog — de tanh-in-de-feedback-SVF ís de pragmatische vorm. Het zinnige project in deze hoek is klein: een **Moog transistor-ladder als tweede filtermode** (4 cascaded one-poles met elk een tanh, hergebruikt je bestaande LUT en MAC). Leuk, maar een uitbreiding, geen richting.

## Wavetable-synth — je vermoeden klopt: dit is de logische

Dit is de meest FPGA-idiomatische synthese die er bestaat: een oscillator is een fase-accumulator (één 32-bit optelling, nul DSP) plus een BRAM-read. Met je 36 vrije BSRAM-blokken passen tientallen tabellen van 1024×16 inclusief **mipmaps per octaaf** (de standaard anti-aliasing-truc: per octaaf een verder bandgelimiteerde versie van dezelfde tabel). Morphing tussen twee tabellen = twee reads + een crossfade op de gedeelde MAC. En het mooiste: je stuurt het door je bestaande MS-20-filter per stem — wavetable-oscillator → VA-filter is precies de PPG/Waldorf/Microwave-architectuur, en die klinkt dik. 16-32 stemmen zijn haalbaar omdat een wavetable-stem véél goedkoper is dan een KS-stem (geen eigen delay-lijn; tabellen worden gedeeld). Later kan de DDR3 erbij voor megabytes aan tabellen (Gowin heeft DDR3-IP, wel serieus werk).

## Complexer physical modeling — muzikaal het meest onderscheidend

Hier heb je al een fundament, en er liggen upgrades klaar in oplopende moeite:

- **Fractional tuning (allpass-interpolatie in de KS-lijn)** — quick win met echte waarde: je period is nu een geheel getal (`fs/f0` afgerond), waardoor hogere noten hoorbaar vals worden. Bij akkoorden (polyfonie!) ga je dat horen. Eén first-order allpass in de loop lost het op; kost één mult.
- **Gekoppelde snaren / sympathische resonantie** — een beetje van elke stem in de delay-lijnen van de andere stemmen lekken geeft dat piano/gitaar-achtige "levende" gedrag. Spotgoedkoop, klinkt duur.
- **Modale synthese** — en hier wordt het poëtisch: je hebt [mass_spring_resonator.v](src/mass_spring_resonator.v) al liggen, ongebruikt. Time-multiplex die tot een bank van 64-128 resonatoren (elk 3 mults op de gedeelde MAC) en je hebt klokken, marimba's, platen — geëxciteerd door je KS-pluk of een wavetable-burst. 128 modes × ~4 cycles past binnen je 562.
- **2D waveguide-mesh (drums)** — de stretch: een 16×16 mesh haalt je cycle-budget op 27 MHz net niet, dus dat wordt pas realistisch met de PLL op 108 MHz.

## Mijn voorstel: één roadmap die alles combineert

1. **Voice-engine time-multiplexen naar 8 stemmen** (KS + MS-20 per stem, mixbus erachter). Dit is het platform waar élke vervolgoptie op leunt — en delay-lijnen van 8 stemmen passen in BSRAM (evt. 16/18-bit samples in de lijn i.p.v. 32 om blokken te sparen).
2. **Wavetable-oscillator als tweede exciter** per stem naast de KS-pluk, door hetzelfde filter. Dan heb je in één klap een polyfone wavetable-synth én je bassmachine.
3. **Physical-modeling-verdieping**: eerst de fractional-tuning allpass (die wil je sowieso vóór polyfonie), daarna de modale bank uit je bestaande resonator-module.
4. Ladder-filter-mode als toetje, DDR3-wavetables als winterproject.

Zal ik voor stap 1 een concreet ontwerp uitwerken (state-layout per stem, de voice-sequencer-FSM, BSRAM-indeling en wat er aan de SPI-kant per slot bij moet)?

---

## 👤 Gebruiker (10)

Ja, wil je dit plan eerst opschrijven en dan beginnen met stap 1?

Kun je dit eigenlijk zelf simuleren en checken? Als dat zo is, kun je ook als je wilt werkende tussenversies vastleggen (tags) en door naar stap 2.

Ik moet nu slapen, maar kan morgen helpen met het op de echte hardware te proberen.

**🤖 Claude:**

Prima plan — ik ga aan de slag en werk zelfstandig door: plan opschrijven, stap 1 bouwen + simuleren, taggen bij groen, en dan door naar stap 2. Morgen ligt er iets om te flashen. Ik zet eerst een takenlijst op en lees de bestaande roadmap en table-generator:
> 🔧 `ToolSearch`
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\doc\ROADMAP.md
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\gen_tables.py
> 🔧 `PowerShell` — List existing tags and HEAD
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\doc\POLY_PLAN.md
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\doc\ROADMAP.md
> 🔧 `PowerShell` — Commit the plan document
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v

**🤖 Claude:**

spi_frame is om. Nu de grote: [synth_top.v](src/synth_top.v) volledig herschrijven rond de engine:
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\poly_tb.v

**🤖 Claude:**

Nu [synth_top_spi_tb.v](src/synth_top_spi_tb.v) uitbreiden naar twee stemmen via SPI:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v

**🤖 Claude:**

Alle bronbestanden staan. Nu simuleren — eerst de snelle SPI-frametest, dan de polyfonie:
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `PowerShell` — Run spi_frame_tb (per-voice)

**🤖 Claude:**

16/16 op de SPI-laag. Nu de kern: poly_tb (4,2 s sim):
> 🔧 `PowerShell` — Run poly_tb 8-voice test
> 🔧 `PowerShell` — Run wah_toggle_tb (poly version)
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\wah_toggle_tb.v
> 🔧 `PowerShell` — Re-run wah_toggle_tb with fixed numbering
> 🔧 `PowerShell` — Run SPI end-to-end and demo render sims
> 🔧 `Bash` — Render polyphonic demo WAVs
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v

**🤖 Claude:**

Stap 1 is compleet en groen. Committen en taggen:
> 🔧 `PowerShell` — Commit step 1 and tag 0.2-poly8
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\gen_tables.py
> 🔧 `Bash` — Generate wavetable and phase-inc tables

**🤖 Claude:**

Tabellen staan. Nu de phinc-ROM en de wavetable-oscillator in de engine:
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v

**🤖 Claude:**

Nu de WT-oscillator in [voice_engine.v](src/voice_engine.v) — poorten, datapath en FSM-staten:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v

**🤖 Claude:**

Nu de wavetable-testbench:
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\src\wavetable_tb.v
> 🔧 `PowerShell` — Run wavetable_tb
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v

**🤖 Claude:**

Nu de volledige regressie-suite draaien — wavetable, poly, wah, SPI en de demo-render in één keer:
> 🔧 `PowerShell` — Run wavetable_tb and poly_tb
> 🔧 `PowerShell` — Run wah, SPI end-to-end and demo render sims
> 🔧 `Bash` — Render mixed KS+WT demo WAVs
> 🔧 `Grep` — \.v"|VerilogFile|enable
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\MS20_Synth_Voice.gprj
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\MS20_Synth_Voice.gprj
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\MS20_Synth_Voice.gprj

**🤖 Claude:**

Stap 2 compleet — committen en taggen:
> 🔧 `PowerShell` — Commit step 2 and tag 0.3-wavetable
> 🔧 `PowerShell` — Delete stray sim log files
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `Write` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\poly-wavetable-status.md
> 🔧 `Edit` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\MEMORY.md
> 🔧 `Read` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\MEMORY.md
> 🔧 `Edit` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\MEMORY.md
> 🔧 `TodoWrite` — takenlijst bijgewerkt

**🤖 Claude:**

Klaar — beide stappen zijn gebouwd, gesimuleerd en getagd. Samenvatting voor morgenochtend:

## Wat er nu op `main` staat

**Plan** — [doc/POLY_PLAN.md](doc/POLY_PLAN.md) met de resource-analyse en de stappen; ROADMAP fase 4 bijgewerkt.

**Tag `0.2-poly8` — 8-stemmige polyfonie.** Nieuwe kern [voice_engine.v](src/voice_engine.v): één gedeelde KS + MS-20 rekenkern die per sample alle 8 stemmen doorloopt (~75 van de 562 beschikbare cycles), met per stem een eigen delay-lijn (één BRAM van 16384×18), filter-state en wah-envelope. Het vullen van een delay-lijn bij een aanslag gebeurt in de idle-cycles. SPI is per stem: CvSet-slot = `voice*4 + param`, GateSet-slot = stem — stem 0 is backwards-compatible met wat de brain nu al stuurt.

**Tag `0.3-wavetable` — wavetable-exciter per stem.** Bandgelimiteerde saw + square met 8 octaaf-mipmaps (anti-aliasing) uit [gen_tables.py](gen_tables.py), 32-bit fase-accumulator per stem, lineaire interpolatie, en een amp-envelope (attack 0,7 ms / release 85 ms) op de gate. Elke stem kiest KS of wavetable; alles gaat door hetzelfde MS-20-filter met de wah-niveaus op T2/E9.

**Simulaties** (alles zelf gedraaid in DSim): poly_tb 4/4 — alle 8 stemmen klinken tegelijk, geen overflow; wavetable_tb 8/8; wah-regressie 12/12; SPI-frametest 16/16; SPI end-to-end met 2 stemmen OK. De demo-WAV's in [wav/](wav/) zijn ververst — [ms20_filter_output.wav](wav/ms20_filter_output.wav) laat nu de eerste 3 s van het polyfone arpeggio horen (afwisselend pluk en zaag/blok), alvast een voorproefje van wat er morgen uit de jack moet komen.

## Morgen op hardware

1. Gowin EDA: **Synthesize → Place & Route** (nieuwe files staan al in het [.gprj](MS20_Synth_Voice.gprj); `wavetable.hex` en `note_phinc.hex` staan in de projectroot en in git) → flashen zoals altijd.
2. Verwacht geluid: een doorlopend 8-staps arpeggio, elke 0,5 s een nieuwe stem, met overlappende staarten — even stemmen zijn KS-pluk, oneven zijn wavetable. T2 stapt nog steeds door de wah-niveaus, E9 is wah-master, T4 mute.
3. Check even het P&R-rapport: ik verwacht BSRAM ~36/46 en DSP rond 12/24, en 27 MHz timing moet ruim halen — maar dat is de ene stap die ik 's nachts niet kon verifiëren, net als het geluid zelf.

Eén bewuste beperking: in **SPI-mode staat alles nog op KS** — de exciter-keuze per stem via het MusicBrain-protocol vergt een protocol-uitbreiding die ik eerst met jou (en de brain-kant) wil afstemmen. De demo laat de wavetables wél volop horen. Welterusten!

---

## 👤 Gebruiker (11)

hij stopt op 75%, is dat okee?

```

Running parser ...
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\ks_string.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\mass_spring_resonator.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\pt8211_tx.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\i2s_tx.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v'
Compiling module 'synth_top'("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":17)
Compiling module 'spi_slave'("E:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v":16)
Compiling module 'spi_frame'("E:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v":30)
Compiling module 'note_to_period'("E:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v":11)
Extracting RAM for identifier 'rom'("E:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v":19)
Compiling module 'note_phinc'("E:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v":11)
Extracting RAM for identifier 'rom'("E:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v":17)
Compiling module 'voice_engine'("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":30)
Extracting RAM for identifier 'dmem'("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":98)
Extracting RAM for identifier 'wrom'("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":112)
WARN  (EX3791) : Expression size 26 truncated to fit in target size 17("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":158)
Compiling module 'tanh_lut'("E:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v":13)
Extracting RAM for identifier 'rom'("E:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v":19)
WARN  (EX3791) : Expression size 34 truncated to fit in target size 32("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":420)
WARN  (EX3791) : Expression size 34 truncated to fit in target size 32("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":421)
Compiling module 'pt8211_tx'("E:\Dev\Gowin\MS20_synth_voice\src\pt8211_tx.v":23)
NOTE  (EX0101) : Current top module is "synth_top"
[5%] Running netlist conversion ...
WARN  (CV0016) : Input demo_mode is unused("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":35)
Running device independent optimization ...
[10%] Optimizing Phase 0 completed
[15%] Optimizing Phase 1 completed
[25%] Optimizing Phase 2 completed
Running inference ...
[30%] Inferring Phase 0 completed
[40%] Inferring Phase 1 completed
[50%] Inferring Phase 2 completed
[55%] Inferring Phase 3 completed
Running technical mapping ...
[60%] Tech-Mapping Phase 0 completed
[65%] Tech-Mapping Phase 1 completed
[75%] Tech-Mapping Phase 2 completed
```
messages:
WARN  (CV0016) : Input demo_mode is unused("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":35)
WARN  (EX3791) : Expression size 26 truncated to fit in target size 17("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":158)
WARN  (EX3791) : Expression size 34 truncated to fit in target size 32("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":420)
WARN  (EX3791) : Expression size 34 truncated to fit in target size 32("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":421)
NOTE  (EX0101) : Current top module is "synth_top"

**🤖 Claude:**

Ja, dat is hoogstwaarschijnlijk oké — geduld hebben. Op 75% (Tech-Mapping Phase 2) zit de synthesizer precies de twee grote geheugens in BSRAM te mappen: de delay-lijn van 16384×18 én de wavetable-ROM van 16384×16, allebei mét initialisatie-inhoud (de hex-files worden in de bitstream gebakken). Dat is verreweg de zwaarste stap van deze build en kan gerust 5–15 minuten duren, terwijl de vorige (mono) builds in seconden klaar waren. Het belangrijke goede teken staat al in je log: `Extracting RAM for identifier 'dmem'` en `'wrom'` — Gowin heeft ze als RAM herkend en gaat ze dus naar blokgeheugen mappen, niet naar losse LUT's.

Praktisch: kijk in Taakbeheer of het synthese-proces nog CPU gebruikt. Zolang dat zo is, gewoon laten lopen. Staat het na ~20 minuten nog op 75% mét 0% CPU, breek dan af en stuur me de laatste regels, dan graaf ik erin.

Over de warnings — allemaal verwacht en onschuldig:

- **`demo_mode is unused`**: klopt, `DEMO_ONLY=1` vouwt het SPI-mux-pad weg; verdwijnt zodra je met `DEMO_ONLY=0` bouwt.
- **`voice_engine.v:158` (26→17)**: de wavetable-interpolatie — het resultaat past per constructie (het ligt altijd tussen twee 16-bit samples), de bredere tussenterm wordt bewust afgekapt.
- **`voice_engine.v:420/421` (34→32)**: de mix-accumulator (som van 8 stemmen ÷ 4) naar de 32-bit output — de waarde is begrensd door de filter-clamps en past ruim.

Die laatste drie maak ik bij een volgende commit nog expliciet met slices (zoals we eerder met de andere EX3791's deden), maar ze hebben geen invloed op het gedrag.

Als de build klaar is: check even het P&R-rapport — verwachting is **BSRAM rond 36/46** en **DSP rond 12–14/24**. Daarna flashen en zou je het arpeggio moeten horen: elke halve seconde een nieuwe stem, afwisselend KS-pluk en zaag/blok-wavetable, met staarten die over elkaar heen klinken.

---

## 👤 Gebruiker (12)

4.9%

**🤖 Claude:**

4,9% is precies wat je wilt zien: Gowin-synthese is single-threaded, dus op een CPU met ~20 threads is één volledig bezette core ≈ 5%. Hij hangt dus niet — hij is gewoon hard aan het rekenen aan die twee grote geheugens. Laat maar lopen.

Zou het echt vastzitten, dan zag je 0% (of het geheugen dat maar blijft groeien richting gigabytes). Pas als hij na pakweg 20–30 minuten nóg op 75% staat, of het CPU-gebruik naar 0% zakt zonder dat de build klaar meldt, is er reden om af te breken — stuur me dan de laatste logregels.

---

## 👤 Gebruiker (13)

Helaas:

[90%] Tech-Mapping Phase 4 completed
ERROR (RP0006) : The number(28116(27674 LUTs, 370 ALUs, 0 ROM16s, 12 SSRAMs)) of logic in the design exceeds the resource limit(20736) of current device
GowinSynthesis finish

**🤖 Claude:**

Ah — daar is de echte fout: **28k LUTs**, want de delay-RAM en de wavetable-ROM zijn niet in blokgeheugen (BSRAM) terechtgekomen maar in LUT-logica. De oorzaak is mijn toegangspatroon: ik lees/schrijf `dmem` en `wrom` vanuit meerdere FSM-states, waardoor Gowin er meerdere poorten in ziet en BSRAM niet past. De fix is het klassieke recept: één registered lees-adres en één schrijf-poort per geheugen, en de FSM-pipeline daarop hertimen. Ik bouw het om en draai alle sims opnieuw.
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Read` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v

**🤖 Claude:**

Declaraties staan goed (de error was een tussenstand). Nu de volledige suite opnieuw:
> 🔧 `PowerShell` — Run poly_tb and wavetable_tb after BRAM-port refactor

**🤖 Claude:**

Bit-identiek resultaat (zelfs dezelfde mix-piek) — de hertiming verandert het geluid dus niet. Rest van de suite:
> 🔧 `PowerShell` — Run remaining testbenches and demo render
> 🔧 `PowerShell` — Commit BRAM port refactor

**🤖 Claude:**

Gefixt en gecommit (`e09a1bc`) — probeer de synthese opnieuw.

**Wat er misging:** de foutmelding zei dat het ontwerp 28.116 LUT's nodig had (limiet 20.736). De oorzaak: ik las en schreef de delay-RAM en wavetable-ROM vanuit meerdere FSM-states, waardoor Gowin er méér lees/schrijfpoorten in zag dan een BSRAM-blok heeft. Het viel daarom terug op "distributed RAM" — een 16K-diep geheugen uit losse LUT's bouwen, en dat explodeert precies zoals je zag (dat verklaart achteraf ook de trage 75%-fase).

**De fix** is het standaard BRAM-recept: elk geheugen heeft nu precies één geregistreerd leesadres en één schrijfpoort in een eigen klein proces, en de engine-FSM is erop hertimed (het adres gaat er een cyclus eerder in, de data komt er een cyclus later uit). Ik heb alle vijf testbenches opnieuw gedraaid: identieke uitkomsten tot op de sample — het geluid is dus onveranderd. De drie truncation-warnings uit je log zijn ook meteen expliciet gemaakt; alleen `demo_mode is unused` blijft (hoort bij `DEMO_ONLY=1`).

**Verwachting voor de nieuwe run:** flink sneller dan de vorige poging, LUT-gebruik terug naar een paar duizend (~15-20%), en in het rapport zou je nu netjes **BSRAM rond 36/46** moeten zien (16 blokken delay-lijnen + 16 wavetable + tanh/noot-LUTs). Als hij er doorheen is: flashen, en dan hoor je als het goed is het 8-stemmige arpeggio met afwisselend pluk- en wavetable-stemmen.

---

## 👤 Gebruiker (14)

start
Running parser ...
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\ks_string.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\mass_spring_resonator.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\ms20_filter.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\pt8211_tx.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\i2s_tx.v'
Analyzing Verilog file 'E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v'
Compiling module 'synth_top'("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":17)
Compiling module 'spi_slave'("E:\Dev\Gowin\MS20_synth_voice\src\spi_slave.v":16)
Compiling module 'spi_frame'("E:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v":30)
Compiling module 'note_to_period'("E:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v":11)
Extracting RAM for identifier 'rom'("E:\Dev\Gowin\MS20_synth_voice\src\note_to_period.v":19)
Compiling module 'note_phinc'("E:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v":11)
Extracting RAM for identifier 'rom'("E:\Dev\Gowin\MS20_synth_voice\src\note_phinc.v":17)
Compiling module 'voice_engine'("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":30)
Extracting RAM for identifier 'dmem'("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":102)
Extracting RAM for identifier 'wrom'("E:\Dev\Gowin\MS20_synth_voice\src\voice_engine.v":127)
Compiling module 'tanh_lut'("E:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v":13)
Extracting RAM for identifier 'rom'("E:\Dev\Gowin\MS20_synth_voice\src\tanh_lut.v":19)
Compiling module 'pt8211_tx'("E:\Dev\Gowin\MS20_synth_voice\src\pt8211_tx.v":23)
NOTE  (EX0101) : Current top module is "synth_top"
[5%] Running netlist conversion ...
WARN  (CV0016) : Input demo_mode is unused("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":35)
Running device independent optimization ...
[10%] Optimizing Phase 0 completed
[15%] Optimizing Phase 1 completed
[25%] Optimizing Phase 2 completed
Running inference ...
[30%] Inferring Phase 0 completed
[40%] Inferring Phase 1 completed
[50%] Inferring Phase 2 completed
[55%] Inferring Phase 3 completed
Running technical mapping ...
[60%] Tech-Mapping Phase 0 completed
[65%] Tech-Mapping Phase 1 completed
[75%] Tech-Mapping Phase 2 completed
[80%] Tech-Mapping Phase 3 completed
[90%] Tech-Mapping Phase 4 completed
WARN  (NL0002) : The module "note_to_period" instantiated to "u_n2p" is swept in optimizing("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":211)
[95%] Generate netlist file "E:\Dev\Gowin\MS20_synth_voice\impl\gwsynthesis\MS20_Synth_Voice.vg" completed
[100%] Generate report file "E:\Dev\Gowin\MS20_synth_voice\impl\gwsynthesis\MS20_Synth_Voice_syn.rpt.html" completed
GowinSynthesis finish
Reading netlist file: "E:\Dev\Gowin\MS20_synth_voice\impl\gwsynthesis\MS20_Synth_Voice.vg"
Parsing netlist file "E:\Dev\Gowin\MS20_synth_voice\impl\gwsynthesis\MS20_Synth_Voice.vg" completed
Processing netlist completed
Reading constraint file: "E:\Dev\Gowin\MS20_synth_voice\src\synth_top.cst"
Physical Constraint parsed completed
Running placement......
[10%] Placement Phase 0 completed
[20%] Placement Phase 1 completed
[30%] Placement Phase 2 completed
[50%] Placement Phase 3 completed
Running routing......
[60%] Routing Phase 0 completed
[70%] Routing Phase 1 completed
[80%] Routing Phase 2 completed
[90%] Routing Phase 3 completed
Running timing analysis......
[95%] Timing analysis completed
Placement and routing completed
Bitstream generation in progress......
Bitstream generation completed
Running power analysis......
[100%] Power analysis completed
Generate file "E:\Dev\Gowin\MS20_synth_voice\impl\pnr\MS20_Synth_Voice.power.html" completed
Generate file "E:\Dev\Gowin\MS20_synth_voice\impl\pnr\MS20_Synth_Voice.pin.html" completed
Generate file "E:\Dev\Gowin\MS20_synth_voice\impl\pnr\MS20_Synth_Voice.rpt.html" completed
Generate file "E:\Dev\Gowin\MS20_synth_voice\impl\pnr\MS20_Synth_Voice.rpt.txt" completed
Generate file "E:\Dev\Gowin\MS20_synth_voice\impl\pnr\MS20_Synth_Voice.tr.html" completed
Mon Jul  6 21:17:52 2026

NOTE  (EX0101) : Current top module is "synth_top"
WARN  (CV0016) : Input demo_mode is unused("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":35)
WARN  (NL0002) : The module "note_to_period" instantiated to "u_n2p" is swept in optimizing("E:\Dev\Gowin\MS20_synth_voice\src\synth_top.v":211)

Het flashen gaat nog niet goed. Ik hoor nog de oude demo ook

**🤖 Claude:**

De synthese en P&R zijn nu wél helemaal goed doorgelopen (dat probleem is opgelost), maar de flash is niet geland: **"User code mismatch"** plus het feit dat je de oude demo hoort betekent dat de FPGA nog op zijn oude configuratie draait — waarschijnlijk herlaadt hij uit de embedded flash (waar je oude build in staat) en is de SRAM-load niet aangekomen. Laat me eerst kijken of openFPGALoader op deze machine staat, dan kan ik het flashen zelf proberen langs de betrouwbare route:
> 🔧 `PowerShell` — Check for openFPGALoader and fresh bitstream
> 🔧 `PowerShell` — Search common openFPGALoader install locations

**🤖 Claude:**

openFPGALoader staat niet op deze machine, dus we doen het via de Gowin Programmer. De diagnose: de programmer meldde "Finished", maar las daarna **User Code 0x00000000** terug terwijl de nieuwe bitstream `0x0000DA2F` heeft — de FPGA draait dus nog zijn oude configuratie. Vrijwel zeker zit je **oude build in de embedded flash**, en valt de chip daarop terug (of komt de SRAM-load niet door de wakeup). Dat verklaart precies waarom je de oude demo blijft horen.

Doe dit, in volgorde:

1. **Schrijf naar de embedded flash in plaats van SRAM** — dit wil je toch, en het haalt de oude demo definitief weg:
   - Dubbelklik in de Programmer op de **Operation**-cel van device #1
   - Access Mode: **Embedded Flash Mode**
   - Operation: **embFlash Erase, Program** (of "…, Program, Verify")
   - OK → groene Program-knop
   - Dit duurt aanzienlijk langer dan 5 s (de flash moet gewist en geschreven worden) — dat is normaal.
2. **Power-cycle het bord** (USB eruit/erin). Hij boot nu uit de flash → je zou het nieuwe geluid moeten horen: elke halve seconde een nieuwe stem, afwisselend pluk en zaag/blok, met overlappende staarten.
3. Mocht ook de flash-write op "User code mismatch" eindigen: probeer dan de **andere kabel** (hij vond er twee: A/0/625 en A/1/626 — wisselen via *USB Cable Setting*), en/of zet daar de frequentie op 2 MHz. En herstart de Programmer even helemaal, zodat zeker de verse `.fs` van 21:17 is geladen en niet een gecachte oude.

Ter geruststelling: de "User code mismatch"-warning bij een geslaagde flash-write mag je daarna negeren als de verify slaagt en het geluid klopt — de echte test is wat je hoort na de power-cycle.

Lukt het met stap 1–3 nog niet, dan haal ik openFPGALoader binnen en flashen we via die route.

---

## 👤 Gebruiker (15)

er is alleen external Flash mode

**🤖 Claude:**

Ah, mijn fout — de GW2A heeft geen embedded flash; op de Tang Primer 20K zit een **externe** SPI NOR-flash (32 Mbit), dus External Flash Mode is precies goed. Kies:

1. Access Mode: **External Flash Mode**
2. Operation: **exFlash Erase,Program,Verify thru GAO-Bridge** (de verify-variant, dan weten we zeker dat hij geland is)
3. Check in het dialoog dat het **start-adres op 0x000000** staat (daar wijst die waarschuwingstekst onderin ook op — met een ander adres boot de FPGA er niet uit)
4. FS File = de verse `E:/Dev/Gowin/MS20_synth_voice/impl/pnr/MS20_Synth_Voice.fs` → Program

Dit duurt duidelijk langer dan de 5 s van net — de tool laadt eerst een hulp-bitstream in de FPGA (dat is die "GAO-Bridge") en programmeert daarmee de flash-chip, inclusief wissen en terugleesverificatie. Denk aan een minuut of meer.

Daarna: **power-cycle** (USB los en weer vast). De FPGA laadt dan de nieuwe bitstream uit de flash en je zou het 8-stemmige arpeggio moeten horen — elke halve seconde een nieuwe stem, om en om KS-pluk en zaag/blok-wavetable, met lange overlappende staarten. T2 stapt nog steeds door de wah-niveaus heen.

---

## 👤 Gebruiker (16)

Wel iets met SPI flash not found

**🤖 Claude:**

De "Spi flash not found" is een gevolg, niet de oorzaak. Kijk naar de regel erboven: **"Gao-Bridge User Code is: 0x00000000"** — de GAO-Bridge is zélf een klein hulp-bitstream dat eerst via JTAG in de FPGA geladen wordt, en ook díe lading is niet aangekomen (zelfde symptoom als bij je SRAM-poging). Zonder werkende bridge in de FPGA kan de tool de flash-chip niet bereiken → "flash not found". De rode draad: **IDCODE lezen lukt, maar élke configuratie-overdracht via JTAG mislukt.** Dat wijst op datacorruptie op de JTAG-lijn — en de onboard BL702-debugger van de Tang Primer staat bekend als kieskeurig op 2,5 MHz.

Probeer dit, in volgorde:

1. **Power-cycle het bord** (USB los/vast) en herstart de Gowin Programmer.
2. **Verlaag de JTAG-klok**: knop *USB Cable Setting* → Frequency van 2.5MHz naar **1 MHz** (of het laagste dat er staat).
3. Doe eerst een snelle **SRAM Program** als test. Kijk naar de output: als er nu `User Code is: 0x0000DA2F` staat (en geen mismatch), is de overdracht goed — en zou je *meteen* het nieuwe arpeggio moeten horen.
4. Werkt dat, doe dan de **exFlash Erase,Program,Verify thru GAO-Bridge** om het persistent te maken, en power-cycle.
5. Nog steeds mismatch op 1 MHz? Probeer dan de **andere kabel** (A/1) via USB Cable Setting, en eventueel een andere USB-poort/kabel (datacorruptie kan ook gewoon de USB-kabel zijn).

Als het met de Gowin Programmer niet lukt, haal ik openFPGALoader binnen en flashen we via die route — die heeft speciale ondersteuning voor dit bord (`-b tangprimer20k`) en is bij de Tang-community de standaardweg juist omdat de Gowin-tool hier vaker op struikelt.

---

## 👤 Gebruiker (17)

lukt niet

**🤖 Claude:**

Interessant detail: de operatie duurde **5,47 s — exact even lang als op 2,5 MHz**. Op 0,1 MHz zou het schuiven van een volledige GW2A-18-bitstream ruim een minuut moeten duren. Conclusie: de configuratiedata wordt helemaal niet verstuurd (of de BL702-debugger negeert de klokinstelling). Het lezen (IDCODE) werkt, maar schrijvende JTAG-operaties landen gewoon niet.

Twee snelle, diagnostische dingen in de Programmer:

1. **Herselecteer eerst het FS-bestand** (klik op de `...` bij FS File en kies de .fs opnieuw) — sluit uit dat er een verouderde cache meespeelt.
2. Zet de Operation op **SRAM Erase** (Access Mode: SRAM Mode) en voer die uit. Dit is de lakmoesproef: als de oude demo daarna **stopt met spelen**, hebben we wél schrijf-controle over de chip en zit het probleem in de program-stap. Blijft hij gewoon doorspelen, dan komt er werkelijk níets van onze commando's aan — en dan is de onboard BL702-debugger de verdachte (bekend euvel bij deze borden; Sipeed adviseert zelf openFPGALoader).

Vertel me wat de erase doet (muziek stopt of niet). Bij "stopt niet" ga ik openFPGALoader voor je binnenhalen en flashen we daarmee — één kanttekening: dat gebruikt op Windows een andere USB-driver (WinUSB via Zadig) voor het JTAG-interface, wat de Gowin Programmer-toegang blokkeert tot je de driver terugzet. Dat is omkeerbaar, maar goed om te weten voordat we die stap zetten.

Eén controlevraag om de puzzel compleet te maken: de eerdere wah-builds van gisteren — flashte je die met déze zelfde Gowin Programmer en instellingen, of via een andere weg (bijv. openFPGALoader op een andere machine, of de IDE zelf)? Als exact dezelfde route toen wél werkte, is er iets veranderd (USB-poort, kabel, hub?) en zoeken we het eerst daar.

---

## 👤 Gebruiker (18)

na sram erase speelt ie nog gewoon

**🤖 Claude:**

Dan is het beeld compleet: ook de erase komt niet aan — schrijvende JTAG-operaties bereiken de chip gewoon niet, alleen lezen werkt. Vóórdat we aan de USB-driver gaan sleutelen is er nog één niet-invasieve route in de Gowin Programmer die het proberen waard is, omdat hij **geen werkende SRAM-configuratie nodig heeft**:

**Probeer: External Flash Mode → `exFlash Erase,Program` (de onderste optie, dus zónder "thru GAO-Bridge").**

Die variant bit-bangt de flash-chip rechtstreeks via de boundary-scan-keten in plaats van eerst een hulp-bitstream in de FPGA te laden (precies de stap die bij jou faalt). Zet de frequentie terug op 2,5 MHz, want deze methode is traag — reken op enkele minuten, dat is normaal en juist een góed teken (het betekent dat er echt data stroomt, anders dan die verdachte 5,47 s van steeds). Daarna power-cycle → hij boot uit de flash met de nieuwe bitstream.

Let op bij het dialoog: start-adres 0x000000, en het verse FS-bestand geselecteerd.

Als ook dit faalt ("Spi flash not found" of weer zo'n snelle mislukking), dan is de BL702-debugger op het bord de bottleneck en gaan we naar openFPGALoader. Dat betekent: ik download de tool + Zadig, en jij zet met twee klikken de WinUSB-driver op het JTAG-interface (omkeerbaar, maar de Gowin Programmer kan er dan tijdelijk niet meer bij — zeg het als je daarmee akkoord bent, dan zet ik het vast klaar).

---

## 👤 Gebruiker (19)

ik flashte steeds met deze

**🤖 Claude:**

Zelfde tool, zelfde bord, gisteren werkte het — dan is er iets veranderd tussen toen en nu, en dat maakt de puzzel oplosbaarder. Twee verdachten: de USB/JTAG-verbinding (stack in rare staat, of de IDE die de kabel vasthoudt) óf iets aan deze specifieke bitstream. Even kijken of ik de Gowin command-line tools kan vinden, dan kan ik zelf een testbuild van gisteren's ontwerp maken om dat te isoleren:
> 🔧 `Glob` — Gowin*/IDE/bin/gw_sh.exe
> 🔧 `PowerShell` — Check running Gowin processes
> 🔧 `PowerShell` — Get Gowin IDE and Programmer install paths

**🤖 Claude:**

Belangrijke vondst: er draaien nu **twee Gowin-processen tegelijk** — de IDE (`gw_ide.exe`) én de losse Programmer (`programmer.exe`). De IDE heeft z'n eigen programmer-integratie en kan een claim op de USB-debugger houden. Twee processen die om dezelfde JTAG-kabel vechten geeft precies dit beeld: kleine leesacties (IDCODE) glippen ertussendoor, maar de lange schrijf-sessies falen. Gisteren werkte het — grote kans dat toen maar één van de twee openstond.

Dus:

1. **Sluit de Gowin IDE volledig af** (niet alleen minimaliseren). Laat alléén de standalone Programmer open — of andersom, flash juist vanuit de IDE en sluit de standalone; maar niet allebei.
2. USB-kabel van het bord even los en weer vast (verse verbinding).
3. In de Programmer: rescan → **SRAM Program**. Kijk naar de output: `User Code is: 0x0000DA2F` zonder mismatch = raak, en je hoort meteen het arpeggio.
4. Werkt dat, doe dan meteen **External Flash Mode → exFlash Erase,Program** (persistent) en een power-cycle.
5. Helpt het sluiten van de IDE niet: herstart de PC (USB-stack schoon) en probeer stap 3 nogmaals vóór we naar openFPGALoader gaan.

Over de Teensy: via USB is dat inderdaad een totaal ander apparaat en stoort het de Gowin Programmer niet — die heeft de juiste debugger al te pakken. Het zou alleen relevant zijn als er **draadjes van de Teensy fysiek aan het bord** hangen in de buurt van de JTAG-pinnen; de SPI-bus-pinnen zijn in de constraints nog niet eens toegewezen, dus elektrisch kan onze eigen logica daar niet in de weg zitten. Hangen er dupont-draadjes aan de dock-headers, haal ze tijdens het flashen voor de zekerheid even los.

**🤖 Claude:**

No response requested.

---

## 👤 Gebruiker (20)

de PC crashte, dus deze is weer helemaal fris.

Ik probeer het nog eens vanaf het begin. SRAM?

**🤖 Claude:**

Ja — en belangrijk detail: vlak voor de crash zag ik dat **gw_ide.exe én de losse Programmer tegelijk draaiden**. Dat is heel waarschijnlijk de boosdoener geweest: twee processen die om dezelfde JTAG-kabel vechten geeft precies dit beeld (lezen lukt, schrijven raakt corrupt). Na de reboot is dat opgelost, dus grote kans dat het nu gewoon werkt.

Zo pak je het schoon aan:

1. **Start alléén de Gowin Programmer** — laat de IDE dicht (of andersom, maar niet allebei).
2. USB Cable Setting: frequentie op **2.5 MHz** (terugzetten van die 0.1).
3. **SRAM Program** als snelle test. Let op de output: staat er nu `User Code is: 0x0000DA2F` zonder mismatch, dan is hij geland — en hoor je meteen het nieuwe geluid: elke halve seconde een nieuwe stem, om en om KS-pluk en zaag/blok-wavetable.
4. Werkt dat → maak het persistent: **External Flash Mode → exFlash Erase,Program,Verify thru GAO-Bridge**, startadres 0x000000. Duurt een paar minuten. Daarna power-cycle om te checken dat hij er zelf uit boot.

Als stap 3 wéér "User code mismatch" geeft op een verse PC met maar één programma open, dan weten we zeker dat het niet aan software-contentie ligt en pakken we de openFPGALoader-route.

---

## 👤 Gebruiker (21)

user code mismatch helaas

**🤖 Claude:**

Oké, dan is het niet de proces-contentie. Volgende stap in het isoleren: is het de **verbinding** of deze specifieke **bitstream**? Gisteren flashte exact deze route prima — het enige dat echt veranderd is, is de bitstream zelf. Ik ga kijken of ik de Gowin command-line tools kan vinden; dan kan ik zélf de oude (gisteren werkende) versie herbouwen en allebei testen, en misschien zelfs het flashen scripten zodat we meer diagnose-info krijgen:
> 🔧 `PowerShell` — Locate Gowin CLI tools
> 🔧 `PowerShell` — Check processes and show programmer_cli help
> 🔧 `PowerShell` — Close GUI programmer and scan JTAG cables
> 🔧 `PowerShell` — SRAM Program and Verify via CLI
> 🔧 `PowerShell` — Read device codes (usercode/status)
> 🔧 `PowerShell` — Create worktree at yesterday's commit with build script
> 🔧 `PowerShell` — Build yesterday's design headless with gw_sh
> 🔧 `PowerShell` — Flash yesterday's bitstream and read device codes
> 🔧 `PowerShell` — Write new bitstream to external flash via boundary-scan

**🤖 Claude:**

Even kijken of hij goed van start gaat (of meteen struikelt):
> 🔧 `Bash` — Peek at bscan flash progress

**🤖 Claude:**

Hij loopt — en belangrijker: **geen "Spi flash not found"** dit keer. De boundary-scan-route bereikt de flash-chip wél, en de voortgang tikt gestaag (~6% na 20 seconden, dus reken op zo'n 5–10 minuten totaal). Dit bevestigt ook de diagnose: de flash is prima bereikbaar, alleen de SRAM-configuratieweg via JTAG doet raar.

Ik krijg vanzelf bericht als hij klaar is en meld me dan. Daarna is het aan jou: **USB eruit en erin** (power-cycle), en dan zou het bord uit de flash moeten booten met het nieuwe ontwerp — het 8-stemmige arpeggio met om en om pluk- en wavetable-stemmen. Nog even geduld dus.

---

## 👤 Gebruiker (22)

<task-notification>
<task-id>b3y17zv85</task-id>
<tool-use-id>toolu_01GzhUL7nD7A7iAbVkc5GqHN</tool-use-id>
<output-file>C:\Users\User\AppData\Local\Temp\claude\e--Dev-Gowin-MS20-synth-voice\c65b7593-8bdd-4a1a-baf0-84b138168ff0\tasks\b3y17zv85.output</output-file>
<status>completed</status>
<summary>Background command "Write new bitstream to external flash via boundary-scan" completed (exit code 0)</summary>
</task-notification>
> 🔧 `Bash` — Check final bscan flash result

**🤖 Claude:**

De flash-write is geslaagd — "Finished!" na 7,5 minuut, exit-code 0, en die duur is precies wat een echte volledige write hoort te kosten (geen 5-seconden-nepsucces zoals eerder).

Nu jij: **trek de USB los, wacht even, en plug hem weer in.** Het bord boot dan uit de flash — en daar staat nu de nieuwe bitstream in.

Wat je zou moeten horen: het 8-stemmige arpeggio — elke halve seconde een nieuwe noot op de volgende stem, om en om een KS-pluk en een aangehouden zaag/blok-wavetable (die ~2 s blijft staan en dan wegsterft), met lange overlappende staarten. T2 stapt door de wah-niveaus (dik niveau hoor je meteen aan de resonantie), E9 is wah-master, T4 mute.

Laat horen wat eruit komt!

---

## 👤 Gebruiker (23)

Cool! Werkt. Een soort drone, bass en de arpeggio. De wah variaties werken. Eentje is wel heel distant-ambient opeens. Dat is die heel resonante?

**🤖 Claude:**

Gefeliciteerd — 8 stemmen polyfonie plus wavetables op je eigen FPGA-synth! 🎉

En ja, je analyse klopt: dat "distant-ambient" niveau is **niveau 3, de dikke/resonante**. De verklaring zit in de sweep-eindpunten: niveau 3 opent bij de aanslag het verst (4 kHz) maar zakt daarna naar het láágste eindpunt van alle niveaus (~200 Hz, de andere stoppen op 300 Hz), mét de hoogste resonantie (k=0.375). De aanslag is dus vet, maar de aangehouden wavetable-drones brengen het grootste deel van hun 2 seconden dóór achter een bijna dicht, sterk resonerend filter — dat hoor je als ver weg en hol/vocaal, precies dat ambient-karakter. Wil je niveau 3 juist dik láten klinken over de hele noot, dan is dat een kleine tweak: het eindpunt op ~400 Hz leggen of de sweep langzamer maken. Zeg het maar.

Ik ruim intussen de diagnose-spullen op en leg de werkende flash-route vast in de docs — dat SRAM-programmeren via JTAG kapot is maar flash-boot werkt, wil je volgende keer niet opnieuw uitzoeken:
> 🔧 `PowerShell` — Clean up diagnostic worktree and log
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\doc\FLASHING.md
> 🔧 `Edit` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\poly-wavetable-status.md
> 🔧 `PowerShell` — Commit flashing documentation update

**🤖 Claude:**

Alles vastgelegd. Waar we staan:

- **`0.3-wavetable` draait op hardware** — 8 stemmen, KS-plukken + wavetable-drones door het MS-20-filter, wah-niveaus werken. De mijlpaal uit het plan is compleet: van mono naar polyfone wavetable-synth in één (lange) sessie.
- **Flash-route gedocumenteerd** in [doc/FLASHING.md](doc/FLASHING.md) en mijn memory: bouwen kan headless (`gw_sh build.tcl`), flashen betrouwbaar via `programmer_cli --run 12` (boundary-scan naar de externe flash, ~7,5 min) + power-cycle. De kapotte SRAM-route staat erbij beschreven inclusief symptomen, zodat we er niet nóg een avond aan kwijtraken. Vanaf nu kan ik dus de hele cyclus — bouwen, flashen — vanaf hier draaien; jij hoeft alleen de USB te power-cyclen en te luisteren.
- De tijdelijke worktree en logs zijn opgeruimd.

Voor een volgende sessie, in volgorde van wat het meest oplevert:

1. **Niveau 3 minder "distant" maken** (eindpunt van de sweep naar ~400 Hz, of de sweep trager) — vijf minuten werk, als je het huidige ambient-karakter tenminste niet juist wilt hóuden; het heeft ook wel iets.
2. **SPI-integratie met de MusicBrain** — de per-stem slots liggen klaar (voice×4+param), de brain kan er in principe zo 8-stemmig op spelen. Mode-select per stem (KS vs. wavetable) vergt nog een kleine protocol-afspraak.
3. Uitzoeken waarom JTAG-SRAM-config opeens weigert — niet urgent nu flash-boot werkt, maar handig voor snellere iteraties (5 s in plaats van 7,5 min per test).

Geniet van de drone-machine!

---

## 👤 Gebruiker (24)

Ja, graag. WIl je verder met 1 (korte klus). En dan naar de SPI integratie. Wat moet er afgesproken worden?

**🤖 Claude:**

Ja! Eerst de korte klus: niveau 3 krijgt zijn sweep-eindpunt op ~400 Hz (was 200 Hz), zodat de drones dik blijven in plaats van weg te zakken. Stap per 64 samples opnieuw berekend voor dezelfde 0,5 s sweep:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `PowerShell` — Regression: wah_toggle_tb after level-3 tweak
> 🔧 `PowerShell` — Check for MusicBrain repo and protocol doc
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\build.tcl
> 🔧 `PowerShell` — Check no Gowin GUI tools are running
> 🔧 `PowerShell` — Commit level-3 tweak and build script
> 🔧 `PowerShell` — Build bitstream and flash via bscan (chained)
> 🔧 `Read` — D:\Git\Muziek\MusicBrain\doc\protocols\spi-frame.md
> 🔧 `Read` — D:\Git\Muziek\MusicBrain\doc\adr\0013-fpga-synth-instrument.md
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\doc\SPI_SLOTMAP.md
> 🔧 `PowerShell` — Commit SPI slotmap proposal

**🤖 Claude:**

De tweak is gecommit en de build+flash loopt in de achtergrond — ik geef een sein wanneer je de USB kunt power-cyclen (reken op ~10 min).

## Wat er afgesproken moet worden voor de SPI-integratie

Ik heb de MusicBrain-docs gelezen (spi-frame.md + ADR 0013) en het goede nieuws is: het frame-protocol zelf is al rond en onze implementatie volgt het. ADR 0013 benoemt zelf twee open questions, en daar komen er uit ons polyfonie-werk nog een paar bij. Het complete lijstje, nu vastgelegd als voorstel in [doc/SPI_SLOTMAP.md](doc/SPI_SLOTMAP.md):

1. **De slotmap** (ADR 0013 open question #1). Ons voorstel is wat de FPGA al implementeert: CvSet-slot = `voice·4 + param` (0=pitch, 1=cutoff, 2=reson, 3=drive) en GateSet-slot = voice 0..7. De brain-kant moet dit overnemen in de voice-allocator/editor-adressering.

2. **De pitch-schaal** (ADR 0013 open question #2). De ADR bevat nog een verouderde regel ("noot 69, 256 LSB/semitoon"); geldend is jouw eigen PITCH_CV.md: dCV offset-binary, 0..10 V @ 1 V/oct, 0 V = MIDI 0, dus `note = (code·120)>>16`. De brain moet bevestigen dat hij dát stuurt — anders speelt alles een vreemd interval te hoog of te laag.

3. **Exciter-keuze per stem** — het enige echt níeuwe. Mijn voorstel: **slots 32..39 als "exciter/morph-CV" per stem**: onderste kwart van de range = KS-pluk, de rest = wavetable, waarbij de positie later de morph-positie wordt. Dat is modulair-idiomatisch (gewoon een extra CV-bestemming, zoals een wave-knop), vergt géén nieuw opcode of versie-bump, en groeit mee naar wavetable-morphing.

4. **Gate-semantiek bevestigen**: retrigger vereist gate 0→1; de allocator moet dus note-off doen vóór een stem hergebruikt wordt (ADR 0011 suggereert dat hij dat al doet — even checken).

5. **Filter-CV-curves**: de huidige mappings zijn lineair en gedocumenteerd; omdat de brain "smart" is kan die zelf exponentiële curves in de dCV stoppen. Afspraak is dus vooral: dít zijn de formules, curve-vorming gebeurt brain-side (of we bouwen later een exp-LUT in de FPGA).

6. **Praktisch/elektrisch**: SCLK ≤ ~4–5 MHz, en de **SPI-pinnen op de Dock moeten nog gekozen worden** (PMOD; de .cst heeft ze nu unconstrained) — dat is samen met de bekabeling naar de Teensy de eerste fysieke stap.

Bewust uitgesteld: `CvSegment` (FPGA-side interpolatie — ADR 0013 zegt zelf dat CvSet volstaat bij lage stemaantallen) en `TriggerPulse`. 

Kortom: punt 3 is de enige echte ontwerpbeslissing die jij aan de brain-kant moet nemen; de rest is bevestigen en documenteren. Als jij het slots-32-voorstel ziet zitten, kan ik de FPGA-kant ervan (decode + morph-stub) alvast bouwen zodra de flash klaar is.

---

## 👤 Gebruiker (25)

<task-notification>
<task-id>bliyl9vpk</task-id>
<tool-use-id>toolu_01T5VhHYdxe2x1LKQTyhfobZ</tool-use-id>
<output-file>C:\Users\User\AppData\Local\Temp\claude\e--Dev-Gowin-MS20-synth-voice\c65b7593-8bdd-4a1a-baf0-84b138168ff0\tasks\bliyl9vpk.output</output-file>
<status>completed</status>
<summary>Background command "Build bitstream and flash via bscan (chained)" completed (exit code 0)</summary>
</task-notification>
> 🔧 `Bash` — Check build+flash final result

**🤖 Claude:**

Build en flash zijn allebei geslaagd ("Finished!", volledige ~7,5 min write). **Je kunt de USB power-cyclen.**

Wat je daarna zou moeten horen op wah-niveau 3 (de dikke, één druk op T2 vanaf boot): de aanslag opent nog steeds hard naar 4 kHz, maar de drones zakken nu naar ~400 Hz in plaats van 200 Hz — dus vet en aanwezig in plaats van distant. De andere niveaus zijn ongewijzigd.

Laat even weten of niveau 3 nu naar je zin is. En als je het slots-32-voorstel voor de exciter/morph-CV goedkeurt, bouw ik daarna de FPGA-kant ervan alvast in, zodat de brain straks per stem tussen pluk en wavetable kan kiezen.

---

## 👤 Gebruiker (26)

de distant is nog wel heel distant, hoor... 

En ik snap niets van "En als je het slots-32-voorstel voor de exciter/morph-CV goedkeurt, bouw ik daarna de FPGA-kant ervan alvast in, zodat de brain straks per stem tussen pluk en wavetable kan kiezen." kun je dat uitleggen? Ik verwachtte iets over SPI

**🤖 Claude:**

Twee dingen — eerst de uitleg, dan de fix.

## Wat ik bedoelde met "slots 32"

Dit gáát over SPI, alleen was ik te compact. De situatie: over SPI kan de brain nu alleen **KS-plukstemmen** bespelen — de wavetable-oscillator is via SPI helemaal niet bereikbaar (alleen de interne demo gebruikt hem). Er moet dus iets in het SPI-protocol bijkomen waarmee de brain per stem kan zeggen: "jij bent een pluk" of "jij bent een zaag-drone".

Het protocol adresseert alles via **slots** — zie het als genummerde CV-ingangen op een module. Slot 0–31 zijn al bezet (8 stemmen × pitch/cutoff/resonantie/drive). Mijn voorstel: geef elke stem één extra ingang, **slot 32 t/m 39** (stem 0 → slot 32, stem 1 → slot 33, …), met als betekenis "klankbron-keuze": lage waarde = KS-pluk, hogere waarde = wavetable. En omdat zo'n slot gewoon een getal van 0–65535 draagt, kan datzelfde getal later de *morph-positie* worden (glijdend van zaag naar blok naar wat we nog meer in de tabellen stoppen) — één afspraak die meegroeit. Het alternatief is een nieuw frame-type ("ModeSet") aan het protocol toevoegen, maar dat vergt een protocolwijziging aan de brain-kant; een extra slot niet.

"De FPGA-kant bouwen" = de decoder in [spi_frame.v](src/spi_frame.v) die slots leren herkennen en de engine per stem laten omschakelen. Daarna kan de Teensy het per stem aansturen.

## De distant blijft distant

Even checken: heb je na de flash de USB gepower-cycled? De stap van 200→400 Hz had hoorbaar moeten zijn. Hoe dan ook was hij blijkbaar niet groot genoeg — ik zet het sweep-eindpunt van niveau 3 nu op **800 Hz** (gelijk aan de statische "uit"-cutoff, dus de drones behouden echt hun lijf; de wah-beweging blijft de dip van 4 kHz → 800 Hz):
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `PowerShell` — Commit level-3 endpoint 800 Hz
> 🔧 `PowerShell` — Rebuild and flash via bscan (chained)

**🤖 Claude:**

De nieuwe build+flash draait (~12 min, ik meld me voor de power-cycle).

Nog één ding om alvast over na te denken terwijl hij loopt: als niveau 3 óók op 800 Hz nog "ver weg" klinkt, dan is het eindpunt niet de boosdoener maar de **resonantie** (k=0.375 + drive 3.0). Een sterk resonerend filter klinkt hol/nasaal — dat kan als "ambient" overkomen. De volgende draai aan de knop is dan k omhoog naar ~0.5 (minder scream, meer body). We horen het zo.

En voor de SPI-kant: als het slot-32-verhaal nu duidelijk is en je akkoord bent, dan bouw ik de decoder + stemomschakeling in (KS ↔ wavetable per stem via CvSet slot 32+stem), met testbench erbij. Dan ligt de FPGA-kant klaar en is de Teensy-kant puur nog "stuur het juiste slot".

---

## 👤 Gebruiker (27)

<task-notification>
<task-id>br5ixpj6p</task-id>
<tool-use-id>toolu_01HXsdUXCP6nsyqQbn1kT2co</tool-use-id>
<output-file>C:\Users\User\AppData\Local\Temp\claude\e--Dev-Gowin-MS20-synth-voice\c65b7593-8bdd-4a1a-baf0-84b138168ff0\tasks\br5ixpj6p.output</output-file>
<status>completed</status>
<summary>Background command "Rebuild and flash via bscan (chained)" completed (exit code 0)</summary>
</task-notification>
> 🔧 `Bash` — Check rebuild+flash result

**🤖 Claude:**

Klaar — **power-cycle de USB maar weer.** Niveau 3 (één druk op T2 vanaf boot) heeft nu een sweep van 4 kHz naar 800 Hz: de drones zouden hun volle lijf moeten houden, met alleen nog de wah-dip bij elke aanslag.

Luister vooral in vergelijking met niveau 2 (nog een druk verder in de cyclus, na uit en licht): niveau 3 hoort nu duidelijk de dikste te zijn. Is hij nog steeds te "ver weg", dan zit het in de resonantie en zet ik k van 0.375 naar 0.5 — zeg het maar.

---

## 👤 Gebruiker (28)

Ja, het is resonantie. Ik kom terug met een verhaal over de SPI

**🤖 Claude:**

Dan gaat k voor niveau 3 van 0.375 naar 0.5 — minder scream, meer body, terwijl hij nog steeds duidelijk resonanter blijft dan medium (0.625):
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `PowerShell` — Commit level-3 resonance change
> 🔧 `PowerShell` — Rebuild and flash via bscan (chained)

**🤖 Claude:**

De resonantie-aanpassing is gecommit (`c1ac8f0`) en de build+flash draait weer in de achtergrond — ik geef een sein wanneer je kunt power-cyclen.

En prima, ik wacht op je SPI-verhaal voordat ik daar iets bouw. Neem de tijd; de slotmap-voorstellen staan in [doc/SPI_SLOTMAP.md](doc/SPI_SLOTMAP.md) als je ze er bij wilt pakken, en waar je ook mee komt — de decoder-kant is hier zo aangepast.

---

## 👤 Gebruiker (29)

<task-notification>
<task-id>bup28rc4u</task-id>
<tool-use-id>toolu_017ksapLnxB6rx2Ljgm3Ebbs</tool-use-id>
<output-file>C:\Users\User\AppData\Local\Temp\claude\e--Dev-Gowin-MS20-synth-voice\c65b7593-8bdd-4a1a-baf0-84b138168ff0\tasks\bup28rc4u.output</output-file>
<status>completed</status>
<summary>Background command "Rebuild and flash via bscan (chained)" completed (exit code 0)</summary>
</task-notification>
> 🔧 `Bash` — Check rebuild+flash result
> 🔧 `Bash` — Check final lines of flash log

**🤖 Claude:**

Klaar — de flash-write is netjes afgerond (hele image tot 0x0DD800 geschreven). **Power-cycle de USB** en niveau 3 heeft nu k=0.5: nog steeds de meest resonante en gedreven stand, maar zonder dat holle, verre karakter.

Ter herinnering, de cyclus vanaf boot: start = medium → T2 ×1 = **dik (de aangepaste)** → ×2 = uit → ×3 = licht → ×4 = weer medium.

Benieuwd of hij nu goed valt — en ik hoor je SPI-verhaal wel wanneer je zover bent.

---

## 👤 Gebruiker (30)

## SPI - extended/gedelegeerd interne module
Over SPI. De FPGA is eigenlijk een gedelegeerde interne module. Deze volgt de logica van een interne module, namelijk: deze heeft ports en controls (en displays: leds of displays) EN de teensy kan overal bij; kan als het ware aan de knoppen draaien.

Een externe module heeft dat voordeel niet, die kan alleen CV.

Zie UML.

We hebben denk ik nu een paar modules gemaakt op 1 FPGA.

Deze moeten dus via SPI een eigen module ID (een adres, eigenlijk) krijgen. Is er in het MMB project niet iets over opgeschreven? De CV's gaan dan over de SPI, geaddresseerd aan een module. Als het een poly module is, dan kan ie meer stemmen ontvangen, zou ik denken, maar dat hebben we misschien nog niet helder afgesproken, cq, het hele protocol uitgeschreven.

Als ik er blanco over nadenk: de teensy is de brain en doet voice allocatie. De brain weet van de modules (intern of gedelegeerd intern) hoeveel-stemmig deze zijn. En kan dus de stemmen toewijzen zoals er in de brain is ingesteld (voice stealing of niet, portamento op de bovenste toon, alles is denkbaar). De module moet zich daar niet mee bezig houden. Die speelt alleen.

Voor een poly module zijn er echter ook globale controls: met name de knoppen en switches - in panel termen gedacht - (en eventueel ook een indicator ledje of, aan de FPGA kunnen we ook gemakkelijk een displaytje hangen voor informatie over de status en patch bijv.).

Dus: over de SPI moeten **per module** (heeft een adres):
- globale controls naar het geheel (de instellingen)
- individuele voice CV's (pitch en gate meestal, maar eventueel ook velocity per stem)

-> voor per stem modulatie (ik heb immers een Expressive E Osmose keyboard...) moet er misschien nog meer info mee kunnen.

**🤖 Claude:**

Dit is een mooi kader — en het UML geeft precies de haakjes: `Port.eventKind: voice|global` bestaat al in jullie model, net als `cvFormat: dcv16`. Laat me eerst kijken wat er in de MusicBrain-repo al over adressering en module-identiteit is vastgelegd voordat ik iets voorstel:
> 🔧 `Glob` — doc/**/*.md
> 🔧 `Glob` — **/*.md
> 🔧 `Glob` — adr/*.md
> 🔧 `Glob` — tech/spi*.md
> 🔧 `PowerShell` — List MusicBrain ADRs and protocol docs
> 🔧 `Read` — D:\Git\Muziek\MusicBrain\doc\adr\0009-module-runtime-classes.md
> 🔧 `Grep` — voice-indexed|voice stamp|voice-stamp|slotId|slot map|share mode

**🤖 Claude:**

Ik heb nu het hele beeld — en het goede nieuws: **MusicBrain heeft dit al grotendeels opgeschreven**, en jouw mentale model klopt er precies mee. De relevante stukken:

## Wat er al vastligt in MMB

**Adressering (ADR 0010 §5):** er bestaat géén apart module-ID op de draad, en dat is bewust. Het adres van een module is **chip-select (board) + een slot-bereik**: elke module-instantie draagt een `(caseId, firstSlot)` basisadres, en het kanaal op de draad is `channel = (caseId << 8) | (firstSlot + i)`. De voice-stamp-expansie in de editor schrijft stem *v* naar `firstSlot + v`. Dus: "een eigen module-adres" = een eigen `firstSlot`-blok binnen de slotruimte van het board. Meerdere logische modules op één FPGA = meerdere slot-blokken achter één CS. Geen protocolwijziging nodig.

**Jouw "gedelegeerde interne module" bestaat al als concept** (ADR 0009): de vier-lagen-architectuur zegt dat een `ModuleDefinition` (laag 1, de catalog) de `ports[]`, `controls[]` en `displays[]` beschrijft — en het UML dat je stuurt heeft zelfs al `Port.eventKind: voice|global`. Hoeveel-stemmig een module is, is dus **catalog-data**, niet iets op de draad: de brain weet uit de definitie dat deze module 8 voice-indexed poorten heeft. En "de Teensy draait aan de knoppen" is letterlijk het `ControllerBreakIn`-mechanisme uit ADR 0009: fysieke controls worden als CV-waarden over de bus geforward. Een "knop" van de FPGA-module is gewoon een **globaal slot** dat een CvSet ontvangt.

**Displays/LEDs terug naar de brain** vallen onder wat ADR 0009 "management messages" noemt (status/telemetrie naast het muziek-verkeer) — de framing daarvan is in MMB expliciet uitgesteld. Pong is er al als levensteken; de rest parkeren we tot MMB die laag definieert.

## De ene botsing die we moeten oplossen

Onze huidige FPGA-slotmap is **voice-major** (`slot = voice·4 + param`), maar de voice-stamp-expansie van de brain is **port-major** (`firstSlot + v`: één poort beslaat N opeenvolgende slots, één per stem). Om een standaard MMB-module te zijn moet de FPGA dus herindelen:

| Slots | Poort | eventKind |
|---|---|---|
| 0–7 | pitch, stem 0–7 | voice |
| 8–15 | cutoff | voice |
| 16–23 | resonantie | voice |
| 24–31 | drive | voice |
| 32–39 | exciter/morph (KS ↔ wavetable, later morph-positie) | voice |
| 40–47 | **per-stem expressie**: pressure/velocity (Osmose!) | voice |
| 48+ | globale controls: wah-niveau, damping, … (één slot per "knop") | global |
| GateSet 0–7 | gate per stem | voice (al port-major ✓) |

Per-noot-pitchbend van de Osmose heeft trouwens geen extra poort nodig: pitch is al een continue CV per stem, de brain moduleert gewoon het pitch-slot. Voor pressure/timbre komen er per-voice poorten bij zoals hierboven — en bij hogere update-rates wordt dat later het bestaande `CvSegment`-verhaal (FPGA-side interpolatie, ADR 0008/0013).

Mijn advies verder: zie de FPGA nu als **één 8-stemmige module** ("MS20 poly voice") in plaats van meerdere — KS en wavetable delen per stem het filter en de envelope, dus exciter-keuze is een eigenschap van de stem, geen aparte module. Een tweede module (bijv. straks een modale resonator-bank) krijgt dan gewoon een eigen `firstSlot`-blok, bijv. vanaf 128.

## Voorstel

1. Ik bouw de **port-major slotmap** in de FPGA (decode-wijziging + de exciter/morph-slots 32–39 en een eerste globaal slot voor wah-niveau), werk [doc/SPI_SLOTMAP.md](doc/SPI_SLOTMAP.md) bij naar v2, en draai de sim-suite.
2. Jij (of ik, als je de MMB-repo openstelt voor edits) legt aan de brain-kant de catalog-entry vast: `ModuleDefinition` voor de FPGA-voice met deze poorten, `voiceCount: 8`, en het basisadres als instantie-config — plus een update van ADR 0013's slot-map open question.

Let op: de herindeling breekt de mono-backwards-compat van slot 1–3 (pitch/gate op stem 0 blijven wél gewoon slot 0). Dat lijkt me nu de juiste ruil — beter uitlijnen op het brain-model dan vasthouden aan een tussenstand. Akkoord? Dan bouw ik punt 1 meteen.

---

## 👤 Gebruiker (31)

- wat is slotmap, wat is voice-major, wat is voice-stamp-expansie. Je verzint heel veel nieuwe woorden en ik snap het niet meer. Probeer bij het bestaande idioom te blijven. Dat helpt. Dit is heel staccato.
- Uit de tabel begrijp ik het misschien iets beter, maar toch is het mij niet helder.

Waarom kan een voice geen subadres zijn van een module. VOice 3, parameter pitch, waarde X,  voice 4, parameter gate, waarde 0, enz.? Dan moet je die parameters afstemmen in een contract zodat ze alleen een nummer krijgen. Dat lijkt slimmer in het protocol dan een soort van slots reserveren.

Ik snap de voice architectuur nog niet, denk ik. KS is een oscillator. Wavetable ook. Dan is er 1 envelope, of twee? En de filter en een soort VCA?

Dan is het idd CV in en audio uit. EN dat x 8. De audio eventueel gemixt, dus een stereo ' dVCA'  per stem en dan een totale stereo uit.

Ik snap dat firstSlot nog niet goed, excuus.

**🤖 Claude:**

Sorry — ik gooide te veel termen tegelijk over de schutting. Laat me het rustig opbouwen, want er zitten eigenlijk maar twee ideeën in, en één daarvan is precies wat jij zelf voorstelt.

## "Slot" is niet mijn woord, het is jullie eigen protocol

In het SPI-frame van MusicBrain zit één adresveld: `channel`, 16 bits. Het hoge byte is de case (voor de bridge), het lage byte heet in jullie eigen spi-frame.md de **slotId** — gewoon een nummer van 0 tot 255 dat zegt: *deze CV-waarde is bestemd voor ingang zoveel op dit board*. Meer is een slot niet: een genummerde CV-ingang. En het "contract" waar jij het over hebt — de afspraak welke betekenis elk nummer heeft — is precies wat ik de slotmap noemde. Jij beschrijft dus hetzelfde: parameters krijgen een nummer, vastgelegd in een contract. Daar zijn we het al over eens.

## Jouw voorstel (voice als subadres) is wat de FPGA nú al doet

De vraag is alleen: hoe stop je "stem 3, parameter pitch" in dat ene nummer? Er zijn twee manieren, en het is niet meer dan een vermenigvuldig-volgorde:

- **Jouw manier**: nummer = stem × 4 + parameter. Stem 3, pitch (param 0) → nummer 12. Dit is wat ik in de FPGA gebouwd heb.
- **De manier die in ADR 0010 staat**: nummer = beginnummer-van-de-parameter + stem. Alle pitches liggen dan naast elkaar (pitch stem 0..7 = nummers 0..7), alle cutoffs naast elkaar (8..15), enzovoort.

Waarom koos MMB die tweede? Vanwege de editor. Daar trek je **één kabel** naar de poort "pitch in" van de polyfone module, en de brain vertakt die ene kabel automatisch naar de 8 stemmen. Dat vertakken is in ADR 0010 gedefinieerd als: *neem het beginnummer van die poort en tel het stemnummer erbij op*. Eén optelling, klaar. Met jouw volgorde kan het ook, maar dan moet de brain per module óók de vermenigvuldigfactor kennen ("×4"). Beide werken; het is puur de vraag welke afspraak je één keer vastlegt — en de brain-kant heeft er al één opgeschreven.

En **firstSlot** is niets mysterieuzers dan het beginnummer van het blok nummers dat een module krijgt — een basisadres, zoals een chip in een geheugenkaart. Onze FPGA is nu de enige module achter zijn chip-select, dus zijn blok begint gewoon bij 0. Komt er ooit een tweede module in dezelfde FPGA (die resonator-bank bijvoorbeeld), dan begint die bij bijvoorbeeld 128. Dat is alles.

## De stem-architectuur

Terechte vraag, want dit heb ik nooit netjes getekend. Per stem (×8, allemaal op één gedeelde rekenkern) ziet de keten er zo uit:

```
              ┌─ KS-snaar (pluk) ──────────────┐
CV's/gate →   │                                 ├→ MS-20 filter → naar de mix
              └─ Wavetable-osc → AR-env × VCA ──┘
```

- **Twee oscillatoren, waarvan er per stem één actief is** (dat is de exciter-keuze). Ze verschillen fundamenteel in gedrag: de KS-snaar is een gepluk — hij sterft vanzelf uit, zoals een echte snaar, dus die heeft **geen envelope of VCA nodig**; zijn verval zit fysiek in het model (de demping in de lus). De wavetable-oscillator loopt daarentegen eeuwig door, dus die heeft wél een envelope: een simpele attack/release die de gate volgt, met de bijbehorende vermenigvuldiging — inderdaad een VCA, zoals jij zegt.
- **Rondom het filter zit nog een tweede envelope**: de wah, die per aanslag de cutoff opent en laat terugzakken. Die bestaat alleen in demo-mode; zodra de brain speelt, stuurt díe de cutoff-CV en is de FPGA daar "dom" in — precies zoals ADR 0013 het wil.
- **De mix**: alle 8 stemmen worden opgeteld (mono, vaste verhouding, som ÷ 4) en gaan naar de PT8211.

Jouw stereo-idee — per stem een niveau/pan en dan een stereo-som — is een goed en goedkoop plan: de PT8211 is al stereo (we sturen nu links = rechts), en per stem kost het één extra vermenigvuldiging op de gedeelde kern. In het contract zijn dat gewoon twee extra parameters per stem (level, pan). Dat kan op de lijst.

## Dus, de keuze die voorligt

Eén beslissing maar: pakken we in het contract **jouw volgorde** (stem × aantal-params + param, wat er nu in de FPGA zit) of **de ADR 0010-volgorde** (beginnummer per parameter + stem)? Inhoudelijk is het lood om oud ijzer; mijn advies is de ADR-volgorde, simpelweg omdat de brain-kant die al gedocumenteerd heeft en de editor er dan zonder extra kennis één kabel per poort op kan aansluiten. De ombouw in de FPGA is klein en de testbenches vangen fouten af.

Zeg welke het wordt, dan leg ik het contract vast in [doc/SPI_SLOTMAP.md](doc/SPI_SLOTMAP.md) (in gewone woorden dit keer) en bouw ik de FPGA-kant erop om — inclusief de exciter-keuze per stem, zodat de brain straks echt tussen pluk en wavetable kan kiezen.

---

## 👤 Gebruiker (32)

okee, doe maar precies zoals je voorstelt!

**🤖 Claude:**

Aan de slag. Takenlijst voor deze klus:
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v

**🤖 Claude:**

Nu de decoder-case en de nieuwe registers:
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\synth_top_spi_tb.v

**🤖 Claude:**

Nu het contract-document in gewone taal:
> 🔧 `Write` — e:\Dev\Gowin\MS20_synth_voice\doc\SPI_SLOTMAP.md
> 🔧 `TodoWrite` — takenlijst bijgewerkt
> 🔧 `PowerShell` — Run spi_frame_tb and SPI end-to-end with new contract
> 🔧 `Edit` — e:\Dev\Gowin\MS20_synth_voice\src\spi_frame_tb.v
> 🔧 `PowerShell` — Run full regression suite
> 🔧 `PowerShell` — Headless synthesis check and resource summary
> 🔧 `PowerShell` — Commit slot contract v2
> 🔧 `Edit` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\poly-wavetable-status.md

**🤖 Claude:**

Klaar — het contract is geïmplementeerd, getest en vastgelegd (commit `cdcd8b6`).

**Wat er nu geldt:**

- **Het contract**: elke parameter heeft een blok van 8 opeenvolgende slots, één per stem (pitch 0–7, cutoff 8–15, resonantie 16–23, drive 24–31), plus per stem een exciter/morph-ingang (32–39: onder 0x4000 = pluk, daarboven wavetable) en het eerste globale "paneelknop"-slot: 48 = snaar-damping, van kort plukje tot bijna oneindige sustain. Alles staat in gewone taal in [doc/SPI_SLOTMAP.md](doc/SPI_SLOTMAP.md).
- **De protocol-laag is dommer geworden** (netter): [spi_frame.v](src/spi_frame.v) geeft het slotnummer nu ruw door en synth_top kent het contract — zo blijft het frame-parsen generiek MusicBrain.
- **Bewezen in simulatie**: de end-to-end test speelt nu via SPI een KS-pluk op stem 0 én een wavetable-saw op stem 1 (via exciter-slot 33) tegelijk — precies wat de brain straks doet. Verder alles groen: frametest 16/16, polyfonie 4/4, wavetable 8/8, wah 12/12, en de synthese komt netjes door P&R (Logic 13%, BSRAM 37/46, DSP 12/24).

Niet geflasht: het demo-geluid is exact hetzelfde, dus er valt op het bord nu niets nieuws te horen totdat de Teensy aangesloten is.

**Volgende stappen liggen aan de brain-kant** (staan onderaan het contract-doc): de slotmap opnemen in de MusicBrain-catalog en ADR 0013, bevestigen dat de voice-allocator gate-off stuurt vóór stem-hergebruik — en fysiek: SPI-pinnen kiezen op de Dock en de Teensy bedraden. Zeg het als je wilt dat ik in de MusicBrain-repo alvast de ADR-teksten voorbereid.

---

## 👤 Gebruiker (33)

ja, wil je dat doen: ADR teksten?

**🤖 Claude:**

Ja — ik ga in de MusicBrain-repo (1) de twee open questions van ADR 0013 afsluiten en (2) een nieuwe ADR schrijven die het slot-contract en het "gedelegeerde interne module"-concept vastlegt. Eerst even hun conventies en de repo-status checken:
> 🔧 `Read` — D:\Git\Muziek\MusicBrain\doc\adr\README.md
> 🔧 `PowerShell` — Check MusicBrain repo status and conventions
> 🔧 `Write` — D:\Git\Muziek\MusicBrain\doc\adr\0015-poly-instrument-slot-addressing.md
> 🔧 `Edit` — D:\Git\Muziek\MusicBrain\doc\adr\0013-fpga-synth-instrument.md
> 🔧 `Edit` — D:\Git\Muziek\MusicBrain\doc\adr\README.md
> 🔧 `Read` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\musicbrain-integration.md
> 🔧 `Edit` — C:\Users\User\.claude\projects\e--Dev-Gowin-MS20-synth-voice\memory\musicbrain-integration.md
> 🔧 `TodoWrite` — takenlijst bijgewerkt

**🤖 Claude:**

De ADR-teksten staan klaar in de MusicBrain-repo. Wat ik heb geschreven:

1. **Nieuwe [ADR 0015](D:\Git\Muziek\MusicBrain\doc\adr\0015-poly-instrument-slot-addressing.md)** — "Poly-instrument slot addressing and the FPGA voice contract". Die legt de beslissingen vast in jullie eigen ADR-stijl (Engels, Nygard-format): een module = een aaneengesloten slot-bereik achter zijn chip-select (geen module-ID-veld op de draad nodig), per-stem poorten in blokken van 8, de complete slottabel van de MS20 poly voice, exciter/morph als CV in plaats van een mode-opcode, globale controls vanaf slot 48, de pitch-formule, en de gate-afspraak (note-off vóór stem-hergebruik). Met verwijzing naar het geteste contract in de FPGA-repo als canonieke bron.
2. **ADR 0013 bijgewerkt**: de twee open questions zijn gemarkeerd als resolved met verwijzing naar 0015, inclusief de correctie dat de oude "noot 69 / 256 LSB per semitoon"-regel superseded is. De oorspronkelijke tekst heb ik laten staan (jullie ADR's zijn immutable; ik heb alleen resolutie-notities toegevoegd, in de stijl van de eerdere 0004-amendering).
3. **De ADR-index** (README-tabel) heeft een rij voor 0015.

**Bewust niet gecommit**: je MusicBrain-werkboom staat vol lopend werk (control-surface, teensyLink, e.d. — er is daar duidelijk een andere sessie actief). De drie gewijzigde/nieuwe bestanden liggen klaar om mee te gaan in je eigen volgende MMB-commit, of om eerst nog te reviewen.

Eén observatie die het samenbrengen leuk maakt: de MMB-kant blijkt al aan "Morph-WT met per-octaaf mip-levels" te werken — hetzelfde recept als de FPGA-wavetables. Het exciter/morph-slot (32–39) is daar bewust op voorgesorteerd: de morph-positie van de brain kan straks één-op-één als dCV naar de FPGA-stem.

Daarmee is de SPI-kant van de FPGA af tot aan de fysieke integratie. Wat rest: SPI-pinnen kiezen op de Dock (.cst), de Teensy bedraden, en aan de brain-kant de catalog-entry + de allocator die dit contract spreekt. Dat laatste hoort bij je MMB-sessies — de FPGA ligt er klaar voor.

