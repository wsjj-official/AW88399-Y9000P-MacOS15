# AW88399Fixup — 让 Legion Y9000P 2025（ALC287 + AW88399）的内置扬声器在 macOS 上正常发声

> 目标机器：Lenovo Legion Y9000P 2025 / 16IAX10H（DMI `83F4`，ACPI `SPKR._SUB = 17AA3907`）
> 系统：macOS Sequoia 15.7.8（x86_64, OpenCore 1.0.8）
> 问题：内置扬声器由 **两颗 Awinic AW88399 智能功放**（ACPI `AWDZ8399`，I2C2 上 `0x34`/`0x35`）驱动，
> 它们需要 I2C 初始化（上电、I2S 配置、解除静音），macOS 没有这个驱动 ——
> 结果是"能出声但音量极小"（功放停在上电默认态）。

## 这个仓库是什么

一个 **IOKit kext**（`AW88399Fixup.kext`）：匹配 `VoodooI2CDeviceNub`（即 ACPI 里的 `AWDZ8399`），
用 VoodooI2C 提供的公开 I2C 接口（`writeI2C` / `writeReadI2C`）去初始化这两颗功放。

它不是从零发明的：寄存器流程、复位时序、标定数据来源全部来自 Linux 侧对同一台机器的修复
（主线 commit [`494978ae8243`](https://github.com/torvalds/linux/commit/494978ae8243) 与
`nuclearcat/aw88399-hda-dkms`），映射关系逐条记录在 [docs/references.md](docs/references.md)。
macOS 侧的工程骨架参考 [`hoaug-tran/CirrusAudioFixup`](https://github.com/hoaug-tran/CirrusAudioFixup)
（同机型家族的 CS35L41 智能功放，2026-10 已做到 100% working）。

## 当前状态（里程碑）

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 仓库骨架、寄存器表生成、固件归档、CI 构建 | ✅ 本仓库 |
| M1a | kext 加载并匹配 `AWDZ8399`，通过 I2C 读回芯片 ID（`0x00 → 0x2183`） | 🚧 代码已就绪，待上机 |
| M1b | 上电 + DSP 旁路 + 解除静音（不含 DSP/ACF）→ 期望音量正常 | 🚧 同一次上机即可验证 |
| M2 | 下发 ACF/DSP 配置 + 标定数据（`_DSM`）+ 音量联动 | ⏳ |
| M3 | 故障 IRQ、睡眠唤醒、双通道（`0x34`+`0x35`）完整覆盖 | ⏳ |

## 怎么用（M1 阶段）

1. 需要 **VoodooI2C**（你已在用；必须是能正常驱动 LPSS I2C 的版本）+ Lilu 生态照旧。
2. 把 CI 产物 `AW88399Fixup.kext` 放进 `EFI/OC/Kexts/`，加进 `config.plist → Kernel → Add`（放在 `VoodooI2C.kext` 之后）。
3. 首次上机**建议先只读**：`boot-args` 加 `-aw88399ro`（kext 只读寄存器、不写任何东西），
   确认能读到芯片 ID 之后再放开写入。
4. 诊断：打开 IORegistryExplorer，找 `AW88399Fixup` 节点，里面的 `BringUpStage` / `ChipId` / `Applied` 属性会说明走到哪一步；
   内核日志（`log show --predicate 'process == "kernel"'` 或 `dmesg`）里 `AW88399Fixup:` 前缀的行是驱动输出。

调试开关（`boot-args`）：

| 参数 | 作用 |
|---|---|
| `-aw88399dbg` | 详细日志 |
| `-aw88399ro` | 只读模式：只读寄存器，绝不写（最安全的第一次上机） |
| `-aw88399rw` | 覆盖 `-aw88399ro`，强制写入模式（用于手动 `kextload` 时免重启切换） |
| `-aw88399nodsp` | 强制 DSP 旁路模式（M1 默认就是这个） |
| `-aw88399delay=N` | 启动后延迟 N 秒再动 I2C（默认 5，给 VoodooI2C/电源管理留时间） |

## 构建

CI（`.github/workflows/build.yml`，macos runner）：

```
xcodebuild -project AW88399Fixup.xcodeproj -target AW88399Fixup -configuration Release \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CONFIGURATION_BUILD_DIR=build/Release build
```

本地（macOS）：`python3 Tools/generate.py && xcodebuild ...`，或直接跑 `python3 Tests/check_repo.py` 做仓库自检。

## 免责声明

写寄存器有把功放打进异常状态的风险（同类项目曾遇到"一次灌几百条 I2C 会把总线打死、要断电冷启动才恢复"）。
所以本仓库的做法是：**默认分步、带延时、先只读、每次只改必要的位**。
一切写入均可通过重启撤销，但请按里程碑逐级开放。

## License

GPL-2.0（寄存器定义与初始化流程派生自 Linux 内核的 GPL-2.0 源码，见 `LICENSE` 与
[docs/references.md](docs/references.md)）。
