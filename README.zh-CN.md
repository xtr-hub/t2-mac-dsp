# t2-mac-dsp — Apple T2 MacBook 内置扬声器 DSP

在 Linux 上为 Apple T2 MacBook 启用**逐单元扬声器校正**，
复现 macOS 那套「多单元分频 + 单元保护」的效果。

**语言：[English](README.md) | 简体中文**

---

## 这是什么

macOS 通过私有 DSP 驱动内置扬声器，对**每个扬声器单元单独处理**：每个单元
各有一路 FIR 校正曲线，外加独立的压缩器和限幅器。而 Linux 下的
`t2bce_audio` 驱动是**直通**——把信号原封不动丢给单元，所以听起来明显更差
（低频薄、中高频发刺）。

Asahi Linux 团队测量了各机型的扬声器频响并生成 FIR 校正数据，T2 Linux 团队
把它打包进了 `t2linux-audio`。**Fedora 其实已经把这套数据装好了，只是从未生效**
（原因见 [NOTES.zh-CN.md](NOTES.zh-CN.md)）。

本项目把这些数据接到 **PipeWire 原生 `filter-chain`** 上，
绕开有问题的 WirePlumber `software-dsp` 路径。

## 处理链

```
应用 (立体声)
   ↓
DSP Sink  "MacBook Pro xx,x DSP Speakers"
   ↓
bankstown 虚拟低音        ← 心理声学低频，不硬推单元
   ↓
响度补偿 (loud_comp)
   ↓
四路 FIR 卷积            ← 前 L/R + 后 L/R，各用独立校正曲线
   ↓
分频压缩 → 独立限幅       ← 每对单元一组，防过载
   ↓
4 声道输出 (AUX0-3)
   ↓
硬件 (四个扬声器单元)
```

## 支持机型

有 DSP 数据的机型（`/usr/share/t2linux-audio/<目录>/`）：

| 目录 | 机型 |
|---|---|
| `8_1` `8_2` `9_1` | MacBookAir8,1 / 8,2 / 9,1 |
| `15_1` `15_2` `15_4` | MacBookPro15,1 / 15,2 / 15,4 |
| `16_1` `16_2` `16_3` `16_4` | MacBookPro16,1 / 16,2 / 16,3 / 16,4 |

查看本机型号：`cat /sys/class/dmi/id/product_name`

## 环境要求

### 硬件

Apple T2 MacBook（2018–2020 年带 T2 安全芯片的 Intel 机型），且机型在上表
中。确认方式：

```bash
cat /sys/class/dmi/id/product_name    # 例如 MacBookPro15,4
ls /usr/share/t2linux-audio/          # 已安装哪些机型的数据
```

### 软件

| 组件 | 最低版本 | 作用 |
|---|---|---|
| t2linux 内核 | — | 提供 `t2bce_audio` 驱动栈。发行版原版内核**完全驱动不了 T2 音频** |
| `wireplumber` | ≥ 0.5.1 | 会话管理器 |
| `pipewire` | ≥ 1.0 | 需含 `libpipewire-module-filter-chain` |
| `pipewire-module-filter-chain-lv2` | — | DSP 图使用的 LV2 后端 |
| `lsp-plugins-lv2` | ≥ 1.2.13 | 压缩器、响度补偿 |
| `lv2-bankstown` | ≥ 1.1.0 | 虚拟低音 |
| `lv2-triforce` | ≥ 0.2.0 | — |
| `lv2-swh-plugins` | — | — |
| `t2linux-audio` | ≥ 2.1.0 | **提供 FIR 数据与 `graph.json`** |

上述插件都是 `t2linux-audio` 的依赖，所以通常装上它一个就够了。核对：

```bash
rpm -q --requires t2linux-audio
```

`install.sh` 在动手前会检查这些，缺什么会直接告诉你。

### 实测环境

**只在一台机器上验证过** —— 本仓库的所有结论都来自它：

```
机型          MacBookPro15,4   (13 英寸 2019, i5-8257U)
发行版        Fedora Linux 44 (Workstation Edition)
内核          7.1.9-200.t2.fc44.x86_64
PipeWire      1.6.8
WirePlumber   0.5.14
t2linux-audio 2.1.0-1.20260831git3cd0333.fc44
```

**其余九个支持机型均未实测。** `t2linux-audio` 提供了它们的数据、图格式
完全一致，理论上同样可用，**但请当作未验证对待**。

**其他发行版同样未实测。** 本项目没有 Fedora 特有的东西（只写
`~/.config/pipewire/`），但包名会有差异，且 [NOTES.zh-CN.md](NOTES.zh-CN.md)
里记录的那些打包缺陷是 Fedora 的——别的发行版有没有，需要自行确认。

## 安装

```bash
./install.sh              # 默认卷积器增益 4.0
./install.sh 4.0          # 音量不够时加大
```

