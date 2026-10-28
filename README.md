# 创维 8S03 / 42E600Y 机身按键改造：一键切换 HDMI · 红外共用遥控器

> 用电视自带的机身按键直接切 HDMI 输入源。不需要遥控器、不需要联网、不需要买任何硬件。
>
> 附带：**让投影仪遥控器顺手把电视也控了** —— 一个遥控器管两台设备。

适用机型：**创维 42E600Y**（机芯 **8S03**，MStar `amber3` / `BD_MST029B_CUS36_A3`）
固件验证版本：`V1.0.6.0` / SVN `1917E` / Android 4.0.3 (IML74K, userdebug, test-keys)

---

## 一、问题

创维 42E600Y 机身只有五个按键：

```
电源    音量 +    音量 -    频道 +    频道 -    菜单
```

**没有方向键，也没有确认键。**

这在触屏或遥控器场景下无所谓，但一旦遥控器丢了，问题就来了：Android 的界面导航**完全依赖方向键**。没有 `←/→` 和 `ENTER`，你连系统信源条里的选项都移不过去。

实测确认（用 `input keyevent` 逐个注入验证）：

| 尝试 | 结果 |
|---|---|
| 音量 +（信源条打开时） | 信源不变 |
| 频道 +（信源条打开时） | 信源不变 |
| 连按信源键 3 次（178） | 信源不变（信源条 3 秒后自动关闭） |
| `←` / `→`（21/22） | **能切**，但机身没有这两个键 |
| 电视菜单键（82） | 只弹 3D 设置，无信源项 |

结论：**只靠机身按键，物理上无法切换输入源。** 遥控器一丢，电视就永久锁死在开机通道上。

本项目解决的就是这个问题。

---

## 二、原理

### 2.1 先搞清楚机身按键是什么

机身按键不是普通的 GPIO 独立按键，而是 **SAR（Sigma-Delta ADC）分压按键阵列** —— 多个按键通过不同阻值接到同一路 ADC，按不同键得到不同电压。

MStar 平台的处理链路：

```
SAR 分压阵列
   ↓  MDrv_SAR_Kpd_GetKeyCode()
/system/bin/sky_virtualkeypad      ← 守护进程，init 拉起
   ↓  写 /dev/uinput
"MStar Smart TV Keypad"  = /dev/input/event11
   ↓  Android EventHub
   ↓  Generic.kl 映射
Android KeyEvent
```

实测各按键上报的原始键码：

| 机身按键 | Linux 键名 | 编号 |
|---|---|---|
| 音量 + | `KEY_F17` | 187 |
| 音量 − | `KEY_F18` | 188 |
| 频道 + | `KEY_F19` | 189 |
| 频道 − | `KEY_F20` | 190 |
| 菜单 | `KEY_F14` | 184 |
| *（扫描探测，非真实按键）* | `KEY_F21` | 191 |

> `KEY_F21` 每次按键前都会出现一次 DOWN，这是 SAR 按键扫描的"有键按下"探测信号，不要拿它做触发器。

### 2.2 为什么之前完全按不动

关键发现：`/system/usr/keylayout/Generic.kl` 里 **183~194 这批 F 键全被注释掉了**：

```
# key 183   F13
# key 184   F14
...
# key 187   F17
# key 188   F18
```

也就是说，机身按键在 Android 层全部映射成 `UNKNOWN`。按下去系统毫无反应 —— 不是"没实现功能"，而是**这些键根本没有对应的 Android KeyCode**。

这对改造反而极其有利：这批编号是空闲的，改动它们**不会与任何标准按键冲突**，也不会影响外接 USB 键盘（外接键盘走的是另一个输入设备，有各自的 keylayout）。

### 2.3 切源机制

`178` 是 Android 的 `KEYCODE_TV_INPUT`。在**全屏电视模式**下按它，会弹出系统信源条。实测行为：

```
[<]    HDMI1        HDMI2(高亮)       电脑
```

规律：

1. **焦点默认落在当前源上**，不需要归位；
2. 顺序固定，从左到右 `HDMI1(23) → HDMI2(24) → 电脑/VGA(0)`；
3. 只显示**有信号**的源；
4. 信源条 3 秒后自动关闭；
5. **只在 `sky_app_atv.RootActivity`（全屏电视）下弹出**，在智能主页按 178 无效。

