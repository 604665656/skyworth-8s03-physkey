#!/usr/bin/env bash
# ============================================================
# install.sh —— 把「物理按键切 HDMI」安装到创维 8S03 电视
#
# 用法:
#   ./install.sh 192.168.1.100      # 通过网络 adb
#   ./install.sh                    # 通过 USB adb（已连接单台设备时）
#
# 前置: 电视已开 ADB 网络调试(5555)，且可 adb root
# ============================================================
set -euo pipefail

ADB="${ADB:-adb}"
TARGET="${1:-}"
DEST=/system/etc/tvkeys
MARK="tvkeys/physkey.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()   { red "错误: $*"; exit 1; }

command -v "$ADB" >/dev/null 2>&1 || die "找不到 adb，请先安装 Android Platform Tools 或设置 ADB 环境变量"

# ---------- 1. 连接 ----------
if [ -n "$TARGET" ]; then
  info "连接 $TARGET:5555"
  "$ADB" connect "$TARGET:5555" >/dev/null 2>&1 || true
  SERIAL="$TARGET:5555"
else
  SERIAL="$("$ADB" get-serialno 2>/dev/null || true)"
  if [ -z "$SERIAL" ] || [ "$SERIAL" = "unknown" ]; then
    die "没有检测到设备，请传入电视 IP，例如 ./install.sh 192.168.1.100"
  fi
fi

A() { "$ADB" -s "$SERIAL" "$@"; }

A shell true >/dev/null 2>&1 || die "无法连接 ${SERIAL}，请检查 IP、网络和电视的 ADB 调试开关"

# ---------- 2. root ----------
info "获取 root（adbd 会重启，稍等）"
A root >/dev/null 2>&1 || true
sleep 3
# root 重启后需要重连
for i in 1 2 3 4 5 6 7 8; do
  sleep 2
  if A shell id 2>/dev/null | grep -q "uid=0"; then break; fi
  if [ "$i" = "8" ]; then die "获取 root 失败。本方法要求固件为 userdebug/test-keys 版本"; fi
done
green "root OK"

# ---------- 3. 机型检查 ----------
MODEL="$(A shell getprop ro.build.skymodel 2>/dev/null | tr -d '\r')"
SVN="$(A shell getprop ro.build.version.skysvn 2>/dev/null | tr -d '\r')"
info "机型: ${MODEL:-未知}  固件SVN: ${SVN:-未知}"
if [ "$MODEL" != "8S03" ]; then
  red "警告: 本脚本仅在 8S03 上验证过（当前为 ${MODEL:-未知}）"
  printf "继续安装？[y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 1
fi

# ---------- 4. 校验关键前提 ----------
info "检查依赖"
for f in /system/bin/busybox /system/bin/sendevent /system/xbin/sqlite3 /dev/input/event11; do
  if A shell "[ -e $f ] && echo ok" 2>/dev/null | grep -q ok; then
    green "  ✓ $f"
  else
    die "缺少 $f，本机环境不满足要求"
  fi
done

# ---------- 5. 安装脚本 ----------
info "挂载 /system 可写"
A shell mount -o remount,rw /system >/dev/null 2>&1 || die "无法挂载 /system 为可写"
A shell mkdir -p "$DEST"

info "推送脚本到 $DEST"
A push "$HERE/scripts/physkey.sh" "$DEST/physkey.sh" >/dev/null
A push "$HERE/scripts/setsrc.sh"  "$DEST/setsrc.sh"  >/dev/null
A shell chmod 755 "$DEST/physkey.sh" "$DEST/setsrc.sh"

A shell sh -n "$DEST/physkey.sh" || die "physkey.sh 语法检查失败"
A shell sh -n "$DEST/setsrc.sh"  || die "setsrc.sh 语法检查失败"
green "脚本安装完成"

# ---------- 6. 注入开机自启（幂等） ----------
BOOT=/system/bin/bootimprove1.sh
if A shell "/system/bin/busybox grep -q '$MARK' $BOOT 2>/dev/null && echo yes" | grep -q yes; then
  info "自启已存在，跳过注入"
else
  info "备份并注入自启: $BOOT"
  if A shell "[ -f ${BOOT}.orig ] && echo yes" | grep -q yes; then
    info "  已存在备份 ${BOOT}.orig，不再覆盖"
  else
    A shell /system/bin/busybox cp "$BOOT" "${BOOT}.orig"
  fi
  A shell "echo '' >> $BOOT"
  A shell "echo '# --- 物理按键快捷切源, by tvkeys ---' >> $BOOT"
  A shell "echo '/system/bin/busybox setsid /system/bin/sh $DEST/physkey.sh </dev/null >/dev/null 2>&1 &' >> $BOOT"
  green "自启注入完成"
fi

# ---------- 7. 立即启动一次（免重启试用） ----------
info "尝试立即启动守护进程"
A shell "/system/bin/busybox setsid /system/bin/sh $DEST/physkey.sh </dev/null >/dev/null 2>&1 & /system/bin/busybox usleep 2000000" >/dev/null 2>&1 || true
if A shell "/system/bin/busybox ps | /system/bin/busybox grep -c '[p]hyskey.sh'" 2>/dev/null | grep -q "[1-9]"; then
  green "守护进程已运行"
else
  red "守护进程未启动，重启后会自动拉起"
fi

echo
green "=============================="
green " 安装完成"
green "=============================="
echo
echo "按键功能:"
echo "  频道 +  →  HDMI2"
echo "  频道 -  →  HDMI1"
echo
echo "建议重启一次以验证自启:"
echo "  adb -s $SERIAL reboot"
echo
echo "查看日志:"
echo "  adb -s $SERIAL shell cat /data/local/tmp/physkey.log"
echo
echo "卸载:  ./uninstall.sh ${TARGET:-}"
