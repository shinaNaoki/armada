# nabu kernel sources and Armada configuration

The nabu kernel is **not** built from `packages/kernel` (that package still
produces the generic Armada kernel). The nabu CI job runs
`scripts/ci/build-kernel.sh`, which builds the reference Xiaomi Pad 5 kernel and
repackages it in the tarball layout `build_files/20-install-kernel.sh` expects.

## Upstream source

| Item | Value |
| --- | --- |
| Repository | `https://github.com/Kumar-Jy/linux` |
| Branch | `nabu/7.2.y` |
| Pinned commit | `739161a890128f23bd1aa679d8754a9ea299269e` |
| Version | 7.2.11 (`SUBLEVEL=11`) |
| Base config | `arch/arm64/configs/nabu_defconfig` |
| DTB | `sm8150-xiaomi-nabu.dtb` |

The pin is checked at build time: if the branch moves, the build fails instead
of silently producing a different kernel. Update `KERNEL_REF` in
`.github/workflows/nabu-image.yml` (and the default in
`scripts/ci/build-kernel.sh`) deliberately when bumping.

## Armada additions

`kernel.config` is merged on top of `nabu_defconfig`. It contains only generic
Armada requirements: SELinux/LSM, bootc/ostree filesystems, BTF/tracing/scx,
scheduler/memory, splash handoff, zram/crypto, netfilter and controller input.

It intentionally does **not** contain the old 7.2.6 forward-port device options.
The reference branch already carries:

- SM8150 display/DSI/panel, touchscreen/stylus, audio (WCD9340 + CS35L41),
- PM8150B `QCOM_BMS` battery gauge and `CHARGER_IDTP9418` wireless stylus charger,
- SLPI FastRPC sensor remoteproc and `slpi_nb.mbn`,
- iris VPU (`VIDEO_QCOM_IRIS`) and the nabu DTS files.

`kernel.required` asserts the symbols Armada cannot boot/run without. The build
script prints the actual value of any mismatch and exits non-zero.

## Output

```
out/armada-kernel-7.2.11-sm8150-nabu-1.tar.zst
out/armada-kernel-7.2.11-sm8150-nabu-1.tar.zst.sha256
```

Tarball layout:

```
lib/modules/<kver>/vmlinuz
lib/modules/<kver>/modules.*
lib/modules/<kver>/kernel/...
lib/modules/<kver>/dtb/qcom/sm8150-xiaomi-nabu.dtb
lib/modules/<kver>/.armada-source
```

## Local validation (config only, no root required)

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

A full `Image modules qcom/sm8150-xiaomi-nabu.dtb` build additionally needs
`bc` and (for `DEBUG_INFO_BTF`) a recent `pahole`; CI installs them. `pahole`
must be in `PATH` *before* merging the fragment: `DEBUG_INFO_BTF` depends on
`PAHOLE_VERSION >= 122`, and `SCHED_CLASS_EXT` depends on `DEBUG_INFO_BTF`.
Without it `olddefconfig` silently drops both and the required-symbol check
will fail with a clear message.

For a fast local config-only check against an existing checkout, use:

```bash
KERNEL_SRC_DIR=/path/to/linux-nabu VERIFY_ONLY=1 ./scripts/ci/build-kernel.sh
```
