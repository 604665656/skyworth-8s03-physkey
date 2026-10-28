# 用投影仪遥控器控制创维电视（红外共用）

> 目标：**一个遥控器同时管投影仪和电视**。投影仪遥控器照常控投影仪，同时按下的键也被电视接收并翻译成电视操作。
>
> 实测机型：创维 42E600Y（8S03） + 宏碁/麦酷比 **HY300 PRO**（Allwinner H713 / Android 11）

---

## 1. 为什么能行

电视的 `event0` 是 `Skyworth Smart TV IR Receiver`（`Phys=/dev/ir`），背后是 `mdrv_ir` 内核模块。
它把红外帧解码成 scancode 再交给 `rc-skyworth-tv.ko` 的键表查表。

**关键点：这套解码器是通用 NEC 解码器，不是只认创维自家遥控器。**
只要把「引导码（地址码）」设成目标遥控器的值，任何 NEC 遥控器都能被解码出来。

投影仪遥控器是 **标准 NEC，地址 `0x00`，反码 `0xFF`**，所以引导码要设成 `0x0000FF00`。

解码出来后得到的 scancode 是投影仪遥控器自己的命令字节，电视的键表当然不认识对应语义 —— 于是就有了 `KEY_FN_ESC`、`KEY_7` 这种古怪名字。**这些名字没有意义，只用来当唯一标识。**

---

## 2. 怎么把引导码写进驱动

驱动没有 sysfs 接口，只有 ioctl。命令表是从 `mdrv_ir.ko` 的 `.rel.text` 重定位表反推出来的：

| ioctl 命令 | 内核函数 | 说明 |
|---|---|---|
| `0x00007500` | `MDrv_IR_Init` | 初始化 |
| `0x40047501` | `MDrv_IR_SetDelayTime` |  |
| `0x40047502` | `MDrv_IR_GetKey` | 未初始化时返回内核栈垃圾 |
| `0x40047503` | `MDrv_IR_GetLastKeyTime` | **空壳，恒返回 0** |
| `0x40047506` | `MDrv_IR_EnableIR` |  |
| `0x40047509` | `MDrv_IR_SetMasterPid` |  |
| `0x4004750a` | `MDrv_IR_GetMasterPid` |  |
| `0x4004750e` | `MDrv_IR_SendKey` | 发射（**危险，见 §6**） |
| **`0x4004750f`** | **`MDrv_IR_SetHeaderCode`** | **设引导码，本项目用的就是它** |
| `0x4014750b` | `MDrv_IR_TimeCfg` |  |
| `0x4034750c` | `MDrv_IR_InitCfg` |  |
| `0x4808750d` | `MDrv_IR_ReadShotBuffer` | 读出的是一堆内核栈指针，无效 |

好消息：Android 自带的 `toolbox` 里有 `ioctl` 命令，**不用交叉编译就能下发任意 ioctl**：

```bash
# -l 4 长度 4 字节, -a 4 每个参数字节都填成 0xff 的低 4 字节形式
/system/bin/ioctl -l 4 -a 4 /dev/ir 0x4004750f 0xff00
```

`-a 4 0xff00` 实际写进内核缓冲的是 `00 ff 00 00`，即小端 `0x0000FF00`。
反汇编确认 `MDrv_IR_Init` 里就是 `strb byte0 → 0xfd00b48+0`、`strb byte1 → +1`，
所以 byte0=`0x00` 是地址码，byte1=`0xFF` 是反码。

---

## 3. 解码器行为（从 `_MDrv_IR_ISR` 反汇编得到）

| 条件 | 值 |
|---|---|
| 最少脉冲对数 | ≥ 34 |
| 首脉冲（4.5ms 头） | 3600 ~ 5400 µs |
| 比特「0」 | 周期 ≤ 1343 µs |
| 比特「1」 | 周期 1794 ~ 2687 µs |
| 帧结构 | `[addr, ~addr, cmd, ~cmd]`，逐字节校验反码 |

这组阈值对应标准 NEC（载波 38kHz、头 9ms+4.5ms、bit0=1.125ms、bit1=2.25ms），完全兼容。

实测投影仪遥控器**每一帧都能通过校验**，无需任何容错处理。

---

## 4. 守护进程架构

```
/dev/ir ──mdrv_ir──> rc0/input0 ──> /dev/input/event0
                                        │
                              irremote.sh 单进程读
                                        │
                          查 irmap.conf → input keyevent N
```

`irremote.sh` 干三件事：

1. 启动时对 `/dev/ir` 写一次引导码 `0xff00`
2. 死循环用 `getevent -l -c 3` 读 `event0`
3. 查映射表，认识的转成 Android 键值注入；不认识的写进 `ir_unknown.log`

映射表外置在 `/data/local/tmp/irmap.conf`，**每次按键都重新读** —— 改完立即生效，不用重启。

