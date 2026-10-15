# 设计说明与 bring-up 计划

## 1. 硬件事实（本机实测 / 一手来源）

| 项 | 值 | 来源 |
|---|---|---|
| 功放 | 2 × Awinic **AW88399**（智能功放，带 DSP） | Windows 驱动 `AwinicSmartKAmps.sys` + `AWDZ8399.bin`；ACPI `_HID = AWDZ8399` |
| ACPI 节点 | `\_SB.PC02.I2C2.SPKR`，`_SUB` = `17AA3907`(SPID=1) / `17AA3906` | 本机 DSDT |
| I2C 控制器 | `\_SB.PC02.I2C2`（LPSS，`80:15.2`） | 本机 DSDT |
| I2C 地址 | 右 `0x34`、左 `0x35`（7-bit，400 kHz） | DSDT `_CRS` 两条 `I2cSerialBusV2`；Linux `aw88399_setup.c` |
| 复位 | `SPKR._CRS` 里的 `GpioIo` 第 0 路：`low → 1~2 ms → high → 1~2 ms → low → 5~6 ms` | Linux `aw88399_setup.c` |
| 标定数据 | `_DSM`（UUID `1cc539cd-5a26-4288-a572-25c5744ebf1b`）function 3，9 字节 | 同上 |
| 故障中断 | `SPKR._CRS` 的 `GpioInt`（ActiveLow, edge） | 同上 |
| 音频通路 | ALC287 → I2S/ASP → AW88399 → 扬声器 | Linux `snd-hda-scodec-aw88399`（功放作为 HDA side codec 绑定到 codec） |

## 2. 寄存器接口

- I2C 线格式：**8 位寄存器地址 + 16 位数据**（Linux `regmap_config{reg_bits=8, val_bits=16}`）。
- 关键寄存器（完整表见 `Sources/AW88399Fixup/AW88399Registers.hpp`，由 `Tools/generate.py` 从 Linux 头文件生成）：

| 寄存器 | 地址 | 用途 |
|---|---|---|
| `ID_REG` | `0x00` | 读回应为 `0x2183`（`AW88399_CHIP_ID`） |
| `SYSCTRL` | `0x04` | `PWDN`（芯片上下电）、`AMPPD`（功放级上下电）、`DSPBY`（DSP 旁路）、`HMUTE`（bit 8，硬件静音） |
| `SYSCTRL2` | `0x05` | 音量字段；`MUTE_VOL = 1023` 为静音哨兵值 |
| `I2SCTRL1/2/3` | `0x06/0x07/0x08` | I2S/ASP 格式、采样率、`I2STXEN` 使能位 |
| `DBGCTRL` | — | dither 等调试位 |

Linux 侧对应的动作（本仓库照抄的依据）：

```
aw_dev_pwd(aw_dev, false)      → SYSCTRL.PWDN   = WORKING
aw_dev_amppd(aw_dev, false)    → SYSCTRL.AMPPD  = WORKING
aw_dev_dsp_enable(aw_dev, false)→ SYSCTRL.DSPBY = BYPASS      （= 无 DSP 直通模式）
aw88399_dev_mute(aw_dev, false)→ SYSCTRL.HMUTE  = DISABLE(0)  （解除静音）
aw_dev_set_volume(...)         → SYSCTRL2 volume 字段
```

## 3. macOS 侧架构

```
        ┌───────────────────────────────────────────────┐
        │ AW88399Fixup.kext（本仓库）                    │
        │  IOService ──匹配──► VoodooI2CDeviceNub        │
        │      │                (ACPI: AWDZ8399)         │
        │      │  writeI2C / writeReadI2C                │
        │      ▼                                          │
        │  VoodooI2C ──► LPSS I2C2 ──► AW88399 (0x34/35) │
        └───────────────────────────────────────────────┘
```

- 匹配方式：`IOProviderClass = VoodooI2CDeviceNub` + `IOPropertyMatch{IOName = AWDZ8399}`。
- 传输方式：`VoodooI2CDeviceNub` 的公开方法（上游 VoodooI2C 就有，**不需要自定义分支**）：
  - 写寄存器：`writeI2C({reg, hi, lo}, 3)`
  - 读寄存器：`writeReadI2C({reg}, 1, buf, 2)` → `buf[0]<<8 | buf[1]`
- 时序：**boot 后延迟**（默认 5 s，`-aw88399delay=N`）再动 I2C，避免和电源管理/触摸板初始化抢总线。
- 安全开关：`-aw88399ro` 只读、`-aw88399nodsp` 强制旁路、`-aw88399dbg` 详细日志。

## 4. bring-up 计划（逐级放开）

| 阶段 | 动作 | 判据 |
|---|---|---|
| **M1a** | 只读：`ID_REG` 读回 `0x2183`；顺带记录 `SYSCTRL`/`SYSCTRL2`/`I2SCTRL*` 现值 | 日志/ioreg 里 `ChipId = 0x2183`（说明匹配 + I2C 通路都通了） |
| **M1b** | 写入：`PWDN=WORKING`、`AMPPD=WORKING`、`DSPBY=BYPASS`、`HMUTE=DISABLE` | 外放音量显著变大（DSP 旁路模式下不应有明显失真） |
| **M2** | 下发 ACF（`Firmware/aw88399_acf.bin`，152416 字节）+ `_DSM` 9 字节标定 + 音量联动 | 音量正常且带厂商保护/音效；寄存器 `DSPBY=WORKING` |
| **M3** | 第二通道（`0x34`+`0x35` 都覆盖，需 `VoodooI2CControllerDriver::transferI2C` 直接寻址）、故障 IRQ、睡眠唤醒重放 | 立体声完整、睡眠恢复有声 |

## 5. 已知风险与对策

1. **I2C 总线灌爆**：同类项目一次性写 400+ 条寄存器把总线打进死锁，甚至把功放置入 latch-up，需要**彻底断电**才恢复。
   → 对策：分步写、每步之间留延时、失败即停（`kMaxRetries` 有限）、默认走"最小写入集"。
2. **时序过早**：开机瞬间总线上还有别的初始化（触摸板在同一族控制器上）。
   → 对策：延迟执行 + 先只读。
3. **DSP 模式没配好就切 WORKING**：可能出爆音。
   → 对策：M1b 先用 `DSPBY=BYPASS`（无 DSP 直通），确认声音正常后再做 M2。
4. **音量字段**：`SYSCTRL2` 的音量值是厂商标定/FW 决定的分贝映射，M1 不主动改它，避免"一上电就最大音量"。
