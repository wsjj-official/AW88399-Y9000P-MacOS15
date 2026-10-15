#!/bin/bash
# collect_macos.sh -- gather everything needed to judge an AW88399Fixup boot.
#
# Usage:  sudo bash collect_macos.sh       (on the target macOS installation)
# Output: ~/Desktop/aw88399-diag-<timestamp>.txt  (+ a copy of the OpenCore boot log)
#
# What it answers, in order:
#   1. which boot-args the *kernel* actually received (not just what NVRAM stores)
#   2. is the kext injected, and if not: is the file even there, and what error does
#      kextload report?
#   3. did VoodooI2C publish a device nub for ACPI AWDZ8399, and at which address?
#   4. what does the driver report (IORegistry + kernel log)?
#   5. codec-side sanity: read/unmute the speaker pins and the DAC amplifiers.

OUT="$HOME/Desktop/aw88399-diag-$(date +%Y%m%d-%H%M%S).txt"
OCLOG="$HOME/Desktop"
exec 1> >(tee "$OUT")
exec 2>&1

section() { echo; echo "================ $* ================"; }

section "0. 环境与 boot-args"
sw_vers
uname -a
date
echo "--- 内核实际收到的 boot-args（sysctl）---"
sysctl -n kern.bootargs 2>/dev/null || echo "(读取失败)"
echo "--- NVRAM 里存的 boot-args ---"
nvram -p 2>/dev/null | grep -i 'boot-args' || echo "(无)"

section "1. kext 加载情况"
echo "--- AW88399Fixup ---"
kmutil showloaded 2>/dev/null | grep -i 'AW88399Fixup' || echo "❌ AW88399Fixup 没加载"
echo "--- VoodooI2C 家族（我们的依赖）---"
kmutil showloaded 2>/dev/null | grep -i -E 'VoodooI2C|VoodooGPIO' || echo "❌ VoodooI2C 没加载"

section "2. ESP 上的实际情况（kext 文件在不在、config 里怎么写的）"
sudo -v 2>&1 || true
for dev in $(diskutil list 2>/dev/null | grep -i 'EFI' | awk '{print $NF}'); do
  sudo diskutil mount "$dev" >/dev/null 2>&1
done
CFG=""
for v in /Volumes/EFI /Volumes/EFI1 /Volumes/EFI2 /Volumes/SYSTEM_DRV /Volumes/ESP; do
  [ -f "$v/EFI/OC/config.plist" ] && CFG="$v/EFI/OC/config.plist" && ESP="$v" && break
done
if [ -z "$CFG" ]; then
  echo "❌ 没有挂到带 EFI/OC/config.plist 的卷；下面是当前 /Volumes 列表与 diskutil 摘要："
  ls -l /Volumes
  diskutil list
else
  echo "ESP 挂载点: $ESP"
  echo "config.plist sha256: $(shasum -a 256 "$CFG" | awk '{print $1}')"
  echo "--- config 里写的 boot-args ---"
  plutil -extract NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args raw -o - "$CFG" 2>&1
  echo "--- config 里 Kernel>Add 的 AW88399Fixup 条目 ---"
  plutil -p "$CFG" 2>/dev/null | grep -B3 -A8 'AW88399Fixup' | head -30
  echo "--- ESP 上 OC/Kexts 目录 ---"
  ls -l "$ESP/EFI/OC/Kexts"
  KEXTPATH="$ESP/EFI/OC/Kexts/AW88399Fixup.kext"
  if [ -d "$KEXTPATH" ]; then
    echo "✅ kext 在：$KEXTPATH"
    ls -lR "$KEXTPATH" | head -20
    BIN="$KEXTPATH/Contents/MacOS/AW88399Fixup"
    [ -f "$BIN" ] && echo "kext 二进制 sha256: $(shasum -a 256 "$BIN" | awk '{print $1}')" || echo "❌ kext 里没有 Contents/MacOS/AW88399Fixup"
    echo "--- 尝试手动加载（这一步会直接给出没加载的原因）---"
    sudo kextload "$KEXTPATH" 2>&1 | head -20
    echo "--- 加载后再看一次 ---"
    kmutil showloaded 2>/dev/null | grep -i 'AW88399Fixup' || echo "(还是没有)"
  else
    echo "❌ ESP 上没有 $KEXTPATH —— 这就是它没被注入的原因（拷贝 EFI 时这个 kext 没进去）"
  fi
  echo "--- OpenCore 启动日志（会记录 kext 注入失败原因）---"
  ls -lt "$ESP/EFI/OC/Logs" 2>/dev/null | head -5
  LATEST=$(ls -t "$ESP/EFI/OC/Logs"/opencore-*.txt 2>/dev/null | head -1)
  if [ -n "$LATEST" ]; then
    cp "$LATEST" "$OCLOG/" && echo "已复制到桌面：$OCLOG/$(basename "$LATEST")"
    echo "--- 日志里和 kext / AW88399 有关的行 ---"
    grep -i -E 'AW88399|Kext|Failed to inject|not loadable' "$LATEST" | tail -40
  else
    echo "(没有 OC 日志；config 里 Misc>Debug>Target 可能没开文件日志)"
  fi