所以切源就是：先确保在全屏电视 → 按 178 → 按方向键移动 → 按确认。

### 2.4 为什么要用 sendevent 而不是 input keyevent

`input keyevent` 每次都要起一个 Java VM，单次约 **600ms**。连按 5 次方向键就要 3 秒，操作起来像卡死。

`sendevent` 直接往 uinput 设备写 `input_event` 结构，**毫秒级**：

```sh
sendevent /dev/input/event1 1 106 1   # DPAD_RIGHT down
sendevent /dev/input/event1 0 0 0     # SYN_REPORT
sendevent /dev/input/event1 1 106 0   # DPAD_RIGHT up
sendevent /dev/input/event1 0 0 0     # SYN_REPORT
```

映射关系（Linux 键码 → `Generic.kl`）：

| Linux | 编号 | Android |
|---|---|---|
| `KEY_LEFT` | 105 | `DPAD_LEFT` |
| `KEY_RIGHT` | 106 | `DPAD_RIGHT` |
| `KEY_ENTER` | 28 | `ENTER` |

**注意**：`Generic.kl` 里没有 `DPAD_CENTER` 的映射（`352 KEY_OK` 和 `353 KEY_SELECT` 都被注释了），所以 `sendevent 232` 是无效的，确认键只能用 `input keyevent 23`。

### 2.5 开机自启

这台机器有几个坑：

- `/init.rc` 和 `init.amber3.rc` 住在 **rootfs（内存盘）**，改了重启即失效，不能作为持久注入点；
- 没有 `recovery` 分区，`/system/bin/recovery` 不存在，`/cache/recovery` 不存在；
- `init.rc` 里没有 `init.d` 机制。

唯一持久且低风险的注入点是厂商自己的启动脚本 `/system/bin/bootimprove1.sh`：

```sh
start vold
start netd
...
start virtualkpd          # ← 物理按键守护正是被它拉起的
start skymediaserver

# 我们在这里追加一行
/system/bin/busybox setsid /system/bin/sh /system/etc/tvkeys/physkey.sh </dev/null >/dev/null 2>&1 &
```

选它的理由：它本身就是厂商的启动脚本（`class main`，`on boot` 阶段执行），失败也不会影响其他 `start` 语句；而且它拉起的 `virtualkpd` 正是按键设备的提供者，时序天然正确。

---

## 三、安装

### 前置条件

1. 电视已开启 **ADB 网络调试**，端口 `5555`；
2. 能拿到 root（本固件是 `userdebug` + `test-keys`，`adb root` 直接可用）；
3. 电脑上装有 `adb`。

### 步骤

```bash
git clone https://github.com/604665656/skyworth-8s03-physkey.git
cd skyworth-8s03-physkey

# 参数填电视的局域网 IP
./install.sh 192.168.1.100
```

脚本会依次完成：`adb connect` → `adb root` → 挂载 `/system` 可写 → 安装脚本到 `/system/etc/tvkeys/` → 备份并注入 `bootimprove1.sh`。

安装完成后**重启电视**生效。

### 手动安装（不想用脚本）

```bash
adb connect <电视IP>:5555
adb root
adb shell mount -o remount,rw /system
adb shell mkdir -p /system/etc/tvkeys
adb push scripts/physkey.sh /system/etc/tvkeys/physkey.sh
adb push scripts/setsrc.sh  /system/etc/tvkeys/setsrc.sh
adb shell chmod 755 /system/etc/tvkeys/physkey.sh /system/etc/tvkeys/setsrc.sh

# 备份原启动脚本
adb shell cp /system/bin/bootimprove1.sh /system/bin/bootimprove1.sh.orig

# 追加自启（注意用 >> 追加，不要覆盖）
adb shell "echo '' >> /system/bin/bootimprove1.sh"
adb shell "echo '/system/bin/busybox setsid /system/bin/sh /system/etc/tvkeys/physkey.sh </dev/null >/dev/null 2>&1 &' >> /system/bin/bootimprove1.sh"
```

---

## 四、使用

| 机身按键 | 功能 |
|---|---|
| **频道 +** | 切到 **HDMI2** |
| **频道 −** | 切到 **HDMI1** |
| 音量 + / − | 音量（保持原功能） |
| 菜单 | 菜单（保持原功能） |

按一下约 4 秒完成切换，屏幕会闪一下信源条作为反馈。

选频道键的理由：在 HDMI 输入下，频道键本来就是无意义的，不会与正常操作冲突。

