#!/bin/bash
# Build the Xiaomi Pad 5 (SM8150) kernel from Kumar-Jy's nabu/7.2.y branch and
# repackage it in the tarball layout build_files/20-install-kernel.sh expects:
#
#   lib/modules/<kver>/vmlinuz
#   lib/modules/<kver>/modules...
#   lib/modules/<kver>/dtb/qcom/sm8150-xiaomi-nabu.dtb
#
# The device configuration comes from nabu_defconfig; ci/nabu/kernel.config
# adds only the generic Armada (bootc/SELinux/BTF/scx/zram/netfilter) options.
# The source is pinned to a commit so a moving branch cannot silently change the
# image.
#
# Usage (from repo root):
#   ./scripts/ci/build-kernel.sh
#
# Environment:
#   KERNEL_REPO      default https://github.com/Kumar-Jy/linux
#   KERNEL_BRANCH    default nabu/7.2.y
#   KERNEL_REF       default 739161a890128f23bd1aa679d8754a9ea299269e
#   KERNEL_VER       default 7.2.11
#   EXTRAVERSION     default -sm8150-nabu-1 (LOCALVERSION is forced empty)
#   JOBS             default nproc
#   KERNEL_WORK      default <repo>/.ci-kernel
#   KERNEL_SRC_DIR   reuse an existing checkout (skips clone/fetch)
#   OUT_DIR          default <repo>/out
#   VERIFY_ONLY=1    stop after config merge + required-symbol verification
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
KERNEL_REPO=${KERNEL_REPO:-https://github.com/Kumar-Jy/linux}
KERNEL_BRANCH=${KERNEL_BRANCH:-nabu/7.2.y}
KERNEL_REF=${KERNEL_REF:-739161a890128f23bd1aa679d8754a9ea299269e}
KERNEL_VER=${KERNEL_VER:-7.2.11}
# The version suffix belongs in EXTRAVERSION, not LOCALVERSION, and
# LOCALVERSION is passed as an explicitly empty make variable so
# scripts/setlocalversion never appends "+", "-g<sha>" or "-dirty".
EXTRAVERSION=${EXTRAVERSION:--sm8150-nabu-1}
JOBS=${JOBS:-$(nproc)}
WORK_DIR=${KERNEL_WORK:-$repo/.ci-kernel}
OUT_DIR=${OUT_DIR:-$repo/out}
FRAGMENT=$repo/ci/nabu/kernel.config
REQUIRED=$repo/ci/nabu/kernel.required
DTB=sm8150-xiaomi-nabu.dtb

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$FRAGMENT" ] || die "missing $FRAGMENT"
[ -f "$REQUIRED" ] || die "missing $REQUIRED"
for tool in git make pahole; do
    command -v "$tool" >/dev/null 2>&1 ||
        die "missing build tool: $tool (pahole is needed for DEBUG_INFO_BTF/SCHED_CLASS_EXT)"
done

case "$(uname -m)" in
    aarch64|arm64)
        make_opts=(ARCH=arm64)
        ;;
    x86_64)
        command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 ||
            die "aarch64-linux-gnu-gcc not found (install gcc-aarch64-linux-gnu)"
        make_opts=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
        export CROSS_COMPILE=aarch64-linux-gnu-
        ;;
    *)
        die "unsupported build host: $(uname -m)"
        ;;
esac

mkdir -p "$WORK_DIR" "$OUT_DIR"
export ARCH=arm64

# ---------- 1. Source checkout (pinned) ----------
SRC_DIR=${KERNEL_SRC_DIR:-$WORK_DIR/linux-nabu}
if [ -n "${KERNEL_SRC_DIR:-}" ]; then
    [ -d "$SRC_DIR/.git" ] || die "KERNEL_SRC_DIR=$SRC_DIR is not a git checkout"
    log "using existing kernel source at $SRC_DIR"
else
    if [ ! -d "$SRC_DIR/.git" ]; then
        log "cloning $KERNEL_REPO ($KERNEL_BRANCH)"
        git init -q "$SRC_DIR"
        git -C "$SRC_DIR" remote add origin "$KERNEL_REPO"
    fi
    log "fetching $KERNEL_BRANCH"
    git -C "$SRC_DIR" fetch --depth 1 origin "refs/heads/$KERNEL_BRANCH"
    git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
fi

actual_ref=$(git -C "$SRC_DIR" rev-parse HEAD)
[ "$actual_ref" = "$KERNEL_REF" ] ||
    die "kernel source is $actual_ref, expected pinned $KERNEL_REF; update KERNEL_REF deliberately"

source_ver=$(sed -n 's/^SUBLEVEL = //p' "$SRC_DIR/Makefile" | head -1)
major=$(sed -n 's/^VERSION = //p' "$SRC_DIR/Makefile" | head -1)
patchlevel=$(sed -n 's/^PATCHLEVEL = //p' "$SRC_DIR/Makefile" | head -1)
[ "$major.$patchlevel.$source_ver" = "$KERNEL_VER" ] ||
    die "source is $major.$patchlevel.$source_ver, expected KERNEL_VER=$KERNEL_VER"
log "kernel source: $actual_ref ($KERNEL_VER)"

cd "$SRC_DIR"

