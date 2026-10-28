# 双清（恢复出厂）研究

结论先说：**创维 42E600Y（8S03）没有 recovery 模式，"按住某键再插电进 recovery 双清"的做法在这台机器上不存在。**

## 1. 证据：没有 recovery

### 分区表里没有 recovery 分区

```bash
adb shell cat /proc/partitions
```

```
 179        0    1916928 mmcblk
 179        1        512 mmcblk1
 179        2       6144 mmcblk2
 179        3       4096 mmcblk3
 179        4     409600 mmcblk4     → /system
 179        5     614400 mmcblk5     → /data
 179        6     307200 mmcblk6     → /cache
 179        7      61440 mmcblk7     → /tvservice
 179        8      81920 mmcblk8     → /tvcustomer
 179        9       8192 mmcblk9     → /tvdatabase
 179       10     348160 mmcblk10    → /skydir
```

挂载情况确认：

```
/dev/block/mmcblk4 /system    ext4 ro
/dev/block/mmcblk5 /data      ext4 rw
/dev/block/mmcblk6 /cache     ext4 rw
/dev/block/mmcblk7 /tvservice ext4 ro
```

**没有 recovery 分区。**

### 系统里也没有 recovery 程序

```bash
adb shell ls /system/bin/ | busybox grep -i -E 'recov|wipe|reset|factory'
```

只有：

```
lrwxr-xr-x root shell wipe -> toolbox
```

这是 toolbox 的 `wipe`，用来擦除块设备（`wipe /dev/block/mmcblk5`），**不是双清界面**。

```bash
adb shell ls -l /cache/recovery/
# /cache/recovery/: No such file or directory
```

`/cache/recovery`（Android recovery 的命令通道）也不存在。

### rc 文件里的线索

`/init.rc` 里只有一个相关条目：

```
service flash_recovery /system/etc/install-recovery.sh
```

但：

- `/system/etc/install-recovery.sh` 文件不存在
- 整个 rc 里没有任何 `start flash_recovery` 语句去启动它

所以这条也是死的。

## 2. 真正执行双清的组件

```bash
adb shell dumpsys package com.skyworth.recovery.mst
```

```
Activity Resolver Table:
  Non-Data Actions:
      android.intent.action.MAIN:
        com.skyworth.recovery.mst/.SkyResetDefaultMST
      android.intent.action.Recovery:
        com.skyworth.recovery.mst/.SkyResetDefaultMST

  Package [com.skyworth.recovery.mst]:
    codePath=/system/app/SkyRecovery.apk
    versionName=1.0.2
    targetSdk=15
```

拆开 APK：

```
META-INF/...
AndroidManifest.xml          1976 字节
res/drawable-hdpi/ic_launcher.png
res/layout/main.xml           364 字节
resources.arsc               1064 字节
```

`res/layout/main.xml` 只有 **364 字节** —— 一个空的 `RelativeLayout`，**没有任何按钮、文本或确认控件**。

字符串池里唯一的文案是模板残留：`Hello World, SkyRecoveryAMLActivity!`

**结论：这个 Activity 没有确认界面，一触发就直接执行清数据。**

## 3. 可用命令

### 方式一：创维自己的入口（推荐）

```bash
adb root
adb shell am start -n com.skyworth.recovery.mst/.SkyResetDefaultMST
```

或者用它的自定义 action：

```bash
adb shell am start -a android.intent.action.Recovery
```

### 方式二：Android 标准广播

```bash
adb shell am broadcast -a android.intent.action.MASTER_CLEAR
```

前提检查：`sky_app_atv` 运行在 `android.uid.system` 下，且权限列表里确实有

```
android.permission.MASTER_CLEAR
android.permission.CLEAR_APP_USER_DATA
```

`adb root` 后 `am` 以 uid 0 运行，理论上能通过签名级权限检查。

> 这条**未实测**（会真的清数据）。方式一已确认组件存在且无交互。

### 方式三：设置菜单

```
设置 → 高级 / 用户 → 恢复出厂设置
```

`com.skyworth.setting` 只有单一入口：

```
com.skyworth.setting/.SettingActivity
  响应 android.intent.action.SettingActivity
  响应 android.intent.action.MAIN
```

恢复出厂是 `SettingActivity` 内的一个标签页（图像 / 声音 / 网络 / 高级 / 用户 / 本机信息）。

**但这条路需要方向键**，而机身按键没有方向键 —— 除非用本项目的改造方案先把按键变成可用状态。

## 4. 关于"物理按键双清"

**不存在专用按键组合。**

理由：

1. 没有 recovery 分区 → 没有"按键进 recovery"这个入口；
2. 所有双清逻辑都在 Android 应用层，而 Android 应用层需要方向键导航；
3. 机身只有 电源/音量±/频道±/菜单，没有任何组合键被系统监听（`init.rc`、`init.amber3.rc` 里都没有按键触发的 service）。

如果确实需要"物理手段"恢复，实际可行的两条路是：

- **U 盘强制升级**：`/system/app/` 里有 `SkyUpgradeLocal.apk`（`com.skyworth.upgradelocal`），说明支持本地固件升级。MStar 平台通常支持 U 盘放固件后按键上电触发，但具体组合需查该机型维修手册，本项目未验证。
- **串口**：`/proc/cmdline` 里有 `console=ttyS0,115200`，主板上应该有调试串口排针。接上串口可以拿到 uboot shell，但那需要拆机。

## 5. 双清会清掉什么

| 位置 | 内容 | 双清后 |
|---|---|---|
| `/data` | 应用数据、设置、账号 | **清空** |
| `/tvdatabase` | `user_setting.db` / `factory.db` / `customer.db` | 重置为出厂值 |
| `/system` | 系统分区（含本项目脚本） | **保留** |
| `/cache` | 缓存 | 清空 |

所以本项目的脚本放在 `/system/etc/tvkeys/` 是安全的，双清后依然存在（但自启注入的 `bootimprove1.sh` 也在 `/system`，同样保留）。

## 6. 相关数据库

调试和恢复时可能需要读这些库：

```bash
DB=/tvdatabase/Database/user_setting.db
adb shell /system/xbin/sqlite3 $DB "select enInputSourceType from tbl_SystemSetting"
```

关键表与字段：

| 表 | 字段 | 说明 |
|---|---|---|
| `tbl_SystemSetting` | `enInputSourceType` | 当前输入源 |
| `tbl_SystemSetting` | `enForcedInputSourceType` | 强制信源 |
| `tbl_SystemSetting` | `bOverScan` | 过扫描开关 |
| `tbl_VideoSetting` | `eTvFormat` | 显示模式 |
| `tbl_HDMIOverscanSetting` | `u8HCrop_*` | HDMI 裁剪参数 |
| `tbl_ATVOverscanSetting` | `u8HCrop_*` | ATV 裁剪参数 |

输入源枚举：

| 值 | 源 |
|---|---|
| 0 | VGA / 电脑 |
| 1 | ATV |
| 23 | HDMI1 |
| 24 | HDMI2 |
| 25–27 | HDMI3 / HDMI4 / HDMI_MAX |
| 28 | DTV |
