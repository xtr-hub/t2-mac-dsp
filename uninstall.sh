#!/usr/bin/env bash
# T2 Mac 内置扬声器 DSP —— 卸载脚本
#
# 移除用户级配置并重启音频栈，恢复系统原始的直通输出。
# 不触碰任何系统文件。

set -euo pipefail

CONF="$HOME/.config/pipewire/pipewire.conf.d/50-t2-dsp.conf"

echo "T2 Mac 扬声器 DSP 卸载"
echo "──────────────────────"

if [ -f "$CONF" ]; then
    rm -f "$CONF"
    echo "已移除 $CONF"
else
    echo "配置不存在，无需移除"
fi

echo "重启音频栈..."
systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 6

echo
echo "当前默认输出:"
wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -m1 'node.name' | sed 's/^/  /'
echo
echo "完成。音频已恢复直通输出（无 DSP 处理）。"
