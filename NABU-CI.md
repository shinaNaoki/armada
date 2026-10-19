# ArmadaOS for nabu (SM8150)：GitHub Actions 构建 rootfs + UKI

> 目标：在 **公开 fork** 的 arm64 GitHub Runner（免费 4 vCPU）上构建
> 1) 可 `dd` 到 nabu `linux` 分区的 **ext4 rootfs 镜像**（含 ostree 部署、内核模块、固件、/boot）
> 2) 可直接拷到 ESP 的 **UKI**（`EFI/armadaOS/armada-<kver>.efi`）
> 内核用你已验证的 **7.2.6 + 11 个 nabu 补丁**（`ci/nabu-kernel/`），用户态是 ArmadaOS（Steam/FEX/Proton/gamescope/Plasma）。

## 0. 文件系统选择：推荐 ext4（评估结论）

你担心「btrfs 的回滚 rEFInd 不支持」——**rEFInd 根本不读根文件系统**，它只加载 ESP 上的 UKI。bootc/ostree 的「回滚」是切换部署（BLS/`ostree=` 路径），不是 btrfs 快照；所以 **ext4 和 btrfs 都能 OTA/回滚**，与 rEFInd 无关。

选 **ext4** 的理由（本方案采用）：
- 与你现有 fstab/分区方式一致：`PARTLABEL=linux / ext4 ...`，`x-systemd.growfs` 首启自动扩到 106 GiB；
- 自制「rootfs 镜像 → dd」链路最简单：单一 ext4，不需要 subvol 处理；
- ostree/bootc 在 ext4 上完全支持；
- 代价：失去 btrfs 透明压缩/subvol；Armada 默认 kargs 里的 `rootflags=compress=zstd:1` 已在本方案中换成 `rootflags=noatime`。

btrfs 仍可选（改 `image/fstab`、`ci/disk-nabu.toml`/BIB `--rootfs=btrfs`、kargs rootflags），但会把「merge /boot + subvol」变复杂，首轮不建议。

## 1. 目录

```
.github/workflows/nabu-image.yml   # 全部构建流程（手动触发）
scripts/ci/build-kernel.sh         # 7.2.6 + 11 patch → armada-kernel-<kver>.tar.zst
scripts/ci/prepare-rootfs.sh       # BIB ext4 raw → 合并 /boot → 改写 fstab/BLS → rootfs.img.gz + UKI
image/Containerfile               # 在 Armada 镜像上加 fstab/hostname/kargs/UKI 钩子
image/fstab                       # PARTLABEL=linux / ext4 + PARTLABEL=esp /boot/efi
image/hostname                    # xiaomi-nabu
image/10-armada-nabu.toml         # ext4 rootflags=noatime 等 kargs（覆盖 Armada 的 btrfs kargs）
image/armada-uki-update           # OTA/回滚后重生成 /EFI/armadaOS/*.efi（ext4 版）
image/armada-uki-finalize         # 失败自动 bootc rollback
image/armada-uki-sync.service     # 关机钩子
image/10-armada-uki.conf          # ostree-finalize-staged drop-in
image/uki-dtb                     # sm8150-xiaomi-nabu
ci/nabu-kernel/                   # 你的 11 个补丁 + DTS/dtsi + 7.0 config + additions
ci/disk-nabu.toml                 # BIB root 16 GiB（首启 growfs 到整分区）
apply-to-fork.sh                  # 把以上文件复制进你的 Armada fork
```

## 2. 应用到 fork

```bash
cd /path/to/armada-nabu-ci
./apply-to-fork.sh /path/to/your/armada-fork
cd /path/to/your/armada-fork
git add ci image scripts/ci .github/workflows/nabu-image.yml
git commit -m "nabu: CI image with 7.2.6 kernel + ext4 rootfs/UKI"
git push origin <branch>
```

然后在 GitHub 上 **Actions → nabu Armada image → Run workflow**。

## 3. 工作流做了什么

1. `ubuntu-24.04-arm`（公开仓库免费）装 podman/buildah/just/ukify 等；
2. 下载 linux-7.2.6，按顺序应用 `ci/nabu-kernel/patches/0001..0011`（顺序与你的 PKGBUILD 完全一致：0009 在装完 DTS 后打），装 `sm8150-xiaomi-nabu.dts`/`sm8150-wcd9340.dtsi`；
3. 用设备 7.0 config + `nabu-kernel-additions.config` 配内核，构建 `Image modules qcom/sm8150-xiaomi-nabu.dtb`；
4. 打成 Armada 期望的 `armada-kernel-7.2.6-sm8150-726-1.tar.zst`，注册成 `localhost/armada/pkg/kernel:<hash>`；
5. `just build` 组装 Armada rootfs：本地 kernel + 上游 GHCR 的其余 25 个包（不会重编 26 个包）；
6. `podman build -f image/Containerfile` 生成 nabu 派生镜像：写 `/etc/fstab`、`/etc/hostname`、ext4 kargs，安装 `systemd-ukify` 和 UKI 钩子，mask 掉 ABL 的 `armada-bootimg-sync`/`armada-esp-rename`；
7. 推送到 `ghcr.io/<你>/armada-nabu:nabu`（BIB 的 origin 指这里，`bootc upgrade` 才能用）；
8. BIB 以 **ext4** 出 raw 盘 → 把 BIB 的 `/boot` 合并进 root 分区 → 改写 `/etc/fstab` 和 BLS `options`（`root=PARTLABEL=linux`、`rootflags=noatime`）→ 从合并后的 `/boot` 用 `ukify --devicetree` 生成 UKI → 导出 root 分区为 ext4 镜像、`e2fsck`/`resize2fs -M`/gzip；
9. 上传 artifact：`armadaos-rootfs-YYYYMMDD.img.gz`、`EFI/armadaOS/armada-<kver>.efi`、`sha256sums.txt`、`install.txt`（+ 内核 tar 单独 artifact）。

