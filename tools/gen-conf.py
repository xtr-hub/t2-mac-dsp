#!/usr/bin/env python3
"""
把 t2linux-audio 包里的 graph.json 转成 PipeWire 原生 filter-chain 配置。

为什么需要转换：Fedora 的 t2linux-audio 包提供的是 WirePlumber 的
software-dsp 格式（graph.json），但那条路径在 T2 机器上因多处缺陷走不通
（详见 NOTES.md）。而 graph.json 里的 filter.graph 段落本身**就是**
libpipewire-module-filter-chain 的参数格式，两者只差语法：
JSON 用 `"k": v` 和逗号，SPA-JSON 用 `k = v` 无逗号。

因此直接喂给 PipeWire 原生模块，绕开 WirePlumber 整层。

用法:
    gen-conf.py <机型目录> [输出文件] [卷积器增益]

    <机型目录>   如 15_4（MacBookPro15,4）、16_1 等，对应
                 /usr/share/t2linux-audio/<机型>/
    输出文件     默认 ./50-t2-dsp.conf
    卷积器增益   默认 3.0（见下方说明）

关于卷积器增益：
    FIR 滤波器做的是频率校正，校正面板以"削峰"为主，削掉的能量不会回来，
    所以整体电平必然下降。官方 graph.json 的 gain=0.92 没有补偿这个损失，
    导致音量偏小。这里默认放大到 3.0（约 +10 dB）作为补偿。
    固定增益不改变频响形状，只整体放大；后面有限幅器兜底，不会削波。
    若听感偏小/偏大，直接调这个值（2.0 ≈ +6.7dB，4.0 ≈ +12.7dB）。
"""
import json
import os
import sys

DEFAULT_MODEL = "15_4"
DEFAULT_GAIN = 3.0
SRC_DIR = "/usr/share/t2linux-audio"


def spa(v, ind=0):
    """把 Python 对象递归转成 SPA-JSON 文本。"""
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
        sys.exit(f"找不到 {src}\n可用机型: {', '.join(sorted(os.listdir(SRC_DIR)))}")

    d = json.load(open(src))

    # 修 Fedora 打包 bug：graph.json 里 FIR 路径写成 /usr/share/t2-linux-audio/
    # （多一个连字符），实际目录是 /usr/share/t2linux-audio/
    raw = json.dumps(d)
    fixed = raw.replace("/usr/share/t2-linux-audio/", "/usr/share/t2linux-audio/")
    d = json.loads(fixed)

    playback = dict(d["playback.props"])
    # 移除显式 target：PipeWire 在模块加载瞬间匹配不到目标就放弃，
    # 让 session manager 自动连接反而可靠。原 graph.json 的
    # target.object 指向 platform-sound.RawSpeakers（Asahi 风格命名），
    # 在 Fedora 上那个节点不存在。
    playback.pop("target.object", None)
    playback.pop("node.dont-fallback", None)

    # 卷积器增益补偿
    for n in d["filter.graph"]["nodes"]:
        if n.get("label") == "convolver" and "config" in n:
            n["config"]["gain"] = gain

    return f'''# T2 Mac 内置扬声器 DSP —— PipeWire 原生 filter-chain 配置
#
# 由 tools/gen-conf.py 从官方数据生成，机型 {model}
# 数据来源: Fedora t2linux-audio 包 {SRC_DIR}/{model}/graph.json
#          （T2 官方团队基于 Asahi Linux 的测量结果制作）
#
# 处理链: bankstown 虚拟低音 -> 响度补偿 -> 四路 FIR 卷积(前/后 x 左/右)
#         -> 分频压缩 -> 独立限幅
#
# 安装位置: ~/.config/pipewire/pipewire.conf.d/50-t2-dsp.conf
# 完全用户级，删除该文件即可回滚。
#
# 相对官方 graph.json 的改动:
#   1. FIR 路径 t2-linux-audio -> t2linux-audio（Fedora 打包 bug）
#   2. 移除 target.object（改由 session manager 自动连接）
#   3. 卷积器增益 0.92 -> {gain}（电平补偿）

context.modules = [
{{   name = libpipewire-module-filter-chain
    args = {{
        node.description = {spa(d['node.description'])}
        media.name = {spa(d['media.name'])}
        filter.graph = {spa(d['filter.graph'], 2)}
        capture.props = {spa(d['capture.props'], 2)}
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
    print(f"已生成 {out}  (机型 {model}, 卷积器增益 {gain}, {len(conf)} 字节)")


if __name__ == "__main__":
    main()
