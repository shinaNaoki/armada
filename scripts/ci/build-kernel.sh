#!/bin/bash
# Build the nabu (SM8150) 7.2.6 kernel in Armada's expected tarball layout:
#   lib/modules/<kver>/{vmlinuz,modules...,dtb/qcom/sm8150-xiaomi-nabu.dtb}
#
# Source of truth: the 11-patch forward-port in ci/nabu-kernel/ (from
# /home/user/workspace/7.2.6-nabu-port), applied to pristine linux-7.2.6.
# Verified on the tablet with the same patch chain (display/touch/charging).
#
# Usage (from repo root, on aarch64):
#   ./scripts/ci/build-kernel.sh
# Environment:
#   KERNEL_VER=7.2.6
#   JOBS=<n>            default: nproc
#   SKIP_DOWNLOAD=1     reuse an already extracted linux-<ver> tree
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=${KERNEL_WORK:-$repo/.ci-kernel}
out=$repo/out
KERNEL_VER=${KERNEL_VER:-7.2.6}
JOBS=${JOBS:-$(nproc)}
KVER="${KERNEL_VER}-sm8150-726-1"
EXTRA="-sm8150-726-1"
assets="$repo/ci/nabu-kernel"

log() { printf '==> %s\n' "$*"; }

[ -d "$assets/patches" ] || { echo "missing $assets/patches" >&2; exit 1; }
case "$(uname -m)" in
    aarch64|arm64) make_opts=(ARCH=arm64) ;;
    *)             make_opts=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-) ;;
esac

mkdir -p "$work" "$out"
cd "$work"

if [ ! -d "linux-$KERNEL_VER" ]; then
    if [ ! -f "linux-$KERNEL_VER.tar.xz" ]; then
        log "downloading linux-$KERNEL_VER.tar.xz"
        curl -fL --retry 3 -o "linux-$KERNEL_VER.tar.xz" \
            "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VER%%.*}.x/linux-$KERNEL_VER.tar.xz"
    fi
    log "extracting"
    tar -xf "linux-$KERNEL_VER.tar.xz"
fi

cd "linux-$KERNEL_VER"

log "applying 11 nabu forward-port patches"
apply() { patch -Np1 -i "$assets/patches/$1"; }
apply 0001-sm8150-dtsi-add-slim-sound.patch
apply 0002-drm-panel-nt36523-add-nabu.patch
apply 0003-asoc-qcom-add-sm8150-sndcard.patch
apply 0004-arm64-dts-qcom-nabu-726-forward-port-fixes.patch
apply 0005-input-touchscreen-nt36523-spi.patch
apply 0006-display-fixes-7.2.6.patch
apply 0007-dispcc-sm8150-revert-ops-parent-enable.patch
apply 0008-dsi-phy-7nm-fix-bonded-pll-init.patch
apply 0010-power-supply-nabu-charging-drivers.patch
apply 0011-power-supply-qcom-smbx-add-pm8150b-smb5.patch

log "installing nabu board DTS"
install -m644 "$assets/dts/sm8150-xiaomi-nabu.dts" arch/arm64/boot/dts/qcom/
install -m644 "$assets/dts/sm8150-wcd9340.dtsi" arch/arm64/boot/dts/qcom/
apply 0009-arm64-dts-nabu-charging-nodes.patch

grep -q 'sm8150-xiaomi-nabu.dtb' arch/arm64/boot/dts/qcom/Makefile ||
    echo 'dtb-$(CONFIG_ARCH_QCOM) += sm8150-xiaomi-nabu.dtb' >> arch/arm64/boot/dts/qcom/Makefile
# Avoid unrelated/possibly broken SM8150 boards breaking `dtbs`.
sed -i '/^dtb-\$(CONFIG_ARCH_QCOM) += sm8150-xiaomi-raphael.dtb/s/^/#/' \
    arch/arm64/boot/dts/qcom/Makefile

log "configuring (device 7.0 config + nabu additions)"
cp "$assets/config/nabu-7.0-running.config" .config
cat "$assets/config/nabu-kernel-additions.config" >> .config
sed -i '/^CONFIG_LOCALVERSION=/d' .config
# Armada needs SELinux; make sure this never silently disappears.
grep -q '^CONFIG_SECURITY_SELINUX=y' .config || echo 'CONFIG_SECURITY_SELINUX=y' >> .config
grep -q '^CONFIG_SECURITY_SELINUX_BOOTPARAM=y' .config || echo 'CONFIG_SECURITY_SELINUX_BOOTPARAM=y' >> .config
grep -q '^CONFIG_IKCONFIG_PROC=y' .config || echo 'CONFIG_IKCONFIG_PROC=y' >> .config
make "${make_opts[@]}" olddefconfig

missing=()
for sym in DRM_MSM SND_SOC_SM8150 SLIMBUS SLIM_QCOM_NGD_CTRL SND_SOC_WCD934X \
           SND_SOC_CS35L41 SND_SOC_CS35L41_I2C DRM_PANEL_NOVATEK_NT36523 \
           BACKLIGHT_KTZ8866 QCOM_APR TOUCHSCREEN_NT36523_SPI SECURITY_SELINUX; do
    val=$(sed -n "s/^CONFIG_${sym}=//p" .config)
    [[ $val == y || $val == m ]] || missing+=("CONFIG_${sym}")
done
if ((${#missing[@]})); then
    printf 'ERROR: required config symbols missing after olddefconfig: %s\n' "${missing[*]}" >&2
    exit 1
fi

log "building Image + modules + nabu DTB (-j$JOBS)"
make "${make_opts[@]}" EXTRAVERSION="$EXTRA" LOCALVERSION= -j"$JOBS" \
    Image modules qcom/sm8150-xiaomi-nabu.dtb

log "staging Armada kernel tarball layout"
stage="$work/stage-$KVER"
rm -rf "$stage"
install -d "$stage/lib/modules/$KVER/dtb/qcom"
install -m644 arch/arm64/boot/Image "$stage/lib/modules/$KVER/vmlinuz"
make "${make_opts[@]}" EXTRAVERSION="$EXTRA" LOCALVERSION= \
    INSTALL_MOD_PATH="$stage" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "$stage/lib/modules/$KVER/build" "$stage/lib/modules/$KVER/source"
install -m644 arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb \
    "$stage/lib/modules/$KVER/dtb/qcom/"

name="armada-kernel-$KVER.tar.zst"
tar --owner=0 --group=0 -C "$stage" -cf - lib | zstd -q -T0 -10 -f -o "$out/$name"
( cd "$out" && sha256sum "$name" > "$name.sha256" )
log "kernel package: $out/$name ($(du -h "$out/$name" | cut -f1))"
cat "$out/$name.sha256"
