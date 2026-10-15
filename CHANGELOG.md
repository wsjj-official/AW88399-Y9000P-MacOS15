# Changelog

## [0.1.0] - 2026-10-15

First public scaffold (milestone M0/M1a).

### Added
- IOKit kext skeleton (`AW88399Fixup`) matching `VoodooI2CDeviceNub` / ACPI `AWDZ8399`.
- I2C register access for the AW88399 wire format (8-bit register, 16-bit data) via
  `VoodooI2CDeviceNub::writeI2C` / `writeReadI2C`.
- Chip ID probe (`ID_REG 0x00` → `0x2183`), IORegistry diagnostics, and boot-args
  (`-aw88399dbg`, `-aw88399ro`, `-aw88399nodsp`, `-aw88399delay=N`).
- M1b bring-up: power-up (`SYSCTRL` PWDN/AMPPD working, DSP bypass) + hardware un-mute
  (`HMUTE` disable), volume left to the ACF/AppleHDA.
- `Tools/generate.py`: generates the register header from the Linux reference headers and
  embeds the ACF firmware (`Firmware/aw88399_acf.bin`).
- `Tests/check_repo.py`: host-side integrity checks (ACF hash/size, register constants,
  Info.plist match keys), run by CI before every build.
- Xcode project + GitHub Actions workflow building Release/Debug kexts as artifacts.

### Known limitations
- Only the I2C address that VoodooI2C exposes for `AWDZ8399` is used; the second channel
  (the other of `0x34`/`0x35`) needs controller-level transfers (`VoodooI2CControllerDriver::transferI2C`).
- No DSP/ACF download yet (M2), no `_DSM` calibration, no GPIO reset, no fault IRQ.
- Not yet validated on hardware.
