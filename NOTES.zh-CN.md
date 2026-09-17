# 踩坑记录 —— Fedora 的 5 个打包缺陷

调试日期：2026-09-17 · 机型：MacBookPro15,4 (13" 2019, i5-8257U)
环境：Fedora 44 + t2linux 内核 7.1.9 · PipeWire 1.6.8 · WirePlumber 0.5.14

**语言：[English](NOTES.md) | 简体中文**

---

## 结论先行

Fedora 的 `t2linux-audio` 包**已经提供了完整的 DSP 数据与配置**，但在 T2 机器上
**从未生效过**——因为打包和上游代码里埋了 5 处缺陷。本文记录它们，以便：

- 判断上游是否已修复（对照检查）
- 在别的机器上复现时快速定位

## 五个缺陷

### 1. udev 规则装在了不被扫描的目录

```
包内位置: /usr/lib64/udev/rules.d/99-t2-audio-rename.rules
实际位置: /usr/lib/udev/rules.d/    ← udev 只读这里
```

udev 只扫描 `/usr/lib/udev/rules.d/`、`/etc/udev/rules.d/`、`/run/udev/rules.d/`。
**`lib64` 那份从未被读取**，声卡 id 一直停留在 `Audio`。

对比：同项目的 `t2ncm` 包把规则正确装在 `/usr/lib/udev/rules.d/90-network-t2-ncm.rules`。

**验证**：`udevadm test /sys/class/sound/card0 2>&1 | grep t2-audio` → 无输出即未加载。

### 2. 匹配用的 card id 超过 ALSA 长度上限

`/usr/share/wireplumber/wireplumber.conf.d/99-t2-audio.conf` 里：

```
{ alsa.id = "t2-MacBookPro15,4", api.alsa.pcm.stream = "playback" }
           ↑ 17 字符
```

ALSA 的 card id 上限是 **15 字符**，会被截断，导致**永远匹配不上**。

lemmyg 上游版（`t2-apple-audio-dsp`）用短名 `t2-15_4` 正是为绕开此坑，注释里
写明了原因。**Fedora 打包版没绕。**

### 3. WirePlumber `software-dsp.rules` 读取存在竞态

`/usr/share/wireplumber/scripts/node/software-dsp.lua` 第 11 行在脚本加载时
一次性读取配置：

```lua
config.rules = Conf.get_section_as_json("node.software-dsp.rules", Json.Array{})
```

若此时 conf.d 尚未合并完，读到空数组，后续 `match_rules` 永远匹配不到东西。

**实测证据**：同一份配置，22:04–22:07 匹配成功 7 次（`DSP rule found`），
之后**每一个实例都是 0 次**。

### 4. `find-defined-target.lua` 的 target 匹配

同名脚本中，以**字符串**形式给出的 `target.object` 走的是按 `node.name` 匹配的
分支，与缺陷 3 叠加时无法可靠解析。

> **更正**：这一点在排查中一度被误判。本机（`wireplumber 0.5.14-1.fc44`）
> 第 88 行实际是 `lutils.canLink (si_props, lnkbl)`，与 RPM 包内一致，
> **并非 bug**。报告前务必以包内文件为准核对。

### 5. `graph.json` 里 FIR 路径多一个连字符 ⚠️

```json
"filename": ["/usr/share/t2-linux-audio/15_4/front-48.wav", ...]
                          ↑ 多了连字符
实际目录:    /usr/share/t2linux-audio/15_4/
```

**这是「完全无声」的直接原因**：Convolver 加载不到 FIR 文件，整个
filter-chain graph 启动失败：

```
failed file /usr/share/t2-linux-audio/15_4/front-96.wav: 没有那个文件或目录
spa.filter-graph: cannot create plugin instance 0 rate:48000
pw.stream: error (-2) can't start graph
```

**注意**：修好前四个也绕不开它——WirePlumber 路线就算走通，也会撞在这上面。

## 为什么绕开 WirePlumber

官方设计的链路是：

```
udev 重命名声卡 -> WirePlumber monitor.alsa.rules 改名节点
                -> node.software-dsp.rules 按机型挂载 graph.json
```

这条链依赖缺陷 1–4 全部正常。与其逐个打补丁（且会改到系统文件），
不如**直接使用 PipeWire 原生 `libpipewire-module-filter-chain`**：

| | WirePlumber 路线 | 直接 filter-chain |
|---|---|---|
| 依赖 | software-dsp 机制 | PipeWire 原生模块 |
| 受缺陷影响 | 1,2,3,4 | 无 |
| 权限 | 需 root 改 `/etc`、`/usr/share` | **完全用户级** |
| 回滚 | 多文件还原 | **删一个文件** |

关键洞察：**`graph.json` 的 `filter.graph` 段落本身就是
`libpipewire-module-filter-chain` 的参数格式**，两者只差语法
（JSON 的 `"k": v` + 逗号 vs SPA-JSON 的 `k = v` 无逗号）。

## 其他实测要点

**UCM 的节点结构**：同一 ALSA 设备会产生多个节点，共享 `device.id` 与
`api.alsa.path`：

```
alsa_output.hw_t2-15_4_0                              Audio/Sink/Internal  4ch  ← 硬件
alsa_output.pci-...HiFi__Speaker__sink                Audio/Sink           4ch  ← UCM 虚拟
alsa_output.pci-...HiFi__Speaker__sink.split          Stream/.../Internal       ← 其内部流
```

**不要把 `hw_` 节点改名**——UCM loopback 的 `.split` 流 `target.object`
硬编码指向它，改名会打断 UCM 链路。

**`capture.volumes` 的 cubic 曲线很陡**：

```
sink 音量 100% -> 内部   0 dB
sink 音量  75% -> 内部 -25 dB
sink 音量  50% -> 内部 -37 dB
```

这是官方设计（把音量控制接力给响度补偿器）。**不要改 `min`**——改成 0 会让
映射区间变成 `[0,0]`，音量锁死在最大且无法调节。要么原样保留，要么整块移除。

**`target.object` 反而是绊脚石**：PipeWire 的 filter-chain 在模块加载瞬间
匹配不到目标就放弃（`defined target not found`），而那时目标节点可能还没建好。
移掉它，让 session manager 自动连接，反而可靠。

## 排查用的命令

```bash
# 配置文件是否被读取
journalctl --user -u pipewire -b | grep "50-t2-dsp"

# graph 是否启动失败
journalctl --user -u pipewire -b | grep -E "can't start graph|failed file"

# 节点与端口
pw-dump | python3 -c "..."     # 见 install.sh 里的用法
pw-link -l

# 内部 volume 控制值
journalctl --user -u pipewire -b | grep "filter-graph.*volume"

# 声卡 id / udev 规则是否生效
cat /sys/class/sound/card0/id
udevadm test /sys/class/sound/card0 2>&1 | grep t2-audio
```

## 上游参考

- `lemmyg/t2-apple-audio-dsp` —— T2 官方团队的 DSP 项目（Ubuntu 向）
- `t2linux/wiki` —— audio-config 指南
- `angelobdev/t2-easyeffects-preset` —— EasyEffects 方案（另一条路）
