#!/usr/bin/env bash
# Static checks for the nabu 7.2.11 port.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [ -f "$ROOT/$1" ] || fail "missing $1"; }
assert_contains() {
    local file=$1 needle=$2
    grep -qF -- "$needle" "$ROOT/$file" || fail "$file does not contain: $needle"
}
assert_not_contains() {
    local file=$1 needle=$2
    ! grep -qF -- "$needle" "$ROOT/$file" || fail "$file still contains: $needle"
}

# --- kernel source / build -------------------------------------------------
assert_file ci/nabu/kernel.config
assert_file ci/nabu/kernel.required
assert_file ci/nabu/README.md
assert_file scripts/ci/build-kernel.sh
assert_contains scripts/ci/build-kernel.sh "Kumar-Jy/linux"
assert_contains scripts/ci/build-kernel.sh "nabu/7.2.y"
assert_contains scripts/ci/build-kernel.sh "739161a890128f23bd1aa679d8754a9ea299269e"
assert_contains scripts/ci/build-kernel.sh "nabu_defconfig"
assert_contains scripts/ci/build-kernel.sh "ci/nabu/kernel.config"
assert_contains scripts/ci/build-kernel.sh "ci/nabu/kernel.required"
assert_contains scripts/ci/build-kernel.sh "-sm8150-nabu-1"
assert_contains scripts/ci/build-kernel.sh 'EXTRAVERSION="$EXTRAVERSION" LOCALVERSION='
assert_contains scripts/ci/build-kernel.sh 'make "${make_opts[@]}" syncconfig'
assert_not_contains scripts/ci/build-kernel.sh 'LOCALVERSION="$LOCALVERSION"'
assert_not_contains scripts/ci/build-kernel.sh "7.2.6"
assert_not_contains scripts/ci/build-kernel.sh "ci/nabu-kernel"

# --- Armada config fragment / required symbols -----------------------------
for symbol in \
    CONFIG_SECURITY_SELINUX=y \
    CONFIG_SECURITY_NETWORK=y \
    CONFIG_EROFS_FS=y \
    CONFIG_DEBUG_INFO_BTF=y \
    CONFIG_SCHED_CLASS_EXT=y \
    CONFIG_UCLAMP_TASK=y \
    CONFIG_PSI_DEFAULT_DISABLED=y \
    CONFIG_RD_ZSTD=y \
    CONFIG_FW_LOADER_COMPRESS_XZ=y; do
    assert_contains ci/nabu/kernel.config "$symbol"
    assert_contains ci/nabu/kernel.required "$symbol"
done
assert_contains ci/nabu/kernel.config "CONFIG_LOCALVERSION_AUTO=n"
assert_contains ci/nabu/kernel.required "CONFIG_LOCALVERSION_AUTO=n"
assert_contains ci/nabu/kernel.config 'CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"'
assert_contains ci/nabu/kernel.required "CONFIG_DEBUG_INFO_REDUCED=n"
assert_contains ci/nabu/kernel.required "CONFIG_DRM_PANEL_NOVATEK_NT36523=y"
assert_contains ci/nabu/kernel.required "CONFIG_TOUCHSCREEN_NT36523_SPI=m"
assert_contains ci/nabu/kernel.required "CONFIG_QCOM_BMS=y"
assert_contains ci/nabu/kernel.required "CONFIG_CHARGER_IDTP9418=m"
assert_contains ci/nabu/kernel.required "CONFIG_F2FS_FS=y"

# --- kargs -----------------------------------------------------------------
assert_file image/10-armada-nabu.toml
assert_contains image/10-armada-nabu.toml '"acpi=off"'
assert_contains image/10-armada-nabu.toml '"fw_devlink=permissive"'
assert_contains image/10-armada-nabu.toml '"rootflags=noatime"'
assert_contains image/10-armada-nabu.toml '"systemd.gpt_auto=no"'
assert_not_contains image/10-armada-nabu.toml "fw_devlink.strict"

