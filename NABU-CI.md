# ArmadaOS for nabu (Xiaomi Pad 5 / SM8150)

目标：把 ArmadaOS 移植到小米平板 5（`nabu`，SM8150），用 **Kumar-Jy 的 7.2.11
内核**替换仓库里早期的 7.2.6 手工 forward-port，并通过 GitHub Actions 产出：

1. 可 `dd` 到 `linux` 分区的 **ext4 rootfs 镜像**（含 ostree 部署、内核模块、固件、`/boot`）；
2. 可拷到 ESP 的 **UKI**（`EFI/armadaOS/armada-<kver>.efi`）。

> 本分支（`nabu`）现在是核心硬件 + Plasma 配置层 + 传感器/SLPI + iris VA-API。
> 相机、patched upower、stylus-popup 仍留到后续迭代。

## 1. 参考与源码固定

| 项目 | 值 |
| --- | --- |
| 内核源码 | `https://github.com/Kumar-Jy/linux` |
| 内核分支 | `nabu/7.2.y` |
| 固定 commit | `739161a890128f23bd1aa679d8754a9ea299269e` |
| 内核版本 | 7.2.11（`SUBLEVEL=11`） |
| 基础配置 | `arch/arm64/configs/nabu_defconfig` |
| DTB | `sm8150-xiaomi-nabu.dtb` |
| 固件包 | `linux-firmware-xiaomi-nabu-25.04.26-1-any.pkg.tar.xz` |
| 固件 SHA256 | `bef43c32029902bc4c3c1b7c7007c6e5d954fe673933087a836b5a41b567bac9` |
| libssc | `v0.4.4`（nabu patch） |
| hexagonrpc | `v0.4.0` |
| qrtr | `5923eea97377f4a3ed9121b358fd919e3659db7b`（`qrtr-ns` enabled） |
| rmtfs / tqftpserv | `v1.3` / `v1.2` |
| iio-sensor-proxy | `3.9` + SSC race/proximity patches |
| iris-vaapi | `b0ef8f7512321d36d52e4a1a52fd3eb0eec9a107` |

参考仓库：`Nabu-arch-images`（安装/UKI/Plasma 配置）与 `nabu-pkgs`（Arch 包、
内核 PKGBUILD、固件、UCM、传感器包）。**不要**再使用旧的 `ci/nabu-kernel/`
补丁链。

## 2. 目录

```
ci/nabu/kernel.config          # armada 在 nabu_defconfig 之上的增量配置
ci/nabu/kernel.required        # 构建后必须成立的符号清单
ci/nabu/README.md              # 内核来源、配置理由、tarball 布局
scripts/ci/build-kernel.sh     # 拉取固定 commit → 配置 → 编译 → 打 tar.zst
scripts/ci/prepare-rootfs.sh   # BIB ext4 raw → 合并 /boot → fstab/BLS → UKI
image/10-armada-nabu.toml      # ext4 + nabu kargs（覆盖 base 的 kargs.d）
image/Containerfile            # 固件/UKI 钩子/tablet-mode 编译与安装
image/firmware/                # nabu 专用固件（小写 qcom/sm8150/xiaomi/nabu）
image/nabu/tablet-mode/        # 键盘/盖子驱动的 SW_TABLET_MODE 守护进程
image/nabu/userspace/build.sh  # libssc/hexagonrpc/qrtr-ns/rmtfs/tqftpserv/iio/iris 源码构建
image/nabu/sensors/patches/    # libssc + iio-sensor-proxy 的 nabu 补丁
image/nabu/iris/patches/       # iris-vaapi DMA-buf/derive 补丁
system_files/usr/share/qcom/   # SLPI 传感器 sensors/socinfo 配置树
system_files/usr/bin/nabu-autobrightness            # 环境光自动亮度
system_files/usr/libexec/nabu-sensors-recover       # 睡眠/唤醒后的传感器恢复
image/armada-uki-update        # OTA/回滚后重生成 UKI（含 DTB 回退）
system_files/usr/share/alsa/ucm2/Xiaomi/nabu/       # 四扬声器 UCM
system_files/usr/share/alsa/ucm2/conf.d/sm8150/     # 声卡匹配
system_files/usr/share/pipewire/pipewire.conf.d/    # 扬声器保护滤波
system_files/usr/bin/nabu-pmac-set                  # 由板序列号推导 Wi-Fi MAC
system_files/etc/skel/.config/kwinoutputconfig.json # DSI-1 旋转/缩放/120Hz
system_files/etc/skel/.config/kwinrc|plasmarc       # 虚拟键盘
system_files/etc/sddm.conf.d/10-nabu.conf           # 保守的 greeter 配置
.github/workflows/nabu-image.yml                    # kernel job + image job
.github/workflows/nabu-bib-debug.yml                # 只重跑 BIB 的调试流程
```

