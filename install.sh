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
check_deps() {
    local missing=()
    [ -d /usr/share/t2linux-audio ] \
        || missing+=("t2linux-audio (data dir /usr/share/t2linux-audio missing)")
    [ -e /usr/lib64/pipewire-0.3/libpipewire-module-filter-chain.so ] \
        || missing+=("pipewire (filter-chain module missing)")
    [ -d /usr/lib64/spa-0.2/filter-graph ] \
        || missing+=("pipewire-module-filter-chain-lv2 (filter-graph missing)")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: missing components (normally provided by t2linux-audio):" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        echo "Make sure you run a t2linux kernel with the t2linux-audio package." >&2
        return 1
    fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
    local gain="${1:-4.0}"

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

    echo
    echo "Verifying:"
    if wpctl status 2>/dev/null | grep -q "DSP Speakers"; then
        echo "  [ok]   DSP node created"
    else
        echo "  [FAIL] DSP node did not appear; check: journalctl --user -u pipewire" >&2
        return 1
    fi

    local default_sink
    default_sink=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
        | grep -m1 'node.name' | sed 's/.*= "//; s/"//')
    if [[ "$default_sink" == *"speakers"* && "$default_sink" == *"t2-1"* ]]; then
        echo "  [ok]   default output routed to DSP"
    else
        echo "  [warn] default output is '$default_sink'"
        local dsp_id
        dsp_id=$(wpctl status 2>/dev/null | grep "DSP Speakers" \
            | grep -o '[0-9]\+' | head -1)
        [ -n "$dsp_id" ] && echo "         run: wpctl set-default $dsp_id"
    fi

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
    echo "  [info] DSP output ports: ${outports:-?} (expected 4)"

    echo
    echo "Done. Play something — the volume keys should work normally."
    echo "Uninstall: $HERE/uninstall.sh"
}

main "$@"
