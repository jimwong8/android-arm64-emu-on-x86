# 验证记录

本仓库的每个结论都来自实际执行，不是推断。下面是原始输出。

环境：x86_64 Linux 6.12（Debian 13），32 核，62 GB RAM，**无 KVM 加速可用**，
宿主 loadavg 9–25（同时跑着别的东西）。

---

## 1. 37.2.12 上 API 26 镜像也报 PCI 错误（推翻"只有 API 30 会中招"）

```
$ emulator/qemu/linux-x86_64/qemu-system-aarch64 -avd gx26 -no-window -accel off \
    -port 5562 -no-snapshot -crash-report-mode disabled -no-metrics -verbose
qemu-system-aarch64: PCI bus not available for hda
```

`-verbose` 打出的设备组是 virtio-mmio（`virtio-blk-device`、`virtio-net-device`），
**末尾被追加了 `-soundhw hda`**：

```
Concatenated QEMU options: ... -soundhw hda
```

逐项排除（每次都同样报错）：

| 尝试 | 还对吗 |
|------|--------|
| `-no-audio` | `-soundhw hda` 仍被追加 |
| `-audio none` | 同上 |
| `config.ini` 改 `hw.audioInput=no` / `hw.audioOutput=no` | 同上 |
| `QEMU_AUDIO_DRV=none` | 同上 |
| 抓 `Concatenated QEMU options:` 去掉 `-soundhw hda` 直接跑 | `unknown option: -serial`，不可重放 |

## 2. 换 30.4.5 之后 QEMU 起来了，但启动卡死

```
$ adb devices
emulator-5562   device
$ adb -s emulator-5562 shell getprop sys.boot_completed
                                        <- 空
$ adb -s emulator-5562 logcat -d | grep -E 'Audioserver died|Waiting for service'
E AudioService: Audioserver died.
I ServiceManager: Waiting for service media.sound_trigger_hw...
E SoundTriggerHalImpl: couldn't load sound trigger module sound_trigger.primary
```

## 3. 打补丁后

```
$ sudo ./scripts/patch-image-audio-hal.py
image    : /home/jimwong/Android/Sdk/system-images/android-26/default/arm64-v8a/vendor.img
partition: offset 1048576
lib64/hw/android.hardware.audio@2.0-impl.so: 237536 bytes, word@0x24a10 = 0xd00000a8
state    : unpatched (lazy-init entry present)
patched  : wrote .../vendor.img.audiohal-patched.so
verify   : in-image word = 0x1400001f  OK

$ sudo ./scripts/patch-image-timeout.sh
image    : .../system.img
partition: offset 1048576
state    : appended 20
verify   : ro.hw_timeout_multiplier=20
```

## 4. gx26（手工配好的 AVD）

```
$ adb -s emulator-5562 shell getprop sys.boot_completed
1
$ adb -s emulator-5562 shell getprop ro.product.cpu.abi
arm64-v8a
$ adb -s emulator-5562 shell getprop ro.build.version.sdk
26
$ adb -s emulator-5562 shell uname -m
aarch64
$ adb -s emulator-5562 shell pm list packages | wc -l
78
$ adb -s emulator-5562 shell service check media.sound_trigger_hw
Service media.sound_trigger_hw: found
$ adb -s emulator-5562 exec-out screencap -p > screen.png
PNG 320 x 640 —— 桌面正常渲染
```

## 5. 从仓库模板新建的 AVD（证明可复现，不是只能在这台机器上用）

```
$ ./scripts/create-avd.sh armrepo_test gx26
creating AVD 'armrepo_test' from template 'gx26'
created: /home/jimwong/.android/avd/armrepo_test.avd
  abi.type=arm64-v8a
  avd.name=armrepo_test
  hw.cpu.arch=arm64
  hw.cpu.ncore=4
  hw.lcd.density=160
  hw.lcd.height=640
  hw.lcd.width=320
  hw.ramSize=3072
  image.sysdir.1=system-images/android-26/default/arm64-v8a/

$ ./bin/arm-emu.sh armrepo_test 5566
$ adb -s emulator-5566 shell getprop sys.boot_completed
1
$ adb -s emulator-5566 shell getprop ro.build.version.sdk
26
$ adb -s emulator-5566 shell getprop ro.product.cpu.abi
arm64-v8a
$ adb -s emulator-5566 shell pm list packages | wc -l
78
$ adb -s emulator-5566 exec-out screencap -p > screen.png
PNG 320 x 640 —— 桌面 + 一次 "System UI isn't responding"（TCG 慢，正常）
```

冷启动耗时：约 **8–10 分钟**（宿主 loadavg 9–25 的真实负载下，两台模拟器并行时更久）；
宿主空闲时约 4–6 分钟。

## 6. 失败过、已修掉的坑（留档，别再踩）

- `avdmanager create avd` 在近期 cmdline-tools 上报
  `Range [0, 0 + -1) out of bounds for length 256` → 改成直接写两个 AVD 文件。
- `yes "" | avdmanager ...` 在 `set -o pipefail` 下会被 SIGPIPE 杀掉整条脚本 → 用 `< /dev/null`。
- 补丁脚本用 `sudo` 跑时 `$HOME` 变成 `/root`，默认镜像路径失效 → 按 `SUDO_USER` 解析。
- `emulator/source.properties` 的字段是 `Pkg.Revision` / `Pkg.BuildId`，不是 `Revision` / `BuildId`。
