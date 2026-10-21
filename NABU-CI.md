# ArmadaOS for nabu (Xiaomi Pad 5 / SM8150)

目标：把 ArmadaOS 移植到小米平板 5（`nabu`，SM8150），用 **Kumar-Jy 的
7.2.11 内核**，并通过 GitHub Actions 产出：

1. 可 `dd` 到 `linux` 分区的 **plain ext4 rootfs 镜像**（无 bootc/OSTree/OTA）；
2. 可拷到 ESP 的 **UKI**（`EFI/armadaOS/armada-<kver>.efi`），由 rEFInd/DBKP 启动。

> `nabu` 的启动链与 sheng（小米平板 6S Pro）不同：sheng 用原厂 ABL 直接刷
> `boot_b.img`；nabu 仍走 **rEFInd/DBKP → ESP 上的 UKI → 内核**。但根文件系统
> 采用 **sheng 的容器导出方案**：直接把已构建的 Armada 容器文件树写进单个
> ext4 镜像，不再走 BIB/OSTree 部署。这是修复 "Preparing Armada" 卡住的关键。

## 1. 为什么放弃 BIB/OSTree

此前用 BIB 生成 ESP + `/boot` + root，再合并 `/boot` 到 root、改写 BLS/ostree=。
实际设备在 splash 的 "Preparing Armada" 卡住，常见原因是：

- bootc 部署里的 `/etc/fstab` 仍带一个 `/boot` 分区条目，systemd 等待不存在的
  设备；
- 合并后的 `/boot`、BLS `ostree=` 与 initramfs 的部署 UUID 不一致；
- 容器/Fedora 的 SELinux label 与真实硬件不匹配。

`sheng` 的解决方式是彻底不用 bootc/OSTree：`podman export` 容器树到 ext4，
`/boot` 并入根，只保留 root fstab，OTA 入口替换为提示，SELinux 降到 permissive。
本仓库现在对 nabu 采用同样的 rootfs 方案，仅把 boot 产物换成 UKI。

## 2. 源码固定

| 项目 | 值 |
| --- | --- |
| 内核 | `Kumar-Jy/linux` `nabu/7.2.y` @ `739161a890128f23bd1aa679d8754a9ea299269e`（7.2.11） |
| 内核配置 | `nabu_defconfig` + `ci/nabu/kernel.config` |
| 固件 | `linux-firmware-xiaomi-nabu-25.04.26-1`，SHA256 `bef43c32...b567bac9` |
| libssc | `v0.4.4` + 2 个 nabu patch |
| hexagonrpc | `v0.4.0` |
| qrtr | `5923eea...`（`qrtr-ns` enabled） |
| rmtfs / tqftpserv | `v1.3` / `v1.2` |
| iio-sensor-proxy | `3.9` + SSC race/proximity patches |
| iris-vaapi | `b0ef8f75...` |
| upower | `1.91.5` + battery-state sed |
| stylus-popup | `17a42ee...` + 3 patches |
| camera-studio | `1.0.6` |

参考仓库：`Nabu-arch-images`（rEFInd/DBKP/Plasma 配置）、`nabu-pkgs`（Arch 包、
固件、传感器/相机补丁）、`armada-sheng`（plain-rootfs 导出流水线）。

## 3. 目录

```
ci/nabu/kernel.config              # nabu_defconfig 之上的 Armada 增量配置
ci/nabu/kernel.required            # 构建后必须成立的符号
ci/nabu/README.md                  # 内核来源/配置/tarball 布局
scripts/ci/build-kernel.sh         # 固定 commit → 配置 → 编译 → armada-kernel-*.tar.zst
scripts/ci/prepare-rootfs.sh       # 容器导出 → plain ext4 → fstab/OTA → UKI
.github/workflows/nabu-image.yml   # kernel job + container build + export
.github/workflows/build-nabu-export.yml # 已有容器 → rootfs+UKI（不重建内核）
image/Containerfile                # nabu 固件/用户态/UKI 钩子 + tablet-mode 编译
image/firmware/                    # nabu 专用固件（小写 qcom/sm8150/xiaomi/nabu）
image/nabu/userspace/build.sh      # libssc/hexagonrpc/qrtr/rmtfs/tqftpserv/iio/iris/upower/stylus
image/nabu/{sensors,iris,stylus}/  # 对应补丁
system_files/usr/share/qcom/       # SLPI sensors/socinfo 配置树
system_files/...                   # UCM、Plasma、传感器、stylus、相机、应用等
```

## 4. 内核

`scripts/ci/build-kernel.sh`：

1. 浅取固定 commit，校验 HEAD 等于 `KERNEL_REF`；
2. `make ARCH=arm64 nabu_defconfig`；
3. 合并 `ci/nabu/kernel.config`，`olddefconfig`，`syncconfig`；
4. 按 `ci/nabu/kernel.required` 校验；
5. 用 `EXTRAVERSION=-sm8150-nabu-1 LOCALVERSION=` 编译
   `Image modules qcom/sm8150-xiaomi-nabu.dtb`；
6. 打包成 `lib/modules/<kver>/{vmlinuz,modules...,dtb/qcom/sm8150-xiaomi-nabu.dtb}`。

`CONFIG_LOCALVERSION_AUTO=n`，避免 `-g<sha>`/`-dirty`。内核覆盖 SELinux、
BTF/sched_ext、EROFS、zram、netfilter、f2fs、nabu 的 CAMSS/OV13B10/OV8856、
iris、SLPI/FastRPC 等。

