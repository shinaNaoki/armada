#!/bin/bash
# Turn the built Armada container into the sheng-style plain-rootfs nabu image
# set:
#   1) armadaos-rootfs-<ver>.img.zst — plain ext4 rootfs (no bootc/OSTree
#      deployment, no OTA), dd-able to the nabu `linux` partition.
#   2) EFI/armadaOS/armada-<kver>.efi.zst — UKI (kernel + initramfs + nabu DTB
#      + root=PARTLABEL=linux cmdline), copied to the ESP for rEFInd.
#
# Why not BIB/OSTree (this is the sheng lesson):
#   - nabu boots the kernel from a UKI on the ESP (rEFInd/DBKP), not a vendor
#     Android boot_b image, so the UKI stays.
#   - but the root is exported verbatim from the container into one plain ext4
#     image, exactly like armada-sheng's no-OTA export: no /ostree deployment,
#     no separate /boot partition, no bootc fstab/BLS/ostree= chain. That
#     removes the stale /boot fstab and deployment-UUID mismatch that leaves
#     the splash at "Preparing Armada".
#
# Requires: root, podman, mount/losetup, mkfs.ext4/e2fsprogs, tar with xattrs,
#           systemd-ukify + the aa64 EFI stub, zstd.
#
# Usage: sudo -E ./scripts/ci/prepare-rootfs.sh <image-ref> <outdir>
# Environment:
#   ROOT_PART=linux       partition label the rootfs is dd'ed to
#   CONSOLE_MODE=quiet    quiet | verbose (verbose: loglevel=7, mask splash)
#   IMG_SIZE=20G          temporary ext4 image size (shrunk before export)
set -euo pipefail

image=${1:?usage: prepare-rootfs.sh <image-ref> <outdir>}
out=${2:?usage: prepare-rootfs.sh <image-ref> <outdir>}
ROOT_PART=${ROOT_PART:-linux}
DTB_NAME=${DTB_NAME:-sm8150-xiaomi-nabu}
CONSOLE_MODE=${CONSOLE_MODE:-quiet}
IMG_SIZE=${IMG_SIZE:-20G}
VER=$(date +%Y%m%d)
STUB=${UKIFY_STUB:-/usr/lib/systemd/boot/efi/linuxaa64.efi.stub}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (or via sudo)"
for tool in podman mkfs.ext4 mount umount losetup ukify zstd e2fsck resize2fs tar; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[ -r "$STUB" ] || die "missing $STUB (install systemd-boot-efi)"
mkdir -p "$out/EFI/armadaOS"