开机后脚本会自动把画面落到**全屏电视**（如果当前停在智能主页，会自动切过去）—— 因为机身没有 Home 键，摸不回电视的话就很麻烦。

### 自定义按键 / 目标源

编辑 `/system/etc/tvkeys/physkey.sh` 里的 `case` 分支即可：

```sh
case "$ev" in
  *KEY_F19*DOWN*)                      # 频道+
    /system/bin/sh "$SW" 24 &          # 24 = HDMI2
    ;;
  *KEY_F20*DOWN*)                      # 频道-
    /system/bin/sh "$SW" 23 &          # 23 = HDMI1
    ;;
esac
```

也可以用别的键（`KEY_F17`=音量+ / `KEY_F18`=音量- / `KEY_F14`=菜单）。

`setsrc.sh` 支持的源编号（由 `pos()` 决定，需与信源条的实际顺序一致）：

| 编号 | 源 | 信源条位置 |
|---|---|---|
| 23 | HDMI1 | 0 |
| 24 | HDMI2 | 1 |
| 0 | 电脑 / VGA | 2 |

如果你的电视信源条顺序不同，改 `setsrc.sh` 里的 `pos()` 函数。

### 手动调用

```bash
adb shell sh /system/etc/tvkeys/setsrc.sh 23    # 切 HDMI1
adb shell sh /system/etc/tvkeys/setsrc.sh 24    # 切 HDMI2
```

返回码：`0` 成功，`2` 目标源不在信源条，`3` 切换后校验失败。

### 查看日志

```bash
adb shell cat /data/local/tmp/physkey.log
```

```
15:39:25 physkey 就绪
15:40:03 频道- -> HDMI1
```

---

## 五、卸载

```bash
./uninstall.sh 192.168.1.100
```

或手动：

```bash
adb root
adb shell mount -o remount,rw /system
adb shell cp /system/bin/bootimprove1.sh.orig /system/bin/bootimprove1.sh
adb shell rm -rf /system/etc/tvkeys
adb reboot
```

卸载后机身按键恢复出厂行为，其他一切不受影响。

---

## 六、风险与注意

**这个项目会修改 `/system` 分区并需要 root。请先读完再动手。**

1. **仅在一个固件版本上验证过**（`V1.0.6.0` / SVN `1917E`）。其他版本的分区布局、键码、信源条顺序都可能不同，**不要照搬**。上机前先用 `getevent` 确认键码。
2. **务必先备份** `bootimprove1.sh`。如果注入内容有语法错误，理论上不影响其他 `start` 语句（我们是追加到末尾），但备份是最后的保险。
3. **双清不会清掉本项目**（脚本在 `/system`），但会清掉 `/data` 和设置数据库。
4. **拔掉网线后**：本项目完全在电视本地运行，不依赖网络。但你同时会失去网页遥控、`adb` 以及投屏功能（该机型没有 WiFi 硬件，只有有线网口）。
5. **只有一个进程能读 `event11`**。evdev 设备的事件是"谁先读谁拿到"，不是广播。如果你同时用 `getevent` 调试，会把按键事件抢走，导致脚本失灵 —— 调试完记得关掉。

---

## 七、双清（恢复出厂）研究

顺手把一个常见误区的结论也记下来。

**这台机器没有 recovery 模式。**

| 检查项 | 结果 |
|---|---|
| 分区表 `mmcblk1~10` | 没有 recovery 分区 |
| `/system/bin/recovery` | 不存在（只有 toolbox 的 `wipe`，那是擦块设备的命令） |
| `/cache/recovery/` | 不存在 |

所以网上"按住音量+ 再插电进 recovery 双清"的教程对本机**完全无效** —— 硬件上就没有这个模式。

真正执行恢复出厂的是：

```
com.skyworth.recovery.mst/.SkyResetDefaultMST
  ← /system/app/SkyRecovery.apk  (13 KB, v1.0.2)
  响应 android.intent.action.MAIN
  响应 android.intent.action.Recovery
```

该 APK 的 `res/layout/main.xml` 只有 **364 字节**（空布局，零按钮）——**没有确认界面，触发即执行**。

```bash
# 会立即清数据并重启，没有二次确认
adb shell am start -n com.skyworth.recovery.mst/.SkyResetDefaultMST
```

