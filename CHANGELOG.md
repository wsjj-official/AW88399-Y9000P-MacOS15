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

## [0.1.1] - 2026-10-15

### Added
- `-aw88399rw` boot-arg: overrides `-aw88399ro` so a hand-loaded kext (`kextload`) can be
  switched to write mode without rebooting (the running kernel's boot-args cannot change).

## [0.1.2] - 2026-10-15

### Fixed
- Declare the real dependency (`com.alexandred.VoodooI2C`) in `OSBundleLibraries`; the kext
  calls `VoodooI2CDeviceNub` methods but never declared the provider, which is one candidate
  for both the failed OpenCore injection and the `KMErrorDomain Code=71` manual load.
- CI now ad-hoc signs the kext (`codesign --force --deep -s -`) so a signature is present
  even though `SecureBootModel` is disabled.