## 3. 内核

`scripts/ci/build-kernel.sh` 做以下事情：

1. 在 `.ci-kernel/linux-nabu` 初始化仓库，浅取 `nabu/7.2.y`，校验 HEAD 等于
   `KERNEL_REF`；分支移动会直接失败，必须显式更新 pin。
2. `make ARCH=arm64 nabu_defconfig`。
3. 用 `scripts/kconfig/merge_config.sh` 合并 `ci/nabu/kernel.config`，
   关闭 `DEBUG_INFO_REDUCED`，`make olddefconfig`，再 `make syncconfig`
   刷新 `include/config/auto.conf`。
4. 按 `ci/nabu/kernel.required` 逐项校验（SELinux/BTF/scx/EROFS/nabu 驱动等），
   任何不匹配都会打印实际值并退出。
5. 编译 `Image modules qcom/sm8150-xiaomi-nabu.dtb`，通过 make 参数
   `EXTRAVERSION=-sm8150-nabu-1 LOCALVERSION=` 得到 `7.2.11-sm8150-nabu-1`。
   `CONFIG_LOCALVERSION_AUTO` 已在 config 中关闭，避免 `-g<sha>`/`-dirty`
   后缀进入 `/usr/lib/modules` 和 UKI 名称。
6. 暂存成 Armada 需要的布局并打包：
   ```
   lib/modules/<kver>/vmlinuz
   lib/modules/<kver>/modules...
   lib/modules/<kver>/dtb/qcom/sm8150-xiaomi-nabu.dtb
   ```
   输出 `out/armada-kernel-<kver>.tar.zst` + `.sha256`。

`ci/nabu/kernel.config` 只放 **Armada 通用需求**：SELinux/LSM、bootc/ostree
文件系统、BTF/tracing/scx、调度/内存、splash handoff、zram/crypto、netfilter、
手柄输入。设备驱动完全来自 `nabu_defconfig`（参考内核已经带
`QCOM_BMS`、`CHARGER_IDTP9418`、SLPI、iris 等），不再复制 7.2.6 的旧设备项。

本地只验证配置（不需要 root）：

```bash
cd /home/user/workspace
WORK=.work/linux-nabu
git init -q "$WORK" && git -C "$WORK" remote add origin https://github.com/Kumar-Jy/linux
git -C "$WORK" fetch --depth 1 origin refs/heads/nabu/7.2.y
git -C "$WORK" checkout -q FETCH_HEAD
test "$(git -C "$WORK" rev-parse HEAD)" = 739161a890128f23bd1aa679d8754a9ea299269e
cd "$WORK"
make ARCH=arm64 nabu_defconfig
bash scripts/kconfig/merge_config.sh .config /home/user/workspace/armada/ci/nabu/kernel.config
make ARCH=arm64 olddefconfig
```

## 4. 固件

`image/firmware/` 已按参考固件包更新为小写路径：

- `qcom/sm8150/xiaomi/nabu/{a640_zap.mbn,adsp.mbn,cdsp.mbn,modem.mbn,modemuw.jsn,slpi_nb.mbn,venus.mbn,wlanmdsp.mbn}`
- `qcom/{a630_sqe.fw,a640_gmu.bin}`、`novatek/`、`cirrus/`、`qca/`

旧的 `qcom/sm8150/Xiaomi/`（大写）在大小写敏感的内核固件加载器下会静默失败，
已删除。`slpi_nb.mbn` 供 `&remoteproc_slpi` 使用；即使本分支不装传感器 daemon
也保留。

## 5. 启动链

`image/10-armada-nabu.toml` 覆盖 `/usr/lib/bootc/kargs.d/10-armada.toml`：

- ext4 root：`rootflags=noatime`（不带 btrfs compress/subvol）；
- `acpi=off`、`fw_devlink=permissive`（7.2.11 nabu DTS 路径；不要
  `fw_devlink.strict=1`）；
- `systemd.gpt_auto=no`，避免自动挂载 Android 分区；
- `console=tty0`、`quiet`、`loglevel=3`、`fbcon=rotate:1`、
  `allow_mismatched_32bit_el0`、`psi=1`、`cgroup_disable=pressure`、
  `cpufreq.default_governor=schedutil`、`swiotlb=8192`、
  `vt.global_cursor_default=0`、`cryptomgr.notests`。

UKI 的 DTB 解析顺序（`prepare-rootfs.sh` 与设备端 `armada-uki-update` 一致）：

