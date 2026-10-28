#!/system/bin/sh
# ============================================================
# setsrc.sh —— 把电视输入源切到指定编号
#   用法: setsrc.sh 23   (23=HDMI1, 24=HDMI2)
# 原理: 全屏电视模式下按 178 弹出信源条(焦点=当前源),
#       再用 sendevent 注入 DPAD 左右键移动, 最后 23 确认。
#       实测信源条顺序(左→右): HDMI1(23) → HDMI2(24) → 电脑(0)
# ============================================================

TGT="$1"
DB=/tvdatabase/Database/user_setting.db
SQ=/system/xbin/sqlite3
BB=/system/bin/busybox
SE=/system/bin/sendevent
UDEV=/dev/input/event1
LOCK=/dev/setsrc.lock
RM="/system/bin/busybox rm"

[ -z "$TGT" ] && exit 1

# 防重入: 整轮切源约 4 秒, 期间忽略重复请求
if [ -f "$LOCK" ]; then
  OLDPID=$(cat "$LOCK" 2>/dev/null)
  if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
    exit 0
  fi
fi
echo $$ >"$LOCK"

cur() { $SQ "$DB" "select enInputSourceType from tbl_SystemSetting" 2>/dev/null; }

# 信源条里的横向位置
pos() {
  case "$1" in
    23) echo 0 ;;   # HDMI1
    24) echo 1 ;;   # HDMI2
    0)  echo 2 ;;   # 电脑/VGA
    *)  echo -1 ;;
  esac
}

# 注入一次按键(毫秒级, 比 input keyevent 快一个数量级)
snd() {
  $SE $UDEV 1 "$1" 1
  $SE $UDEV 0 0 0
  $SE $UDEV 1 "$1" 0
  $SE $UDEV 0 0 0
}

c=$(cur)
if [ "$c" = "$TGT" ]; then
  $RM -f "$LOCK"
  exit 0
fi

# 信源条只在全屏电视模式下弹出, 先确保处于该界面
/system/bin/am start -n com.skyworth.sky_app_atv/.RootActivity >/dev/null 2>&1
$BB usleep 900000

# 打开信源条
/system/bin/input keyevent 178
$BB usleep 700000

pc=$(pos "$c")
pt=$(pos "$TGT")

if [ "$pt" = "-1" ]; then
  # 目标源不在信源条里, 直接放弃
  $RM -f "$LOCK"
  exit 2
fi

if [ "$pc" = "-1" ]; then
  # 当前位置未知: 先一路左移到最左端, 再右移到位
  i=0
  while [ $i -lt 8 ]; do snd 105; $BB usleep 200000; i=$((i+1)); done
  i=0
  while [ $i -lt "$pt" ]; do snd 106; $BB usleep 200000; i=$((i+1)); done
else
  n=$((pt - pc))
  if [ $n -gt 0 ]; then
    i=0
    while [ $i -lt $n ]; do snd 106; $BB usleep 220000; i=$((i+1)); done
  elif [ $n -lt 0 ]; then
    n=$((0 - n)); i=0
    while [ $i -lt $n ]; do snd 105; $BB usleep 220000; i=$((i+1)); done
  fi
fi

# 确认
/system/bin/input keyevent 23
$BB usleep 1500000

c=$(cur)
$RM -f "$LOCK"

if [ "$c" = "$TGT" ]; then
  exit 0
fi
exit 3