# ---------- 2. Configuration ----------
log "generating nabu_defconfig"
make "${make_opts[@]}" nabu_defconfig >/dev/null

log "merging ci/nabu/kernel.config"
frag=$(mktemp)
trap 'rm -f "${frag:-}"' EXIT
# kconfig's conf cannot parse trailing inline comments on assignments.
sed -E '/^[[:space:]]*CONFIG_[A-Z0-9_]+=/ s/[[:space:]]*#.*$//' "$FRAGMENT" > "$frag"
bash scripts/kconfig/merge_config.sh .config "$frag"

# merge_config.sh skips lines starting with '#'; force the one symbol we need
# disabled (BTF requires unreduced debug info).
if [ -x scripts/config ]; then
    scripts/config --disable DEBUG_INFO_REDUCED
else
    sed -i 's/^CONFIG_DEBUG_INFO_REDUCED=y/# CONFIG_DEBUG_INFO_REDUCED is not set/' .config
fi

make "${make_opts[@]}" olddefconfig >/dev/null
# olddefconfig only writes .config; refresh include/config/auto.conf because
# scripts/setlocalversion reads CONFIG_LOCALVERSION_AUTO from there when
# computing the release suffix.
make "${make_opts[@]}" syncconfig >/dev/null

# ---------- 3. Verify required symbols ----------
verify_required() {
    local line sym want actual failed=0
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        sym=${line%%=*}
        want=${line#*=}
        actual=$(grep -m1 "^${sym}=" .config 2>/dev/null | cut -d= -f2- || true)
        if [ "$want" = "n" ]; then
            if [ -n "$actual" ] && [ "$actual" != "n" ]; then
                printf 'ERROR: %s is %s, expected disabled\n' "$sym" "$actual" >&2
                failed=1
            fi
            continue
        fi
        if [ "$actual" != "$want" ]; then
            printf 'ERROR: %s is %s, expected %s\n' "$sym" "${actual:-<unset>}" "$want" >&2
            failed=1
        fi
    done < "$REQUIRED"
    return "$failed"
}

verify_required || die "required kernel configuration is incomplete (see above)"

if [ "${VERIFY_ONLY:-0}" = "1" ]; then
    log "VERIFY_ONLY=1: config merged and required symbols verified"
    exit 0
fi

command -v bc >/dev/null 2>&1 || die "missing build tool: bc"

# ---------- 4. Build ----------
KVER=$(make "${make_opts[@]}" EXTRAVERSION="$EXTRAVERSION" LOCALVERSION= -s kernelrelease)
case "$KVER" in
    "$KERNEL_VER"-*) ;;
    *) die "unexpected kernelrelease '$KVER' (expected ${KERNEL_VER}-...)" ;;
esac
log "kernel release: $KVER"

log "building Image + modules + $DTB (-j$JOBS)"
make "${make_opts[@]}" EXTRAVERSION="$EXTRAVERSION" LOCALVERSION= -j"$JOBS" \
    Image modules "qcom/$DTB"

# ---------- 5. Stage Armada tarball layout ----------
STAGE=$WORK_DIR/stage-$KVER
rm -rf "$STAGE"
install -d "$STAGE/lib/modules/$KVER/dtb/qcom"
install -m644 arch/arm64/boot/Image "$STAGE/lib/modules/$KVER/vmlinuz"

make "${make_opts[@]}" EXTRAVERSION="$EXTRAVERSION" LOCALVERSION= \
    INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "$STAGE/lib/modules/$KVER/build" "$STAGE/lib/modules/$KVER/source"

dtb_src="arch/arm64/boot/dts/qcom/$DTB"
[ -f "$dtb_src" ] || die "DTB was not built: $dtb_src"
install -m644 "$dtb_src" "$STAGE/lib/modules/$KVER/dtb/qcom/$DTB"

cat > "$STAGE/lib/modules/$KVER/.armada-source" <<EOF
Source: $KERNEL_REPO ($KERNEL_BRANCH)
Commit: $KERNEL_REF
Version: $KERNEL_VER
Config: nabu_defconfig + ci/nabu/kernel.config
Built: armada-builder on $(uname -m)
Repackaged for: armada
EOF

# ---------- 6. Package ----------
name="armada-kernel-$KVER.tar.zst"
log "packing $OUT_DIR/$name"
tar --owner=0 --group=0 -C "$STAGE" -cf - lib | zstd -q -T0 -10 -f -o "$OUT_DIR/$name"
( cd "$OUT_DIR" && sha256sum "$name" > "$name.sha256" )

# Verify the archive without a SIGPIPE-prone `tar | grep -q` pipeline.
listing=$(mktemp)
tar --zstd -tf "$OUT_DIR/$name" > "$listing"
grep -qx "lib/modules/$KVER/dtb/qcom/$DTB" "$listing" ||
    die "tarball is missing lib/modules/$KVER/dtb/qcom/$DTB"
grep -qx "lib/modules/$KVER/vmlinuz" "$listing" ||
    die "tarball is missing lib/modules/$KVER/vmlinuz"
rm -f "$listing"

log "done: $OUT_DIR/$name ($(du -h "$OUT_DIR/$name" | cut -f1))"
cat "$OUT_DIR/$name.sha256"
