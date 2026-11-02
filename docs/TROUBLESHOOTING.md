# 逐步排障

按顺序走，每一步都有明确的"过了/没过"判据。**别跳步**——两个问题叠在一起时，
修好第一个会暴露第二个，容易误以为修错了方向。

---

## Step 0 — 确认镜像和 AVD 存在

```bash
ls $ANDROID_SDK_ROOT/system-images/android-26/default/arm64-v8a/
ls ~/.android/avd/*.avd/config.ini
grep -E 'image.sysdir|abi.type|hw.cpu.arch' ~/.android/avd/gx26.avd/config.ini
```

判据：`system.img` `vendor.img` `userdata.img` 三件齐全；`config.ini` 里
`abi.type=arm64-v8a`。

常见误判：`Cannot find AVD system path` 意味着**镜像根本没装**，不是路径配错。
别去折腾 `ANDROID_SDK_ROOT`，直接 `sdkmanager "system-images;android-26;default;arm64-v8a"`。

---

## Step 1 — 启动器拒绝 arm64

```bash
$ANDROID_SDK_ROOT/emulator/emulator -avd gx26 -no-window
```

```
FATAL | Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator
        on x86_64 host. System image must match the host architecture.
```

这是**启动器的策略检查**，不是硬件限制。镜像里同时带了完整的
`emulator/qemu/linux-x86_64/qemu-system-aarch64`，它本身就是完整前端，接受
`-avd` / `-gpu` / `-accel` 等正常参数，直接调用它即可绕过。

---

## Step 2 — `PCI bus not available for hda`

```bash
export LD_LIBRARY_PATH=$ANDROID_SDK_ROOT/emulator/lib64:$ANDROID_SDK_ROOT/emulator/lib64/qt/lib
$ANDROID_SDK_ROOT/emulator/qemu/linux-x86_64/qemu-system-aarch64 \
  -avd gx26 -no-window -accel off -port 5562 -no-snapshot
```

```
qemu-system-aarch64: PCI bus not available for hda
```

判据：**看到这行就是模拟器版本问题**，与镜像、AVD、参数都无关。

已经逐项排除过的无效尝试（别再试一遍）：

| 尝试 | 结果 |
|------|------|
| `-no-audio` | 仍追加 `-soundhw hda` |
| `-audio none` | 同上 |
| `config.ini` 里 `hw.audioInput=no`、`hw.audioOutput=no` | 同上 |
| `QEMU_AUDIO_DRV=none` | 同上 |
| `-verbose` 打印的 `Concatenated QEMU options:` 去掉 `-soundhw hda` 再跑 | 前端解析器报 `unknown option: -serial`，命令不可重放 |
| `-qemu -device pci-host-ecam-generic` | 附加参数排在 `-soundhw` 之后，总线来不及存在 |

**正确做法**：`scripts/get-emulator-3045.sh` 侧装 emulator 30.4.5，用它跑。
30.4.5 不会给 arm64 ranchu 加 hda 卡，设备组是 virtio-mmio（`virtio-blk-device`、
`virtio-net-device`），与 arm64 机器匹配。

---

## Step 3 — QEMU 起来了，但永远启动不完

```bash
adb devices               # emulator-5562  device    <- 已经能连
adb -s emulator-5562 shell getprop sys.boot_completed   # 空
adb -s emulator-5562 shell getprop init.svc.bootanim    # running
```

```bash
adb -s emulator-5562 logcat -d | grep -E 'Audioserver died|Waiting for service'
```

```
E AudioService: Audioserver died.
I ServiceManager: Waiting for service media.sound_trigger_hw...
```

判据：`media.sound_trigger_hw` 不发布 → `system_server` 卡在 `startOtherServices()`
→ `pm install` 一行输出都没有（连 4.5 KB 的包也装不动）。

**不要** `stop audioserver` 绕过：那会把"崩溃重启循环"变成"永久死等"，更没救。

修法：`sudo scripts/patch-image-audio-hal.py`（把
`StreamOut::getPresentationPosition` 懒初始化入口改成 `b 0x2aa8c`）。

---

## Step 4 — 启动完成了，但会弹无响应

```bash
adb -s emulator-5562 shell getprop sys.boot_completed
1
adb -s emulator-5562 shell cat /proc/loadavg
8.91 6.32 2.93 ...
```

看到 `System UI isn't responding` / `Process system isn't responding`：

- 点 **Wait**（`Wait` 在 `Close app` 下方，点错就真杀进程从头再来）
- 等 guest loadavg 从 ~9 降到 ~3，弹窗自己消失

这不是死锁，是 TCG 比原生慢 10–50 倍。`sudo scripts/patch-image-timeout.sh`
把 `ro.hw_timeout_multiplier` 设成 20 只是把阈值放宽，不解决慢。

---

## Step 5 — 正常状态是什么样

```bash
adb -s emulator-5562 shell getprop ro.product.cpu.abi     # arm64-v8a
adb -s emulator-5562 shell getprop ro.build.version.sdk   # 26
adb -s emulator-5562 shell uname -m                       # aarch64   <- 内核是真 arm64
adb -s emulator-5562 shell pm list packages | wc -l       # 78
adb -s emulator-5562 shell service check media.sound_trigger_hw
# Service media.sound_trigger_hw: found
adb -s emulator-5562 exec-out screencap -p > screen.png   # 320x640 桌面图
```

`uname -m` 返回 `aarch64` 这一条最关键：说明跑的是**真 ARM64 指令集**，
不是 libndk_translation 之类的翻译层。翻译层上被加固/自修改代码的应用会崩在
`ndk_translation_HandleNoExec`（`SEGV_ACCERR`），那才是需要真 ARM 环境的场景。

---

## 附：为什么不用 `-no-audio`

`-no-audio` 让 guest 完全没有音频设备，vendor 音频 HAL 打不开设备后崩溃，
`audioserver` 自杀，进而触发 Step 3 的死锁。**在 arm64 镜像上，`-no-audio`
是把"能启动"变成"永远启动不完"的最快方式。**

宿主机没有声卡也不影响：QEMU 的 null 音频后端足以让 HAL 正常打开设备，
不需要真实声卡。
