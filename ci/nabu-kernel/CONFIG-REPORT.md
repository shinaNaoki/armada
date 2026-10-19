# nabu 7.2.6 config vs ArmadaOS 需求（结论）

对比对象：
- Armada：`armada/packages/kernel/config/armada-kernel.config.overrides`（311 个 CONFIG 项）
- 设备：`nabu-7.0-running.config`（7.0 实机 `/proc/config.gz`）+ `nabu-kernel-additions.config`

## 1. 直接比对结果

311 个 Armada override 中：
- 52 个在设备 config 中不存在；
- 88 个值不同。

但其中绝大多数是 **Armada 为另外 27 台掌机准备的设备项**，nabu 不需要：
- 其他面板 `DRM_PANEL_*`（AR06/AR02/ICNA35XX/CH13726A/…）
- 其他 SoC 的 clock/pinctrl/interconnect（SM8250/8550/8650/8750）
- 其他手柄/触控/PMIC/充电/RGB/风扇（JOYSTICK_RETROID、AYANEO HID、SY7758、HL7139、SN3112 等）
- 其他音频 codec（AW88166/AW88261/WCD938X/WSA881X 等）

这些**不加入 nabu 内核**（加了也只是白编译/白占空间）。

## 2. Armada 真正依赖的通用项（本轮已补齐）

已把「与设备无关、Armada 用户态/服务需要」的缺口写进 `nabu-armada.config`（在 `nabu-kernel-additions.config` 之后应用）：

| 类别 | 补齐项 |
|---|---|
| 调度/性能 | `BPF_JIT_ALWAYS_ON`、`BPF_JIT_DEFAULT_ON`、`BPF_EVENTS`、`DEVFREQ_GOV_PERFORMANCE`、`TRANSPARENT_HUGEPAGE_MADVISE` |
| 调试/tracing/BTF | `DEBUG_INFO`(非 REDUCED)、`DEBUG_INFO_BTF`、`FTRACE`、`FUNCTION_TRACER`、`DYNAMIC_FTRACE`、`FTRACE_SYSCALLS`、`KPROBES`、`KPROBE_EVENTS`、`PERF_EVENTS`、`PM_DEBUG`、`PM_SLEEP_DEBUG`、`DYNAMIC_DEBUG`、`KALLSYMS_ALL` |
| 早期显示/splash | `DRM_SIMPLEDRM`、`DRM_FBDEV_EMULATION`、`SYSFB_SIMPLEFB`、`FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER` |
| zram/crypto | `ZRAM_BACKEND_LZ4/LZO`、`CRYPTO_ZSTD`、`CRYPTO_USER_API_HASH/SKCIPHER`、`CRYPTO_DES/MD5` |
| Waydroid/网络 | `IPV6=y`、`NET_KEY`、`XFRM_USER`、`NFT_REDIR`、`NETFILTER_XT_TARGET_MARK` |
| 手柄/震动 | `JOYSTICK_XPAD(_FF/_LEDS)`、`NINTENDO_FF`、`PLAYSTATION_FF`、`SONY_FF`、`STEAM_FF` |
| 串口/充电调试 | `QCOM_PMIC_PDCHARGER_ULOG=m` |

已经在设备 config 里、无需改的 Armada 通用项：
`SECURITY_SELINUX`、`SECURITY_NETWORK`、`SECURITY`、`USER_NS/PID_NS/NET_NS/UTS_NS/IPC_NS`、`CGROUPS/CGROUP_FREEZER/MEMCG`、`TMPFS(_XATTR/_POSIX_ACL)`、`FUSE_FS`、`FANOTIFY`、`INOTIFY_USER`、`SECCOMP(_FILTER)`、`AUDIT(_SYSCALL)`、`EPOLL/EVENTFD/SIGNALFD/TIMERFD/MEMFD_CREATE`、`FUTEX(_PI)`、`KEYS/KEY_DH_OPERATIONS`、`ANDROID_BINDER_IPC/BINDERFS`、`EROFS_FS`、`OVERLAY_FS`、`SQUASHFS_ZSTD`、`EXFAT_FS`、`NTFS3_FS`、`CIFS`、`NLS_UTF8`、`BT_LE/BT_RFCOMM`、`HIDRAW`、`UHID`、`INPUT_UINPUT`、`HID_STEAM/PLAYSTATION/SONY/NINTENDO`、`NTSYNC`、`UCLAMP_TASK(_GROUP)`、`SCHED_CLASS_EXT`、`PSI(_DEFAULT_DISABLED)`、`LRU_GEN(_ENABLED)`、`BPF/BPF_SYSCALL/CGROUP_BPF`、`CONFIGFS_FS`、`USB_CONFIGFS_F_FS`、`RD_ZSTD`、`UNICODE`、`FW_LOADER_COMPRESS(_XZ/_ZSTD)`、`ZSMALLOC/ZRAM`、`IPV6_MULTIPLE_TABLES`、`NF_TABLES/NF_TABLES_INET/NF_CONNTRACK/NF_NAT/NFT_*`、`WIREGUARD`。

## 3. 有意保留的差异

| 项 | Armada | nabu | 说明 |
|---|---|---|---|
| `EROFS_FS` / `OVERLAY_FS` / `BTRFS_FS` | m | y | 内建更稳，功能等价；启动更早可用 |
| `SECURITY_SELINUX` | y | y（additions 已加） | 必须 |
| `CONFIG_DEBUG_INFO_REDUCED` | 未设置 | **改为未设置** | BTF 需要 |
| 设备项（面板/PMIC/其他 SoC） | 各种 y/m | 不加 | 与 nabu 无关 |

## 4. 影响

- 打开 `DEBUG_INFO`/`BTF`/`FTRACE` 会让内核编译更慢、`armada-kernel-*.tar.zst` 变大（预计 +20–50 MB），这是 Armada 侧的预期（它需要 BTF 给 BPF/scx 工具，`armada-sleep-debug` 用 dynamic debug）。
- `DRM_SIMPLEDRM`/`SYSFB_SIMPLEFB`/`DEFERRED_TAKEOVER` 是 Armada splash 和 fbcon handoff 的需要；nabu 的 msm 仍会接管。
- 未加 `DRM_PANEL_*`/其他 SoC 项，nabu 显示仍由 `panel-novatek-nt36523` + `msm` 提供（已在 7.2.6 验证）。

## 5. 验证方法（CI/本机）

```bash
# 构建脚本会依次应用：
#   nabu-7.0-running.config + nabu-kernel-additions.config + nabu-armada.config
#   make olddefconfig
# 然后检查必需符号：
grep -E '^CONFIG_(SECURITY_SELINUX|DEBUG_INFO_BTF|SCHED_CLASS_EXT|NTSYNC|UCLAMP_TASK|UHID|ANDROID_BINDER_IPC|DRM_SIMPLEDRM|JOYSTICK_XPAD)=' .config
```

CI 的 `build-kernel.sh` 已加入这些文件的顺序应用，并会在 olddefconfig 后检查 nabu 必需项。
