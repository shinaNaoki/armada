# nabu firmware

Vendored from the reference Arch package:

- Package: `linux-firmware-xiaomi-nabu-25.04.26-1-any.pkg.tar.xz`
- URL: <https://github.com/rodriguezst/arch-repo/releases/download/aarch64/linux-firmware-xiaomi-nabu-25.04.26-1-any.pkg.tar.xz>
- SHA256: `bef43c32029902bc4c3c1b7c7007c6e5d954fe673933087a836b5a41b567bac9`
- Upstream firmware: <https://github.com/linux-msm/linux-firmware-msm>

The package provides the device-specific Qualcomm blobs under
`qcom/sm8150/xiaomi/nabu/` (lowercase, matching the DTS `firmware-name`
strings) plus the Adreno 640 GPU firmware and Novatek touch firmware.

`cirrus/` (CS35L41 speaker amplifiers) and `qca/` (WCN3990 Wi-Fi/Bluetooth)
are kept from the earlier payload; Fedora's generic firmware packages do not
carry these nabu-specific files either.

This directory is copied to `/usr/lib/firmware/` by `image/Containerfile`.
Do not reintroduce the uppercase `Xiaomi/` path: the kernel firmware loader is
case-sensitive and silently fails to load the GPU/DSP/modem/venus blobs.

`slpi_nb.mbn` is required by `&remoteproc_slpi` in the 7.2.11 nabu DTSI; it is
kept here even though the SLPI userspace daemons are not part of this branch.
