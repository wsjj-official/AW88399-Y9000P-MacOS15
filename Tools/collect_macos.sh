#!/bin/bash
# collect_macos.sh -- AW88399Fixup diagnostics + first-boot test.
#
# Usage:  bash collect_macos.sh
# Output: ~/Desktop/aw88399-diag-<timestamp>.txt
#
# This machine has three ESP candidates (disk0s1 = the boot SSD that also holds macOS,
# disk1s1 = the Windows ESP, disk3s1 = the installer USB).  Volume names are useless
# (two of them are called "NO NAME"), so the boot ESP is located by disk topology:
#   diskutil info /   -> "Part of Whole: diskX"  ->  the "EFI" slice of diskX
#
# Sections:
#   0. environment + the boot-args the kernel actually received
#   1. which ESP is the boot ESP (+ a one-line summary of every other ESP)
#   2. what that ESP holds: config.plist, its Kernel>Add entry, OC/Kexts listing,
#      and whether AW88399Fixup.kext is there
#   3. optional: install the kext from ~/Desktop into the boot ESP
#   4. the decisive step: kextload (Desktop first) and watch what happens
#   5. device nub + read-only codec snapshot + audio devices
#   6. unmount everything this script mounted

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
echo "--- NVRAM ---"
nvram -p 2>/dev/null | grep -i 'boot-args' || echo "(无)"

section "1. 哪个 ESP 才是启动 ESP"
sudo -v 2>&1 || true
BOOTDISK=$(diskutil info / 2>/dev/null | awk -F': *' '/Part of Whole/{print $2}' | tr -d ' ')
echo "macOS 根卷所在的物理盘: ${BOOTDISK:-(没识别出来)}"
diskutil list "/dev/$BOOTDISK" 2>/dev/null
BOOTESP=""
if [ -n "$BOOTDISK" ]; then
  for dev in $(diskutil list "/dev/$BOOTDISK" 2>/dev/null | awk '/EFI/{print $NF}'); do
    BOOTESP="$dev"
    break
  done
fi
echo "→ 启动 ESP 推测为: ${BOOTESP:-(未找到)}"

echo
echo "--- 所有 ESP 一览 ---"
for dev in $(diskutil list 2>/dev/null | awk '/EFI/{print $NF}'); do
  info=$(diskutil info "$dev" 2>/dev/null)
  name=$(echo "$info" | awk -F': *' '/Volume Name/{print $2}')
  if ! echo "$info" | grep -q 'Mounted:.*Yes'; then
    sudo diskutil mount "$dev" >/dev/null 2>&1 && MOUNTED_BY_US="$MOUNTED_BY_US $dev"
    info=$(diskutil info "$dev" 2>/dev/null)
  fi
  mp=$(echo "$info" | awk -F': *' '/Mount Point/{print $2}')
  has_cfg="no"; has_kext="no"
  for rel in "EFI/OC" "EFI/EFI/OC"; do
    [ -f "$mp/$rel/config.plist" ] && has_cfg="yes"
    [ -d "$mp/$rel/Kexts/AW88399Fixup.kext" ] && has_kext="yes"
  done
  printf '  %-9s name=%-12s mount=%-18s config=%-3s AW88399Fixup.kext=%s\n' \
    "$dev" "${name:-?}" "${mp:-未挂载}" "$has_cfg" "$has_kext"
done

section "2. 启动 ESP 里的实际情况"
if [ -z "$BOOTESP" ]; then
  echo "⚠️ 没定位到启动 ESP，跳到后面的手动加载步骤"
else
  BOOTMP=$(diskutil info "$BOOTESP" 2>/dev/null | awk -F': *' '/Mount Point/{print $2}')
  [ -z "$BOOTMP" ] && {
    sudo diskutil mount "$BOOTESP" >/dev/null 2>&1
    MOUNTED_BY_US="$MOUNTED_BY_US $BOOTESP"
    BOOTMP=$(diskutil info "$BOOTESP" 2>/dev/null | awk -F': *' '/Mount Point/{print $2}')
  }
  echo "启动 ESP: $BOOTESP  挂载点: $BOOTMP"
  OC=""
  for rel in "EFI/OC" "EFI/EFI/OC"; do
    [ -f "$BOOTMP/$rel/config.plist" ] && OC="$BOOTMP/$rel" && break
  done
  if [ -z "$OC" ]; then
    echo "❌ 这个 ESP 上没有 EFI/OC/config.plist —— 说明启动用的其实是别的 ESP（把这行发我）"
  else
    echo "OC 目录: $OC"
    echo "config sha256: $(shasum -a 256 "$OC/config.plist" | awk '{print $1}')"
    echo -n "config boot-args: "
    plutil -extract NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args raw -o - "$OC/config.plist" 2>&1 | head -2
    echo "config 里 AW88399Fixup 条目:"
    plutil -p "$OC/config.plist" 2>/dev/null | grep -B2 -A6 'AW88399Fixup' | sed 's/^/    /' | head -20
    echo "OC/Kexts 目录:"
    ls "$OC/Kexts" 2>/dev/null | sed 's/^/    /' | head -30
    if [ -d "$OC/Kexts/AW88399Fixup.kext" ]; then
      echo "✅ kext 已经在启动 ESP 上：$OC/Kexts/AW88399Fixup.kext"
      shasum -a 256 "$OC/Kexts/AW88399Fixup.kext/Contents/MacOS/AW88399Fixup" 2>/dev/null | sed 's/^/    /'
    else
      echo "❌ 启动 ESP 上**没有** AW88399Fixup.kext（这就是它没被注入的原因）"
    fi
  fi