# --- firmware --------------------------------------------------------------
assert_file image/firmware/qcom/sm8150/xiaomi/nabu/adsp.mbn
assert_file image/firmware/qcom/sm8150/xiaomi/nabu/cdsp.mbn
assert_file image/firmware/qcom/sm8150/xiaomi/nabu/modem.mbn
assert_file image/firmware/qcom/sm8150/xiaomi/nabu/slpi_nb.mbn
assert_file image/firmware/qcom/sm8150/xiaomi/nabu/venus.mbn
assert_file image/firmware/qcom/sm8150/xiaomi/nabu/wlanmdsp.mbn
assert_file image/firmware/qcom/a640_gmu.bin
assert_file image/firmware/cirrus/cs35l41-dsp1-spk-prot.wmfw
assert_file image/firmware/qca/crbtfw32.tlv
if find image/firmware -type d -name Xiaomi | grep -q .; then
    fail "uppercase Xiaomi firmware path is still present"
fi

# --- UKI / DTB -------------------------------------------------------------
assert_file image/uki-dtb
[ "$(tr -d '[:space:]' < "$ROOT/image/uki-dtb")" = "sm8150-xiaomi-nabu" ] ||
    fail "image/uki-dtb must name sm8150-xiaomi-nabu"
assert_contains image/armada-uki-update "/usr/lib/modules/\${kver}/dtb/qcom"
assert_contains scripts/ci/prepare-rootfs.sh "podman export"
assert_contains scripts/ci/prepare-rootfs.sh 'PARTLABEL=${ROOT_PART} / ext4'
assert_contains scripts/ci/prepare-rootfs.sh "ukify build"
assert_contains scripts/ci/prepare-rootfs.sh "CONSOLE_MODE"
assert_contains scripts/ci/prepare-rootfs.sh "systemd.mask=armada-splash-initrd.service"
assert_file .github/workflows/build-nabu-export.yml
assert_contains .github/workflows/build-nabu-export.yml "CONSOLE_MODE"
assert_contains .github/workflows/build-nabu-export.yml "prepare-rootfs.sh"

# --- userspace -------------------------------------------------------------
assert_file system_files/usr/share/alsa/ucm2/Xiaomi/nabu/HiFi.conf
assert_file system_files/usr/share/alsa/ucm2/conf.d/sm8150/sm8150.conf
assert_file system_files/usr/share/pipewire/pipewire.conf.d/99-nabu-speaker-protection.conf
assert_file system_files/usr/bin/nabu-pmac-set
assert_file system_files/usr/lib/systemd/system/nabu-pmac.service
assert_file system_files/usr/lib/systemd/network/10-wlan.link
assert_file image/nabu/tablet-mode/nabu-tablet-mode.c
assert_file image/nabu/tablet-mode/nabu-tablet-mode.service
assert_contains image/Containerfile "nabu-tablet-build"
assert_contains image/Containerfile "mkdir -p /out"
assert_contains image/Containerfile "systemctl enable armada-uki-sync.service nabu-pmac.service nabu-tablet-mode.service"
assert_not_contains image/Containerfile "qcom/sm8150/Xiaomi"