work=$(mktemp -d /tmp/armada-export.XXXXXX)
mnt="$work/rootfs"
img="$work/armadaos-rootfs.img"
cid=""
mounted=0
cleanup() {
    [ "$mounted" = 1 ] && umount "$mnt" 2>/dev/null || true
    [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

log "pulling $image"
if ! podman image exists "$image"; then
    podman pull "$image" >/dev/null
fi
cid=$(podman create "$image")
log "exporting container filesystem"
truncate -s "$IMG_SIZE" "$img"
mkfs.ext4 -F -L armada "$img" >/dev/null
mkdir -p "$mnt"
mount -o loop "$img" "$mnt"
mounted=1
if ! podman export "$cid" | tar -x -C "$mnt" --xattrs --selinux 2>/dev/null; then
    log "SELinux xattr extraction failed; retrying with --xattrs only"
    podman export "$cid" | tar -x -C "$mnt" --xattrs
fi
podman rm -f "$cid" >/dev/null 2>&1 || true
cid=""

# ---------------------------------------------------------------------------
# De-bootc the exported tree (everything else stays byte-identical).
# ---------------------------------------------------------------------------
rm -rf "$mnt/boot"
mkdir -p "$mnt/boot"
cat > "$mnt/etc/fstab" <<EOF
PARTLABEL=${ROOT_PART} / ext4 rw,errors=remount-ro,x-systemd.growfs,relatime 0 1
EOF

# Container-built files carry container_file_t; enforcing on hardware would
# deny most services. sheng lowers this to permissive for the plain export.
if [ -f "$mnt/etc/selinux/config" ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$mnt/etc/selinux/config" || true
fi

# Plain root has no bootc deployment: make the OTA entry points harmless.
for svc in steamos-update steamos-select-branch; do
    [ -d "$mnt/usr/bin" ] || continue
    cat > "$mnt/usr/bin/$svc" <<'EOF'
#!/bin/bash
echo "OTA is not available in this plain-rootfs build. Re-flash the image to upgrade." >&2
exit 1
EOF
    chmod 0755 "$mnt/usr/bin/$svc"
done
systemctl --root "$mnt" mask \
    bootc-fetch-apply-updates.timer \
    bootc-fetch-apply-updates.service \
    ostree-finalize-staged.service \
    armada-uki-sync.service \
    >/dev/null 2>&1 || true
# Remote diagnostics; harmless if openssh-server is not installed.
systemctl --root "$mnt" enable sshd.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Build the UKI from the container's own kernel/initramfs/DTB.
# ---------------------------------------------------------------------------
mapfile -t KVERS < <(find "$mnt/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
[ "${#KVERS[@]}" -eq 1 ] || die "expected exactly one kernel under /usr/lib/modules, found ${#KVERS[@]}"
KVER=${KVERS[0]}
VMLINUZ="$mnt/usr/lib/modules/$KVER/vmlinuz"
INITRD="$mnt/usr/lib/modules/$KVER/initramfs.img"
DTB="$mnt/usr/lib/modules/$KVER/dtb/qcom/${DTB_NAME}.dtb"
[ -r "$VMLINUZ" ] || die "missing kernel: $VMLINUZ"
[ -r "$INITRD" ] || die "missing initramfs: $INITRD"
[ -r "$DTB" ] || die "missing DTB: $DTB"

cmdline="root=PARTLABEL=${ROOT_PART} rw rootwait rootflags=noatime console=tty0 fbcon=rotate:1 allow_mismatched_32bit_el0 acpi=off fw_devlink=permissive systemd.gpt_auto=no psi=1 cgroup_disable=pressure cpufreq.default_governor=schedutil swiotlb=8192 vt.global_cursor_default=0 cryptomgr.notests"
if [ "$CONSOLE_MODE" = "verbose" ]; then
    cmdline="$cmdline loglevel=7 systemd.mask=armada-splash-initrd.service systemd.mask=armada-splash-early.service"
else
    cmdline="$cmdline quiet loglevel=3"
fi
log "UKI cmdline: $cmdline"

efi="$out/EFI/armadaOS/armada-$KVER.efi"
osrelease="$mnt/usr/lib/os-release"
[ -r "$osrelease" ] || osrelease="$mnt/etc/os-release"
[ -r "$osrelease" ] || die "os-release missing in exported tree"
ukify build \
    --stub "$STUB" \
    --linux "$VMLINUZ" \
    --initrd "$INITRD" \
    --devicetree "$DTB" \
    --cmdline "$cmdline" \
    --uname "$KVER" \
    --os-release "$osrelease" \
    --output "$efi"
[ -s "$efi" ] || die "ukify produced no output"
zstd -q -T0 -10 -f "$efi" -o "$efi.zst"
rm -f "$efi"
log "UKI: $efi.zst ($(du -h "$efi.zst" | cut -f1))"

# ---------------------------------------------------------------------------
# Shrink/export the ext4 root filesystem.
# ---------------------------------------------------------------------------
sync
umount "$mnt"
mounted=0
log "shrinking rootfs to actual content"
e2fsck -f -y "$img" >/dev/null 2>&1 || true
resize2fs -M "$img" 2>/dev/null || true
# 4096-align the file end; harmless zeros and keeps fastboot/loop happy.
sz=$(stat -c %s "$img")
pad=$(( (sz + 4095) / 4096 * 4096 ))
[ "$pad" -gt "$sz" ] && truncate -s "$pad" "$img"
e2fsck -f -y "$img" >/dev/null 2>&1 || true

imgname="armadaos-rootfs-$VER.img"
mv "$img" "$out/$imgname"
( cd "$out" && sha256sum "$imgname" > "$imgname.sha256" )
log "compressing with zstd"
zstd -q -T0 -10 -f "$out/$imgname" -o "$out/$imgname.zst"
rm -f "$out/$imgname"
( cd "$out" && sha256sum "EFI/armadaOS/armada-$KVER.efi.zst" "$imgname.zst" > sha256sums.txt )

cat > "$out/install.txt" <<EOF
Armada nabu plain-rootfs image set ($VER)

Boot model: UKI on the ESP (rEFInd/DBKP) + plain ext4 root on PARTLABEL=${ROOT_PART}.
There is no bootc/OSTree deployment and no OTA; upgrade by re-flashing.

1) rootfs decompress:
   zstd -d $imgname.zst -o $imgname
   # if the release asset is split into parts:
   #   cat $imgname.zst.part-* | zstd -d > $imgname
   sha256sum -c $imgname.sha256

2) rootfs (on the tablet, from Arch or a live USB):
   sudo dd if=$imgname of=/dev/disk/by-partlabel/$ROOT_PART bs=4M conv=fsync status=progress
   # first boot grows the ext4 fs to the partition (x-systemd.growfs)

3) UKI decompress (mount the ESP):
   zstd -d armada-$KVER.efi.zst -o armada-$KVER.efi
   sudo mkdir -p /boot/efi/EFI/armadaOS
   sudo cp armada-$KVER.efi /boot/efi/EFI/armadaOS/

4) rEFInd will list EFI/armadaOS/armada-$KVER.efi; keep the old entries.
   If the tablet hangs at "Preparing Armada", re-run this workflow with
   console_mode=verbose and use the resulting verbose UKI to read the logs.

5) root=PARTLABEL=$ROOT_PART; /etc/fstab contains only the root entry.
   If you dd to a different partition label, update the cmdline and fstab.
EOF

log "done"
ls -lh "$out" "$out/EFI/armadaOS"
