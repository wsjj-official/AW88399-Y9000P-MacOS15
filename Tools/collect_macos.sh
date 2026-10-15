#!/bin/bash
# collect_macos.sh -- AW88399Fixup diagnostics + first-boot test.
#
# Usage:  bash collect_macos.sh
# Output: ~/Desktop/aw88399-diag-<timestamp>.txt  (+ newest OpenCore log if present)
#
# Sections:
#   0. environment + the boot-args the kernel actually received
#   1. which ESP is the boot ESP.  The macOS root volume is an APFS *synthesized*
#      container (e.g. disk2), so it is resolved to its physical store (disk1s3 ->
#      disk1); the boot ESP is that disk's EFI slice.  Every other ESP is listed too.
#   2. what the boot ESP holds: config.plist hash + boot-args + our Kernel>Add entry,
#      the OC/Kexts listing, the kext's structure and binary hash, and the OpenCore log
#   3. optional: install the kext from ~/Desktop into the boot ESP
#   4. kextload (fixes ownership first, then loads) - the decisive step
#   5. nub, codec snapshot, audio devices, Bluetooth
#   6. unmount what we mounted

OUT="$HOME/Desktop/aw88399-diag-$(date +%Y%m%d-%H%M%S).txt"
exec 1> >(tee "$OUT")
exec 2>&1

section() { echo; echo "================ $* ================"; }
MOUNTED_BY_US=""
OC=""

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
ROOTVOL=$(diskutil info / 2>/dev/null | awk -F': *' '/Part of Whole/{print $2}' | tr -d ' ')
echo "macOS 根卷所属（可能是合成容器）: ${ROOTVOL:-?}"
STORE=$(diskutil info "/dev/$ROOTVOL" 2>/dev/null | awk -F': *' '/Physical Store/{print $2}' | tr -d ' ')
if [ -n "$STORE" ]; then
  echo "  合成容器 -> 物理分区: $STORE"
  ROOTDISK=$(echo "$STORE" | sed 's/s[0-9]*$//')
else
  ROOTDISK="$ROOTVOL"
fi
echo "→ macOS 所在物理盘: ${ROOTDISK:-?}"
BOOTESP=""
[ -n "$ROOTDISK" ] && BOOTESP=$(diskutil list "/dev/$ROOTDISK" 2>/dev/null | awk '/EFI/{print $NF; exit}')
echo "→ 启动 ESP: ${BOOTESP:-(未找到)}"

echo
echo "--- 所有 ESP 一览 ---"
for dev in $(diskutil list 2>/dev/null | awk '/EFI/{print $NF}'); do
  info=$(diskutil info "$dev" 2>/dev/null)
  if ! echo "$info" | grep -q 'Mounted:.*Yes'; then
    sudo diskutil mount "$dev" >/dev/null 2>&1 && MOUNTED_BY_US="$MOUNTED_BY_US $dev"
    info=$(diskutil info "$dev" 2>/dev/null)
  fi
  name=$(echo "$info" | awk -F': *' '/Volume Name/{print $2}')
  mp=$(echo "$info" | awk -F': *' '/Mount Point/{print $2}')
  has_cfg="no"; has_kext="no"
  for rel in "EFI/OC" "EFI/EFI/OC"; do
    [ -f "$mp/$rel/config.plist" ] && has_cfg="yes"
    [ -d "$mp/$rel/Kexts/AW88399Fixup.kext" ] && has_kext="yes"
  done
  mark=""
  [ "$dev" = "$BOOTESP" ] && mark="   <== 启动用这张"
  printf '  %-9s name=%-12s mount=%-18s config=%-3s kext=%-3s%s\n' \
    "$dev" "${name:-?}" "${mp:-未挂载}" "$has_cfg" "$has_kext" "$mark"
done

section "2. 启动 ESP 上的实际情况"
if [ -z "$BOOTESP" ]; then
  echo "⚠️ 没定位到启动 ESP"