# --- second round: sensors + iris -----------------------------------------
assert_file image/nabu/userspace/build.sh
assert_file image/nabu/sensors/patches/0001-report-handler-lifecycle-fixes.patch
assert_file image/nabu/sensors/patches/0002-libssc-base-report-id-gulong.patch
assert_contains image/nabu/userspace/build.sh "0002-libssc-base-report-id-gulong.patch"
assert_file image/nabu/sensors/patches/0001-fix-ssc-race-condition.patch
assert_file image/nabu/sensors/patches/0002-ssc-proximity-nabu-sar-fallback.patch
assert_file image/nabu/iris/patches/0001-vaapi-support-vaAcquireBufferHandle-and-default-expo.patch
assert_file system_files/usr/bin/hexagonrpcd
assert_file system_files/usr/libexec/nabu-sensors-recover
assert_file system_files/usr/lib/systemd/system-sleep/nabu-sensors-resume.sh
assert_file system_files/usr/lib/systemd/system/hexagonrpcd.service
assert_file system_files/usr/lib/systemd/system/hexagonrpcd.service.d/nabu-slpi-hexagonrpcd.conf
assert_file system_files/usr/lib/systemd/system/iio-sensor-proxy.service.d/nabu-ssc.conf
assert_file system_files/usr/lib/systemd/user/nabu-autobrightness.service
assert_file system_files/usr/bin/nabu-autobrightness
assert_file system_files/usr/lib/udev/rules.d/60-hexagonrpcd.rules
assert_file system_files/usr/lib/udev/rules.d/90-nabu-ssc-accelerometer.rules
assert_file system_files/usr/lib/udev/rules.d/99-iris-dmaheap.rules
assert_file system_files/usr/lib/modprobe.d/99-iris-vaapi.conf
assert_file system_files/usr/share/qcom/sm8150/xiaomi/nabu/sensors/registry/lsm6dso_0_platform.md
assert_file system_files/usr/share/qcom/sm8150/xiaomi/nabu/socinfo/soc_id
assert_contains image/Containerfile "nabu-userspace-build"
assert_contains image/Containerfile "COPY --from=nabu-userspace-build /out/ /"
assert_contains image/Containerfile "qrtr-ns.service"
assert_contains image/Containerfile "/lib/firmware/hexagonfs"
assert_contains image/Containerfile "systemctl --global enable nabu-autobrightness.service"
assert_contains image/Containerfile "getent passwd fastrpc"
assert_contains image/Containerfile "protobuf-c-compiler"
assert_contains image/nabu/userspace/build.sh "libssc"
assert_contains image/nabu/userspace/build.sh "qrtr-ns=enabled"
assert_contains image/nabu/userspace/build.sh "ssc-support=enabled"
assert_contains image/nabu/userspace/build.sh "b0ef8f7512321d36d52e4a1a52fd3eb0eec9a107"
assert_contains build_files/10-base-packages.sh "libva-utils"
assert_contains ci/nabu/kernel.required "CONFIG_VIDEO_QCOM_IRIS=m"
assert_contains ci/nabu/kernel.required "CONFIG_QCOM_FASTRPC=m"

# --- final batch: upower, stylus, monitor, torch --------------------------
assert_file system_files/usr/bin/system-monitor
assert_file system_files/usr/bin/torch
assert_file system_files/usr/lib/udev/rules.d/90-torch.rules
assert_file image/nabu/stylus/patches/0001-stylusmonitor-robust-io-and-pen-generation.patch
assert_file image/nabu/stylus/patches/0002-stylus-config-and-popup-generation.patch
assert_file image/nabu/stylus/patches/0003-stylusbuttons-generational-layout.patch
assert_contains image/nabu/userspace/build.sh "upower-v\${UPOWER_VERSION}"
assert_contains image/nabu/userspace/build.sh "UP_DEVICE_STATE_DISCHARGING"
assert_contains image/nabu/userspace/build.sh "stylus-popup"
assert_contains image/nabu/userspace/build.sh "STYLUS_USER_UNIT_DIR=/usr/lib/systemd/user"
assert_contains image/Containerfile "upower.service"
assert_contains image/Containerfile "stylus-popup.service"

# --- camera ---------------------------------------------------------------
assert_file system_files/usr/bin/camera-studio
assert_file system_files/usr/lib/udev/rules.d/90-camera-flash.rules
assert_contains build_files/10-base-packages.sh "gstreamer1-plugin-gtk4"
assert_contains build_files/10-base-packages.sh "libcamera-gstreamer"
assert_contains build_files/10-base-packages.sh "libcamera-tools"
assert_contains ci/nabu/kernel.required "CONFIG_VIDEO_QCOM_CAMSS=m"
assert_contains ci/nabu/kernel.required "CONFIG_VIDEO_OV13B10=m"
assert_contains ci/nabu/kernel.required "CONFIG_VIDEO_OV8856=m"

