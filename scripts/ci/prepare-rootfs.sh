#!/bin/bash
# Turn a built Armada bootc image into:
#   1) armadaos-rootfs-<ver>.img.gz  — ext4 rootfs image, dd-able to the nabu
#      `linux` partition (PARTLABEL=linux); contains the ostree deployment,
#      /boot (merged from BIB's boot partition), kernel modules, firmware.
#   2) EFI/armadaOS/armada-<kver>.efi — UKI (kernel + initramfs + nabu DTB +
#      BLS cmdline), to copy onto the ESP.
#
# Approach: bootc-image-builder builds a normal ext4 raw disk (ESP + /boot +
# root); we merge BIB's /boot into the root partition, rewrite fstab/BLS for
# the nabu partition labels, then export only the root partition and build the
# UKI from the merged /boot.
#
# Requires: root+sodo, podman, losetup/mount, e2fsprogs, rsync, ukify,
#           pigz/zstd, and bootc-image-builder image.
#
# Usage: sudo ./scripts/ci/prepare-rootfs.sh <image-ref> <outdir>
#   e.g. sudo ./scripts/ci/prepare-rootfs.sh ghcr.io/you/armada-nabu:nabu out
set -euo pipefail

image=${1:?usage: prepare-rootfs.sh <image-ref> <outdir>}
out=${2:?usage: prepare-rootfs.sh <image-ref> <outdir>}
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BIB_IMAGE=${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}
DISK_CONFIG=${DISK_CONFIG:-$repo/ci/disk-nabu.toml}
ROOT_LABEL=${ROOT_LABEL:-linux}
ESP_LABEL=${ESP_LABEL:-esp}
DTB_NAME=${DTB_NAME:-sm8150-xiaomi-nabu}
VER=$(date +%Y%m%d)

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (or via sudo)"
[ -f "$DISK_CONFIG" ] || die "missing $DISK_CONFIG"
command -v ukify >/dev/null || die "ukify not found (install systemd-ukify)"
command -v losetup >/dev/null || die "losetup not found"