**完全用户级，不需要 root**——只写 `~/.config/pipewire/`。

脚本会：检测机型 → 从官方 `graph.json` 生成配置 → 装到
`~/.config/pipewire/pipewire.conf.d/` → 重启音频栈 → 验证。

## 卸载

```bash
./uninstall.sh
```

删掉配置文件并重启音频栈，恢复直通。

## 音量

**FIR 校正以「削峰」为主，削掉的能量不会回来，所以整体电平必然低于直通。**
官方 `graph.json` 的 `gain = 0.92` 没有补偿这个损失，直接用的话音量偏小。

`install.sh` 默认把卷积器增益设为 **4.0**（约 +12.7 dB）作补偿。这是固定增益：
只整体放大，**不改变频响形状**，且后面有限幅器兜底保护单元。

| 增益 | 约合 | 适用 |
|---|---|---|
| 2.0 | +6.7 dB | 嫌吵 |
| 3.0 | +10.3 dB | 保守 |
| **4.0** | **+12.7 dB** | **默认** |
| 5.0 | +14.7 dB | 接近上限，动态会被压平 |

> ⚠️ **这是对上游设计的偏离。** 官方 `graph.json` 用的是 `gain = 0.92`，
> 比本项目的默认值低 12.7 dB。抬高增益是为了弥补 FIR 削峰造成的电平损失，
> 代价是限幅器更早介入、动态被压缩。长时间高音量播放会增加单元负担。

### 音量曲线

官方配置把音量映射到 DSP 内部时用的是很陡的 `cubic` 曲线，滑块一半以下
几乎等于静音。`gen-conf.py` 改成 `linear`，并把下限从 −42.5 dB 收到 −36 dB，
使其**贴合标准音频曲线**（PipeWire/PulseAudio 的 `cubic` taper，即
amplitude = volume³，50% 对应 −18 dB）：

| 滑块 | 标准曲线 | 本项目 | 偏差 |
|---|---|---|---|
| 100% | 0 dB | 0 dB | — |
| 75% | −7.5 dB | −9.0 dB | −1.5 |
| **50%** | **−18.1 dB** | **−18.0 dB** | **+0.1** |
| 25% | −36.1 dB | −27.0 dB | +9.1 |

**50% 以上几乎完全吻合**；低音区（25% 以下）比标准略响一些——
这是线性映射的固有局限（`capture.volumes` 只支持 `linear`/`cubic` 两种
scale，无法精确复现 taper 曲线）。

另外注意 WirePlumber 会**持久化**音量到 `~/.local/state/wireplumber/`。
如果你用 `wpctl set-volume` 反复调过，运行时数值可能停在某个奇怪的地方——
**重启会重置为配置的默认值**（`state.default-volume`，本项目设为 1.0）。

调整方式：`./install.sh 4.0`，或直接改配置文件里的 `gain` 后重启音频栈：

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
```

## 常见疑问

**为什么声音设置里只显示 2 个扬声器？**

正常。DSP 的输入是立体声、输出才是 4 声道——**四路分频在 DSP 内部完成**，
系统 UI 只反映送进去的那一端。四个单元确实都在工作。

**音量键还能用吗？**

能。曲线已调整为贴合标准音频曲线，见上文「音量曲线」。

**和 EasyEffects 有什么区别？**

EasyEffects 是在**立体声**上做软件 EQ，分不出四个单元；本项目对**每个单元**
独立校正。两者层次不同，同时用会打架——用了 DSP 就不需要 EasyEffects。

**真的比直通好听吗？**

取决于你的耳朵和机型。DSP 修的是「频响不平直」，代价是整体电平略低。
不喜欢就 `./uninstall.sh` 回到直通。

## 目录结构

```
t2-mac-dsp/
├── README.md              英文说明
├── README.zh-CN.md        本文件
├── NOTES.md               英文踩坑记录
├── NOTES.zh-CN.md         中文踩坑记录
├── install.sh             安装
├── uninstall.sh           卸载
├── conf/
│   └── 50-t2-dsp.conf     生成的配置（参考用）
└── tools/
    └── gen-conf.py        从官方 graph.json 生成配置
```

## 关于数据

**本仓库不含任何音频数据。** FIR 滤波器文件和 DSP 图定义在运行时从系统包
`t2linux-audio` 读取，本项目只提供把它们接进 PipeWire 的胶水代码。

因此本项目用 MIT 许可，不涉及上游数据的再分发。那些数据源自 Asahi Linux
项目与 T2 Linux 团队，版权见系统上的
`/usr/share/t2linux-audio/*/LICENSE.asahi-audio`。

## 致谢

- **Asahi Linux** 团队 —— 扬声器频响测量与 FIR 生成
- **T2 Linux** 团队 —— `t2linux-audio` 包与 DSP 图定义
- `chadmed` (bankstown)、`lsp-plugins` —— 用到的 LV2 插件
