# Debugging notes — the five Fedora packaging bugs

**Language: English | [简体中文](NOTES.zh-CN.md)**

Investigated: 2026-09-17 · Machine: MacBookPro15,4 (13" 2019, i5-8257U)
Environment: Fedora 44 + t2linux kernel 7.1.9 · PipeWire 1.6.8 · WirePlumber 0.5.14

## TL;DR

Fedora's `t2linux-audio` package **already ships the complete DSP data and
config**, but on T2 hardware **it has never worked** — because of three defects
in how the package is put together.

This file documents them so you can (a) check whether upstream has fixed them,
and (b) find the culprit quickly when reproducing on another machine.

**Only defects 1, 2 and 5 are confirmed**, each with reproducible evidence
below. Defects 3 and 4 are kept for the record but are explicitly *retracted*
or *unconfirmed* — they were suspected during debugging and did not survive
verification. Do not report them upstream.

## The confirmed defects

### 1. udev rule installed into a directory udev never scans

```
shipped at:  /usr/lib64/udev/rules.d/99-t2-audio-rename.rules
required at: /usr/lib/udev/rules.d/
```

udev only scans `/usr/lib/udev/rules.d/`, `/etc/udev/rules.d/` and
`/run/udev/rules.d/`. **The `lib64` copy is never read**, so the sound card id
stays at `Audio` forever.

For contrast, the sibling package `t2ncm` installs its rule correctly at
`/usr/lib/udev/rules.d/90-network-t2-ncm.rules`.

**Verify**: `udevadm test /sys/class/sound/card0 2>&1 | grep t2-audio` — no
output means it was never loaded.

### 2. Match key exceeds ALSA's card-id length limit

In `/usr/share/wireplumber/wireplumber.conf.d/99-t2-audio.conf`:

```
{ alsa.id = "t2-MacBookPro15,4", api.alsa.pcm.stream = "playback" }
            ↑ 17 characters
```

ALSA card ids are capped at **15 characters**, so this is truncated and the
rule can **never match**.

The upstream project (`lemmyg/t2-apple-audio-dsp`) uses the short id `t2-15_4`
precisely to dodge this, and its rule file says so in a comment.
**The Fedora package does not.**

### 3. WirePlumber `software-dsp.rules` — NOT CONFIRMED, do not report

`/usr/share/wireplumber/scripts/node/software-dsp.lua` reads its config once,
at script load time:

```lua
config.rules = Conf.get_section_as_json("node.software-dsp.rules", Json.Array{})
```

If conf.d has not been merged yet at that moment, it would get an empty array
and `match_rules` would never match anything.

**Why this is not being reported**: the observation was "the rule matched 7
times in one window, then 0 times afterwards" — but that was recorded while
the config files were being rewritten repeatedly by hand during debugging.
**A stale or malformed config of our own produces the same symptom**, so this
cannot be attributed to upstream without a clean reproduction. Left here as an
open question, not a finding.

### 4. `find-defined-target.lua` — RETRACTED, it is not a bug

This was initially believed to be a defect: line 88 passes what looked like a
loop-external variable to `canLink`. Verifying against the packaged file
disproves it:

```bash
rpm -ql wireplumber | grep find-defined-target     # location
# wireplumber 0.5.14-1.fc44, line 88:
#   lutils.canLink (si_props, lnkbl) then         <- matches the RPM exactly
```

**The packaged file is correct.** This entry is kept only as a reminder of how
the mistake happened: a line read early in the investigation was misremembered
as `target`, and a "fix" was applied to a system file on that basis. **Always
re-check against the shipped file, and prefer `rpm -V` / SHA256 over memory.**

### 5. FIR paths in `graph.json` contain an extra hyphen ⚠️

```json
"filename": ["/usr/share/t2-linux-audio/15_4/front-48.wav", ...]
                          ↑ extra hyphen
actual dir:  /usr/share/t2linux-audio/15_4/
```

**This is the direct cause of total silence.** The convolvers cannot load any
FIR file and the whole filter-chain graph fails to start:

```
failed file /usr/share/t2-linux-audio/15_4/front-96.wav: No such file or directory
spa.filter-graph: cannot create plugin instance 0 rate:48000
pw.stream: error (-2) can't start graph
```

**Note**: fixing defects 1–4 does not help here — even a working WirePlumber
path would still hit this one.

## Why bypass WirePlumber

The intended chain is:

```
udev renames card -> WirePlumber monitor.alsa.rules renames nodes
                  -> node.software-dsp.rules attaches graph.json per model
```

That chain depends on defects 1–4 all being absent. Rather than patch each one
(and touch system files), this project talks to PipeWire's native
`libpipewire-module-filter-chain` directly:

| | WirePlumber path | Direct filter-chain |
|---|---|---|
| Depends on | software-dsp machinery | native PipeWire module |
| Affected by | defects 1,2,3,4 | none |
| Privileges | root, writes `/etc` and `/usr/share` | **user-level only** |
| Rollback | restore several files | **delete one file** |

Key insight: **the `filter.graph` section of `graph.json` already *is* the
argument format of `libpipewire-module-filter-chain`** — the only difference is
syntax (JSON's `"k": v` with commas vs SPA-JSON's `k = v` without).

## Other findings

**UCM node structure.** One ALSA device produces several nodes sharing
`device.id` and `api.alsa.path`:

```
alsa_output.hw_t2-15_4_0                        Audio/Sink/Internal  4ch  ← hardware
alsa_output.pci-...HiFi__Speaker__sink          Audio/Sink           4ch  ← UCM virtual
alsa_output.pci-...HiFi__Speaker__sink.split    Stream/.../Internal       ← its internal stream
```

**Do not rename the `hw_` node** — the UCM loopback's `.split` stream has a
hard-coded `target.object` pointing at it; renaming it breaks the UCM link.

**`capture.volumes` needs care, and the shipped settings are already right.**
It hands volume control off to the DSP's loudness compensator, mapping the
sink volume onto a `[min, max]` dB range:

```
value = min + (max - min) * f(v)     f(v) = v (linear) | cbrt(v) (cubic)
```

(see `sync_volume()` in `spa/plugins/filter-graph/filter-graph.c`).

*`v` is the amplitude, not the slider.* This is the trap that cost a debugging
session. `impl_set_props()` copies `SPA_PROP_channelVolumes` straight into
`vol->volumes[]`, and those are **linear amplitudes** under PipeWire's standard
taper (amplitude = slider³). Verified on this machine:

```
wpctl 0.25 -> channelVolumes 0.015625      (0.25³)
wpctl 0.50 -> channelVolumes 0.125         (0.50³)
wpctl 0.75 -> channelVolumes 0.421875      (0.75³)
```

So with `scale = "cubic"`, `cbrt(v)` recovers the slider position, and the
shipped `min = -42.5` is simply

```
dB = -42.5 * (1 - slider)
```

— a normal curve, close to the standard taper (60·log₁₀(slider)):

```
slider   standard taper   shipped cubic/-42.5   linear/-36 (WRONG)
 100%          0 dB                  0 dB                0 dB
  75%       -7.5 dB              -10.6 dB            -20.8 dB
  50%      -18.1 dB              -21.3 dB            -31.5 dB
  25%      -36.1 dB              -31.9 dB            -35.4 dB
  10%      -60.0 dB              -38.3 dB            -36.0 dB
```

*Do NOT "fix" `cubic` into `linear`.* It reads like the obvious improvement and
is the opposite: `linear` throws the raw amplitude into the range, giving
`dB = min + (max - min)*slider³`. With `min = -36` that is ~10 dB quieter at the
halfway point and nearly flat below 25% — quiet enough to look like the speakers
have died. Tried here, reverted.

*Never set `min = 0`.* It collapses the mapping range to `[0, 0]`, which pins
the volume at maximum and makes it unadjustable — the slider still moves but
nothing changes.

Slider 0 is true silence regardless: `impl_set_props()` applies a hard 0/1 soft
volume when the slider hits zero.

Also relevant: **WirePlumber persists the runtime volume** under
`~/.local/state/wireplumber/`. While tuning, `wpctl set-volume` leaves values
behind that survive a service restart — verified: setting 0.62 and restarting
`pipewire`/`pipewire-pulse`/`wireplumber` brings back 0.62, not the
`state.default-volume` from the config. That property only applies when there
is no persisted state, so it is not a reliable way to choose a starting volume.
Use `wpctl set-volume` (and `wpctl set-volume … --limit` to cap it).

**`target.object` is counterproductive.** PipeWire's filter-chain gives up if
the target cannot be matched at module load time (`defined target not found`),
and the target node may not exist yet. Removing it and letting the session
manager connect automatically is more reliable.

## Useful commands

```bash
# was the config file read?
journalctl --user -u pipewire -b | grep "50-t2-dsp"

# did the graph fail to start?
journalctl --user -u pipewire -b | grep -E "can't start graph|failed file"

# nodes and ports
pw-dump | python3 -c "..."     # see usage in install.sh
pw-link -l

# internal volume control values
journalctl --user -u pipewire -b | grep "filter-graph.*volume"

# card id / did the udev rule take effect?
cat /sys/class/sound/card0/id
udevadm test /sys/class/sound/card0 2>&1 | grep t2-audio
```

## Upstream references

- `lemmyg/t2-apple-audio-dsp` — the T2 team's DSP project (Ubuntu-oriented)
- `t2linux/wiki` — audio-config guide
- `angelobdev/t2-easyeffects-preset` — the EasyEffects route (the other option)