# --- nabu device profile / gamescope / plain-root fixes -------------------
assert_file system_files/usr/lib/armada/devices/xiaomi-nabu.conf
assert_contains system_files/usr/libexec/armada/device-env '"Xiaomi Pad 5"|"Xiaomi Pad 5 (nabu) with cameras") profile=xiaomi-nabu'
assert_contains system_files/usr/lib/armada/devices/xiaomi-nabu.conf 'ARMADA_PANEL_ORIENTATION=right'
assert_contains system_files/usr/lib/armada/devices/xiaomi-nabu.conf 'ARMADA_GAMESCOPE_FAKE_OUTPUT_MM=237x148'
assert_file system_files/etc/environment.d/90-nabu-gamescope.conf
assert_contains system_files/etc/environment.d/90-nabu-gamescope.conf 'ORIENTATION=right'
assert_contains system_files/etc/environment.d/90-nabu-gamescope.conf 'FORCE_COMPOSITION_ROTATION=1'
assert_contains system_files/usr/libexec/armada/controller-type 'no CompositeDevice; nothing to apply'
assert_contains ci/nabu/kernel.config 'CONFIG_SQUASHFS_ZSTD=y'
assert_contains ci/nabu/kernel.required 'CONFIG_SQUASHFS_ZSTD=y'
assert_contains scripts/ci/prepare-rootfs.sh 'bootc-generic-growpart.service'
assert_contains scripts/ci/prepare-rootfs.sh 'rmtfs-dir.service'
assert_contains scripts/ci/prepare-rootfs.sh '90-nabu-gamescope.conf'

# --- Plasma / SDDM config layer -------------------------------------------
assert_file system_files/etc/skel/.config/kwinoutputconfig.json
assert_contains system_files/etc/skel/.config/kwinoutputconfig.json '"connectorName": "DSI-1"'
assert_contains system_files/etc/skel/.config/kwinoutputconfig.json '"refreshRate": 120000'
assert_contains system_files/etc/skel/.config/kwinoutputconfig.json '"scale": 1.75'
assert_contains system_files/etc/skel/.config/kwinoutputconfig.json '"transform": "Rotated270"'
assert_contains system_files/etc/skel/.config/kwinoutputconfig.json '"autoRotation": "InTabletMode"'
assert_contains system_files/etc/skel/.config/kwinrc "VirtualKeyboardEnabled=true"
assert_contains system_files/etc/skel/.config/plasmarc "Enabled=true"
assert_contains system_files/etc/xdg/kwalletrc "Enabled=false"
assert_contains system_files/etc/sddm.conf.d/10-nabu.conf "Current=breeze"
assert_not_contains system_files/etc/sddm.conf.d/10-nabu.conf "CompositorCommand"
assert_contains system_files/etc/sddm.conf.d/armada.conf "Session=gamescope-session-steam.desktop"
assert_contains build_files/10-base-packages.sh "plasma-keyboard"
assert_contains build_files/10-base-packages.sh "f2fs-tools"
assert_contains build_files/50-create-user.sh "/var/lib/sddm/.config"

# --- gamescope virtual-touch orientation ------------------------------------
assert_file packages/gamescope/patches/0029-wlserver-associate-virtual-touch-with-internal.patch
assert_contains packages/gamescope/patches/0029-wlserver-associate-virtual-touch-with-internal.patch 'connector == nullptr'
assert_contains packages/gamescope/patches/0029-wlserver-associate-virtual-touch-with-internal.patch 'GAMESCOPE_SCREEN_TYPE_INTERNAL'

# --- CI --------------------------------------------------------------------
assert_file .github/workflows/nabu-image.yml
assert_contains .github/workflows/nabu-image.yml "Build kernel (Armada tarball layout)"
assert_contains .github/workflows/nabu-image.yml "Download kernel tarball"
assert_contains .github/workflows/nabu-image.yml "kernel_run_id"
assert_contains .github/workflows/nabu-image.yml "gh run download"
assert_contains .github/workflows/nabu-image.yml "739161a890128f23bd1aa679d8754a9ea299269e"
assert_contains .github/workflows/nabu-image.yml "packages/package-hash.sh kernel"
assert_contains .github/workflows/nabu-image.yml "ARMADA_PKG_REGISTRY"
assert_contains .github/workflows/nabu-image.yml 'ghcr.io/${owner}/armada/pkg'
assert_not_contains .github/workflows/nabu-image.yml "7.2.6"
assert_not_contains .github/workflows/nabu-image.yml "ci/nabu-kernel"

printf 'nabu port static checks passed\n'
