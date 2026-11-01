# uwe5622-mainline

Linux driver for the Unisoc **UWE5622** (AW859A) Wi-Fi/Bluetooth chip, kept
building against **current upstream kernels**, with the goal of rewriting it
into a small, readable, mainline-style C driver for the **Orange Pi Zero 3**.

This is a personal project. It is not an attempt to submit the driver to the
Linux kernel, but the code is held to the kernel's rules so that would remain
possible.

## Status

| | |
|---|---|
| Code | Imported from [armbian/uwe5622](https://github.com/armbian/uwe5622) with full history. Vendor-derived; large and noisy. |
| Builds against | longterm 6.18 / 6.12, latest stable, mainline: checked weekly by CI |
| Tested on hardware | **Not yet** from this repository. Armbian's tree is in daily use on Zero 2/Zero 3 images. |
| Rewrite | Phase 1 complete: dead code removed (`unisocwcn` halved), vendor logging moved to `pr_*()` (debug output through dynamic debug), `W=1` and sparse clean with a CI gate, checkpatch baseline recorded for Phase 2. Plan in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |

Chip capabilities: 2.4 GHz 802.11b/g/n, Bluetooth classic + BLE, GNSS (unused
here). The chip is attached over SDIO on the Zero 3.

## Layout

```
unisocwcn/   WCN core: power, firmware upload, SDIO transport, sleep -> uwe5622_bsp_sdio.ko
             (platform/ sdio/ sleep/ include/; only the Allwinner SDIO variant remains)
unisocwifi/  cfg80211 Wi-Fi driver                                 -> sprdwl_ng.ko
tty-sdio/    Bluetooth HCI over SDIO exposed as a TTY              -> sprdbt_tty.ko
dts/         device-tree overlay (and Armbian's patch) enabling mmc1 + power sequence
scripts/     build-against-kernel.sh: fetch, prepare and build against any kernel release
docs/        ARCHITECTURE.md (code map, rewrite plan), HARDWARE.md (wiring, firmware, testing)
reference/   Armbian's historical per-kernel-version patches, kept for archaeology
```

## Building

Against a specific upstream kernel, cross-compiled for arm64 (this is what CI
runs; needs `gcc-aarch64-linux-gnu flex bison libssl-dev libelf-dev bc`):

```sh
scripts/build-against-kernel.sh 6.18.60          # longterm
scripts/build-against-kernel.sh 7.3.1            # stable
WARN=1 SPARSE=1 scripts/build-against-kernel.sh 7.3   # extra warnings + sparse
```

The kernel source is downloaded to `build/linux-<version>` once; later runs only
rebuild the driver. Modules land next to their sources
(`unisocwcn/uwe5622_bsp_sdio.ko`, `unisocwifi/sprdwl_ng.ko`,
`tty-sdio/sprdbt_tty.ko`); the overlay is compiled to `build/*.dtbo`.

Against the kernel a board is running, with its headers installed:

```sh
make -C /lib/modules/$(uname -r)/build M=$PWD \
     CONFIG_AW_WIFI_DEVICE_UWE5622=y CONFIG_WLAN_UWE5622=m CONFIG_TTY_OVERY_SDIO=m modules
```

`dkms.conf` is kept from upstream and does the same through DKMS.

## Device tree and firmware

Mainline's Zero 3 device tree leaves `mmc1` disabled. Apply
`dts/sun50i-h618-orangepi-zero3-uwe5622.dtso` as an overlay (base DTB built
with `-@`), or the patch in `dts/patches/` when building the kernel. Firmware
files are not redistributable and are **not** in this repository; see
[`docs/HARDWARE.md`](docs/HARDWARE.md) for what is needed and where Armbian
ships it.

## CI

`.github/workflows/build.yml` asks kernel.org which versions are current and
builds the modules against each of them on every push, pull request and every
Monday. The weekly run is the early warning for kernel API changes. The job
also builds with `W=1` and `sparse` and fails on any warning not listed in
`.github/known-warnings.txt`, and runs `checkpatch` on the diff of each change
(informational).

## Syncing with Armbian

```sh
git remote add armbian https://github.com/armbian/uwe5622
git fetch armbian && git merge armbian/master
```

## License

GPL-2.0. Original driver by Spreadtrum/Unisoc; mainline-kernel adaptation by
the Armbian community (see `git log`); see [`LICENSE`](LICENSE).