tmp=$(mktemp -d /tmp/armada-nabu.XXXXXX)
loop=""
mounted=()
cleanup() {
    for m in "${mounted[@]:-}"; do umount "$m" 2>/dev/null || true; done
    [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/image" "$out/EFI/armadaOS"

log "building ext4 raw disk with BIB from $image"
podman run --rm --privileged --pull=newer --net=host --platform linux/arm64 \
    --security-opt label=type:unconfined_t \
    --security-opt apparmor=unconfined \
    --cap-add=CAP_MKNOD \
    -v "$DISK_CONFIG":/config.toml:ro \
    -v "$tmp/image":/output \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$BIB_IMAGE" \
    --type raw --use-librepo=True --rootfs=ext4 --target-arch arm64 "$image" \
    || die "BIB failed (does bootc-image-builder support --rootfs=ext4 here?)"

raw="$tmp/image/disk.raw"
[ -f "$raw" ] || die "BIB did not produce $raw"

loop=$(losetup -fP --show "$raw") || die "losetup failed"
sleep 1
mapfile -t parts < <(lsblk -lnpo NAME,TYPE "$loop" | awk '$2=="part"{print $1}' | sort)
[ "${#parts[@]}" -ge 2 ] || die "no partitions found on $loop"

# Identify the /boot partition (has loader/entries) and the root partition
# (has ostree/), independent of BIB's numbering.
bootpart="" rootpart=""
for p in "${parts[@]}"; do
    m="$tmp/probe.$(basename "$p")"
    mkdir -p "$m"
    if mount -o ro "$p" "$m" 2>/dev/null; then
        if [ -z "$bootpart" ] && [ -d "$m/loader" ] && [ -d "$m/ostree" ]; then bootpart=$p; fi
        if [ -z "$rootpart" ] && [ -d "$m/ostree" ] && [ -d "$m/usr" ]; then rootpart=$p; fi
        umount "$m"
    fi
done
[ -n "$bootpart" ] || die "could not find /boot partition"
[ -n "$rootpart" ] || die "could not find root partition"
log "boot=$bootpart root=$rootpart"

rootmnt="$tmp/root"; bootmnt="$tmp/boot"
mkdir -p "$rootmnt" "$bootmnt"
mount "$rootpart" "$rootmnt"; mounted+=("$rootmnt")
mount "$bootpart" "$bootmnt"; mounted+=("$bootmnt")

log "merging /boot into the root partition"
mkdir -p "$rootmnt/boot"
cp -a "$bootmnt/." "$rootmnt/boot/"

# UKI transport: no bootloader should rewrite the ESP/BLS on deployment
# switches; our armada-uki-update hook owns /EFI/armadaOS. Best-effort config.
if [ -x "$rootmnt/usr/bin/ostree" ]; then
    chroot "$rootmnt" /usr/bin/ostree config --repo=/ostree/repo set sysroot.bootloader none 2>/dev/null || true
    chroot "$rootmnt" /usr/bin/ostree config --repo=/ostree/repo set sysroot.bootprefix true 2>/dev/null || true
fi

# Locate the ostree deployment's /etc (fstab/hostname live there) and write
# the nabu versions. Keep a copy in root/etc too (harmless, used on recovery).
dep_etc=$(find "$rootmnt/ostree/deploy" -maxdepth 4 -type d -name etc 2>/dev/null | head -1)
[ -n "$dep_etc" ] || dep_etc="$rootmnt/etc"
mkdir -p "$dep_etc" "$rootmnt/etc"
cat > "$tmp/fstab" <<EOF
PARTLABEL=$ROOT_LABEL / ext4 rw,errors=remount-ro,x-systemd.growfs,relatime 0 1
PARTLABEL=$ESP_LABEL /boot/efi vfat fmask=0022,dmask=0022 0 1
EOF
printf 'xiaomi-nabu\n' > "$tmp/hostname"
# Keep the existing SELinux label of the image's files when replacing them.
for pair in "fstab:$dep_etc/fstab" "hostname:$dep_etc/hostname"; do
    src=${pair%%:*}; ref=${pair#*:}
    if [ -e "$ref" ] && command -v chcon >/dev/null 2>&1; then
        chcon --reference="$ref" "$tmp/$src" 2>/dev/null || true
    fi
done
install -m644 "$tmp/fstab" "$dep_etc/fstab"
install -m644 "$tmp/fstab" "$rootmnt/etc/fstab"
install -m644 "$tmp/hostname" "$dep_etc/hostname"
install -m644 "$tmp/hostname" "$rootmnt/etc/hostname"

# Sanitize BLS options for ext4 + PARTLABEL root, and collect the UKI cmdline.
shopt -s nullglob
entries=("$rootmnt"/boot/loader*/entries/*.conf)
[ "${#entries[@]}" -gt 0 ] || die "no BLS entries after merging /boot"
bls=${entries[0]}
kver=$(basename "$(sed -n 's/^linux //p' "$bls" | head -1)")
kver=${kver#vmlinuz-}
linux=$(sed -n 's/^linux //p' "$bls" | head -1)
initrd=$(sed -n 's/^initrd //p' "$bls" | head -1)
fdtdir=$(sed -n 's/^fdtdir //p' "$bls" | head -1)
options=$(sed -n 's/^options //p' "$bls" | head -1)

sanitize_options() {
    local opts=$1 out=() t
    set -f
    for t in $opts; do
        case "$t" in
            root=*|rw|ro|quiet|loglevel=*|console=*|ostree=*|ostree=*) out+=("$t") ;;
            rootflags=*)
                # drop btrfs-only flags; ext4 wants just noatime
                out+=("rootflags=noatime") ;;
            *) out+=("$t") ;;
        esac
    done
    printf '%s' "${out[*]}"
}
newopts=$(sanitize_options "$options")
# Force PARTLABEL root; keep exactly one rootflags=noatime.
newopts=$(printf '%s\n' "$newopts" | sed "s#root=[^ ]*#root=PARTLABEL=$ROOT_LABEL#")
case " $newopts " in
    *" rootflags="*) ;;
    *) newopts="rootflags=noatime $newopts" ;;
esac
# Rewrite every BLS entry (there is normally one, but be safe).
for e in "${entries[@]}"; do
    sed -i "s#^options .*#options $newopts#" "$e"
done
log "BLS: $(sed -n 's/^options //p' "$bls")"

kpath="$rootmnt$linux"
ipath="$rootmnt$initrd"
dtb="$rootmnt${fdtdir}/qcom/$DTB_NAME.dtb"
# Some bootc/BIB installs write BLS without the /boot prefix (bootprefix=false).
if [ ! -r "$kpath" ] && [ -r "$rootmnt/boot$linux" ]; then
    kpath="$rootmnt/boot$linux"
    ipath="$rootmnt/boot$initrd"
    dtb="$rootmnt/boot${fdtdir}/qcom/$DTB_NAME.dtb"
fi
[ -r "$kpath" ] || die "kernel missing: $kpath"
[ -r "$ipath" ] || die "initramfs missing: $ipath"
[ -r "$dtb" ] || die "DTB missing: $dtb"

log "building UKI for $kver"
ukify build \
    --linux "$kpath" \
    --initrd "$ipath" \
    --devicetree "$dtb" \
    --cmdline "$newopts" \
    --uname "$kver" \
    --os-release "$rootmnt/usr/lib/os-release" \
    --output "$out/EFI/armadaOS/armada-$kver.efi"
log "UKI: $out/EFI/armadaOS/armada-$kver.efi ($(du -h "$out/EFI/armadaOS/armada-$kver.efi" | cut -f1))"

# Export the root partition as a dd-able ext4 image.
umount "$bootmnt"; umount "$rootmnt"
mounted=()
img="$tmp/armadaos-rootfs.img"
log "exporting root partition -> $img"
dd if="$rootpart" of="$img" bs=4M status=progress
losetup -d "$loop"; loop=""

log "e2fsck + shrink to minimum (grows back via x-systemd.growfs)"
e2fsck -fy "$img" >/dev/null || true
resize2fs -M "$img" 2>/dev/null || true
imgname="armadaos-rootfs-$VER.img"
mkdir -p "$out"
cp --sparse=always "$img" "$out/$imgname"

log "compressing"
if command -v pigz >/dev/null; then
    pigz -6 -p "$(nproc)" -c "$out/$imgname" > "$out/$imgname.gz"
else
    gzip -6 -c "$out/$imgname" > "$out/$imgname.gz"
fi
rm -f "$out/$imgname"
( cd "$out" && sha256sum "EFI/armadaOS/armada-$kver.efi" "$imgname.gz" > sha256sums.txt )

cat > "$out/install.txt" <<EOF
Armada nabu image set ($VER)

1) rootfs (on the tablet, from Arch or a live USB):
   zcat $imgname.gz | sudo dd of=/dev/disk/by-partlabel/$ROOT_LABEL bs=4M conv=fsync status=progress
   # the first boot grows the ext4 fs to the partition (x-systemd.growfs)

2) UKI (mount the ESP):
   sudo mkdir -p /boot/efi/EFI/armadaOS
   sudo cp armada-$kver.efi /boot/efi/EFI/armadaOS/

3) rEFInd will list EFI/armadaOS/armada-$kver.efi (if not, add a menuentry);
   keep the old Arch/Windows entries intact.

4) First boot: root=PATLABEL=$ROOT_LABEL, /etc/fstab uses PARTLABEL=$ROOT_LABEL
   and PARTLABEL=$ESP_LABEL. If the rootfs was dd'ed to a different label,
   edit /etc/fstab and the UKI cmdline accordingly.
EOF
log "done"
ls -lh "$out" "$out/EFI/armadaOS"
