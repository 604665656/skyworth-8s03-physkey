#!/system/bin/sh
# 投影仪红外遥控器 -> 电视按键
# NEC addr=0x00 ~addr=0xFF -> 引导码寄存器值 0x0000FF00
#
# ── 实测踩过的坑, 改之前先读完 ──────────────────────────────
#  1) SetHeaderCode 的 ioctl 必须打到 /dev/ir; 打到 /dev/input/event0 会静默失败
#  2) 引导码只需写一次; 反复重写会打断正在接收的 NEC 帧(整帧约 68ms)导致解不出码
#  3) event0 同一时刻只能有一个读进程, 否则谁都收不到事件
#  4) 注入必须串行(不要加 &)。input 命令每次要拉起一个 dalvik 进程,
#     本机总内存仅 538MB, 并发注入会挤压 UI 进程
#  5) 不能无脑注入 BACK。在 ATV 的 RootActivity 上按返回会结束该应用,
#     随后桌面在 surfaceCreated 里抛 "The surface has been released" 连锁崩溃。
#     所以 BACK 注入前要先查焦点, 焦点是 RootActivity 就跳过。
#
# 映射表: /data/local/tmp/irmap.conf  每行 "<key名> <Android键值>"
# 未命中的键: /data/local/tmp/ir_unknown.log

IRDEV=/dev/ir
CAPDEV=/dev/input/event0
BB=/system/bin/busybox
GEN=/system/bin/getevent
IO=/system/bin/ioctl
IN=/system/bin/input
MAP=/data/local/tmp/irmap.conf
LOG=/data/local/tmp/irremote.log
RAW=/data/local/tmp/irraw.log
UNK=/data/local/tmp/ir_unknown.log
DEBOUNCE=25          # 同键去重窗口, 单位 1/100 秒

$BB rm -f "$LOG" "$RAW" "$UNK"
$BB echo "# irremote $($BB date '+%H:%M:%S') 启动" >> "$LOG"

if [ ! -f "$MAP" ]; then
  $BB echo "KEY_FN_ESC   24"  >  "$MAP"
  $BB echo "KEY_FN_F12   25"  >> "$MAP"
  $BB echo "KEY_3        19"  >> "$MAP"
  $BB echo "KEY_2        20"  >> "$MAP"
  $BB echo "KEY_FAVORITES 4"  >> "$MAP"
fi

n=0
while [ ! -e "$CAPDEV" ] || [ ! -e "$IRDEV" ]; do
  $BB usleep 500000
  n=$((n+1))
  [ $n -gt 240 ] && { $BB echo "设备未出现, 退出" >> "$LOG"; exit 1; }
done

$IO -l 4 -a 4 "$IRDEV" 0x4004750f 0xff00 >/dev/null 2>&1
$BB echo "$($BB date '+%H:%M:%S') 引导码 0xff00 已写入 $IRDEV (仅一次)" >> "$LOG"

last=""
lastcs=0

while true; do
  ev=$($GEN -l -c 3 "$CAPDEV" 2>/dev/null)
  [ -z "$ev" ] && continue
  $BB echo "$($BB date '+%H:%M:%S') $ev" >> "$RAW"

  name=$($BB echo "$ev" | $BB sed -n 's/.*EV_KEY *\(KEY_[A-Za-z0-9_]*\) *DOWN.*/\1/p' | $BB head -1)
  [ -z "$name" ] && continue

  # 同键去重, 吸收 -c 3 批边界造成的重复
  u=$($BB cat /proc/uptime); u=${u%% *}
  cs=$($BB echo "$u" | $BB awk -F. '{printf "%d", $1*100+$2}')
  if [ "$name" = "$last" ] && [ $((cs - lastcs)) -lt $DEBOUNCE ]; then
    continue
  fi
  last="$name"; lastcs=$cs

  kc=$($BB grep -i "^$name " "$MAP" 2>/dev/null | $BB awk '{print $2}' | $BB head -1)
  if [ -z "$kc" ]; then
    $BB echo "$($BB date '+%H:%M:%S') 未识别 $name" >> "$UNK"
    continue
  fi

  # 返回键: 焦点在 RootActivity 上时跳过, 否则会连锁崩溃
  if [ "$kc" = "4" ]; then
    f=$($BB dumpsys window 2>/dev/null | $BB grep mFocusedApp)
    case "$f" in
      *RootActivity*)
        $BB echo "$($BB date '+%H:%M:%S') 返回 跳过(当前 RootActivity, 防崩)" >> "$LOG"
        continue ;;
    esac
  fi

  $BB echo "$($BB date '+%H:%M:%S') $name -> $kc" >> "$LOG"
  $IN keyevent "$kc"
done