fi

section "3. （可选）把桌面上的 kext 装进启动 ESP"
KEXT_SRC=""
for c in "$HOME/Desktop/AW88399Fixup.kext" "$HOME/Desktop/macOS-拷贝到桌面/AW88399Fixup.kext"; do
  [ -d "$c" ] && KEXT_SRC="$c" && break
done
if [ -z "$KEXT_SRC" ]; then
  echo "(桌面上没有 AW88399Fixup.kext，跳过安装；手动加载那一步也会被跳过)"
elif [ -z "$OC" ]; then
  echo "(没定位到启动 ESP 的 OC 目录，跳过安装)"
else
  echo "源：$KEXT_SRC"
  echo "目标：$OC/Kexts/AW88399Fixup.kext"
  echo "安装吗？（会把上面这个文件夹拷进去，覆盖同名目录）(y/N）"
  read -r ANS
  case "$ANS" in
    y|Y|yes|YES)
      sudo rm -rf "$OC/Kexts/AW88399Fixup.kext"
      sudo cp -R "$KEXT_SRC" "$OC/Kexts/AW88399Fixup.kext" && echo "✅ 已拷贝"
      echo "校验：$(shasum -a 256 "$OC/Kexts/AW88399Fixup.kext/Contents/MacOS/AW88399Fixup" 2>/dev/null | awk '{print $1}')"
      echo "→ 下次重启时 OpenCore 就会注入它（config 里的 Kernel>Add 条目已经在了）"
      ;;
    *) echo "(跳过安装)" ;;
  esac
fi

section "4. 手动加载 kext（本次关键一步）"
KEXT=""
for c in "$KEXT_SRC" "$OC/Kexts/AW88399Fixup.kext"; do
  [ -d "$c" ] && KEXT="$c" && break
done
if [ -z "$KEXT" ]; then
  echo "❌ 桌面和启动 ESP 上都没有这个 kext"
else
  echo "用：$KEXT"
  echo "--- kextload 输出（失败原因看这里）---"
  sudo kextload "$KEXT" 2>&1 | head -20
  sleep 3
  echo "--- 加载后的 kext 列表 ---"
  kmutil showloaded 2>/dev/null | grep -i 'AW88399Fixup' || echo "(仍然没加载)"
  echo "--- IORegistry 节点 ---"
  ioreg -l -w0 -p IOService 2>/dev/null | grep -i -A22 'AW88399Fixup' | head -40 || echo "(没有节点)"
  echo "--- 最近 3 分钟 AW88399 的内核日志 ---"
  log show --last 3m --info --debug --predicate 'process == "kernel"' 2>/dev/null | grep -i 'AW88399' | tail -40 || echo "(无)"
fi

section "5. 设备 nub / codec 只读快照 / 音频设备"
echo "--- AWDZ8399 的 nub ---"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B8 -A4 'AWDZ8399' | head -30 || echo "❌ 没有 nub"
ALC=""
for c in "$HOME/Desktop/alc-verb" "$(dirname "$0")/alc-verb" "$HOME/Desktop/macOS-拷贝到桌面/alc-verb"; do
  [ -x "$c" ] && ALC="$c" && break
done
if [ -n "$ALC" ]; then
  echo "--- codec 只读快照（alc-verb）---"
  for nid in 0x14 0x17 0x02 0x03; do
    printf '  NID %s: pin=%s amp=%s\n' "$nid" \
      "$("$ALC" "$nid" GET_PIN_WIDGET_CONTROL 0 2>&1 | tail -1)" \
      "$("$ALC" "$nid" GET_AMP_GAIN_MUTE 0x8000 2>&1 | tail -1)"
  done
else
  echo "(没找到 alc-verb，跳过 codec 快照)"
fi
echo "--- 音频设备 ---"
system_profiler SPAudioDataType 2>/dev/null | head -25

section "6. 收尾：卸载本次挂载的 ESP"
for dev in $MOUNTED_BY_US; do
  sudo diskutil unmount "$dev" >/dev/null 2>&1 && echo "已卸载 $dev"
done
[ -z "$MOUNTED_BY_US" ] && echo "(本次没有新挂载的卷)"

section "完成"
echo "把这个文件发回：$OUT"
open -R "$OUT" 2>/dev/null
