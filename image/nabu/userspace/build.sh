#!/bin/bash
# Build the non-Fedora nabu userspace stack inside the image build stage:
#   libssc, hexagonrpc/hexagonrpcd, qrtr-ns, rmtfs, tqftpserv, iio-sensor-proxy
#   and the iris-vaapi driver.
#
# Everything is installed under /out (plus, where a later package needs it at
# build time, /usr inside this disposable stage). The final image copies /out
# over / and never carries the compiler/build dependencies.
set -euxo pipefail

OUT=${OUT:-/out}
SRC=${SRC:-/src/nabu}
WORK=${WORK:-/tmp/nabu-userspace}
JOBS=${JOBS:-$(nproc)}
IIS_VERSION=3.9
LIB_SSC_VERSION=0.4.4
HEXAGONRPC_VERSION=0.4.0
QRTR_REF=5923eea97377f4a3ed9121b358fd919e3659db7b
RMTFS_VERSION=1.3
TQFTPSERV_VERSION=1.2
IRIS_REF=b0ef8f7512321d36d52e4a1a52fd3eb0eec9a107

mkdir -p "$OUT" "$WORK"
cd "$WORK"

fetch() {
    local url=$1 name=$2
    if [ ! -s "$WORK/$name.tar.gz" ]; then
        curl -fL --retry 3 --retry-delay 2 -o "$WORK/$name.tar.gz" "$url"
    fi
}

extract() {
    local name=$1 dir=$2
    rm -rf "$WORK/$dir"
    mkdir -p "$WORK/$dir"
    tar -xf "$WORK/$name.tar.gz" -C "$WORK/$dir" --strip-components=1
}

# --- libssc ---------------------------------------------------------------
fetch "https://codeberg.org/DylanVanAssche/libssc/archive/v${LIB_SSC_VERSION}.tar.gz" libssc
extract libssc libssc
cd "$WORK/libssc"
patch -p1 -i "$SRC/sensors/patches/0001-report-handler-lifecycle-fixes.patch"
meson setup build --prefix=/usr --libdir=/usr/lib64 --buildtype=release
ninja -C build
DESTDIR="$OUT" meson install -C build
# iio-sensor-proxy builds against libssc via pkg-config, so also install it in
# this disposable stage's /usr.
meson install -C build

# --- hexagonrpc / hexagonrpcd --------------------------------------------
fetch "https://github.com/linux-msm/hexagonrpc/archive/refs/tags/v${HEXAGONRPC_VERSION}.tar.gz" hexagonrpc
extract hexagonrpc hexagonrpc
cd "$WORK/hexagonrpc"
meson setup build --prefix=/usr --libdir=/usr/lib64 --buildtype=release
ninja -C build
DESTDIR="$OUT" meson install -C build
install -d "$OUT/usr/libexec/hexagonrpc"
mv "$OUT/usr/bin/hexagonrpcd" "$OUT/usr/libexec/hexagonrpc/hexagonrpcd"

# --- qrtr (with qrtr-ns; Fedora's package deliberately disables it) -----
fetch "https://github.com/linux-msm/qrtr/archive/${QRTR_REF}.tar.gz" qrtr
extract qrtr qrtr
cd "$WORK/qrtr"
meson setup build --prefix=/usr --libdir=/usr/lib64 --buildtype=release \
    -Dqrtr-ns=enabled -Dsystemd-service=enabled \
    -Dsystemd-unit-prefix=/usr/lib/systemd/system
ninja -C build
DESTDIR="$OUT" meson install -C build
meson install -C build

# --- rmtfs ----------------------------------------------------------------
fetch "https://github.com/linux-msm/rmtfs/archive/refs/tags/v${RMTFS_VERSION}.tar.gz" rmtfs
extract rmtfs rmtfs
cd "$WORK/rmtfs"
# qmi_rmtfs.c is pre-generated; make would otherwise try to run qmic if the
# .qmi timestamp is newer.
touch qmi_rmtfs.c
make -j"$JOBS"
make DESTDIR="$OUT" prefix=/usr install

# --- tqftpserv ------------------------------------------------------------
fetch "https://github.com/linux-msm/tqftpserv/archive/refs/tags/v${TQFTPSERV_VERSION}.tar.gz" tqftpserv
extract tqftpserv tqftpserv
cd "$WORK/tqftpserv"
meson setup build --prefix=/usr --libdir=/usr/lib64 --buildtype=release
ninja -C build
DESTDIR="$OUT" meson install -C build

# --- iio-sensor-proxy with SSC support -----------------------------------
fetch "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/archive/${IIS_VERSION}/iio-sensor-proxy-${IIS_VERSION}.tar.gz" iio-sensor-proxy
extract iio-sensor-proxy iio-sensor-proxy
cd "$WORK/iio-sensor-proxy"
patch -p1 -i "$SRC/sensors/patches/0001-fix-ssc-race-condition.patch"
patch -p1 -i "$SRC/sensors/patches/0002-ssc-proximity-nabu-sar-fallback.patch"
meson setup build --prefix=/usr --libdir=/usr/lib64 --buildtype=release \
    -Dssc-support=enabled -Dgtk_doc=false -Dgtk-tests=false -Dtests=false \
    -Dsystemdsystemunitdir=/usr/lib/systemd/system \
    -Dudevrulesdir=/usr/lib/udev/rules.d \
    -Dsysconfdir=/usr/share
ninja -C build
DESTDIR="$OUT" meson install -C build

# --- iris-vaapi -----------------------------------------------------------
fetch "https://github.com/CFM880/iris-vaapi/archive/${IRIS_REF}.tar.gz" iris-vaapi
extract iris-vaapi iris-vaapi
cd "$WORK/iris-vaapi"
patch -p1 -i "$SRC/iris/patches/0001-vaapi-support-vaAcquireBufferHandle-and-default-expo.patch"
# Fedora's libva uses /usr/lib64/dri; keep /usr/lib/dri links for the
# LIBVA_DRIVERS_PATH values used by some wrappers.
make DRIVERDIR=/usr/lib64/dri
make install DESTDIR="$OUT" DRIVERDIR=/usr/lib64/dri
install -d "$OUT/usr/lib64/dri" "$OUT/usr/lib/dri"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib64/dri/iris_drv_video.so"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib64/dri/msm_drm_drv_video.so"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib64/dri/msm_drv_video.so"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib/dri/vpu_drv_video.so"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib/dri/iris_drv_video.so"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib/dri/msm_drm_drv_video.so"
ln -sfn /usr/lib64/dri/vpu_drv_video.so "$OUT/usr/lib/dri/msm_drv_video.so"

echo "nabu userspace stack installed under $OUT"
find "$OUT/usr" -maxdepth 3 -type f \( -name '*.so*' -o -name 'hexagonrpcd' -o -name 'qrtr-ns' -o -name 'iio-sensor-proxy' -o -name 'vpu_drv_video.so' \) | sort