1. BLS `devicetree`；
2. BLS `fdtdir` + `/qcom/<name>.dtb`；
3. `/usr/lib/modules/<kver>/dtb/qcom/<name>.dtb` 回退。

`image/uki-dtb` 固定为 `sm8150-xiaomi-nabu`。ESP 上保留最近 2 个 UKI（KEEP=2）。

## 6. 用户态（本分支）

- **音频**：`Xiaomi/nabu` UCM（四路 CS35L41 + WCD9340 麦克风）和 PipeWire
  扬声器高通/保护滤波。
- **Wi-Fi MAC**：`nabu-pmac-set` + `nabu-pmac.service` + `10-wlan.link`
  （固定 `wlan0`）。
- **平板模式基础**：`nabu-tablet-mode`（键盘/盖子 → `SW_TABLET_MODE`），
  `/usr/libexec/nabu-tablet-mode`，systemd 服务已 enable。
- **背光权限**：ktz8866 的 udev 规则。
- **F2FS/userdata**：`CONFIG_F2FS_FS=y` 由 `kernel.required` 断言，镜像内置
  `f2fs-tools`；可手动 `mount -t f2fs -o ro` 读取 userdata。Android 的
  FBE/元数据加密仍需 keymaster/TEE 密钥，不在本分支处理。
- **SLPI 传感器**：在 image 构建阶段从源码编译 `libssc`、`hexagonrpc`
  (`hexagonrpcd`)、带 `qrtr-ns` 的 `qrtr`、`rmtfs`、`tqftpserv`，并编译
  `ssc-support=enabled` 且打了 SSC race/proximity 补丁的 `iio-sensor-proxy` 3.9。
  镜像内含 `/usr/share/qcom/sm8150/xiaomi/nabu/{sensors,socinfo}` 并部署到
  `/usr/lib/firmware/hexagonfs`；`hexagonrpcd`、`qrtr-ns`、`rmtfs`、`tqftpserv`
  及 suspend/resume 单元已 enable；`iio-sensor-proxy` 没有 `[Install]`，由
  `90-nabu-ssc-accelerometer` udev 规则在 `fastrpc-sdsp` 出现时触发。
- **自动旋转/自动亮度**：`nabu-tablet-mode` + `nabu-sensors-resume.sh` /
  `nabu-sensors-recover` 处理休眠后的 SLPI/FastRPC 恢复；`nabu-autobrightness`
  作为用户服务全局启用，读取 SensorProxy 的环境光并驱动 PowerDevil。
- **iris VA-API**：从固定 commit `b0ef8f75...` 编译 `iris-vaapi`，安装到
  `/usr/lib64/dri`（同时保留 `/usr/lib/dri` 链接），配套 dma-heap udev 规则、
  `99-iris-vaapi.conf`；镜像带 `libva-utils`/`v4l-utils` 便于 `vainfo` 验证。
- **Plasma 配置层**（只配置，不重编 Plasma）：
  - `kwinoutputconfig.json`：`DSI-1`、1600×2560@120Hz、`scale=1.75`、
    `Rotated270`、`autoRotation=InTabletMode`、HDR 关闭、`sdrBrightness=200`；
  - `kwinrc`/`plasmarc` 打开虚拟键盘，`plasma-keyboard` 已加入 base 包；
  - `/etc/xdg/kwalletrc` 关闭 KWallet；
  - `sddm.conf.d/10-nabu.conf` 只设置 Breeze 主题和 layer-shell greeter 环境，
    **不替换** greeter 合成器（避免破坏 gamescope 自动登录）。
  - **默认会话仍是 gamescope**（`system_files/etc/sddm.conf.d/armada.conf`），
    Plasma 作为可选会话。

## 7. CI

`.github/workflows/nabu-image.yml`：

1. `kernel` job（`ubuntu-24.04-arm`，330 分钟）：装 `bc/bison/flex/libssl-dev/
   libelf-dev/dwarves/...`，跑 `scripts/ci/build-kernel.sh`，上传内核 artifact。
2. `image` job（`needs: kernel`，300 分钟）：下载 kernel artifact，用
   `packages/package-hash.sh kernel` 注册本地 kernel 镜像，`just build`，
   构建 `image/Containerfile`（`nabu-userspace-build` 阶段使用精简的
   `quay.io/fedora/fedora:44`，从源码编译
   libssc/hexagonrpc/qrtr/rmtfs/tqftpserv/iio-sensor-proxy/iris-vaapi，
   只把 `/out` 运行时文件 COPY 进最终镜像；gcc/meson/devel 包不会进入产物，
   首次约增加 10–20 分钟），推送 GHCR，跑 `prepare-rootfs.sh`，
   上传 rootfs/UKI 并（可选）发布 Release（>1.9 GB 自动分卷）。

