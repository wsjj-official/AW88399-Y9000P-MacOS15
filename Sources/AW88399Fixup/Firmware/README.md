# Firmware

## aw88399_acf.bin

| 项 | 值 |
|---|---|
| 大小 | 152416 字节 |
| SHA256 | `1e927c9bca76d868181c0f81df2bccef3cf19c7d0910219f229360c87babd42c` |
| 来源 A（本机） | Windows 驱动包 `awinicsmartkamps.inf_amd64_*/AWDZ8399.bin`（`oem204.inf` / `AwinicSmartKAmps.sys`） |
| 来源 B（社区） | `imitoy/aw88399_acf.bin`（Linux 侧同一份 ACF，供内核驱动 `request_firmware` 使用） |
| 一致性 | **A 与 B 逐字节相同**（SHA256 相同），因此这份 ACF 就是本机硬件在 Windows 下实际使用的配置 |

ACF（AWINIC Configuration File）里是该芯片的 DSP 程序与调音/保护参数。
M2 阶段会把它下发给功放（Linux 侧由 `aw88399_request_firmware_file()` + `aw88399_fw_download()` 完成）。
M1 阶段不使用它，kext 以 `DSPBY=BYPASS`（无 DSP 直通）方式工作。

构建时 `Tools/generate.py` 会把本文件转换成 `Firmware/aw88399_acf.h`（C 数组，不进版本库）。