---

## 5. 踩过的四个坑（都踩实了）

### 坑 1：ioctl 打错设备，静默失败

```sh
DEV=/dev/input/event0                      # ✗ 错
$IO -l 4 -a 4 $DEV 0x4004750f 0xff00 2>/dev/null
```

`0x4004750f` 是 `mdrv_ir` 的私有命令，打到 evdev 设备只会返回 `ENOTTY`，而且因为重定向了 stderr，**什么提示都没有**。必须打到 `/dev/ir`。

### 坑 2：反复重写引导码会打断正在接收的帧（最坑）

最初加了个「守夜」，每 300ms 重写一次引导码，怕被系统还原：

```sh
while true; do ioctl ... 0xff00; usleep 300000; done &
```

结果：**红外中断数在涨，但一个事件都解不出来。**

一帧 NEC 是 4.5ms 头 + 32 bit ≈ 68ms。每 300ms 重写一次寄存器，约 23% 的概率正好打断帧中间的解码。
而且 `SetHeaderCode` 不只是写两个字节，它还会重置驱动内部解码状态。

实测对比：

| 做法 | IRQ 增量 | 解出事件 |
|---|---|---|
| 每 300ms 重写 | +291 | **0** |
| 只写一次 | +455 | **13 / 13** |

**结论：引导码写一次就够，系统不会还原它。** 重启后依然是 `0xff00` 生效。

### 坑 3：event0 只能有一个读进程

evdev 不是广播。两个 `getevent` 同时读，事件被随机瓜分，两边都拿残缺数据。
而且 `getevent` 每次调用会残留子进程，反复重启脚本后会积累一堆幽灵读进程：

```bash
# 部署前先清理
ps | grep '[e]vent0' | awk '{print $1}' | xargs -r kill -9
```

### 坑 4：`getevent -c 1` 会丢事件

`-c N` 是「攒够 N 个事件就 flush 退出」。一次按键正好产生 `DOWN + SYN + UP` 三个事件，所以 `-c 3` 刚好。
`-c 1` 每个事件重启一次进程，重启间隙的事件会丢；`-c 6` 攒不够就永远不输出。

但 `-c 3` 有个副作用：**长按时批边界会错位**，同一次按键可能被处理两次。所以守护里加了 250ms 同键去重。

---

## 6. 不要碰红外发射

`MDrv_IR_SendKey`（`0x4004750e`）看起来能省掉"逐个按键试码"的麻烦 —— 让电视发码，投影仪收到响应就知道码对了。

**实测：发出去电视直接重启。**

```bash
ioctl -l 4 /dev/ir 0x4004750e 0x10 0x18 0x43 0x0f   # ✗ 重启
```

所以本项目**只做接收，不做发射**。要确认某个键的码值，只能靠人工按。

---

## 7. 一个真实的副作用：返回键会让电视界面崩

把投影仪的返回键映射到 Android `BACK`（4）之后，电视会间歇性「界面消失又回来」。抓 logcat 拿到铁证：

```
20:47:11.487  Process com.skyworth.sky_app_atv (pid 3709) has died.
20:47:11      irremote.log: KEY_FAVORITES -> 4          ← 我们注入的 BACK，同一毫秒
20:47:14.479  FATAL EXCEPTION: main
              java.lang.IllegalArgumentException: The surface has been released
                at com.tvos.impl.PlayerImpl._setVideoSurface(Native Method)
                at com.skyworth.platform.ex.ThirdPartyApi$1.surfaceCreated(ThirdPartyApi.java:112)
```

因果链：在 `RootActivity` 上按返回 → ATV 应用结束 → tvos 播放器的 Surface 悬空 →
接手的桌面在 `surfaceCreated` 里调 `setVideoSurface` → 抛异常 → 桌面也崩，连续崩两次。

**这是固件自带 bug**：`20:10:15` 也崩过一次，那时守护还没启动。但我们的 BACK 注入能稳定复现它。

试过用焦点判断来兜底：

```sh
f=$(dumpsys window | grep mFocusedApp)
case "$f" in *RootActivity*) 跳过 ;; esac
```

**挡不住。** 只要主界面被任何窗口盖住（`RootActivity paused=true`），`mFocusedApp` 就查不到它，判断放行，1.1 秒后进程照样死。

所以默认**把返回键注释掉**。需要的话在 `irmap.conf` 里取消一行注释即可，代价是接受偶发界面重启。

---

## 8. 已知的键码（HY300 PRO 遥控器）