else
  BOOTMP=$(diskutil info "$BOOTESP" 2>/dev/null | awk -F': *' '/Mount Point/{print $2}')
  [ -z "$BOOTMP" ] && {
    sudo diskutil mount "$BOOTESP" >/dev/null 2>&1
    MOUNTED_BY_US="$MOUNTED_BY_US $BOOTESP"
    BOOTMP=$(diskutil info "$BOOTESP" 2>/dev/null | awk -F': *' '/Mount Point/{print $2}')
  }
  echo "启动 ESP: $BOOTESP  挂载点: $BOOTMP"
  for rel in "EFI/OC" "EFI/EFI/OC"; do
    [ -f "$BOOTMP/$rel/config.plist" ] && OC="$BOOTMP/$rel" && break
  done
  if [ -z "$OC" ]; then
    echo "❌ 这张 ESP 上没有 EFI/OC/config.plist"
  else
    echo "OC 目录: $OC"
    echo "config sha256 : $(shasum -a 256 "$OC/config.plist" | awk '{print $1}')"
    echo -n "config boot-args: "
    plutil -extract NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args raw -o - "$OC/config.plist" 2>&1 | head -2
    echo "config 里的 AW88399Fixup 条目:"
    plutil -p "$OC/config.plist" 2>/dev/null | grep -B3 -A8 'AW88399Fixup' | sed 's/^/    /' | head -24
    echo "OC/Kexts 里和我们相关的目录:"
    ls -l "$OC/Kexts" 2>/dev/null | grep -i -E 'AW88399|VoodooI2C' | sed 's/^/    /'
    echo "kext 结构:"
    ls -lR "$OC/Kexts/AW88399Fixup.kext" 2>/dev/null | sed 's/^/    /' | head -20
    echo "kext 二进制 sha256: $(shasum -a 256 "$OC/Kexts/AW88399Fixup.kext/Contents/MacOS/AW88399Fixup" 2>/dev/null | awk '{print $1}')"
    echo "（对照：CI 里 0.1.1 的产物应为 ca2b8/b3a5a 开头那类值；只要下面 kextload 能过就说明文件没问题）"
  fi
  echo "--- OpenCore 启动日志 ---"
  if [ -d "$OC/Logs" ]; then
    ls -lt "$OC/Logs" | head -5 | sed 's/^/    /'
    LATEST=$(ls -t "$OC/Logs"/opencore-*.txt 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
      cp "$LATEST" "$HOME/Desktop/" && echo "    已复制到桌面：$(basename "$LATEST")"
      echo "    日志里与我们相关的行："
      grep -i -E 'AW88399|VoodooI2C|Kext|Failed|not loadable|Inject' "$LATEST" | tail -30 | sed 's/^/      /'
    fi
  else
    echo "    （没有 OC/Logs 目录：config 里 Misc>Debug>Target 没开文件日志）"
  fi
fi

section "3. （可选）把桌面上的 kext 装进启动 ESP"
KEXT_SRC=""
for c in "$HOME/Desktop/AW88399Fixup.kext" "$HOME/Desktop/macOS-拷贝到桌面/AW88399Fixup.kext"; do
  [ -d "$c" ] && KEXT_SRC="$c" && break
done
if [ -n "$KEXT_SRC" ] && [ -n "$OC" ]; then
  echo "源：$KEXT_SRC"
  echo "目标：$OC/Kexts/AW88399Fixup.kext"
  echo "安装/覆盖吗？(y/N)"
  read -r ANS
  case "$ANS" in
    y|Y|yes|YES)
      sudo rm -rf "$OC/Kexts/AW88399Fixup.kext"
      sudo cp -R "$KEXT_SRC" "$OC/Kexts/AW88399Fixup.kext" && echo "✅ 已拷贝"
      echo "校验：$(shasum -a 256 "$OC/Kexts/AW88399Fixup.kext/Contents/MacOS/AW88399Fixup" 2>/dev/null | awk '{print $1}')"
      ;;
    *) echo "(跳过)" ;;
  esac
