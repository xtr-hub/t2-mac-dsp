#!/usr/bin/env bash
# T2 Mac 内置扬声器 DSP —— 安装脚本
#
# 完全用户级：只写 ~/.config/pipewire/，不需要 root。
# 回滚运行 ./uninstall.sh。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
CONF_NAME="50-t2-dsp.conf"

# ── 检测机型 ──────────────────────────────────────────────────────────────────
detect_model() {
    local name
    name=$(cat /sys/class/dmi/id/product_name 2>/dev/null) || {
        echo "错误: 读不到 /sys/class/dmi/id/product_name" >&2; return 1
    }
    # MacBookPro15,4 -> 15_4 ; MacBookAir9,1 -> 9_1
    local model
    model=$(echo "$name" | sed -E 's/^MacBook(Air|Pro)//; s/,/_/')
    case "$model" in
        8_1|8_2|9_1|15_1|15_2|15_4|16_1|16_2|16_3|16_4)
            echo "$model" ;;
        *)
            echo "错误: 机型 '$name' 不在支持列表内" >&2
            echo "支持: MacBookAir8,1/8,2/9,1  MacBookPro15,1/15,2/15,4/16,1/16,2/16,3/16,4" >&2
            return 1 ;;
    esac
}

# ── 检查依赖 ──────────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    [ -d /usr/share/t2linux-audio ] || missing+=("t2linux-audio")
    [ -e /usr/lib64/pipewire-0.3/libpipewire-module-filter-chain.so ] || missing+=("pipewire")
    [ -d /usr/lib64/spa-0.2/filter-graph ] || missing+=("pipewire-module-filter-chain-lv2")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "错误: 缺少以下组件（通常由 t2linux-audio 包提供）:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        echo "请先确认系统使用 t2linux 内核且已安装 t2linux-audio 包。" >&2
        return 1
    fi
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    local gain="${1:-3.0}"

    echo "T2 Mac 内置扬声器 DSP 安装"
    echo "────────────────────────────"

    check_deps

    local model
    model=$(detect_model)
    echo "检测到机型: $(cat /sys/class/dmi/id/product_name)  (目录 $model)"

    if [ ! -f "/usr/share/t2linux-audio/$model/graph.json" ]; then
        echo "错误: 找不到 /usr/share/t2linux-audio/$model/graph.json" >&2
        echo "该机型的 DSP 数据未随包提供。" >&2
        return 1
    fi

    mkdir -p "$CONF_DIR"

    # 生成配置
    echo "生成配置 (卷积器增益 $gain)..."
    python3 "$HERE/tools/gen-conf.py" "$model" "$CONF_DIR/$CONF_NAME" "$gain"

    # 重启音频栈
    echo "重启音频栈..."
    systemctl --user restart pipewire pipewire-pulse wireplumber
    sleep 7

    # 验证
    echo
    echo "验证:"
    if wpctl status 2>/dev/null | grep -q "DSP Speakers"; then
        echo "  ✓ DSP 节点已创建"
    else
        echo "  ✗ DSP 节点未出现，请检查 journalctl --user -u pipewire" >&2
        return 1
    fi

    local default_sink
    default_sink=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null \
        | grep -m1 'node.name' | sed 's/.*= "//; s/"//')
    if [[ "$default_sink" == *"t2-1"*"speakers"* ]]; then
        echo "  ✓ 默认输出已切到 DSP"
    else
        echo "  ! 默认输出是 '$default_sink'"
        local dsp_id
        dsp_id=$(wpctl status 2>/dev/null | grep "DSP Speakers" \
            | grep -o '[0-9]\+' | head -1)
        [ -n "$dsp_id" ] && echo "    执行: wpctl set-default $dsp_id"
    fi

    local outports
    outports=$(pw-dump 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
nid=None
for o in d:
    if o.get('type')=='PipeWire:Interface:Node' and 'effect_output' in str(o.get('info',{}).get('props',{}).get('node.name','')):
        nid=o['id']
print(sum(1 for o in d if o.get('type')=='PipeWire:Interface:Port'
          and o.get('info',{}).get('props',{}).get('node.id')==nid))
" 2>/dev/null)
    echo "  DSP 输出端口数: ${outports:-?} (应为 4)"

    echo
    echo "完成。放首歌试试，音量键应可正常调节。"
    echo "卸载: $HERE/uninstall.sh"
}

main "$@"