## 5. rootfs 与 UKI（sheng 式导出）

`prepare-rootfs.sh`：

1. `podman pull` + `podman create` 已构建的 Armada nabu 容器；
2. `podman export | tar -x --xattrs` 到 loop-mounted ext4（默认 20 GiB，最后 shrink）；
3. 去 bootc：
   - `rm -rf /boot && mkdir /boot`（无独立 boot 分区）；
   - `/etc/fstab` 只写 `PARTLABEL=linux / ext4 rw,...,x-systemd.growfs 0 1`；
   - `SELINUX=enforcing` → `permissive`（容器 label 不适合真机 enforcing）；
   - `steamos-update`/`steamos-select-branch` 替换为提示；mask bootc/ostree/UKI sync；
4. 从容器自己的 `/usr/lib/modules/<kver>` 取 `vmlinuz`、`initramfs.img`、DTB；
5. `ukify` 生成 UKI，cmdline 为
   `root=PARTLABEL=linux rw rootwait rootflags=noatime ... acpi=off fw_devlink=permissive`（无 `ostree=`）；
6. 卸载、`e2fsck`、`resize2fs -M`、zstd 压缩。

输出：

```
armadaos-rootfs-YYYYMMDD.img.zst
EFI/armadaOS/armada-<kver>.efi.zst
sha256sums.txt
install.txt
```

调试选项 `CONSOLE_MODE=verbose`：加入 `loglevel=7` 并 mask
`armada-splash-initrd.service` / `armada-splash-early.service`，用于定位
"Preparing Armada" 卡住。

## 6. 用户态

- 音频 UCM、PipeWire 扬声器保护、Wi-Fi MAC、平板模式、背光权限；
- SLPI 传感器：libssc/hexagonrpc/qrtr-ns/rmtfs/tqftpserv/iio-sensor-proxy，
  `sensors/socinfo` → `/usr/lib/firmware/hexagonfs`；
- 自动旋转/自动亮度：`nabu-tablet-mode` + `nabu-sensors-recover` +
  `nabu-autobrightness`；
- iris VA-API：`/usr/lib64/dri/vpu_drv_video.so` + dma-heap udev 规则；
- patched upower、stylus-popup、camera-studio、system-monitor、nabu-torch；
- Plasma 配置层：DSI-1 旋转/缩放/120Hz、虚拟键盘、关闭 KWallet、保守 SDDM；
- F2FS/userdata 读取（`f2fs-tools`）。

## 7. CI

### `nabu-image.yml`（完整构建）

1. `kernel` job：构建/复用内核对 artifact。
2. `image` job：
   - 下载内核 artifact，注册本地 kernel 镜像；
   - `just build` → `image/Containerfile` → 推送 GHCR；
   - `prepare-rootfs.sh` 导出 plain ext4 + UKI；
   - 上传/发布。

输入：`kernel_ref`、`kernel_run_id`（复用旧内核 artifact）、`console_mode`
（quiet/verbose）、`publish_release`。

### `build-nabu-export.yml`（仅导出）

对已推送的容器重跑导出，不重建内核/容器。适合只调 rootfs/UKI/fstab 时使用：

- `container_ref`：默认 `ghcr.io/<owner>/armada-nabu:nabu`
- `console_mode`、`root_partition`、`publish_release`

## 8. 安装

设备上已有 rEFInd/DBKP。从 Arch 或 live USB：

```bash
zstd -d armadaos-rootfs-*.img.zst -o armadaos-rootfs.img
sudo dd if=armadaos-rootfs.img of=/dev/disk/by-partlabel/linux bs=4M conv=fsync status=progress
zstd -d armada-*.efi.zst -o armada.efi
sudo mkdir -p /boot/efi/EFI/armadaOS
sudo cp armada.efi /boot/efi/EFI/armadaOS/
```

首启由 `x-systemd.growfs` 扩到整分区。rEFInd 列出 `EFI/armadaOS/*.efi`。
**没有 OTA**：升级 = 重新刷 rootfs + UKI；不要混用不同构建的 rootfs 和 UKI。

## 9. 验证

```bash
journalctl -b -p err
dmesg | grep -iE "firmware|remoteproc|dsi|panel|cs35l41|iris|ath10k|qcom_bms|camss"
cat /proc/cmdline
ls /dev/dri /dev/input /sys/class/backlight
aplay -l
nmcli device status
vainfo
monitor-sensor
upower -d
systemctl --user status stylus-popup
cam -l
camera-studio
torch set 100
system-monitor
kscreen-doctor -o
```

## 10. 已知限制

- 无 OTA：plain rootfs 没有 bootc deployment；升级需重刷。
- SELinux 为 permissive（容器 label）；要 enforcing 需在设备上 relabel。
- 相机质量取决于 mainline CAMSS/OV13B10/OV8856 ISP 调校。
- USB-C DisplayPort alt-mode 是 nabu 硬件限制。
- 若仍卡 "Preparing Armada"，先用 `build-nabu-export.yml` 的
  `console_mode=verbose` 生成调试 UKI，或确认 rootfs/UKI 来自同一次构建。

## 11. 分支

```bash
git switch -c nabu main
git push ssh-fork nabu:nabu
# 验证后
git switch main
git merge --no-ff nabu
git push ssh-fork main:main
```

只推 fork `shinaNaoki/armada`，不推上游 `armada-os/armada`。