else
  echo "(桌面没有 kext，或没定位到启动 ESP，跳过)"
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
  echo "--- 先把属主/权限修正成 root:wheel（上次报错就是这里）---"
  sudo chown -R 0:0 "$KEXT" 2>&1
  sudo chmod -R go-w "$KEXT" 2>&1
  ls -ld "$KEXT" "$KEXT/Contents"
  echo "--- 顺带做个 ad-hoc 签名（SecureBootModel 已禁用，只是排除签名因素）---"
  sudo codesign --force --deep --sign - "$KEXT" 2>&1 | head -5
  echo "--- kextutil -v 6 诊断（不加载，只做校验；真正原因会写在这里）---"
  if command -v kextutil >/dev/null 2>&1; then
    sudo kextutil -v 6 -t "$KEXT" 2>&1 | grep -v -E '^Kext file|^Checking|^ *$' | head -40
    echo "--- kextutil -v 6 正式加载 ---"
    sudo kextutil -v 6 "$KEXT" 2>&1 | tail -25
  else
    echo "(系统里没有 kextutil)"
  fi
  echo "--- kextload 输出 ---"
  sudo kextload "$KEXT" 2>&1 | head -25
  sleep 3
  echo "--- 加载后的 kext 列表 ---"
  kmutil showloaded 2>/dev/null | grep -i 'AW88399Fixup' || echo "(仍然没加载)"
  echo "--- IORegistry 节点（BringUpStage / ChipId / Applied 就在这里）---"
  ioreg -l -w0 -p IOService 2>/dev/null | grep -i -A25 'AW88399Fixup' | head -45 || echo "(没有节点)"
echo "--- 模式校验（这一项决定第 5 节的 codec 测试有没有意义）---"
MODE=$(ioreg -l -w0 -p IOService 2>/dev/null | grep -A20 'AW88399Fixup' | grep -E '"ReadOnly"|"Applied"|"BootArgsSeenByKext"' | tr -d ' ' | paste -sd' ' -)
echo "    $MODE"
case "$MODE" in
  *'"ReadOnly"=Yes'*)
    echo "    ⚠️ 当前是只读模式：功放没上电，第 5 节的 codec 路由轮换不会有效果。"
    echo "       请把 备用 config/config-写入模式-aw88399rw.plist 覆盖成 EFI/OC/config.plist 后重启再跑。" ;;
  *) echo "    ✅ 写入模式（功放应已上电）" ;;
esac
  echo "--- 最近 3 分钟 AW88399 的内核日志 ---"
  log show --last 3m --info --debug --predicate 'process == "kernel"' 2>/dev/null | grep -i 'AW88399' | tail -40 || echo "(无)"
fi

section "5. nub / codec / 音频设备 / 蓝牙"
echo "--- AWDZ8399 的 nub ---"
ioreg -l -w0 -p IOService 2>/dev/null | grep -i -B6 -A4 'AWDZ8399' | head -25 || echo "❌ 没有 nub"
ALC=""
for c in "$HOME/Desktop/alc-verb" "$HOME/Desktop/macOS-拷贝到桌面/alc-verb" "$(dirname "$0")/alc-verb"; do
  [ -x "$c" ] && ALC="$c" && break