| 投影仪按键 | getevent 键名 | scancode | Android 键值 | 确定度 |
|---|---|---|---|---|
| 音量 + | `KEY_FN_ESC` | `0x9b` | 24 | ✅ 实测 |
| 音量 − | `KEY_FN_F12` | `0x0f` | 25 | ✅ 实测 |
| 方向 ↑ | `KEY_3` | `0x03` | 19 | ✅ 实测 |
| 方向 ↓ | `KEY_2` | `0x02` | 20 | ✅ 实测 |
| OK / 确认 | `KEY_7` | `0x07` | 23 | ✅ 实测 |
| 返回 | `KEY_FAVORITES` | `0x5c` | 4 | ✅ 实测，**默认停用** |
| 方向 ← | `KEY_NEXTSONG` | `0x48` | 21 | ⚠️ 推断 |
| 方向 → | `KEY_CHANNELDOWN` | `0x13` | 22 | ⚠️ 推断 |
| 主页 | `KEY_1` | `0x01` | 3 | ⚠️ 推断 |

「推断」的三个是按按键节奏推的（`0x48` 常出现长按连发，像方向键滚动；`0x01` 是干净的点按）。
**没有逐键标注验证过**，用之前建议自己确认一遍。

scancode 和 getevent 键名的对应关系，可以从 `rc-skyworth-tv.ko` 的 `.data` 段表推出（86 项，偏移 256 起，每项 8 字节 `<scancode, keycode>`）。

---

## 9. 公开码表是错的，别用

查 HY300 遥控器码时找到两份公开资料，**都和实测不符**：

| 键 | 本机实测 | vogello/hy300_pilot_codes | Fiooodooor/hy300-linux-porting |
|---|---|---|---|
| 音量 + | **0x9b** | 0x18 | 0x47 |
| 音量 − | **0x0f** | 0x10 | 0x48 |
| 上 | **0x03** | 0x16 | 0x40 |
| 下 | **0x02** | 0x1A | 0x41 |
| 返回 | **0x5c** | 0x19 | 0x45 |

三份数据互相矛盾，一份都对不上。**HY300 至少有多种遥控器批次，码表不通用。**
按这些表盲发不但无效，还因为用了发射路径把电视搞重启了（见 §6）。

---

## 10. 安装

```bash
# 1. 推送
adb push scripts/irremote.sh /data/local/tmp/irremote.sh
adb push scripts/irmap.conf  /data/local/tmp/irmap.conf
adb shell chmod 755 /data/local/tmp/irremote.sh

# 2. 清理幽灵读进程（很重要，见坑 3）
adb shell "ps | grep '[e]vent0' | awk '{print \$1}' | xargs -r kill -9"

# 3. 装进 /system 并启动
adb root && adb shell mount -o remount,rw /system
adb shell "cp /data/local/tmp/irremote.sh /system/etc/tvkeys/irremote.sh && chmod 755 /system/etc/tvkeys/irremote.sh"
adb shell "/system/bin/busybox setsid /system/bin/sh /system/etc/tvkeys/irremote.sh </dev/null >/dev/null 2>&1 &
           /system/bin/busybox usleep 3000000"

# 4. 开机自启（与 physkey.sh 并列）
adb shell "echo '/system/bin/busybox setsid /system/bin/sh /system/etc/tvkeys/irremote.sh </dev/null >/dev/null 2>&1 &' >> /system/bin/bootimprove1.sh"
```

注意 `setsid ... &` 后必须跟一句 `busybox usleep`，否则 adb shell 一退出就把子进程带走。

---

## 11. 自定义

改设备上的 `/data/local/tmp/irmap.conf`，**立即生效**：

```
# <getevent 键名> <Android 键值>
KEY_7         23     # OK
```

常用 Android 键值：`3` 主页、`4` 返回、`19/20/21/22` 上下左右、`23` OK、`24/25` 音量±、`26` 电源、`85` 播放暂停。

想加新键但不知道键名，直接按一下，去看 `/data/local/tmp/ir_unknown.log`。

---

## 12. 排查

```bash
# 红外到底收没收到（最可靠判据：一次按键约 +34）
adb shell "cat /proc/interrupts | grep '^155:'"

# 引导码是否写过
adb shell "cat /data/local/tmp/irremote.log"

# 原始事件
adb shell "cat /data/local/tmp/irraw.log"

# 未识别的键
adb shell "cat /data/local/tmp/ir_unknown.log"

# 只有一个读进程？
adb shell "ps | grep '[e]vent0'"
```

**「IRQ 在涨但日志空」= 收到了但没解出来**，回头查引导码是不是被别的程序重写了（坑 2）。

---

## 13. 局限

- 只能接收，不能发射（§6）
- 返回键默认不可用（§7）
- 电视原配遥控器的按键也走 `event0`，会和投影仪的键混在同一份日志里。如果映射错了，可能出现「按电视遥控器某键，电视执行了投影仪的动作」——这种情况改 `irmap.conf` 即可
- 只验证了 NEC 协议、地址 `0x00`。其他协议（RC5/RC6/Sony）这套驱动不支持
