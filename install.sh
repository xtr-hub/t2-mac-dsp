#!/usr/bin/env bash
# t2-mac-dsp — installer
#
# Entirely user-level: writes only under ~/.config/pipewire/.
# No root required. Run ./uninstall.sh to roll back.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF_NAME="50-t2-dsp.conf"

SUPPORTED="8_1 8_2 9_1 15_1 15_2 15_4 16_1 16_2 16_3 16_4"

# ── helpers ───────────────────────────────────────────────────────────────────

# Find an installed LV2 bundle. Distros put them in different places.
find_lv2() {
    local name="$1" dir
    for dir in /usr/lib64/lv2 /usr/lib/lv2 /usr/local/lib/lv2 "$HOME/.lv2"; do
        [ -d "$dir/$name" ] && return 0
    done
    return 1
}

# How to install packages on this system, for the error message.
install_hint() {
    local pkgs="$*"
    if   command -v dnf    >/dev/null; then echo "sudo dnf install $pkgs"
    elif command -v pacman >/dev/null; then echo "sudo pacman -S $pkgs"
    elif command -v apt    >/dev/null; then echo "sudo apt install $pkgs"
    elif command -v zypper >/dev/null; then echo "sudo zypper install $pkgs"
    else echo "<your package manager> install $pkgs"
    fi
}

# ── detect model ──────────────────────────────────────────────────────────────
detect_model() {
    local name
    name=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || {
        echo "ERROR: cannot read /sys/class/dmi/id/product_name" >&2
        return 1
    }
    # MacBookPro15,4 -> 15_4 ; MacBookAir9,1 -> 9_1
    local model
    model=$(echo "$name" | sed -E 's/^MacBook(Air|Pro)//; s/,/_/')
    case " $SUPPORTED " in
        *" $model "*) echo "$model" ;;
        *)
            echo "ERROR: model '$name' is not supported" >&2
            echo "Supported: $SUPPORTED" >&2
            return 1 ;;
    esac
}

# ── check dependencies ────────────────────────────────────────────────────────
# Everything here is checked up front so failures surface before anything is
# written, rather than as silence after a restart.
check_deps() {
    local missing=()

    [ -d /usr/share/t2linux-audio ] \
        || missing+=("t2linux-audio")
    [ -e /usr/lib64/pipewire-0.3/libpipewire-module-filter-chain.so ] \
        || missing+=("pipewire")
    [ -d /usr/lib64/spa-0.2/filter-graph ] \
        || missing+=("pipewire-module-filter-chain-lv2")

    # LV2 plugins the shipped DSP graphs actually reference.
    # Missing any of these makes the graph fail to load — and PipeWire
    # reports that only in the journal, so without this check the install
    # would appear to succeed and simply produce no sound.
    find_lv2 bankstown.lv2   || missing+=("lv2-bankstown")
    find_lv2 lsp-plugins.lv2 || missing+=("lsp-plugins-lv2")
    find_lv2 triforce.lv2    || missing+=("lv2-triforce")

    if [ ${#missing[@]} -gt 0 ]; then
        {
            echo "ERROR: missing components:"
            printf '  - %s\n' "${missing[@]}"
            echo
            echo "Install them with:"
            echo "  $(install_hint "${missing[@]}")"
            echo
            echo "(All of these are dependencies of t2linux-audio, so installing"
            echo " that package is usually enough.)"
        } >&2
        return 1
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local gain="${1:-1.0}"

    echo "t2-mac-dsp installer"
    echo "────────────────────"

    check_deps

    local model
    model=$(detect_model)
    echo "Detected model: $(cat /sys/class/dmi/id/product_name)  (dir: $model)"

    if [ ! -f "/usr/share/t2linux-audio/$model/graph.json" ]; then
        echo "ERROR: /usr/share/t2linux-audio/$model/graph.json not found" >&2
        echo "DSP data for this model is not shipped by the package." >&2
        return 1
    fi

    mkdir -p "$CONF_DIR"

    echo "Generating config (convolver gain $gain)..."
    python3 "$HERE/tools/gen-conf.py" "$model" "$CONF_DIR/$CONF_NAME" "$gain"

    echo "Restarting audio stack..."
    systemctl --user restart pipewire pipewire-pulse wireplumber
    sleep 7

    # ── verify ────────────────────────────────────────────────────────────────
    echo
    echo "Verifying:"

    # 1. Did the filter graph actually start? Check the journal first — a node
    #    can exist while its graph failed, which is exactly the silent-failure
    #    mode this project exists to avoid.
    local graph_err
    graph_err=$(journalctl --user -u pipewire --since "1 min ago" --no-pager 2>/dev/null \
        | grep -E "can't start graph|failed file|Failed to load" | tail -3 || true)
    if [ -n "$graph_err" ]; then
        {
            echo "  [FAIL] filter graph did not start:"
            echo "$graph_err" | sed 's/^/         /'
            echo
            echo "  Full log: journalctl --user -u pipewire -b | grep -i 'filter'"
        } >&2
        return 1
    fi
    echo "  [ok]   no errors in the filter graph"

    # 2. Node present?
    if wpctl status 2>/dev/null | grep -q "DSP Speakers"; then
        echo "  [ok]   DSP node created"
    else
        echo "  [FAIL] DSP node did not appear; check: journalctl --user -u pipewire" >&2
        return 1
    fi

    # 3. All four output channels wired up?
    local outports
    outports=$(pw-dump 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
nid=None
for o in d:
    if o.get('type')=='PipeWire:Interface:Node' and \
       'effect_output' in str(o.get('info',{}).get('props',{}).get('node.name','')):
        nid=o['id']
print(sum(1 for o in d if o.get('type')=='PipeWire:Interface:Port'
          and o.get('info',{}).get('props',{}).get('node.id')==nid))
" 2>/dev/null)
    if [ "${outports:-0}" = "4" ]; then
        echo "  [ok]   4 output channels (front L/R + rear L/R)"
    else
        echo "  [warn] expected 4 output channels, found ${outports:-?}"
    fi

    # 4. Is it the default output?
    local default_sink
    default_sink=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
        | grep -m1 'node.name' | sed 's/.*= "//; s/"//')
    if [[ "$default_sink" == *speakers* && "$default_sink" == *t2-1* ]]; then
        echo "  [ok]   default output routed to DSP"
    else
        echo "  [warn] default output is '$default_sink'"
        local dsp_id
        dsp_id=$(wpctl status 2>/dev/null | grep "DSP Speakers" \
            | grep -o '[0-9]\+' | head -1)
        [ -n "$dsp_id" ] && echo "         fix with: wpctl set-default $dsp_id"
    fi

    echo
    echo "Done. Play something — the volume keys should work normally."
    echo "Uninstall: $HERE/uninstall.sh"
}

main "$@"
