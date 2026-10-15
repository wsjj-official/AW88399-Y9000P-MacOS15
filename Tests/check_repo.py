#!/usr/bin/env python3
"""Host-side integrity checks for this repository (run by CI before every build).

Runs Tools/generate.py first so the generated headers exist, then verifies:
  * the ACF firmware blob is the expected file (size + SHA256)
  * the generated register header contains the constants the driver relies on
  * Info.plist matches the ACPI device of the target machine
  * provenance/licensing notes are present
"""

from __future__ import annotations

import hashlib
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "AW88399Fixup"

EXPECTED_ACF_SHA256 = "1e927c9bca76d868181c0f81df2bccef3cf19c7d0910219f229360c87babd42c"
EXPECTED_ACF_SIZE = 152416
EXPECTED_CHIP_ID = "0x2183"
REQUIRED_REGISTER_DEFINES = [
    "AW88399_ID_REG",
    "AW88399_SYSCTRL_REG",
    "AW88399_SYSCTRL2_REG",
    "AW88399_I2SCTRL1_REG",
    "AW88399_I2SCTRL3_REG",
    "AW88399_PWDN_MASK",
    "AW88399_PWDN_WORKING_VALUE",
    "AW88399_AMPPD_MASK",
    "AW88399_AMPPD_WORKING_VALUE",
    "AW88399_DSPBY_MASK",
    "AW88399_DSPBY_BYPASS_VALUE",
    "AW88399_HMUTE_MASK",
    "AW88399_HMUTE_DISABLE_VALUE",
    "AW88399_CHIP_ID",
]

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print("  ok   %s" % message)
    else:
        print("  FAIL %s" % message)
        failures.append(message)


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    print("[1/4] generate headers")
    subprocess.run([sys.executable, str(ROOT / "Tools" / "generate.py")], check=True)

    print("[2/4] ACF firmware blob")
    blob = SRC / "Firmware" / "aw88399_acf.bin"
    check(blob.exists(), "Firmware/aw88399_acf.bin present")
    if blob.exists():
        data = blob.read_bytes()
        check(len(data) == EXPECTED_ACF_SIZE,
              "ACF size == %d (got %d)" % (EXPECTED_ACF_SIZE, len(data)))
        check(hashlib.sha256(data).hexdigest() == EXPECTED_ACF_SHA256,
              "ACF sha256 matches the blob used by Linux and by the Windows driver")

    print("[3/4] generated register header")
    header = SRC / "AW88399Registers.hpp"
    check(header.exists(), "AW88399Registers.hpp generated")
    if header.exists():
        text = header.read_text(encoding="utf-8")
        for name in REQUIRED_REGISTER_DEFINES:
            check(name in text, "register define %s present" % name)
        check(EXPECTED_CHIP_ID in text, "chip ID %s present" % EXPECTED_CHIP_ID)

    print("[4/4] Info.plist / provenance")
    plist = plistlib.loads((SRC / "Info.plist").read_bytes())
    check(plist["CFBundleExecutable"] == "AW88399Fixup", "CFBundleExecutable")
    personality = plist["IOKitPersonalities"]["AW88399Fixup"]
    check(personality["IOClass"] == "AW88399Fixup", "IOClass")
    check(personality["IOProviderClass"] == "VoodooI2CDeviceNub", "IOProviderClass")
    check(personality["IOPropertyMatch"]["IOName"] == "AWDZ8399",
          "IOPropertyMatch.IOName == AWDZ8399 (the ACPI node of the amplifiers)")
    check((ROOT / "docs" / "references.md").read_text(encoding="utf-8").find("494978ae8243") > 0,
          "docs/references.md cites the Linux fix commit")
    check("GPL-2.0" in (ROOT / "LICENSE").read_text(encoding="utf-8"),
          "LICENSE is GPL-2.0")

    print()
    if failures:
        print("%d check(s) failed:" % len(failures))
        for item in failures:
            print("  - %s" % item)
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
