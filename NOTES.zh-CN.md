# 踩坑记录 —— Fedora 的 5 个打包缺陷

调试日期：2026-09-17 · 机型：MacBookPro15,4 (13" 2019, i5-8257U)
环境：Fedora 44 + t2linux 内核 7.1.9 · PipeWire 1.6.8 · WirePlumber 0.5.14

**语言：[English](NOTES.md) | 简体中文**

---

## 结论先行

Fedora 的 `t2linux-audio` 包**已经提供了完整的 DSP 数据与配置**，但在 T2 机器上
**从未生效过**——因为打包方式上存在 3 处缺陷。本文记录它们，以便：

- 判断上游是否已修复（对照检查）
- 在别的机器上复现时快速定位

**只有缺陷 1、2、5 经确认**，下方各附可复现的证据。缺陷 3、4 留档但明确标注为
*已撤回* / *未确认*——它们调试期间被怀疑过，但没通过验证。**不要上报这两条。**

## 已确认的缺陷

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

### 3. WirePlumber `software-dsp.rules` —— 未确认，不予上报

`/usr/share/wireplumber/scripts/node/software-dsp.lua` 第 11 行在脚本加载时
一次性读取配置：

```lua
config.rules = Conf.get_section_as_json("node.software-dsp.rules", Json.Array{})
```

若此时 conf.d 尚未合并完，读到空数组，后续 `match_rules` 永远匹配不到东西。

**为什么不报**：当时的观察是"某个时间窗内匹配 7 次，之后 0 次"——但那是
在反复手改配置的调试过程中记录的。**我们自己留下一份陈旧或残缺的配置，
会产生一模一样的症状**，所以没有干净复现之前，不能归因于上游。
此处仅作开放问题留存，不作为结论。

### 4. `find-defined-target.lua` —— 已撤回，不是 bug

一度认为这是缺陷：第 88 行传给 `canLink` 的像是循环外的变量。核对包内文件后
被推翻：

```bash
rpm -ql wireplumber | grep find-defined-target     # 文件位置
# wireplumber 0.5.14-1.fc44 第 88 行：
#   lutils.canLink (si_props, lnkbl) then         <- 与 RPM 完全一致
```

**包内文件是正确的。** 保留此条只为记住教训：排查早期读到的一行被记成了
`target`，还据此给系统文件打了补丁。**务必以随包发布的文件为准核对，
用 `rpm -V` / SHA256 而不是记忆。**

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

**`capture.volumes` 要小心对待，而且官方给的值本来就是对的。** 它把音量控制
接力给 DSP 内部的响度补偿器，映射到一段 `[min, max]` dB 区间：

```
value = min + (max - min) * f(v)     f(v) = v (linear) | cbrt(v) (cubic)
```

（见 `spa/plugins/filter-graph/filter-graph.c` 的 `sync_volume()`）。

*`v` 是幅度，不是滑块位置。* 这是踩掉一整个调试下午的坑。
`impl_set_props()` 把 `SPA_PROP_channelVolumes` 原样拷进 `vol->volumes[]`，
而按 PipeWire 的标准 taper，那是**线性幅度**（幅度 = 滑块³）。本机实测：

```
wpctl 0.25 -> channelVolumes 0.015625      (0.25³)
wpctl 0.50 -> channelVolumes 0.125         (0.50³)
wpctl 0.75 -> channelVolumes 0.421875      (0.75³)
```

所以 `scale = "cubic"` 里的 `cbrt(v)` 恰好把滑块位置还原出来，官方
`min = -42.5` 等价于

```
dB = -42.5 * (1 - 滑块)
```

——一条很正常的曲线，相当接近标准 taper（60·log₁₀(滑块)）：

```
滑块     标准曲线     官方 cubic/-42.5     linear/-36（错）
 100%        0 dB              0 dB            0 dB
  75%     -7.5 dB          -10.6 dB        -20.8 dB
  50%    -18.1 dB          -21.3 dB        -31.5 dB
  25%    -36.1 dB          -31.9 dB        -35.4 dB
  10%    -60.0 dB          -38.3 dB        -36.0 dB
```

*千万别把 `cubic` "修"成 `linear`。* 看着像显然的改进，实际正好相反：
`linear` 把原始幅度直接代进区间，得到 `dB = min + (max - min)*滑块³`。
取 `min = -36` 时，滑块一半处就低约 10 dB，25% 以下几乎持平——安静到像是
扬声器坏了。**本项目试过，已回退。**

*绝对不要设 `min = 0`。* 那会让映射区间塌缩成 `[0, 0]`，音量锁死在最大值
且无法调节——滑块还在动，但什么都不会变。

无论怎么配，滑块归零都是真静音：`impl_set_props()` 在滑块为 0 时会额外施加
一个 0/1 的软音量。

另外：**WirePlumber 会持久化运行时音量**（存在 `~/.local/state/wireplumber/`）。
调试期间用 `wpctl set-volume` 设过的值，重启服务也不会丢——实测：设成 0.62 后
重启 `pipewire`/`pipewire-pulse`/`wireplumber`，回来的仍是 0.62，而不是配置里的
`state.default-volume`。**那个属性只在没有持久化状态时生效**，所以不能靠它来定
开机音量。要限制上限用 `wpctl set-volume <id> <值> --limit <上限>`。

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
