#!/bin/bash
# collect_macos.sh -- AW88399Fixup diagnostics + the decisive first-boot test.
#
# Usage:  bash collect_macos.sh
# Output: ~/Desktop/aw88399-diag-<timestamp>.txt
#
# Sections:
#   0. environment + the boot-args the kernel actually received
#   1. is the kext loaded?
#   2. content-based inventory of every mounted volume: which OpenCore config.plist is
#      where, does its Kernel>Add list our kext, and is AW88399Fixup.kext actually on
#      that volume?  (ESP volume names are not reliable - on this machine they are
#      "NO NAME", which is why name-based searches failed before.)
#   3. the decisive step: load the kext by hand (from ~/Desktop or from the ESP) so the
#      real load error - or the chip ID - lands in the log
#   4. ACPI device nub (AWDZ8399 / i2cAddress)
#   5. read-only codec snapshot (alc-verb)
#   6. audio devices
#   7. unmount whatever we mounted, so no stray volumes stay in Finder

OUT="$HOME/Desktop/aw88399-diag-$(date +%Y%m%d-%H%M%S).txt"
exec 1> >(tee "$OUT")
exec 2>&1

section() { echo; echo "================ $* ================"; }
MOUNTED_BY_US=""

section "0. 环境与 boot-args"
sw_vers
uname -a
date
echo "--- 内核实际收到的 boot-args（sysctl）---"
sysctl -n kern.bootargs 2>/dev/null || echo "(读取失败)"
echo "--- NVRAM 里存的 boot-args ---"
nvram -p 2>/dev/null | grep -i 'boot-args' || echo "(无)"

section "1. kext 是否已加载"
kmutil showloaded 2>/dev/null | grep -i 'AW88399Fixup' || echo "❌ AW88399Fixup 没加载"
kmutil showloaded 2>/dev/null | grep -i -E 'VoodooI2C|VoodooGPIO' || echo "❌ VoodooI2C 家族没加载"

section "2. 所有卷上的 config / kext 盘点（按内容找，不依赖卷名）"
sudo -v 2>&1 || true
for dev in $(diskutil list 2>/dev/null | grep -i 'EFI' | awk '{print $NF}'); do
  if ! diskutil info "$dev" 2>/dev/null | grep -q 'Mounted:.*Yes'; then
    if sudo diskutil mount "$dev" >/dev/null 2>&1; then MOUNTED_BY_US="$MOUNTED_BY_US $dev"; fi
  fi
done
echo "--- 当前 /Volumes ---"
ls -1 /Volumes
echo
FOUND=""
for v in /Volumes/*; do
  for rel in "EFI/OC" "EFI/EFI/OC"; do
    [ -f "$v/$rel/config.plist" ] || continue
    FOUND="yes"
    echo "=== 卷：$v   （OpenCore 在 $rel）"
    echo "    config sha256   : $(shasum -a 256 "$v/$rel/config.plist" | awk '{print $1}')"
    echo -n "    config boot-args: "
    plutil -extract NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args raw -o - "$v/$rel/config.plist" 2>&1 | head -2
    echo "    AW88399Fixup 条目:"
    plutil -p "$v/$rel/config.plist" 2>/dev/null | grep -B2 -A6 'AW88399Fixup' | sed 's/^/      /' | head -20
    echo "    Kexts 目录:"
    ls "$v/$rel/Kexts" 2>/dev/null | sed 's/^/      /' | head -20
    if [ -d "$v/$rel/Kexts/AW88399Fixup.kext" ]; then
      echo "    ✅ kext 在这里：$v/$rel/Kexts/AW88399Fixup.kext"
      shasum -a 256 "$v/$rel/Kexts/AW88399Fixup.kext/Contents/MacOS/AW88399Fixup" 2>/dev/null | sed 's/^/      /'
    else
      echo "    ❌ 这个卷上没有 AW88399Fixup.kext（这就会导致它不被注入）"
    fi
    echo
  done
done
[ -z "$FOUND" ] && echo "⚠️ 没有在任何已挂载卷上找到 EFI/OC/config.plist"

section "3. 手动加载 kext（本次关键一步）"
KEXT=""
for c in "$HOME/Desktop/AW88399Fixup.kext" /Volumes/*/EFI/OC/Kexts/AW88399Fixup.kext \
         /Volumes/*/EFI/EFI/OC/Kexts/AW88399Fixup.kext; do
  [ -d "$c" ] && KEXT="$c" && break
done
if [ -z "$KEXT" ]; then
  echo "❌ 桌面（~/Desktop/AW88399Fixup.kext）和所有 ESP 上都没有这个 kext —— 先把文件夹拷到桌面再来"
else
  echo "用：$KEXT"
  echo "sha256(二进制): $(shasum -a 256 "$KEXT/Contents/MacOS/AW88399Fixup" 2>/dev/null | awk '{print $1}')"
  echo "--- kextload 输出（失败原因直接看这里）---"
  sudo kextload "$KEXT" 2>&1 | head -20
  sleep 3
  echo "--- 加载后的 kext 列表 ---"
  kmutil showloaded 2>/dev/null | grep -i 'AW88399Fixup' || echo "(仍然没加载)"
  echo "--- 加载后的 IORegistry 节点 ---"
  ioreg -l -w0 -p IOService 2>/dev/null | grep -i -A22 'AW88399Fixup' | head -40 || echo "(没有节点)"
  echo "--- 最近 3 分钟 AW88399 的内核日志 ---"
  log show --last 3m --info --debug --predicate 'process == "kernel"' 2>/dev/null | grep -i 'AW88399' | tail -40 || echo "(无)"
fi

section "4. ACPI 设备 nub"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B8 -A4 'AWDZ8399' | head -40 || echo "❌ 没有 AWDZ8399 的 nub"

section "5. codec 只读快照（alc-verb，不再做写入——已证明无效）"
ALC=""
for c in "$HOME/Desktop/alc-verb" "$(dirname "$0")/alc-verb" "$HOME/Downloads/alc-verb"; do
  [ -x "$c" ] && ALC="$c" && break
done
if [ -z "$ALC" ]; then
  echo "(没找到 alc-verb，跳过)"
else
  for nid in 0x14 0x17 0x02 0x03; do
    echo "  NID $nid"
    "$ALC" "$nid" GET_PIN_WIDGET_CONTROL 0 2>&1 | tail -1 | sed 's/^/    pin: /'
    "$ALC" "$nid" GET_AMP_GAIN_MUTE 0x8000 2>&1 | tail -1 | sed 's/^/    amp: /'
  done
fi

section "6. 音频设备"
system_profiler SPAudioDataType 2>/dev/null | head -30

section "7. 收尾：卸载本次脚本挂上的 ESP"
if [ -n "$MOUNTED_BY_US" ]; then
  for dev in $MOUNTED_BY_US; do
    sudo diskutil unmount "$dev" >/dev/null 2>&1 && echo "已卸载 $dev"
  done
else
  echo "(本次没有新挂载的卷)"
fi
echo "（如果之前手动挂过 ESP，想让它从访达消失：sudo diskutil unmount /Volumes/NO\\ NAME）"

section "完成"
echo "把这个文件发回：$OUT"
open -R "$OUT" 2>/dev/null
