#!/usr/bin/env bash
# ============================================================
# uninstall.sh —— 还原创维 8S03 电视的机身按键原始行为
#
# 用法:
#   ./uninstall.sh 192.168.1.100
#   ./uninstall.sh                 # USB adb
# ============================================================
set -euo pipefail

ADB="${ADB:-adb}"
TARGET="${1:-}"
DEST=/system/etc/tvkeys
BOOT=/system/bin/bootimprove1.sh

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m\n' "$*"; }
die()   { red "错误: $*"; exit 1; }

command -v "$ADB" >/dev/null 2>&1 || die "找不到 adb"

if [ -n "$TARGET" ]; then
  "$ADB" connect "$TARGET:5555" >/dev/null 2>&1 || true
  SERIAL="$TARGET:5555"
else
  SERIAL="$("$ADB" get-serialno 2>/dev/null || true)"
  if [ -z "$SERIAL" ] || [ "$SERIAL" = "unknown" ]; then
    die "没有检测到设备，请传入电视 IP"
  fi
fi

A() { "$ADB" -s "$SERIAL" "$@"; }

A shell true >/dev/null 2>&1 || die "无法连接 ${SERIAL}"

info "获取 root"
A root >/dev/null 2>&1 || true
sleep 3
for i in 1 2 3 4 5 6 7 8; do
  sleep 2
  if A shell id 2>/dev/null | grep -q "uid=0"; then break; fi
  if [ "$i" = "8" ]; then die "获取 root 失败"; fi
done

info "停止守护进程"
A shell "for p in \$(/system/bin/busybox ps | /system/bin/busybox grep '[p]hyskey.sh' | /system/bin/busybox awk '{print \$1}'); do /system/bin/kill \$p 2>/dev/null; done" >/dev/null 2>&1 || true
A shell "for p in \$(/system/bin/busybox ps | /system/bin/busybox grep '[i]rremote.sh' | /system/bin/busybox awk '{print \$1}'); do /system/bin/kill \$p 2>/dev/null; done" >/dev/null 2>&1 || true
A shell "for p in \$(/system/bin/busybox ps | /system/bin/busybox grep '[e]vent0' | /system/bin/busybox awk '{print \$1}'); do /system/bin/kill \$p 2>/dev/null; done" >/dev/null 2>&1 || true

info "挂载 /system 可写"
A shell mount -o remount,rw /system >/dev/null 2>&1 || die "无法挂载 /system 为可写"

info "恢复启动脚本"
if A shell "[ -f ${BOOT}.orig ] && echo yes" | grep -q yes; then
  A shell /system/bin/busybox cp "${BOOT}.orig" "$BOOT"
  A shell /system/bin/chmod 755 "$BOOT"
  green "已从 ${BOOT}.orig 恢复"
else
  red "未找到备份 ${BOOT}.orig，无法自动恢复启动脚本"
  red "请手动删除 ${BOOT} 末尾的 tvkeys 相关行"
fi

info "删除 $DEST"
A shell /system/bin/busybox rm -rf "$DEST"

info "清理日志与锁文件"
A shell /system/bin/busybox rm -f /data/local/tmp/physkey.log /dev/setsrc.lock
A shell /system/bin/busybox rm -f /data/local/tmp/irremote.log /data/local/tmp/irraw.log /data/local/tmp/ir_unknown.log /data/local/tmp/irmap.conf

echo
green "=============================="
green " 卸载完成，请重启电视"
green "=============================="
echo
echo "  adb -s $SERIAL reboot"
echo