> 内核策略说明：这是 **pristine 7.2.6 + nabu 11 patch**，不是 Armada 自带的「7.2.6 + 192 patch」内核。原因是两者冲突（Armada 已有 bonded-DSI PLL 修复 `0048b`、qcom 电源/显示补丁等，nabu 的 0007/0008/0010/0011 会重复或上下文冲突）。nabu 不需要 Armada 的掌机 HDR/输入/风扇补丁；先保证显示/触摸/充电/音频可用，后续再考虑合并 Armada 的 DPU 色彩补丁。

## 4. 在平板上安装

```bash
# 1) 写 rootfs 到 linux 分区（会覆盖现 Arch；先备份）
zcat armadaos-rootfs-YYYYMMDD.img.gz | sudo dd of=/dev/disk/by-partlabel/linux bs=4M conv=fsync status=progress
# 首启由 x-systemd.growfs 扩到整分区

# 2) UKI 拷到 ESP
sudo mkdir -p /boot/efi/EFI/armadaOS
sudo cp EFI/armadaOS/armada-7.2.6-sm8150-726-1.efi /boot/efi/EFI/armadaOS/

# 3) rEFInd：一般会自动扫到 EFI/armadaOS/*.efi；若没有，在 refind.conf 加：
# menuentry "ArmadaOS (nabu)" {
#     icon   /EFI/BOOT/icons/os_linux.png
#     loader /EFI/armadaOS/armada-7.2.6-sm8150-726-1.efi
# }

# 4) 保留旧 Arch UKI，重启在 rEFInd 里选 ArmadaOS
```

**fstab / hostname 已在镜像里**：
```
PARTLABEL=linux / ext4 rw,errors=remount-ro,x-systemd.growfs,relatime 0 1
PARTLABEL=esp /boot/efi vfat fmask=0022,dmask=0022 0 1
```
hostname=`xiaomi-nabu`。

## 5. OTA / 回滚

- 镜像推在 `ghcr.io/<你>/armada-nabu:nabu`，BIB 的 bootc origin 指向它；在设备上 `sudo bootc upgrade` 拉新 digest。
- 关机时 `ostree-finalize-staged` 的 drop-in → `armada-uki-finalize` → `armada-uki-update` 重新生成 `/EFI/armadaOS/armada-<新kver>-<hash>.efi`（保留最近 2 个）；UKI 生成失败会自动 `bootc rollback`。
- rEFInd 里每代 UKI 都是独立文件 → 直接选旧 UKI 即可回滚（与文件系统无关）。
- 若只改内核：工作流重新构建会带新 KVER/新 UKI；老部署的 UKI 仍保留。

## 6. 首次运行的验证清单（重要）

工作流是「按现有 BIB/Armada 约定写的」，第一次跑很可能要微调，按顺序看：

- [ ] `just build` 是否用了本地 kernel：日志里 `localhost/armada/pkg/kernel:<hash>`；若失败，先单独 `bash scripts/ci/build-kernel.sh` 看内核编译。
- [ ] BIB 是否接受 `--rootfs=ext4`（不支持就把 `prepare-rootfs.sh` 里改成 `--rootfs=btrfs` 并同步 fstab；或改用 `--rootfs=ext4` 对应的 BIB 版本）。
- [ ] BIB 的 raw 分区布局：脚本按内容自动识别 `/boot`（含 `loader/`+`ostree/`）和 root（含 `/usr`+`/ostree`）；若 BIB 用 systemd-boot 把 BLS 放 ESP，需要再改。
- [ ] 合并后 root 分区空间（16 GiB）是否够 Armada rootfs；不够就调 `ci/disk-nabu.toml` 到 20 GiB。
- [ ] UKI 大小 ~70–110 MB，ESP FAT 目前只有 264 MB 可用；**先备份并扩容 ESP FAT**（`fatresize -s max /dev/sda31`），或只保留 1 个 UKI。
- [ ] artifact 上传大小：rootfs.gz 约 4–6 GB；`upload-artifact` 若超限，改为只上传到 Release/对象存储或拆分。
- [ ] 首启：`journalctl -b` 看 `ostree-prepare-root`、`root=PARTLABEL=linux` 是否解析成功；`systemctl status armada-uki-sync`。
- [ ] `bootc status` 的 origin 是否为 `ghcr.io/<你>/armada-nabu:nabu`；`bootc upgrade` 能拉新镜像。
- [ ] 音频（7.2.6 NGD）、触摸、充电、Wi-Fi、GPU 按你 7.2.6 真机清单复测。

## 7. 备注

- 首次构建时间：kernel 40–90 min + Armada rootfs 20–40 min + BIB/导出 10–20 min；公开仓库 runner 免费。
- 本工作流只构建/推送镜像 + 产物，不改 Android 分区；ESP 操作全在设备上手动完成。
- 如果之后要合并 Armada 的 192 条 patch（HDR/色彩/输入），建议另开分支做 patch 顺序调和，不要直接叠加。
