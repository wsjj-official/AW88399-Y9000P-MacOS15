# 参考来源（每条事实的出处）

## Linux（这套硬件的"标准答案"）

| 主题 | 出处 |
|---|---|
| 本机修复函数 | `sound/hda/codecs/realtek/alc269.c` → `alc287_fixup_legion_16iax10h_aw88399()` |
| 修复提交 | [torvalds/linux@`494978ae8243`](https://github.com/torvalds/linux/commit/494978ae8243) "ALSA: hda/realtek: enable AW88399 on Lenovo Legion"（2026-07-29，随内核 7.3-rc1） |
| 覆盖机型 | Legion Pro 7 16IAX10H `17aa:3906`、**Legion Y9000P IAX10H `17aa:3907`**、Legion Pro 7 16AFR10H `17aa:3938` |
| 驱动本体 | `sound/soc/codecs/aw88399.c`（+ 共享库 `aw88395`） |
| 寄存器/位定义 | `include/sound/aw88399.h`（`ID_REG 0x00`、`SYSCTRL 0x04`、`SYSCTRL2 0x05`、`I2SCTRL1..3 0x06..0x08`、`HMUTE` bit 8、`MUTE_VOL 1023`、`CHIP_ID 0x2183`） |
| 用户态初始化 | `nuclearcat/aw88399-hda-dkms` → `aw88399_setup.c`（GPIO 复位时序、`_DSM` 9 字节标定、故障 IRQ、`0x34`/`0x35` 双实例） |
| HDA 侧绑定/起停 | 同上仓库 → `side-codecs/aw88399_hda.c`（PCM open/close → 功放 start/stop） |
| ACF 固件 | `imitoy/aw88399_acf.bin`（152416 字节）；**本仓库 `Firmware/aw88399_acf.bin` 与其 SHA256 一致** |

## macOS（工程做法）

| 主题 | 出处 |
|---|---|
| 同类智能功放的 macOS 实现（先例） | [`hoaug-tran/CirrusAudioFixup`](https://github.com/hoaug-tran/CirrusAudioFixup)（CS35L41 + ALC287，Legion，2026-10 起 working） |
| 匹配 VoodooI2C 设备 nub 的写法 | 同上 → `Info.plist`（`IOProviderClass = VoodooI2CDeviceNub`、`IOPropertyMatch{IOName=...}`） |
| I2C 传输 API | 上游 [VoodooI2C](https://github.com/VoodooI2C/VoodooI2C) → `VoodooI2CDeviceNub.hpp`：`readI2C` / `writeI2C` / `writeReadI2C`（均为 public，非 virtual）；控制器级直接寻址见 `VoodooI2CControllerDriver.hpp` 的 public `transferI2C` |
| 构建/CI 做法 | CirrusAudioFixup 的 `xcodebuild` + GitHub Actions 产物打包方式（本仓库 `.github/workflows/build.yml` 同构） |
| 安全经验 | 同上项目 issue #2：一次灌 403 条 I2C 写导致总线死锁、功放 latch-up，需冷启动恢复 → 本仓库分步写 + 只读模式 |

## 本机取证（在 Windows 侧完成，存档于 `E:\macos\_analysis`）

| 内容 | 位置 |
|---|---|
| Windows 驱动包 `awinicsmartkamps.inf` + `AwinicSmartKAmps.sys` + `AWDZ8399.bin` | `_analysis\v18\` |
| ACF 固件 SHA256 `1e927c9bca76d868181c0f81df2bccef3cf19c7d0910219f229360c87babd42c` | 同 `AWDZ8399.bin`，与 `Firmware/aw88399_acf.bin` 相同 |
| 本机 DSDT（`SPKR` 节点、`_CRS`、`_SUB`） | `_analysis\v3\acpi\efidsdt.dsl` |
| Linux 侧原始驱动/工具存档 | `_analysis\v25\`（`aw88399.c`、`aw88399_linux.c/.h`、`aw88399_setup.c`、`aw88399_hda.c`、`aw88399_acf.bin` 等） |

## 尚未解决 / 待确认

1. `0x34` / `0x35` 两个地址在 ACPI 里是同一个 `SPKR` 设备的资源；VoodooI2C 建 nub 时取的是哪一个地址需要上机确认（M1a 日志会打印）。
2. AppleALC 布局是否已经把音频送到 ALC287 的 I2S/ASP 通路（Linux 侧靠 `alc287_fixup_legion_16iax10h_aw88399()` 做这件事）。若 M1b 无声，需要对着 codec 转储核对布局。
3. `_DSM` 9 字节标定的用途（Linux 只把它交给驱动，未说明写到哪里）——M2 再处理。
