# t2-mac-dsp — Per-driver speaker DSP for Apple T2 MacBooks

**Language: English | [简体中文](README.zh-CN.md)**

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
| `15_1` `15_4` | MacBookPro15,1 / 15,4 |
| `16_1` `16_2` `16_3` `16_4` | MacBookPro16,1 / 16,2 / 16,3 / 16,4 |

(2.1.0 also shipped `15_2`; 2.2.0 dropped it. `install.sh` still lists it as
supported so that it keeps working with the older package.)

Check yours: `cat /sys/class/dmi/id/product_name`

## Requirements

### Hardware

An Apple T2 MacBook (2018–2020 Intel models with the T2 security chip) whose
model appears in the table above. Verify with:

```bash
cat /sys/class/dmi/id/product_name    # e.g. MacBookPro15,4
ls /usr/share/t2linux-audio/          # which model dirs are installed
```

### Software

| Component | Minimum | Why |
|---|---|---|
| t2linux kernel | — | The `t2bce_audio` driver stack. A stock distribution kernel does not drive T2 audio at all. |
| `wireplumber` | ≥ 0.5.1 | Session manager |
| `pipewire` | ≥ 1.0 | Must include `libpipewire-module-filter-chain` |
| `pipewire-module-filter-chain-lv2` | — | LV2 backend used by the DSP graph |
| `lsp-plugins-lv2` | ≥ 1.2.13 | Compressors, loudness compensation |
| `lv2-bankstown` | ≥ 1.1.0 | Virtual bass |
| `lv2-triforce` | ≥ 0.2.0 | Used by `mic.json` |
| `t2linux-audio` | ≥ 2.1.0 | **Ships the FIR data and `graph.json`** |

All of the plugin packages come in as dependencies of `t2linux-audio`, so
installing that one package is normally enough. Verify:

```bash
rpm -q --requires t2linux-audio
```

`install.sh` checks the ones that are actually referenced by the DSP graphs
and tells you what is missing, with the install command for your package
manager. (Note `lv2-swh-plugins` is listed as a dependency upstream but is not
referenced by any of the models' graphs, so it is not checked.)

### Tested on

**Exactly one configuration** — every claim in this repository comes from it:

```
Machine      MacBookPro15,4   (13" 2019, i5-8257U)
Distro       Fedora Linux 44 (Workstation Edition)
Kernel       7.1.9-200.t2.fc44.x86_64
PipeWire     1.6.8
WirePlumber  0.5.14
t2linux-audio 2.2.0-1.20260917git9527bff.fc44
```

**The other eight supported models are untested here.** `t2linux-audio` ships
their data and the graph format is identical, so the approach should carry
over — but treat it as unverified.

**Other distributions are untested too.** Nothing in this repo is
Fedora-specific (it only writes under `~/.config/pipewire/`), but package
names differ and the packaging bugs documented in [NOTES.md](NOTES.md) are
Fedora's — they may or may not exist elsewhere.

## Install

```bash
./install.sh              # default convolver gain 1.0 (unity)
./install.sh 4.0          # louder, at the cost of headroom — see Volume
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

`install.sh` uses a convolver gain of **1.0** — unity, which is what upstream's
`0.92` amounts to in practice.

An earlier version of this project defaulted to **4.0** (+12.0 dB), on the theory
that FIR correction is peak-cutting and the lost level needs making up.
**Measuring the filters shows that theory was wrong.** The two FIRs are a
crossover, not two copies of one calibration:

| Filter | 200 Hz | 400 Hz | 3 kHz | 10 kHz |
|---|---|---|---|---|
| `front-*.wav` (woofer) | +0.1 | +2.3 | −14.6 | −41.3 |
| `rear-*.wav` (full band) | −0.7 | +1.8 | −4.0 | −7.6 |

Each is ~0 dB in the band its own driver reproduces. `front-48.wav` does measure
an L2 norm of −13.4 dB, but that is the low-pass rejecting HF — not attenuation
in the woofer's band. There is no broadband level to make up, so unity is right.

**If you do raise the gain, know what it costs.** The gain applies to all four
convolvers equally — giving the two pairs different gains would break the
crossover balance by ~12 dB — and the volume curve tops out at 0 dB, so the
signal reaches the output `gain` dB over full scale at full volume:

| Gain | Rear path reaches 0 dBFS above |
|---|---|
| **1.0** | **only at 100% — the whole range below that is clean** |
| 2.0 (+6.0 dB) | ~86% volume |
| 4.0 (+12.0 dB) | ~72% volume |
| 5.0 (+14.0 dB) | ~67% volume |

Past that point the rear path rides the limiter. The output stays bounded, but
dynamics collapse and sustained loud playback puts more stress on those drivers.
Keeping the gain at 1.0 and using the volume slider gives the same loudness with
the entire range usable.

### Volume curve

`capture.volumes` hands the sink's volume over to the DSP's loudness
compensator instead of applying it in software:

```
value = min + (max - min) * f(v)     f(v) = v (linear) | cbrt(v) (cubic)
```

The value written is a **dB** gain, and `v` is *not* the slider position — it is
the linear amplitude from `SPA_PROP_channelVolumes`. Since PipeWire's standard
taper is exactly amplitude = slider³, `cbrt(v)` recovers the slider, and the
shipped `cubic` + `min = −42.5` evaluates to `dB = −42.5·(1 − slider)` — a sane
curve close to the standard taper (60·log₁₀(slider)):

| Slider | Standard taper | Shipped curve |
|---|---|---|
| 100% | 0 dB | 0 dB |
| 75% | −7.5 dB | −10.6 dB |
| **50%** | **−18.1 dB** | **−21.3 dB** |
| 25% | −36.1 dB | −31.9 dB |
| 10% | −60.0 dB | −38.3 dB |

**This project passes it through unchanged.** Switching to `scale = "linear"`
looks like the obvious fix and is not — it feeds the raw amplitude into the
range directly, giving `dB = −36 + 36·slider³`: roughly 10 dB quieter at the
halfway point, and nearly flat below 25%. That was tried here and reverted. If
the speakers ever sound ~10 dB quieter for no reason, check `scale` under
`capture.volumes` in the generated config.

Slider 0 is true silence either way: the module applies an additional hard 0/1
soft volume when the slider hits zero.

Note that WirePlumber **persists** the volume in
`~/.local/state/wireplumber/`, so it survives service restarts;
`state.default-volume` only applies when there is no persisted state, so it is
not a reliable starting volume. Use `wpctl set-volume <id> <value>` and, if you
want a ceiling, `wpctl set-volume <id> <value> --limit <max>`.

Change the gain via `./install.sh 4.0`, or edit `gain` in the config and restart:

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
```

## FAQ

**Why does the sound settings panel show only 2 speakers?**

Expected. The DSP takes stereo in and produces 4 channels out — **the four-way
split happens inside the DSP**. The system UI only reflects the input side.
All four drivers are working.

**Do the volume keys still work?**

Yes. The volume curve is left as upstream ships it, which already tracks the
standard audio taper — see "Volume curve" above.

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
