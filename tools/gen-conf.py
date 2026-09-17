#!/usr/bin/env python3
"""
Convert the graph.json shipped by t2linux-audio into a native PipeWire
filter-chain config.

Why a conversion is needed: Fedora's t2linux-audio package provides the DSP
graph in WirePlumber's software-dsp format (graph.json), but that path does not
work on T2 machines due to several defects (see NOTES.md). Meanwhile, the
`filter.graph` section inside graph.json **is already** the argument format of
libpipewire-module-filter-chain — the only difference is syntax:
JSON uses `"k": v` with commas, SPA-JSON uses `k = v` without.

So we feed it straight to the native PipeWire module, bypassing WirePlumber
entirely.

Usage:
    gen-conf.py <model_dir> [output_file] [convolver_gain]

    <model_dir>     e.g. 15_4 (MacBookPro15,4), 16_1, ...
                    corresponds to /usr/share/t2linux-audio/<model_dir>/
    output_file     defaults to ./50-t2-dsp.conf
    convolver_gain  defaults to 4.0 (see below)

About the convolver gain:
    FIR correction is predominantly peak-cutting, and the removed energy does
    not come back — so overall level necessarily drops. The official graph.json
    uses gain=0.92 and applies no compensation, which is why the stock result
    sounds quiet. We default to 4.0 (about +12.7 dB) as compensation.

    A fixed gain only scales the signal, it does NOT alter the frequency
    response, and the downstream limiter stages still protect the drivers.
    Tune to taste: 2.0 ~ +6.7dB, 3.0 ~ +10.3dB, 4.0 ~ +12.7dB, 5.0 ~ +14.7dB.

    Note this is +12.7 dB above upstream's value — a deliberate deviation, not
    an upstream-validated setting. See RISKS in README.
"""
import json
import os
import sys

DEFAULT_MODEL = "15_4"
DEFAULT_GAIN = 4.0
SRC_DIR = "/usr/share/t2linux-audio"


def spa(v, ind=0):
    """Recursively render a Python object as SPA-JSON text."""
    pad, pad2 = '    ' * ind, '    ' * (ind + 1)
    if isinstance(v, dict):
        if not v:
            return '{}'
        body = '\n'.join(f'{pad2}{k} = {spa(x, ind + 1)}' for k, x in v.items())
        return '{\n' + body + f'\n{pad}}}'
    if isinstance(v, list):
        if not v:
            return '[]'
        if all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v):
            return '[ ' + ' '.join(str(x) for x in v) + ' ]'
        body = '\n'.join(f'{pad2}{spa(x, ind + 1)}' for x in v)
        return '[\n' + body + f'\n{pad}]'
    if isinstance(v, str):
        return '"' + v.replace('\\', '\\\\').replace('"', '\\"') + '"'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if v is None:
        return 'null'
    return str(v)


def build(model, gain):
    src = os.path.join(SRC_DIR, model, "graph.json")
    if not os.path.exists(src):
        available = ', '.join(sorted(os.listdir(SRC_DIR))) if os.path.isdir(SRC_DIR) else 'none'
        sys.exit(f"cannot find {src}\navailable models: {available}")

    d = json.load(open(src))

    # Fix a Fedora packaging bug: graph.json references FIR paths under
    # /usr/share/t2-linux-audio/ (extra hyphen) while the actual directory is
    # /usr/share/t2linux-audio/. Without this the convolvers load nothing and
    # the whole graph fails to start.
    raw = json.dumps(d)
    fixed = raw.replace("/usr/share/t2-linux-audio/", "/usr/share/t2linux-audio/")
    d = json.loads(fixed)

    playback = dict(d["playback.props"])
    # Drop the explicit target: PipeWire gives up if the target cannot be
    # matched at module load time, and the node may not exist yet. Letting the
    # session manager connect automatically is more reliable. (The original
    # value points at platform-sound.RawSpeakers, an Asahi-style name that does
    # not exist on Fedora anyway.)
    playback.pop("target.object", None)
    playback.pop("node.dont-fallback", None)

    # Start at full volume. The stock default is 0.75, and with the steep
    # cubic volume curve below that maps to roughly -25 dB internally, which
    # sounds distinctly quiet until you push the slider to 100%.
    capture = dict(d["capture.props"])
    capture["state.default-volume"] = 1.0

    # Rewrite the volume curve to approximate the standard audio taper.
    #
    # PipeWire/PulseAudio use amplitude = volume^3 (see alsa.volume-method
    # "cubic" in /usr/share/pipewire/client.conf), which is -18 dB at 50%.
    # capture.volumes only offers linear/cubic scaling across a [min,max] dB
    # range, so it cannot reproduce that exactly. A linear mapping with
    # min = -36 dB tracks it closely from 50% upward:
    #
    #   slider   standard cubic   this config
    #    100%          0 dB           0 dB
    #     75%       -7.5 dB        -9.0 dB
    #     50%      -18.1 dB       -18.0 dB   <- matches
    #     25%      -36.1 dB       -27.0 dB   <- low end is shallower
    #
    # The stock -42.5 dB wastes much of the slider on inaudible levels
    # (50% mapped to -21 dB), which reads as "the bottom half does nothing".
    for v in d["filter.graph"].get("capture.volumes", []):
        if v.get("scale") == "cubic":
            v["scale"] = "linear"
        v["min"] = -36.0

    # Gain compensation on the convolvers
    for n in d["filter.graph"]["nodes"]:
        if n.get("label") == "convolver" and "config" in n:
            n["config"]["gain"] = gain

    return f'''# T2 Mac built-in speaker DSP — native PipeWire filter-chain config
#
# Generated by tools/gen-conf.py for model {model}
# Data source: Fedora t2linux-audio package, {SRC_DIR}/{model}/graph.json
#             (produced by the T2 Linux team from Asahi Linux measurements)
#
# Chain: bankstown virtual bass -> loudness compensation
#        -> 4x FIR convolution (front/rear x L/R) -> crossover compression
#        -> per-pair limiting
#
# Install to: ~/.config/pipewire/pipewire.conf.d/50-t2-dsp.conf
# Entirely user-level; delete the file to roll back.
#
# Deviations from the official graph.json:
#   1. FIR paths t2-linux-audio -> t2linux-audio  (Fedora packaging bug)
#   2. target.object removed  (let the session manager connect)
#   3. convolver gain 0.92 -> {gain}  (level compensation)

context.modules = [
{{   name = libpipewire-module-filter-chain
    args = {{
        node.description = {spa(d['node.description'])}
        media.name = {spa(d['media.name'])}
        filter.graph = {spa(d['filter.graph'], 2)}
        capture.props = {spa(capture, 2)}
        playback.props = {spa(playback, 2)}
    }}
}}
]
'''


def main():
    args = sys.argv[1:]
    model = args[0] if args else DEFAULT_MODEL
    out = args[1] if len(args) > 1 else "50-t2-dsp.conf"
    gain = float(args[2]) if len(args) > 2 else DEFAULT_GAIN

    conf = build(model, gain)
    open(out, "w").write(conf)
    print(f"wrote {out}  (model {model}, convolver gain {gain}, {len(conf)} bytes)")


if __name__ == "__main__":
    main()