手动触发：Actions → **nabu Armada image** → Run workflow → 分支 `main`
（或 `nabu`）；`kernel_ref` 留空即使用固定 commit。失败时把 job 日志贴回来。

如果只想重跑 image（例如只改了传感器/iris 构建），把上一次 kernel job 成功的
run ID 填到 `kernel_run_id`：kernel job 会被跳过，image job 用
`gh run download` 取回该 run 的 `armada-kernel-nabu-*` artifact，避免每次
重编 1–2 小时的内核。留空则照常重建内核。

`nabu-bib-debug.yml` 可在镜像已推送后只重跑 BIB 部分，节省内核/rootfs 时间。

## 8. 安装

设备上已有 rEFInd/DBKP 启动链。从 Arch 或 live USB：

```bash
zstd -d armadaos-rootfs-*.img.zst -o armadaos-rootfs.img
# Release 分卷时：cat armadaos-rootfs-*.img.zst.part-* | zstd -d > armadaos-rootfs.img
sha256sum -c armadaos-rootfs-*.img.sha256
sudo dd if=armadaos-rootfs.img of=/dev/disk/by-partlabel/linux bs=4M conv=fsync status=progress

zstd -d armada-*.efi.zst -o armada.efi
sudo mkdir -p /boot/efi/EFI/armadaOS
sudo cp armada.efi /boot/efi/EFI/armadaOS/
```

首启由 `x-systemd.growfs` 扩到整分区。rEFInd 会自动列出
`EFI/armadaOS/*.efi`；保留旧的 Arch/Android 条目。

## 9. 验证清单

```bash
journalctl -b -p err
dmesg | grep -iE "firmware|remoteproc|dsi|panel|cs35l41|iris|ath10k|qcom_bms"
cat /proc/cmdline
ls /dev/dri /dev/input /sys/class/backlight
aplay -l
nmcli device status
kscreen-doctor -o     # 切到 Plasma 后确认 connector/scale/rotation
vainfo                 # 应列出 Qualcomm Iris / vpu_drv_video
monitor-sensor         # 加速度计/环境光应有数据
systemctl status hexagonrpcd qrtr-ns rmtfs tqftpserv iio-sensor-proxy
dmesg | grep -iE "fastrpc|slpi|iris|venus"
```

本分支预期：显示/触摸/GPU/音频/Wi-Fi/充电可用；传感器/自动旋转/自动亮度
在 Plasma 下生效；`vainfo` 能看到 Iris VA-API；Plasma 配置在切到 Plasma 时
生效；默认 gamescope。

## 10. 已知限制与注意事项

- 相机、patched upower、stylus-popup 仍不在本分支。
- 传感器依赖 SLPI 固件与 `hexagonrpcd` 链路；如果 `monitor-sensor` 无数据，
  先看 `systemctl status hexagonrpcd iio-sensor-proxy` 和
  `journalctl -u hexagonrpcd -b`。
- iris VA-API 需要内核 `VIDEO_QCOM_IRIS=m` 和 `venus.mbn`；若 `vainfo` 报
  driver 不存在，检查 `/usr/lib64/dri/vpu_drv_video.so` 与 udev dma-heap 规则。
- USB-C DisplayPort alt-mode 是 nabu 硬件限制，不支持。
- `sddm-nabu` 的 VT/session-reuse 补丁未合入；若出现 autologin 后切换用户黑屏，
  下一轮再 rebase 到 Fedora sddm 0.21。
- `kwinoutputconfig.json` 的 `DSI-1`/`scale=1.75` 来自参考设备，切到 Plasma 后
  用 `kscreen-doctor -o` 核对；不同命名/偏好需调整 JSON。
- Release 单文件 2 GiB 限制；工作流自动 split。
- ESP 264 MB 左右时，两个 ~100 MB UKI 可能吃紧；必要时把 `KEEP` 降为 1。
- 不要修改 `packages/`：`package-hash.sh` 会把 `packages/Containerfile`
  计入所有包 hash，任何改动都会让 `just build` 找不到已发布镜像。

## 11. 分支流程

```bash
git switch -c nabu main
# 提交
git push ssh-fork nabu:nabu
# CI + 设备验证通过后：
git switch main
git merge --no-ff nabu -m "Merge nabu: ArmadaOS 7.2.11 port for Xiaomi Pad 5"
git push ssh-fork main:main
```

只推 fork `shinaNaoki/armada`，不推上游 `armada-os/armada`。