done
if [ -n "$ALC" ]; then
  echo "--- codec 只读快照 ---"
  for nid in 0x14 0x17 0x02 0x03; do
    printf '  NID %s: pin=%s amp=%s\n' "$nid" \
      "$("$ALC" "$nid" GET_PIN_WIDGET_CONTROL 0 2>&1 | tail -1)" \
      "$("$ALC" "$nid" GET_AMP_GAIN_MUTE 0x8000 2>&1 | tail -1)"
  done
  # 0x17 is the woofer/amplifier path.  Its connection list is returned as packed
  # nibbles (0x08060302 -> 2,0,3,0,6,0,8,0 -> candidates 0x02, 0x03, 0x06, 0x08).
  # We cannot know which converter macOS is currently streaming on, so try them all.
  echo "--- 0x17 的连接列表与当前选择 ---"
  LIST=$("$ALC" 0x17 GET_CONNECT_LIST 0 2>&1 | tail -1)
  SEL=$("$ALC" 0x17 GET_CONNECT_SEL 0 2>&1 | tail -1)
  echo "    connect list = $LIST   当前选中索引 = $SEL"
  # The response packs node IDs as bytes (0x08060302 -> 0x02,0x03,0x06,0x08, lowest
  # byte first); SET_CONNECT_SEL wants the position in that list.
  CANDIDATES=$(printf '%s' "$LIST" | sed 's/^0x//' | awk '{
      s=$0; if (length(s)%2) s="0" s; n=length(s);
      for (i=n; i>=2; i-=2) { b=substr(s,i-1,2); if (b!="00") printf "%d ", (n-i)/2 }
  }')
  echo "    候选索引（去掉 0 项）= ${CANDIDATES:-无}"
  echo "--- 逐个候选做「接通 + 打开引脚 + EAPD + 解除静音」，每步之间请听一下 ---"
  for idx in $CANDIDATES; do
    echo "=== 候选索引 $idx ==="
    "$ALC" 0x17 SET_CONNECT_SEL "$idx" 2>&1 | tail -1
    "$ALC" 0x17 SET_PIN_WIDGET_CONTROL 0x40 2>&1 | tail -1
    "$ALC" 0x17 SET_EAPD_BTLENABLE 0x02 2>&1 | tail -1
    "$ALC" 0x17 SET_AMP_GAIN_MUTE 0x807F 2>&1 | tail -1
    "$ALC" 0x17 SET_AMP_GAIN_MUTE 0x007F 2>&1 | tail -1
    printf '    回读: sel=%s pin=%s amp=%s\n' \
      "$("$ALC" 0x17 GET_CONNECT_SEL 0 2>&1 | tail -1)" \
      "$("$ALC" 0x17 GET_PIN_WIDGET_CONTROL 0 2>&1 | tail -1)" \
      "$("$ALC" 0x17 GET_AMP_GAIN_MUTE 0x8000 2>&1 | tail -1)"
    echo "    >>> 现在播一段音乐听 3~5 秒：低音/音量有变化吗？（按回车继续下一个候选）"
    read -r _
  done
  echo "--- 别忘了同时确认：这一步做的时候，功放本身是「已上电」状态才有效 ---"
  echo "    （用 备用 config\\config-写入模式-aw88399rw.plist 启动时，kext 会在开机 5 秒后把功放上电）"
  ioreg -l -w0 -p IOService 2>/dev/null | grep -A14 'AW88399Fixup' | grep -E 'ReadOnly|Applied|ChipId|BringUpStage|SysCtrl|I2sCtrl' | sed 's/^/    /'
fi
echo "--- 音频设备 ---"
system_profiler SPAudioDataType 2>/dev/null | head -25
echo "--- 蓝牙（这次坏了，一起看）---"
echo "蓝牙相关 kext:"
kmutil showloaded 2>/dev/null | grep -i -E 'IntelBluetooth|BlueToolFixup' | sed 's/^/    /' || echo "    ❌ 蓝牙 kext 没加载"
echo "蓝牙控制器:"
system_profiler SPBluetoothDataType 2>/dev/null | head -20 | sed 's/^/    /'
echo "已配对的蓝牙设备:"
system_profiler SPBluetoothDataType 2>/dev/null | sed -n '/Connected:/,/Not Connected:/p' | head -20 | sed 's/^/    /'
echo "USB 上的蓝牙设备（VID 8087）:"
system_profiler SPUSBDataType 2>/dev/null | grep -i -B3 -A6 -E '8087|bluetooth' | head -30 | sed 's/^/    /'
echo "蓝牙报错（最近 10 分钟）:"
log show --last 10m 2>/dev/null | grep -i -E 'bluetoothd|IOBluetooth' | grep -i -E 'fail|error|timeout|unable' | tail -15 | sed 's/^/    /'

section "6. 收尾：卸载本次挂载的 ESP"
for dev in $MOUNTED_BY_US; do
  sudo diskutil unmount "$dev" >/dev/null 2>&1 && echo "已卸载 $dev"
done
[ -z "$MOUNTED_BY_US" ] && echo "(本次没有新挂载的卷)"

section "完成"
echo "把这个文件发回：$OUT"
open -R "$OUT" 2>/dev/null
