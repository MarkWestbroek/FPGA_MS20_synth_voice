# zijn er standaarden over de exacte spanningsrange en welke noot dan bijv 1V is?
Ja, er zijn standaarden, al is er in de analoge wereld een belangrijk verschil tussen de spanningsrange en de absolute noottoewijzing. Waar de spanningsrange redelijk strak gedefinieerd is, is de koppeling aan een specifieke noot vaak een kwestie van afspraak en handmatige afstemming (tuning). [1, 2] 
------------------------------
## 1. De Spanningsrange (De Hardware)
Binnen het populaire Eurorack-formaat zijn er twee gangbare standaarden voor pitch-CV: [3] 

* 0 V tot +10 V (Unipolair): Dit biedt een bereik van exact 10 octaven. Veel sequencers en MIDI-naar-CV-converters sturen dit uit.
* -5 V tot +5 V (Bipolair): Dit biedt ook een bereik van 10 octaven, maar duikt onder nul voor de allerlaagste tonen. [4, 5] 

Opmerking: De meeste analoge oscillators (VCO's) kunnen prima overweg met negatieve spanningen. Ze trillen dan simpelweg nóg langzamer. [5] 
------------------------------
## 2. Welke noot hoort bij welke spanning?
Analoge oscillators hebben geen ingebouwd geheugen dat weet wat een "Centrale C" is. Zij ontvangen puur een signaal en verhogen hun frequentie op basis daarvan. Om software en hardware toch met elkaar te laten communiceren, zijn er afspraken gemaakt: [2, 6] 
## De Software-standaard (VCV Rack)
In virtuele modulaire software zoals [VCV Rack](https://vcvrack.com/manual/VoltageStandards) is de afspraak wél digitaal vastgelegd: [7] 

* 0 V = C4 (Middle C / Centrale C, ~261.63 Hz)
* 1 V = C5
* 2 V = C6, enzovoort.
* -4 V = C0 (de laagst bruikbare noot). [7, 8] 

## De Hardware-afspraak (Arturia, Moog, Doepfer)
Bij fysieke hardware kiezen veel fabrikanten (zoals [Intellijel](https://intellijel.com/support/eurorack-101/) of Arturia) er juist voor om de laagste C op 0 Volt te zetten om negatieve spanningen te voorkomen: [4] 

* 0 V = C0 of C1
* 1 V = C1 of C2
* 5 V = C5 (Centrale C) [1, 9] 

------------------------------
## Waarom dit in de praktijk (bijna) nooit een probleem is
In de praktijk maakt het voor een analoge synthesizer niet uit of je sequencer 0 V of 5 V uitstuurt voor een C. Dit los je op met de Tune-knop (coarse/fine) op je oscillator: [1, 2, 7] 

   1. Je drukt de C in op je keyboard of sequencer (deze stuurt nu bijvoorbeeld 1 V uit).
   2. Je draait aan de Tune-knop van je oscillator tot je op je gehoor (of met een stemapparaat) een exacte C hoort.
   3. Vanaf dat moment staat je systeem gekoppeld: elke stap van 1 V omhoog via je keyboard is nu gegarandeerd weer een C, maar dan een octaaf hoger. [1, 4, 7] 

Loop je bij een specifieke module of synth aan tegen het probleem dat de octaven niet mooi matchen, of wil je weten hoe je een MIDI-keyboard correct koppelt aan je systeem?

[1] [https://www.reddit.com](https://www.reddit.com/r/modular/comments/1jgd83p/pitch_voltage_standards/)
[2] [https://www.facebook.com](https://www.facebook.com/groups/eurorackmodular/posts/2071070036668235/)
[3] [https://www.reddit.com](https://www.reddit.com/r/synthdiy/comments/8iex2l/eurorack_voltage_standards/)
[4] [https://intellijel.com](https://intellijel.com/support/eurorack-101/)
[5] [https://forum.pjrc.com](https://forum.pjrc.com/index.php?threads/cv-voltage-from-modular-to-control-teensy-oscillator.52362/)
[6] [https://www.rakt.info](https://www.rakt.info/post/understanding-voltage-in-eurorack)
[7] [https://vcvrack.com](https://vcvrack.com/manual/VoltageStandards)
[8] [https://community.vcvrack.com](https://community.vcvrack.com/t/ability-to-enter-note-values-into-parameters/20759)
[9] [https://www.lfusionmodular.com](https://www.lfusionmodular.com/eurorack/synthesizer-system/)

# wat is de midi noot 0?
MIDI-noot 0 is de allerlaagste noot binnen de MIDI-standaard. De exacte naam van deze noot hangt af van de fabrikant of software die je gebruikt, maar de toonhoogte is altijd hetzelfde: een extreem lage C met een subsonische frequentie van 8,18 Hz. [1, 2] 
De twee meest gebruikte naamgevingen zijn:

* C-1 (C min één): Dit is de officiële [MIDI-specificatie van de MIDI Association](https://en.wikipedia.org/wiki/MIDI_tuning_standard) en wordt onder andere gebruikt door [Audiodev](https://audiodev.blog/midi-note-chart/) en DAWs zoals Cubase.
* C-2 (C min twee): Dit wordt veel gebruikt door Roland en in software zoals Ableton Live en Logic Pro. [3, 4, 5] 

## Waarom is er een verschil in de naam?
Dit komt doordat fabrikanten er vroeger niet uitkwamen hoe ze "Centrale C" (MIDI-noot 60) moesten noemen. Sommigen noemden het C3, anderen C4 of C5. Als Centrale C in jouw DAW wordt weergegeven als C3, dan schuift de hele schaal naar beneden en wordt noot 0 logischerwijs C-2. [1, 3] 
## Wat betekent dit voor CV / Modulair?
Als je een MIDI-naar-CV-converter gebruikt (zoals een [Intellijel µMIDI](https://intellijel.com/support/eurorack-101/) of [Arturia BeatStep](https://forum.vintagesynth.com/viewtopic.php?t=112849)), bepaalt de firmware welke spanning er bij MIDI-noot 0 hoort. [6, 7] 

* Bij een converter die 0 V tot 10 V uitstuurt, is MIDI-noot 0 vrijwel altijd gelijk aan 0 V.
* Bij een converter die -5 V tot +5 V uitstuurt, is MIDI-noot 0 vaak niet eens te bereiken, omdat 0 V daar meestal gekoppeld is aan een hogere noot zoals MIDI-noot 60 (Centrale C). [6, 8] 

Wil je weten hoe je jouw specifieke DAW of MIDI-controller zo instelt dat de octaven correct overeenkomen met je modulaire synthesizer?

[1] [https://midi.teragonaudio.com](http://midi.teragonaudio.com/tutr/notenum.htm)
[2] [https://www.onlinemusictools.com](https://www.onlinemusictools.com/midi-notes/)
[3] [https://audiodev.blog](https://audiodev.blog/midi-note-chart/)
[4] [https://en.wikipedia.org](https://en.wikipedia.org/wiki/MIDI_tuning_standard)
[5] [https://www.modwiggler.com](https://www.modwiggler.com/forum/viewtopic.php?t=186603)
[6] [https://www.facebook.com](https://www.facebook.com/groups/eurorackmodular/posts/2071070036668235/)
[7] [https://forum.vintagesynth.com](https://forum.vintagesynth.com/viewtopic.php?t=112849)
[8] [https://www.reddit.com](https://www.reddit.com/r/synthesizers/comments/z3n68c/for_a_standalone_synthesizer_with_its_own/)
