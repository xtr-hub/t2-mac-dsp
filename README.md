# t2-mac-dsp — Per-driver speaker DSP for Apple T2 MacBooks

Enable **per-driver speaker correction** on Apple T2 MacBooks under Linux,
reproducing the "multi-driver crossover + driver protection" chain that macOS
runs natively.

## What this is

macOS drives the built-in speakers through a private DSP that processes **each
driver individually**: every driver gets its own FIR correction curve plus
independent compressor and limiter stages. On Linux, the `t2bce_audio` driver
is a **pass-through** — it hands the signal straight to the drivers, which is
why the speakers sound distinctly worse (thin bass, harsh upper-mids).

The Asahi Linux team measured the speakers of each model and generated FIR
correction data; the T2 Linux team packaged it into `t2linux-audio`.
**Fedora already ships the data — it just never worked** (see [NOTES.md](NOTES.md)).

This project wires that data into a **native PipeWire `filter-chain`**,
bypassing the broken WirePlumber `software-dsp` path entirely.

## Signal chain

```
Application (stereo)
   ↓
DSP sink   "MacBook Pro xx,x DSP Speakers"
   ↓
bankstown virtual bass        ← psychoacoustic bass, no driver excursion
   ↓
Loudness compensation (loud_comp)
   ↓
4x FIR convolution            ← front L/R + rear L/R, independent curves
   ↓
Crossover compression → per-pair limiting
   ↓
4-channel output (AUX0-3)
   ↓
Hardware (four drivers)
```

## Supported models

Models with DSP data in `/usr/share/t2linux-audio/<dir>/`:

| Directory | Model |
|---|---|
| `8_1` `8_2` `9_1` | MacBookAir8,1 / 8,2 / 9,1 |
| `15_1` `15_2` `15_4` | MacBookPro15,1 / 15,2 / 15,4 |
| `16_1` `16_2` `16_3` `16_4` | MacBookPro16,1 / 16,2 / 16,3 / 16,4 |

Check yours: `cat /sys/class/dmi/id/product_name`

## Install

```bash
./install.sh              # default convolver gain 3.0
./install.sh 4.0          # louder
```

**Entirely user-level — no root required.** Writes only under `~/.config/pipewire/`.

The script detects your model, generates the config from the official
`graph.json`, installs it, restarts the audio stack and verifies the result.

## Uninstall

```bash
./uninstall.sh
```

Removes the config, restarts the audio stack, returns to pass-through.

## Volume

**FIR correction is mostly peak-cutting, and the removed energy does not come
back — so overall level is necessarily lower than pass-through.** The official
`graph.json` uses `gain = 0.92` and applies no compensation, so the stock
result is quiet.

`install.sh` defaults to a convolver gain of **3.0** (≈ +10 dB) to compensate.
This is a fixed gain: it scales the signal without altering the frequency
response, and the limiter stages still protect the drivers.

| Gain | Approx. | When |
|---|---|---|
| 2.0 | +6.7 dB | too loud |
| **3.0** | **+10.3 dB** | **default** |
| 4.0 | +12.7 dB | still too quiet |
| 5.0 | +14.7 dB | near the limit; dynamics get flattened |

Change it via `./install.sh 4.0`, or edit `gain` in the config and restart:

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
```

## FAQ

**Why does the sound settings panel show only 2 speakers?**

Expected. The DSP takes stereo in and produces 4 channels out — **the four-way
split happens inside the DSP**. The system UI only reflects the input side.
All four drivers are working.

**Do the volume keys still work?**

Yes. The volume curve is left at the official design (`capture.volumes` untouched).

**How is this different from EasyEffects?**

EasyEffects applies software EQ to a **stereo** signal and cannot address
individual drivers. This project corrects **each driver separately**. They
operate at different levels and will fight each other — once DSP is active you
don't need EasyEffects.

**Is it actually better than pass-through?**

Depends on your ears and your model. DSP fixes uneven frequency response at the
cost of somewhat lower overall level. If you don't like it, `./uninstall.sh`
returns to pass-through.

## Layout

```
t2-mac-dsp/
├── README.md              this file
├── NOTES.md               the five Fedora packaging bugs + debugging notes
├── install.sh             installer
├── uninstall.sh           uninstaller
├── conf/
│   └── 50-t2-dsp.conf     generated config (for reference)
└── tools/
    └── gen-conf.py        generates the config from the official graph.json
```

## About the data

**This repository contains no audio data.** The FIR filter files and DSP graph
definitions are read at runtime from the system package `t2linux-audio`; this
project only provides the glue that wires them into PipeWire.

That is why MIT is sufficient here — no upstream data is redistributed. The
data itself originates from the Asahi Linux project and the T2 Linux team;
see `/usr/share/t2linux-audio/*/LICENSE.asahi-audio` on an installed system.

## Credits

- **Asahi Linux** team — speaker frequency-response measurements and FIR generation
- **T2 Linux** team — `t2linux-audio` package and DSP graph definitions
- `chadmed` (bankstown), `lsp-plugins` — the LV2 plugins used
