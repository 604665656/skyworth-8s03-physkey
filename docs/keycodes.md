# 键码逆向记录

本文记录创维 42E600Y（8S03）机身按键的完整识别过程，方便在其他固件版本上复现。

## 1. 输入设备清单

```bash
adb shell cat /proc/bus/input/devices
```

这台机器有 13 个 event 节点，其中与本项目相关的：

| 设备 | 名称 | 说明 |
|---|---|---|
| `event0` | `Skyworth Smart TV IR Receiver` | 红外接收头，`Phys=/dev/ir` |
| `event1` | `Skyworth virtual device` | 通用注入口，可写（本项目用它注入方向键） |
| `event11` | `MStar Smart TV Keypad` | **机身按键**，由 `sky_virtualkeypad` 创建 |
| `event12` | `Vendor_3697_Product_0003` | 触摸/传感器 |

> `event0` 的存在说明电视自带红外接收头 —— 这意味着任何能发 NEC 红外的设备（万能遥控器、带红外的手机）都能控制它，不必买原厂遥控器。

## 2. 机身按键的处理链路

```
SAR 分压按键阵列（不是独立 GPIO 按键）
   ↓  MDrv_SAR_Kpd_GetKeyCode()   ← libutopia.so
/system/bin/sky_virtualkeypad      ← init 拉起，Class=main
   ↓  write(/dev/uinput)
uinput 设备名 "MStar Smart TV Keypad" → /dev/input/event11
   ↓  Android EventHub
   ↓  /system/usr/keylayout/Generic.kl 映射
Android KeyEvent
```

从 `sky_virtualkeypad` 的字符串表可以确认：

```
mdrv_gpio_get_level
MDrv_SAR_Kpd_SetChInfo
MDrv_SAR_Kpd_Init
MDrv_SAR_Kpd_GetKeyCode
/dev/uinput
MStar Smart TV Keypad        ← uinput 设备名
yxd send keycode:%d
E_SAR_KPD_not OK PreviousKeycode = %d
```

## 3. 抓取键码

### 关键前提：同一时刻只能有一个进程读

evdev 设备的事件是 **"谁先读谁拿到"**，不是广播。如果同时开两个 `getevent`，事件会被随机瓜分，两边都拿到残缺数据。

调试前务必确认没有其他读取者：

```bash
adb shell /system/bin/busybox ps | /system/bin/busybox grep getevent
```

### 抓取命令

```bash
# 前台抓，按完 Ctrl-C 退出
adb shell getevent -l /dev/input/event11
```

`-l` 会把键码翻译成名字（`KEY_F19` 而不是 `0xbd`）。

如果需要后台记录（比如遥控操作时），注意 Android 老版本的 `getevent` 输出是**全缓冲**的，重定向到文件时不会实时落盘。可行的写法是用 `-c` 分片：

```sh
# 每 4 个事件退出一次进程，退出时 flush，外层循环重开
while true; do
  getevent -t -l -c 4 /dev/input/event11 >> /data/local/tmp/keys.log
done
```

## 4. 实测结果

按顺序按 音量+ / 音量- / 频道+ / 频道- / 菜单 得到的原始输出：

```
EV_KEY  KEY_F17  DOWN
EV_KEY  KEY_F17  UP
EV_SYN  SYN_REPORT
EV_KEY  KEY_F21  DOWN
EV_KEY  KEY_F18  DOWN
EV_KEY  KEY_F18  UP
EV_SYN  SYN_REPORT
EV_KEY  KEY_F21  DOWN
EV_KEY  KEY_F19  DOWN
EV_KEY  KEY_F19  UP
EV_SYN  SYN_REPORT
EV_KEY  KEY_F21  DOWN
EV_KEY  KEY_F20  DOWN
EV_KEY  KEY_F20  UP
EV_SYN  SYN_REPORT
EV_KEY  KEY_F21  DOWN
EV_KEY  KEY_F14  DOWN
EV_KEY  KEY_F14  UP
EV_SYN  SYN_REPORT
```

对应关系：

| 机身按键 | Linux 键名 | 编号 | Android 映射 |
|---|---|---|---|
| 音量 + | `KEY_F17` | 187 | `UNKNOWN` |
| 音量 − | `KEY_F18` | 188 | `UNKNOWN` |
| 频道 + | `KEY_F19` | 189 | `UNKNOWN` |
| 频道 − | `KEY_F20` | 190 | `UNKNOWN` |
| 菜单 | `KEY_F14` | 184 | `UNKNOWN` |
| *扫描探测* | `KEY_F21` | 191 | `UNKNOWN` |

**`KEY_F21` 不是真实按键**。它出现在每次按键之前，是 SAR 扫描的"有键按下"通知（对应源码里的 `E_SAR_KPD_not OK` 分支），没有对应的 UP 事件。**不要拿它做触发器**，否则每个按键都会双触发。

## 5. 为什么这些键在 Android 层是 UNKNOWN

```bash
adb shell /system/bin/busybox grep -n 'F1[0-9]\|F2[0-4]' /system/usr/keylayout/Generic.kl
```

结果：

```
205:# key 183   F13
206:# key 184   F14
207:# key 185   F15
208:# key 186   F16
209:# key 187   F17
210:# key 188   F18
211:# key 189   F19
212:# key 190   F20
213:# key 191   F21
214:# key 192   F22
215:# key 193   F23
216:# key 194   F24
```

**183~194 全被注释掉了。** 创维故意选用这批空闲编号来承载电视专用按键，好处是不会与标准 PC 键盘的 F13~F24 冲突。

推论：机身按键在 Android 层完全没有 KeyCode，所以按下去**任何 App 都收不到**。这解释了为什么"音量键能调音量"——音量是 `sky_virtualkeypad` 或底层直接调 audio HAL 实现的，走的不是 KeyEvent 这条路。

同时这也意味着：**改动这些键不会影响音量等原有功能**（如果走的是非 KeyEvent 通道），也不会影响外接 USB 键盘。

## 6. 可用于注入的方向键

要注入方向键，需要知道 `Generic.kl` 里哪些 Linux 键码映射到方向键：

```bash
adb shell /system/bin/busybox grep -n 'DPAD' /system/usr/keylayout/Generic.kl
```

```
125:key 103   DPAD_UP
127:key 105   DPAD_LEFT
128:key 106   DPAD_RIGHT
130:key 108   DPAD_DOWN
```

注意 **`DPAD_CENTER` 没有映射**（`# key 352 "KEY_OK"` 和 `# key 353 "KEY_SELECT"` 都被注释），所以：

- 方向键 → `sendevent /dev/input/event1 1 105|106 1`（毫秒级）
- 确认键 → 只能用 `input keyevent 23`（每次约 600ms，起一次 Java VM）

## 7. 在其他机型上复现的步骤

1. `cat /proc/bus/input/devices` 找出行程名带 Keypad / Keyboard 的设备
2. 确认没有其他进程在读该设备
3. `getevent -l /dev/input/eventN` 逐键抓取
4. 排除掉"每次按键前都出现、且没有 UP"的扫描信号
5. 在 `Generic.kl` 里查这些键码是否已被占用
6. 若被占用，需要新建专属 keylayout（按设备名命名，空格换下划线），而不是直接改 `Generic.kl`

第 6 步的设备名规则（Android EventHub）：设备名 `MStar Smart TV Keypad` 对应
`/system/usr/keylayout/MStar_Smart_TV_Keypad.kl`。

本项目**没有**用这个方式，而是选择了运行时监听 + 注入，因为这样不需要重启就能生效，也更容易回滚。
