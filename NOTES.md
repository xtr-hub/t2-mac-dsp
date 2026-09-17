# Debugging notes — the five Fedora packaging bugs

Investigated: 2026-09-17 · Machine: MacBookPro15,4 (13" 2019, i5-8257U)
Environment: Fedora 44 + t2linux kernel 7.1.9 · PipeWire 1.6.8 · WirePlumber 0.5.14

## TL;DR

Fedora's `t2linux-audio` package **already ships the complete DSP data and
config**, but on T2 hardware **it has never worked** — because of five defects
spread across packaging and upstream code.

This file documents them so you can (a) check whether upstream has fixed them,
and (b) find the culprit quickly when reproducing on another machine.

## The five defects

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

### 3. WirePlumber `software-dsp.rules` read races with config loading

`/usr/share/wireplumber/scripts/node/software-dsp.lua` reads its config once,
at script load time:

```lua
config.rules = Conf.get_section_as_json("node.software-dsp.rules", Json.Array{})
```

If conf.d has not been merged yet at that moment, it gets an empty array and
`match_rules` will never match anything.

**Observed**: with an identical config, the rule matched 7 times between
22:04–22:07 (`DSP rule found`), then **0 times in every subsequent instance**.

### 4. `find-defined-target.lua` target matching

In the same script, `target.object` given as a *string* goes through a loop
that matches on `node.name`. Combined with defect 3, `target.object` reliably
fails to resolve.

> Note: this was misdiagnosed during the investigation. On this machine
> (`wireplumber 0.5.14-1.fc44`) line 88 reads `lutils.canLink (si_props, lnkbl)`,
> which matches the RPM — i.e. it is *not* a bug there. **Always verify against
> the packaged file before reporting.**

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

**`capture.volumes` uses a very steep cubic curve**:

```
sink volume 100% -> internal   0 dB
sink volume  75% -> internal -25 dB
sink volume  50% -> internal -37 dB
```

This is by design (volume control is handed off to the loudness compensator).
**Do not change `min`** — setting it to 0 collapses the mapping range to
`[0,0]`, making the volume stuck at maximum and unadjustable. Either keep it
as shipped or remove the block entirely.

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
