# android-arm64-emu-on-x86

在 **x86_64 Linux 主机**上跑**真实 arm64 Android 模拟器**（不是 libhoudini/libndk_translation 翻译层），
用于验证 arm64-only APK、加固包、自修改代码等在翻译层上必崩的应用。

针对的是被 Android SDK 官方模拟器（37.x）掐死的两个问题：

1. 启动器直接拒绝 arm64 镜像
   `FATAL | Avd's CPU Architecture 'arm64' is not supported by the QEMU2 emulator on x86_64 host`
2. 绕过启动器后，捆绑的 `qemu-system-aarch64` 仍然退出：
   `qemu-system-aarch64: PCI bus not available for hda`

本文档记录的是**实测通过**的完整路径，不是推测。

---

## 结论先行

| 组成 | 值 |
|------|-----|
| 系统镜像 | `system-images;android-26;default;arm64-v8a`（Android 8.0，abilist 仅 arm64-v8a） |
| 模拟器 | **30.4.5 (build 7140946)** —— 不能用 SDK 自带的 37.x |
| 加速 | `-accel off`（QEMU TCG，纯软件，无 KVM） |
| 显卡 | `-gpu swiftshader_indirect`（headless 下可渲染） |
| 结果 | `sys.boot_completed=1`，`pm list packages` → 78 包，`screencap` 正常出桌面 |

---

## 根因

### 1. `-soundhw hda` 被无条件加到没有 PCI 总线的机器上

arm64 的 ranchu 机器走 **virtio-mmio**，没有 PCI 总线。而模拟器前端在建命令行时
不看这一点，固定追加 `-soundhw hda`：

```
qemu-system-aarch64: PCI bus not available for hda
```

实测**没法从命令行关掉**：

| 尝试 | 结果 |
|------|------|
| `-no-audio` | 仍然追加 `-soundhw hda` → 依旧报错 |
| `-audio none` | 同上 |
| `config.ini` 里 `hw.audioInput=no` / `hw.audioOutput=no` | 同上 |
| `QEMU_AUDIO_DRV=none` | 同上（而且后端为 none 时 guest HAL 也打不开设备） |
| 拿 `-verbose` 打印的 `Concatenated QEMU options:` 去掉 `-soundhw hda` 自己跑 | 前端解析器不认 `-serial`，命令不可重放 |

**唯一可靠解**：换用 30.4.5。该版本不会给 arm64 ranchu 加 hda 卡。

> 注：镜像 API 级别也会影响设备组（API 30 镜像同样报 PCI 错误），
> 但在 37.x 上**即使 API 26 镜像也会中招**——版本比镜像更关键。

### 2. guest 音频 HAL 在 `getPresentationPosition` 里段错误

换成 30.4.5 之后 QEMU 能起来了，但启动仍然卡住：

```
E AudioService: Audioserver died.
I ServiceManager: Waiting for service media.sound_trigger_hw...
```

`system_server` 在 `startOtherServices()` 里永久等待，表现为
`getprop sys.boot_completed` 为空、`pm install` 一行输出都没有（连 4.5 KB 的系统包都装不动）。

崩溃点在 `/vendor/lib64/hw/android.hardware.audio@2.0-impl.so`：

```
StreamOut::getPresentationPosition
    vaddr 0x2aa10 : adrp x8, ...      <- 懒初始化分支入口
    vaddr 0x2aa8c : ldr  x8, [x21,#0xc0]  <- 初始化完成后的正常路径
```

把入口那条指令改成直接跳过懒初始化、跳到正常路径即可：

```
0x2aa10: 1400001f    b 0x2aa8c
```

文件偏移 = `vaddr - 0x6000` = `0x24a10`（该段映射关系 `vaddr = file_offset + 0x6000`）。

### 3. TCG 太慢导致 Watchdog / ANR 误判

`ro.hw_timeout_multiplier=20` 写进 `system.img` 的 `/build.prop`
（`ro.*` 属性不能 `setprop`，只能改镜像）。

---

## 用法

```bash
# 1) 侧装模拟器 30.4.5（不动 SDK 自带的那份）
./scripts/get-emulator-3045.sh

# 2) 打镜像补丁（需要 sudo：loop mount，会先自动备份）
sudo ./scripts/patch-image-audio-hal.py       # vendor.img: HAL 跳转
sudo ./scripts/patch-image-timeout.sh         # system.img: 超时倍数

# 3) 启动
./bin/arm-emu.sh gx26 5562
```

启动器做的事情等价于：

```bash
export LD_LIBRARY_PATH=$EMU/lib64:$EMU/lib64/qt/lib
$EMU/qemu/linux-x86_64/qemu-system-aarch64 \
  -avd gx26 -no-window -accel off -port 5562 -no-snapshot \
  -gpu swiftshader_indirect
```

## 验证

```bash
$ adb devices
emulator-5562   device
$ adb -s emulator-5562 shell getprop sys.boot_completed
1
$ adb -s emulator-5562 shell getprop ro.product.cpu.abi
arm64-v8a
$ adb -s emulator-5562 shell getprop ro.build.version.sdk
26
$ adb -s emulator-5562 shell pm list packages | wc -l
78
$ adb -s emulator-5562 shell service check media.sound_trigger_hw
Service media.sound_trigger_hw: found
$ adb -s emulator-5562 exec-out screencap -p > screen.png   # 320x640 桌面
```

## 注意事项

- **启动初期会弹 `System UI isn't responding` / `Process system isn't responding`**，
  点 **Wait**（`Wait` 在 `Close app` 下方，点错就真杀进程）。guest loadavg 会从 ~9 掉到 ~3，
  这是 TCG 慢，不是死锁。
- TCG 是**单线程**的，加 vCPU 不会更快。
- 完整启动约 **3–6 分钟**（宿主机空闲时），首次带 `-wipe-data` 更久。
- 快照不可靠（swiftshader 下 `UNSUPPORTED_VK_APP`），脚本用 `-no-snapshot` 冷启动。
- 需要 sudo 只用于 loop mount 改镜像；改完即卸载，无需常驻。
- 先备份再改：所有补丁脚本都会先写 `.orig-backup`。

## 目录

```
bin/arm-emu.sh                      启动器（自动定位 30.4.5，无则报错提示）
scripts/get-emulator-3045.sh        下载并侧装 emulator 30.4.5
scripts/patch-image-audio-hal.py    修补 vendor.img 的音频 HAL 跳转
scripts/patch-image-timeout.sh      给 system.img 的 build.prop 加超时倍数
docs/TROUBLESHOOTING.md             逐步排障：怎么确认是哪个问题
```

## License

MIT
