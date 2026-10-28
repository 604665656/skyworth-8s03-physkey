#!/system/bin/sh
# ============================================================
# physkey.sh —— 物理按键 → 输入源快捷切换（开机自启版）
#   频道+ (KEY_F19/189) → HDMI2 (24)
#   频道- (KEY_F20/190) → HDMI1 (23)
#
# 机身按键走 event11 "MStar Smart TV Keypad"
# 注意: evdev 设备同一时刻只能被一个进程读取(非广播),
#       因此不能有其他 getevent 同时读 event11, 否则会抢事件。
# ============================================================

DEV=/dev/input/event11
GEN=/system/bin/getevent
BB=/system/bin/busybox
SW=/system/etc/tvkeys/setsrc.sh
LOG=/data/local/tmp/physkey.log
GETPROP=/system/bin/getprop

# --- 1) 等机身按键设备就绪 ---
while [ ! -e "$DEV" ]; do
  $BB usleep 500000
done

# --- 2) 等 Android 完全起来，然后落回全屏电视 ---
# 否则开机可能停在智能主页，而机身没有 Home 键，摸不回去
n=0
while [ $n -lt 90 ]; do
  [ "$($GETPROP sys.boot_completed 2>/dev/null)" = "1" ] && break
  $BB usleep 1000000
  n=$((n+1))
done
$BB usleep 2000000

# 只纠正一次：如果当前不在全屏电视，就切过去
w=$(/system/bin/dumpsys window windows 2>/dev/null)
case "$w" in
  *sky_app_atv*) : ;;
  *) /system/bin/am start -n com.skyworth.sky_app_atv/.RootActivity >/dev/null 2>&1 ;;
esac

# --- 3) 监听机身按键 ---
$BB echo "$($BB date '+%H:%M:%S') physkey 就绪" >>"$LOG"

while true; do
  ev=$($GEN -l -c 1 "$DEV" 2>/dev/null)

  if [ -z "$ev" ]; then
    $BB usleep 150000
    continue
  fi

  case "$ev" in
    *KEY_F19*DOWN*)
      $BB echo "$($BB date '+%H:%M:%S') 频道+ -> HDMI2" >>"$LOG"
      /system/bin/sh "$SW" 24 &
      ;;
    *KEY_F20*DOWN*)
      $BB echo "$($BB date '+%H:%M:%S') 频道- -> HDMI1" >>"$LOG"
      /system/bin/sh "$SW" 23 &
      ;;
  esac
done