fi

section "3. ACPI 设备与 VoodooI2C 设备 nub"
echo "--- AWDZ8399 的 nub（IOName / i2cAddress）---"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B10 -A6 'AWDZ8399' | head -60 || echo "❌ 没有 AWDZ8399 的 nub"

section "4. 驱动节点与内核日志"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B2 -A20 'AW88399Fixup' | head -60 || echo "❌ IORegistry 里没有 AW88399Fixup 节点"
echo
echo "--- 统一日志里 AW88399 的行（最近 20 分钟）---"
log show --last 20m --info --debug --predicate 'process == "kernel"' 2>/dev/null | grep -i 'AW88399' | tail -60 || echo "(无)"
echo
echo "--- dmesg ---"
sudo dmesg 2>/dev/null | grep -i 'AW88399' | tail -60 || echo "(无)"

section "5. codec 侧：扬声器引脚与 DAC 放大器（alc-verb）"
ALC=""
for c in "$HOME/Desktop/alc-verb" "$HOME/Downloads/alc-verb" "$(dirname "$0")/alc-verb"; do
  [ -x "$c" ] && ALC="$c" && break
done
if [ -z "$ALC" ]; then
  echo "没找到 alc-verb（把仓库里的 alc-verb 放到桌面再跑一次）"
else
  run() { echo "\$ alc-verb $*"; "$ALC" "$@" 2>&1 | grep -v '^alc-verb for' ; }
  echo "--- 基线：pin 控制 / EAPD / 输出放大 ---"
  for nid in 0x14 0x17 0x02 0x03 0x20; do
    echo "  NID $nid"
    run "$nid" GET_PIN_WIDGET_CONTROL 0
    run "$nid" GET_EAPD_BTLENABLE 0
    run "$nid" GET_AMP_GAIN_MUTE 0x8000
  done
  echo "--- 动作 1：引脚输出使能 + EAPD ---"
  for nid in 0x14 0x17; do run "$nid" SET_PIN_WIDGET_CONTROL 0x40; run "$nid" SET_EAPD_BTLENABLE 0x02; done
  echo "--- 动作 2：输出放大解除静音并给到最大增益（0x8000|0x7F）---"
  for nid in 0x14 0x17 0x02 0x03; do run "$nid" SET_AMP_GAIN_MUTE 0x807F; done
  echo "--- 动作 3：ALC287 功放供电 coef 序列（节点 0x20）---"
  for pair in 0x500:0x24 0x400:0x41 0x500:0x26 0x400:0x02 0x400:0x00 0x400:0x00 0x4b0:0x20 \
              0x500:0x24 0x400:0x42 0x500:0x26 0x400:0x0c 0x400:0x00 0x400:0x2a 0x4b0:0x20 \
              0x500:0x26 0x400:0x02 0x400:0x00 0x400:0x00 0x4b0:0x20; do
    run 0x20 "${pair%%:*}" "${pair##*:}"
  done
  echo "--- 动作后的读数 ---"
  for nid in 0x14 0x17 0x02 0x03; do echo "  NID $nid"; run "$nid" GET_AMP_GAIN_MUTE 0x8000; done
fi

section "6. 音频设备"
system_profiler SPAudioDataType 2>/dev/null | head -40

section "完成"
cat <<'TXT'
请回传：
  1. 这个 txt（路径见上）
  2. 桌面上的 opencore-*.txt（如果脚本复制了）
  3. 主观听感：第 5 节之后，音量/低音有没有变化（变响 / 没变化 / 变失真）
TXT
open -R "$OUT" 2>/dev/null
