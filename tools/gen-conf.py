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
    convolver_gain  defaults to 1.0 (see below)

About the convolver gain:
    The FIRs ARE a crossover, not two copies of one calibration. front-*.wav
    is a low-pass (the woofer), rear-*.wav passes the full band. In the passband
    where each driver actually works, both are ~0 dB.

    So a single number for "the FIR's gain" is misleading: front-48.wav has an
    L2 norm of -13.4 dB, but that is the low-pass rejecting HF, not attenuation
    in the band the woofer reproduces. Measured per band:

        200 Hz   front +0.1   rear -0.7
        400 Hz   front +2.3   rear +1.8
        3 kHz    front -14.6  rear -4.0
       10 kHz    front -41.3  rear -7.6

    Unity is therefore correct, and upstream's 0.92 (-0.7 dB) is essentially
    unity. A boost is NOT needed to compensate for "energy lost to
    peak-cutting" — that was the original reasoning here, and it was wrong.

    The gain is applied to all four convolvers equally. Do NOT give the two
    pairs different gains — that would break the crossover balance by ~12 dB.

    Raising the gain costs headroom at the top of the volume range: the volume
    curve tops out at 0 dB, so at gain 4.0 (+12.0 dB) the signal arrives at the
    output ~12 dB over full scale and rides the limiter. Keep the gain at 1.0
    and use the volume slider instead.

About the volume curve (leave it alone):
    `capture.volumes` takes the sink's volume away from the software mixer and
    maps it onto the DSP's loudness compensator instead:

        value = min + (max - min) * f(v)
        f(v) = v (scale="linear") or cbrt(v) (scale="cubic")
        value is written to an LV2 control that is a gain in dB

    The trap: `v` is NOT the slider position -- it is the linear amplitude from
    `SPA_PROP_channelVolumes`, and PipeWire's standard taper is exactly
    amplitude = slider^3. So cbrt(v) recovers the slider position, and the
    shipped `cubic` + `min = -42.5` evaluates to

        dB = -42.5 * (1 - slider)

    which is a sane, near-standard curve (the true taper is 60*log10(slider)).
    Measured against it:

        slider   standard taper   shipped curve
         100%          0 dB           0 dB
          75%       -7.5 dB       -10.6 dB
          50%      -18.1 dB       -21.3 dB
          25%      -36.1 dB       -31.9 dB
          10%      -60.0 dB       -38.3 dB

    Switching that to scale="linear" is NOT a fix: it feeds the raw amplitude
    into the range instead, giving dB = -36 + 36*slider^3, i.e. -31.5 dB at the
    halfway point and essentially flat below 25%. That is ~10 dB quieter in the
    middle of the slider and reads as "the speakers stopped working". It was
    tried here and reverted. Use `cubic`.
"""
import json
import os
import sys

DEFAULT_MODEL = "15_4"
DEFAULT_GAIN = 1.0
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

    # capture.props (including state.default-volume = 0.75) and the shipped
    # capture.volumes are kept verbatim -- the volume curve is correct as
    # shipped. See "About the volume curve" below for why it must not be
    # "fixed".
    capture = dict(d["capture.props"])

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
#   3. convolver gain 0.92 -> {gain}
#      The FIRs are a crossover and sit at ~0 dB in each driver's own band, so
#      unity is correct - no level was lost to make up. Raising this eats the
#      headroom at the top of the volume range; see the notes in gen-conf.py.
#
# capture.volumes and capture.props are passed through untouched -- the shipped
# volume curve is already the right one. Do not "fix" it; see gen-conf.py.

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