`sky_app_atv` 运行在 `android.uid.system` 下且持有 `android.permission.MASTER_CLEAR`，因此标准的 `MASTER_CLEAR` 广播理论上也可行（未实测，会真清数据）：

```bash
adb shell am broadcast -a android.intent.action.MASTER_CLEAR
```

**结论：物理按键双清在这台机器上不存在。** 没有专用按键组合，只能走「设置 → 高级/用户 → 恢复出厂」，而那条路需要方向键。真要双清，用上面的命令最干净。

详见 [docs/factory-reset.md](docs/factory-reset.md)。

---

## 八、验证记录

两次完整关机重启验证，均通过：

| 验证项 | 结果 |
|---|---|
| `bootimprove1.sh` 拉起 physkey.sh | ✅ 两次均成功 |
| 开机自动落到 `sky_app_atv.RootActivity` | ✅ 不停在主页 |
| 频道- 切 HDMI1（24→23） | ✅ |
| 频道+ 切 HDMI2（23→24） | ✅ |
| 开机耗时 | 网络上线 15~35s，`boot_completed` 45~75s |

---

## 九、红外共用遥控器

投影仪（HY300 PRO）的遥控器按下去，投影仪照常有反应，**电视也同时响应音量、方向、确认**。

不需要拆机、不需要焊接、不需要买万能遥控器。电视本来就带红外接收头（`event0` = `Skyworth Smart TV IR Receiver`，`Phys=/dev/ir`），
背后是通用的 NEC 解码器，**只是被引导码限制成只认创维自家遥控器**。

把引导码改成投影仪遥控器的地址码，就能解出它的键：

```bash
/system/bin/ioctl -l 4 -a 4 /dev/ir 0x4004750f 0xff00   # 地址 0x00 / 反码 0xFF
```

然后 `irremote.sh` 把解出的键翻译成 Android 键值注入回去。

| 投影仪遥控 | 电视 | 状态 |
|---|---|---|
| 音量 + / − | 音量 + / − | ✅ 实测 |
| 方向 ↑ / ↓ | 方向 ↑ / ↓ | ✅ 实测 |
| OK | 确认 | ✅ 实测 |
| 方向 ← / → | 方向 ← / → | ⚠️ 推断，待逐键确认 |
| 主页 | 主页 | ⚠️ 推断，待逐键确认 |
| 返回 | 已停用 | 会让电视界面崩，见下文 |

### 三个必须知道的坑

1. **引导码只能写一次。** 写「守夜」循环每 300ms 重写一次，会把正在接收的 NEC 帧打断（一帧 68ms），
   结果是红外中断在涨、一个事件都解不出来。实测：守夜版 IRQ +291 / 0 事件；只写一次 IRQ +455 / 13 次全解出。
2. **ioctl 必须打到 `/dev/ir`。** 打到 `/dev/input/event0` 返回 `ENOTTY`，重定向掉 stderr 就完全无声。
3. **`event0` 只能有一个读进程。** evdev 不是广播，两个 `getevent` 同时读会把事件瓜分掉。

### 不要用红外发射

`SendKey`（`0x4004750e`）看起来能省掉人工试码，实测**发一次电视直接重启**。本项目只做接收。

### 返回键为什么默认关掉

注入 `BACK` 后电视会间歇性界面消失。logcat 抓到的铁证：

```
20:47:11.487  Process com.skyworth.sky_app_atv (pid 3709) has died.
20:47:11      irremote.log: KEY_FAVORITES -> 4      ← 注入的 BACK，同一毫秒
20:47:14.479  FATAL EXCEPTION: main
              java.lang.IllegalArgumentException: The surface has been released
                at com.tvos.impl.PlayerImpl._setVideoSurface(Native Method)
```

在 `RootActivity` 上按返回 → ATV 应用结束 → tvos 播放器 Surface 悬空 → 接手的桌面在
`surfaceCreated` 里崩，连锁崩两次。**这是固件自带 bug**（守护启动前也崩过一次），
但注入 BACK 能稳定复现。用焦点判断兜不住（主界面被覆盖时 `mFocusedApp` 查不到它）。

要恢复：`irmap.conf` 里取消 `#KEY_FAVORITES  4` 那行的注释。

完整技术细节、ioctl 命令表、解码器阈值、排查手册见 **[docs/ir-remote-sharing.md](docs/ir-remote-sharing.md)**。

---

## 十、License

MIT
