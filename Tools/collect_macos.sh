#!/bin/bash
# collect_macos.sh -- gather everything needed to judge an AW88399Fixup boot.
#
# Usage:  bash collect_macos.sh          (on the target macOS installation)
# Output: ~/Desktop/aw88399-diag-<timestamp>.txt
#
# What it answers, in order:
#   1. is the kext loaded, and is VoodooI2C loaded before it?
#   2. did VoodooI2C publish a device nub for the ACPI node AWDZ8399?
#   3. what does the driver report (IORegistry properties + kernel log)?
#   4. what do the audio devices look like (is "Internal Speakers" still there)?

OUT="$HOME/Desktop/aw88399-diag-$(date +%Y%m%d-%H%M%S).txt"
exec 1> >(tee "$OUT")
exec 2>&1

section() { echo; echo "================ $* ================"; }

section "0. 环境"
sw_vers
uname -a
date
echo "--- boot-args ---"
nvram -p 2>/dev/null | grep -i boot-args || echo "(读取失败)"

section "1. kext 加载情况"
echo "--- 我们的 kext ---"
kmutil showloaded 2>/dev/null | grep -i -E 'AW88399Fixup' || echo "❌ AW88399Fixup 没加载"
echo "--- VoodooI2C / Lilu 家族 ---"
kmutil showloaded 2>/dev/null | grep -i -E 'VoodooI2C|VoodooGPIO|VoodooInput|as.vit9696.Lilu|Lilu' || echo "❌ 相关依赖没加载"

section "2. ACPI 设备与 VoodooI2C 设备 nub"
echo "--- ACPI 节点 AWDZ8399（两条 I2cSerialBus 0x34/0x35 的那个设备）---"
ioreg -l -w0 -p IOACPIPlane 2>/dev/null | grep -i -B3 -A12 'AWDZ8399' | head -40 || echo "(ACPI 平面没找到)"
echo
echo "--- VoodooI2C 有没有为它建 nub（IOName == AWDZ8399）---"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B6 -A6 'AWDZ8399' | head -60 || echo "❌ 没有 AWDZ8399 的 nub —— kext 不会被匹配（见 docs/design.md §5 的备选方案）"
echo
echo "--- 所有 VoodooI2CDeviceNub 的 IOName ---"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i 'VoodooI2CDeviceNub' | head -20 || true

section "3. 我们的驱动节点与日志"
echo "--- IORegistry 里的 AW88399Fixup 节点 ---"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B2 -A25 'AW88399Fixup' | head -60 || echo "❌ IORegistry 里没有 AW88399Fixup"
echo
echo "--- 内核日志（统一日志，最近 15 分钟）---"
log show --last 15m --info --debug --predicate 'process == "kernel"' 2>/dev/null | grep -i 'AW88399' | tail -60 || echo "(无)"
echo
echo "--- dmesg ---"
sudo dmesg 2>/dev/null | grep -i 'AW88399' | tail -60 || echo "(无 / dmesg 不可用)"

section "4. 音频设备现状"
system_profiler SPAudioDataType 2>/dev/null | head -50

section "完成"
echo "把这个文件发回：$OUT"
open -R "$OUT" 2>/dev/null
