# Architecture and rewrite plan

This document describes what the imported driver looks like today and how it is
going to be reshaped. Numbers are from the import commit (Armbian `uwe5622`
master, 2026-10-31).

## What the chip is

The UWE5622 (also sold as AW859A) is a Unisoc/Spreadtrum combo chip:
2.4 GHz 802.11b/g/n Wi-Fi, Bluetooth (classic + BLE) and a GNSS receiver. On
the Orange Pi Zero 3 it is wired to the H618 over **SDIO (mmc1)**. The chip runs
its own closed firmware (`wcnmodem.bin`), which the host uploads at power-up;
the kernel driver is a "fullmac" design: scanning, association and crypto key
handling happen in the firmware, and the host driver mostly translates between
`cfg80211` and the firmware's command/event protocol.

## Modules as imported

| Module | Directory | Lines (C/H) | Role |
|---|---|---|---|
| `uwe5622_bsp_sdio` | `unisocwcn/` | ~40 000 (19 600 after Phase 1) | "WCN core": powers the chip, uploads firmware, owns the SDIO transport, multiplexes channels for Wi-Fi and BT, loop-check watchdog, debug dumps |
| `sprdwl_ng` | `unisocwifi/` | ~35 000 (34 000 after Phase 1) | Wi-Fi: `cfg80211` ops, command/event protocol, TX/RX paths, reorder/defrag, SoftAP, NAN, RTT, vendor commands |
| `sprdbt_tty` | `tty-sdio/` | ~2 000 | Bluetooth: exposes an HCI byte stream from the chip as a TTY, which userspace (`hciattach`) attaches to BlueZ |

Build selection is done with the same Kbuild variables Armbian and `dkms.conf`
use: `CONFIG_AW_WIFI_DEVICE_UWE5622=y CONFIG_WLAN_UWE5622=m CONFIG_TTY_OVERY_SDIO=m`.
For that Allwinner variant the relevant compile-time switches in
`unisocwcn/Makefile` are `CONFIG_AW_BOARD`, `CONFIG_WCN_SDIO`, `CONFIG_WCN_SLP`,
`CONFIG_WCN_SWD`, `CONFIG_WCN_POWER_UP_DOWN`, `CONFIG_BT_WAKE_HOST_EN`,
`CONFIG_WL_WAKE_HOST_EN`, `CONFIG_WCN_LOOPCHECK`, `CONFIG_SDIO_TX_ADMA_MODE`,
`CONFIG_SDIO_RX_ADMA_MODE`, `CONFIG_SDIO_INBAND_INT`. `CONFIG_WCN_PARSE_DTS` is
**off** for Allwinner: the driver does not read its own device-tree node; power
and reset are handled by the kernel's `mmc-pwrseq-simple` from the DT.

## Build map (Allwinner SDIO build)

Derived from the Makefiles and Kconfig files for the selection used by
`dkms.conf`, `scripts/build-against-kernel.sh` and CI:
`CONFIG_AW_WIFI_DEVICE_UWE5622=y CONFIG_WLAN_UWE5622=m CONFIG_TTY_OVERY_SDIO=m`.
Only the three top-level per-module Makefiles take part in the build; the
per-subdirectory `Makefile`/`Kconfig` files that the vendor tree carried for an
in-kernel build were never referenced (Kbuild only descends into a directory
listed with `obj-y += dir/`, and `unisocwcn/Makefile` lists its objects
directly).

### `unisocwcn/` → `uwe5622_bsp_sdio.ko`

Module name is `$(BSP_CHIP_ID)_bsp_$(WCN_HW_TYPE)` = `uwe5622_bsp_sdio`,
built with `obj-m` (`CONFIG_WCN_BSP_DRIVER_BUILDIN` unset).

Compiled objects (`$(MODULE_NAME)-y`, plus the `CONFIG_WCN_SWD` and
`CONFIG_WCN_SDIO` lists, both of which are set):

```
wcn_bus.c
platform/wcn_boot.c      platform/wcn_dump.c      platform/bufring.c
platform/wcn_txrx.c      platform/wcn_op.c        platform/wcn_parn_parser.c
platform/rdc_debug.c     platform/wcn_log.c       platform/wcn_misc.c
platform/wcn_procfs.c    platform/loopcheck.c     platform/wcn_swd_dp.c
platform/mem_pd_mgr.c
sdio/sdiohal_main.c      sdio/sdiohal_common.c    sdio/sdiohal_tx.c
sdio/sdiohal_rx.c        sdio/sdio_v3.c           sdio/sdiohal_ctl.c
sleep/sdio_int.c         sleep/slp_mgr.c          sleep/slp_sdio.c
sleep/slp_test.c
```

Preprocessor switches in effect (`ccflags-y`):

| Defined | Source |
|---|---|
| `CONFIG_UWE5622` | Allwinner chip selection |
| `CONFIG_WCN_SDIO`, `CONFIG_WCN_SLP`, `CONFIG_WCN_SWD` | from `CONFIG_WCN_SDIO=y` |
| `CONFIG_WCN_BOOT`, `CONFIG_WCN_UTILS` | always |
| `CONFIG_AW_BOARD`, `CONFIG_WCN_POWER_UP_DOWN`, `CONFIG_BT_WAKE_HOST_EN`, `CONFIG_WL_WAKE_HOST_EN`, `CONFIG_WCN_LOOPCHECK`, `CONFIG_SDIO_TX_ADMA_MODE`, `CONFIG_SDIO_RX_ADMA_MODE`, `CONFIG_SDIO_INBAND_INT` | Allwinner block |
| `CONFIG_CUSTOMIZE_UNISOC_FW_PATH="/lib/firmware/uwe5622/"` | top-level Makefile |
| `-fno-pic -D__linux__`, `-I include -I platform -I platform/rf -I ../tty-sdio` | always |

Deliberately **not** defined (commented out or belonging to other customers):
`CONFIG_WCN_PARSE_DTS`, `CONFIG_CHECK_DRIVER_BY_CHIPID`, `CONFIG_UWE5621`,
`CONFIG_UWE5623`, `CONFIG_WCN_USB`, `CONFIG_WCN_PCIE`, `CONFIG_WCN_SIPC`,
`CONFIG_WCN_GNSS`, `CONFIG_SC2342_INTEG`, `CONFIG_UMW2653`,
`CONFIG_HISI_BOARD`, `CONFIG_AML_BOARD`, `CONFIG_RK_BOARD`,
`CONFIG_WCN_DOWNLOAD_FIRMWARE_FROM_HEX`, `CONFIG_WCN_PMIC`, `CONFIG_MEM_PD`,
`CONFIG_WCN_RESUME_POWER_DOWN`, `CONFIG_WCN_RESUME_KEEPPWR_RESETSDIO`,
`CONFIG_WCN_CHECK_MODULE_VENDOR`, `CONFIG_CPLOG_DEBUG`,
`CONFIG_SDIO_INBAND_POLLING`, `CONFIG_SDIO_BLKSIZE_512`, `CONFIG_SDIO_PWRSEQ`,
`CONFIG_WCND`, `CONFIG_WCN_FM`, `CONFIG_SDIOM`. Note that Kconfig symbols such
as `CONFIG_AW_BIND_VERIFY` or `CONFIG_RK_WIFI_DEVICE_UWE5622` are *make*
variables in this out-of-tree build and never reach the preprocessor, so
`IS_ENABLED()` tests on them are false.

### `unisocwifi/` → `sprdwl_ng.ko`

All objects listed in `sprdwl_ng-objs` are compiled:

```
main.c cfg80211.c txrx.c cmdevt.c npi.c msg.c work.c vendor.c tcp_ack.c mm.c
reorder.c wl_core.c tx_msg.c rx_msg.c wl_intf.c qos.c dbg_ini_util.c
reg_domain.c defrag.c ibss.c nan.c tracer.c rf_marlin3.c rtt.c api_version.c
rnd_mac_addr.c debug.c
```

Not compiled: `11h.c` (commented out), `edma_test.c`, `softap_hook.c`.

Switches: `IBSS_SUPPORT IBSS_RSN_SUPPORT NAN_SUPPORT RTT_SUPPORT ACS_SUPPORT
RX_HW_CSUM WMMAC_WFA_CERTIFICATION COMPAT_SAMPILE_CODE RND_MAC_SUPPORT
ATCMD_ASSERT TCPACK_DELAY_SUPPORT SPLIT_STACK OTT_UWE CP2_RESET_SUPPORT`,
include paths `../unisocwcn/include`. Not set: `WL_CONFIG_DEBUG`
(`DEBUGMODE`), `STA_SOFTAP_SCC_MODE`, `UNISOC_WIFI_PS`,
`CUSTOMIZE_WIFI_CFG_PATH`, `CUSTOMIZE_WIFI_MAC_FILE`, `DFS_MASTER`.

### `tty-sdio/` → `sprdbt_tty.ko`

All six objects are compiled: `tty.c rfkill.c lpm.c woble.c alignment/sitm.c
dump.c`. Switches: `OTT_UWE WOBLE_FUN`; include path `../unisocwcn/include`.
Not set: `DEBUG`, `KERNEL_VERSION_414`.

### Code that was dead for this board (removed in Phase 1)

A large share of the imported tree served other customers of the vendor BSP
and was compiled out or unreachable in the Allwinner SDIO build. It was
removed in Phase 1 (see below); the list is kept here as the record of what
the import contained:

- Hisilicon, Amlogic and Rockchip board glue (`CONFIG_HISI_BOARD`,
  `CONFIG_AML_BOARD`, `CONFIG_RK_BOARD`, `CONFIG_RK_WIFI_DEVICE_UWE5622`)
- USB, PCIe and SIPC transports (`unisocwcn/usb`, `unisocwcn/pcie`,
  `unisocwcn/sipc`); only `unisocwcn/sdio` is used
- GNSS (`unisocwcn/gnss`, `unisocwcn/platform/gnss`, `CONFIG_WCN_GNSS`), which
  no Zero 3 image exposes
- Firmware-from-hex-array download (`unisocwcn/fw`, 10 MB of hex), integrated
  (non-SDIO) chip variants (`SC2342_INTEG`, `UMW2653`, `unisocwcn/boot`), the
  UWE5621/UWE5623 register maps and the runtime chip-model dispatch
  (`CONFIG_CHECK_DRIVER_BY_CHIPID`), PMIC control (`CONFIG_WCN_PMIC`)
- References to vendor-kernel symbols (`sunxi_wlan_*`, `sunxi_mmc_rescan_card`,
  `rockchip_wifi_set_carddetect`, `extern_wifi_set_enable`, `sdio_reinit`):
  commented out or behind `#ifdef`s that were never set

### External interfaces the driver relies on

- `cfg80211` (fullmac; no `mac80211`)
- MMC/SDIO core: `sdio_register_driver`, `sdio_claim_host`, block transfers, SDIO IRQ
- `request_firmware` for `wcnmodem.bin` (from `/lib/firmware/uwe5622/` then `/lib/firmware/`)
- `/lib/firmware/wifi_2355b001_1ant.ini`, a board tuning file read by the Wi-Fi module
- rfkill, TTY core (Bluetooth), wakeup IRQs

## Goals of the rewrite

In priority order:

1. **Builds against every current upstream kernel**: the longterm series,
   stable and mainline, checked weekly by CI, so a kernel update never silently
   breaks Wi-Fi.
2. **Small and readable**: only the code the SDIO variant needs, in the style
   and structure of in-tree `cfg80211` drivers, with `checkpatch` and `sparse`
   clean.
3. **Robust**: no kernel oops from a misbehaving chip or malformed firmware
   event; bounds-checked parsers; clean teardown on module unload.
4. **Mainline-shaped, not mainline-submitted**: the code follows the kernel's
   rules so a submission would be possible, but this project does not aim to
   upstream it.

Rust is not an option yet: mainline has no Rust abstractions for `cfg80211` or
SDIO, so a driver on those interfaces has to be C.

## Phases

### Phase 0 — baseline (done in the first commits)

- Import Armbian's tree with history.
- CI builds the three modules against the current longterm, stable and mainline
  kernels (`scripts/build-against-kernel.sh`), compiles the DT overlay, and
  reports warning/sparse counts.

### Phase 1 — carve out the Allwinner SDIO build (done)

Delete what the Allwinner SDIO configuration never compiles, then drop the
`#ifdef` forest that remains. Each step is verified by CI; nothing in this
phase changes the code the compiler saw before, so the binary behaviour is
the same and hardware testing (see `HARDWARE.md`) can be done once at the end.

Done (commits `e1a9c49`..`9fc1881`):

- Build map written down (above), derived from the Makefiles.
- Deleted the never-compiled sources: `unisocwcn/{usb,pcie,sipc,boot,fw,gnss,
  log,vm}/`, `platform/gnss/`, `platform/{usb_boot,pcie_boot,rf/rf,wcn_debugfs,
  wcn_dump_integrate}.*`, `sleep/slp_pcie.*`, `include/{mchn,wcn_types}.h`,
  `include/vendor/hisilicon/`, `include/{uwe5623,uwe562x}_glb.h`;
  `unisocwifi/{11h,edma_test,softap_hook}.c`, `edma_test.h`, `softap_hook.h`,
  `cfg80211_compat.h`, `Android.mk`; all per-subdirectory Makefile/Kconfig
  files of the vendor in-kernel layout.
- `unisocwcn/Makefile` reduced to the Allwinner block with the identical
  flag set and object list; Rockchip/Hisilicon/Amlogic blocks, hex-firmware
  rules and Android install targets gone. `CONFIG_RK_WIFI_DEVICE_UWE5622`
  removed from the top-level Makefile, Kconfig and dkms.conf.
- Collapsed every `#if` on `CONFIG_HISI_BOARD`, `CONFIG_AML_BOARD`,
  `CONFIG_RK_BOARD`, `CONFIG_WCN_USB`, `CONFIG_WCN_PCIE`, `CONFIG_WCN_SIPC`,
  `CONFIG_WCN_GNSS`, `CONFIG_SC2342_INTEG`, `CONFIG_UMW2653`,
  `CONFIG_WCN_DOWNLOAD_FIRMWARE_FROM_HEX`, `CONFIG_WCN_PMIC`,
  `CONFIG_CHECK_DRIVER_BY_CHIPID`, `CONFIG_UWE5621`, `CONFIG_UWE5623` and
  `IS_ENABLED(CONFIG_RK_WIFI_DEVICE_UWE5622)`: dead branch removed, the
  compiled branch kept verbatim.
- Removed the commented-out / unused vendor-kernel symbol references listed
  above.

Result: `unisocwcn/` 39 895 → 19 571 lines (104 → 51 files), `unisocwifi/`
34 737 → 33 963 (63 → 57), `tty-sdio/` unchanged at 2 139. 155 k lines
deleted in total including the hex firmware.

Deliberately kept, because removing it would need a judgement call or a
hardware test rather than a proof from the build map:

- `#ifdef`s on switches the Allwinner Makefile *could* enable but does not
  (`CONFIG_WCN_PARSE_DTS`, `CONFIG_MEM_PD`, `CONFIG_WCN_RESUME_*`,
  `CONFIG_SDIO_BLKSIZE_512`, `CONFIG_SDIO_INBAND_POLLING`, `CONFIG_SDIO_PWRSEQ`,
  `CONFIG_CPLOG_DEBUG`, `CONFIG_WCN_CHECK_MODULE_VENDOR`) and on Android-side
  switches (`CONFIG_WCND`, `CONFIG_WCN_FM`, `CONFIG_SDIOM`): all currently off,
  all candidates for Phase 2 once the DT-less power sequence is settled.
- `IS_ENABLED(CONFIG_AW_BIND_VERIFY)` (chip bind verification) and
  `IS_ENABLED(CONFIG_SUNXI_ADDR_MGT)` with `get_custom_mac_address()` in
  `unisocwifi/main.c`: Kconfig symbols that are false in the out-of-tree build
  but belong to an Allwinner kernel feature, not to another vendor.
- `CONFIG_ARCH_SUNXI` branches in `sdiohal_main.c` (real kernel symbol, true
  on arm64 defconfig).
- The GNSS *protocol* code that is not under `CONFIG_WCN_GNSS`: the
  `MARLIN_GNSS` subsystem enum, `wcn_gnss.h` ops registration and the
  `gnss_dl_wq` download path in `wcn_boot.c`. Removing it changes power-state
  bookkeeping and needs a hardware test (Phase 2).
- `unisocwifi` conditionals (`DFS_MASTER`, `CONFIG_P2P_INTF`, `RX_NAPI`,
  `STA_SOFTAP_SCC_MODE`, ...) and `11h.h`, which compiled files include for
  struct definitions.
- `unisocwcn/tool/cp2log_config/`: documentation of a config file the
  (compiled) CP2 log parser reads.
- `platform/rf/rf.h`: `wcn_boot.c` uses `struct wifi_cali_t` and
  `struct wifi_config_t` from it.

Logging moved to kernel `pr_*()` (commits `6aed7dd`..`f3afa20`), see
"Logging" below. Vendor macro call sites before → after:

| Macro | Before | After |
|---|---|---|
| `WCN_INFO` / `WCN_ERR` | 321 / 232 | 0 (→ `pr_info` / `pr_err`) |
| `WCN_DEBUG`, `MDBG_LOG`, `MDBG_FUNC_ENTERY` | 59, 30, 2 | 0 (→ `pr_debug`; 13 trace-style ones dropped) |
| `MDBG_ERR` | 13 | 0 (→ `pr_err`) |
| `BT_VER` (tty-sdio) | 11 | 0 (→ `pr_debug`) |
| `wl_err` / `wl_info` / `wl_debug` / `wl_warn` / `wl_err_ratelimited` | 343 / 238 / 97 / 6 / 5 | unchanged: kept as thin `pr_*()` wrappers because their run-time gating is user-visible |

No message that used to be emitted stopped being emitted, and no message that
was silent by default became visible by default. Visible differences in the
log:

- `unisocwcn`: every `pr_*()` line now starts with `WCN: ` (`pr_fmt`). Former
  `WCN_ERR()` lines said `WCN_ERR: `, former `MDBG_ERR()` lines
  `WCN_MDBG_ERR: `; direct `pr_*()` calls and the `sdiohal_*`, `SLP_MGR_*`,
  `MEM_PD_MGR_*` wrappers had no `WCN: ` before (so they now read e.g.
  `WCN: sdiohal:...`). `MDBG_ERR()` was `KERN_INFO`, now `KERN_ERR`. Three
  messages lost a blank before the newline; a few spell the function name via
  `__func__` (same text).
- `unisocwifi`: the `sprdwl:` text is unchanged. The level tag now follows the
  macro (`wl_warn` → `KERN_WARNING`, `wl_info`/`wl_debug` → `KERN_INFO`; all
  were `KERN_ERR`), `wl_err_ratelimited` is `KERN_ERR` instead of the default
  level, and the few direct `pr_err`/`pr_info` calls gained the `sprdwl:`
  prefix.
- `tty-sdio`: unchanged (no `pr_fmt` added, so its existing output keeps its
  text).

### Logging

| Module | Prefix (`pr_fmt`) | Run-time control |
|---|---|---|
| `uwe5622_bsp_sdio` | `WCN: ` | `pr_err`/`pr_info` always print; `pr_debug` via dynamic debug |
| `sprdwl_ng` | `sprdwl:` | `wl_*()` gated by `sprdwl_debug_level`, see below; `wl_debug()` also via dynamic debug |
| `sprdbt_tty` | none | `pr_err`/`pr_info` always print; `pr_debug` via dynamic debug |

Debug output (needs `CONFIG_DYNAMIC_DEBUG` and debugfs mounted):

```sh
echo 'module uwe5622_bsp_sdio +p' > /sys/kernel/debug/dynamic_debug/control
echo 'module sprdwl_ng +p'        > /sys/kernel/debug/dynamic_debug/control
echo 'module sprdbt_tty +p'       > /sys/kernel/debug/dynamic_debug/control
# add "fl" (e.g. +pfl) for the function name and line number that the old
# WCN_DEBUG/MDBG_LOG macros used to print
```

Kept run-time levels:

- `sprdwl_ng`: `sprdwl_debug_level` (0 none, 1 error = default, 2 warn,
  3 info, 4 debug). Set with the `debug_level` module parameter
  (`/sys/module/sprdwl_ng/parameters/debug_level`), the `log_level` key in
  `wifi_dbg.ini`, or `echo debug_level=N > /sys/kernel/debug/sprdwl_debug/log_level`.
  `wl_err/warn/info/debug()` print only when the level is at least theirs;
  below level 4, `wl_debug()` call sites can additionally be enabled through
  dynamic debug. `wl_ndev_log()` and `wl_hex_dump()` are gated the same way
  but still print at `KERN_ERR` (Phase 2).
- `uwe5622_bsp_sdio`: the `sdiohal_normal/debug/pr_list/pr_data/pr_perf()`
  wrappers stay gated by the debugfs `sdiohal_log_level` bitmask.

Removed because nothing could ever change them: `wcn_print_level` (gated
`WCN_DEBUG`; never written, not a parameter), `MDBG_DEBUG_MODE` (compile-time
0) and the `log_level` gate of `BT_VER` in tty-sdio (static, never written; the
variable is still read by three dead hex-dump blocks, left for Phase 2).

### checkpatch baseline

`checkpatch.pl --no-tree --strict -f` (torvalds/master, 2026-11-01) on every
`.c`/`.h` file at the end of Phase 1, as the starting point for Phase 2:

| Module | Files | Errors | Warnings | Checks |
|---|---|---|---|---|
| `unisocwcn/` | 51 | 7 | 370 | 1 094 |
| `unisocwifi/` | 57 | 13 | 809 | 1 192 |
| `tty-sdio/` | 12 | 1 | 115 | 151 |
| total | 120 | 21 | 1 294 | 2 437 |

Largest groups: `PARENTHESIS_ALIGNMENT` (784 checks), `CONSTANT_COMPARISON`
(344 warnings, Yoda/`KERNEL_VERSION` tests), `LINUX_VERSION_CODE` (294
warnings), `UNNECESSARY_PARENTHESES` (317 checks), `PREFER_KERNEL_TYPES` (268
checks), missing SPDX tags (120 warnings, one per file), trace-style logging
(101 warnings). The errors are spacing, brace placement, trailing statements,
two complex macros and three zero-length arrays (`wcn_dump.c`, `qos.h`,
`vendor.h`).

The lines changed by the logging conversion have no checkpatch errors, and
only two kinds of warning are left on them, on purpose:

- trace-style `pr_info("%s ...", __func__)` messages. They are printed today,
  so the only fixes are removing or demoting them.
- the missing SPDX tag, reported on files whose first line moved. Adding a
  license tag states a license for each file, so it belongs in its own
  deliberate commit, not in a style fix.

The CI "checkpatch (diff)" job runs on `git diff -U0`, so for a changed macro
body it can report `COMPLEX_MACRO` against the `wl_*` wrappers in `sprdwl.h`.
That is a false positive caused by the missing context: the whole-file run
above reports no error there.

### Phase 1b — `W=1` and sparse clean (done)

All four CI kernels now build the three modules with `W=1` and sparse
(built from kernel.org git, because Ubuntu's sparse is too old for 7.x
headers). The "Extra warnings and sparse" step is a gate: any warning not
listed in `.github/known-warnings.txt` fails CI. Every fix was
behaviour-neutral: `static`, prototypes, `const`, endianness and address-space
annotations, `NULL` for pointers, unused variables.

Known issues for Phase 2 (the five accepted warnings; each needs a logic
change):

- `unisocwcn/platform/wcn_procfs.c`: the result of `kstrtol()` is never
  checked, so a malformed procfs write is silently accepted.
- `unisocwifi/txrx.c`: `eth->h_proto` (network order) is compared with
  host-order `ETH_P_IP`/`ETH_P_IPV6`, so the test is always true on
  little-endian. Fixing it changes which broadcast frames are looped back in
  AP mode.
- `unisocwifi/rx_msg.h`, `unisocwifi/vendor.h`: firmware structs holding an
  array of structs that end in a flexible array; the accessors need
  rewriting.

### Phase 2 — restructure

- One `struct device`-centred driver model: SDIO function probe → power →
  firmware → channels → Wi-Fi/BT children, with symmetric remove
- Clear boundary between transport (`sdio`), protocol (`cmdevt`) and
  `cfg80211` glue; no cross-directory `extern`s
- Firmware event parsing moved behind length-checked accessors; unit-testable
  pieces (command encode/decode, TLV parsing) written so they can run under KUnit
- Bluetooth: evaluate exposing HCI through the kernel's `hci_uart`/`serdev`-style
  interface instead of a raw TTY plus an out-of-tree `hciattach` binary
- Logging follow-ups: `dev_*`/`netdev_*` once a `struct device` is at hand
  everywhere; decide whether the user-visible `sprdwl_debug_level` gate stays
  or `wl_*` become plain `pr_*`; give `wl_ndev_log()`/`wl_hex_dump()` real
  levels; fold `sdiohal_*`, `SLP_MGR_*`, `MEM_PD_MGR_*` and
  `wcn_pr_daterate()` into `pr_*`; remove or demote the trace-style
  `pr_info()` messages; `pr_fmt` for tty-sdio; SPDX tags; the remaining
  checkpatch baseline above

### Phase 3 — hardening and test support

- KUnit tests for the pure protocol code; fuzzing harness for event parsers
- Record real SDIO traffic on hardware and replay it in CI (fake SDIO function)
  so regressions are caught without a board
- Power management review (suspend/resume, wake-on-wireless)

## Syncing with Armbian

Armbian's repository stays the source of fixes until Phase 1 lands. To pull its
changes:

```sh
git remote add armbian https://github.com/armbian/uwe5622
git fetch armbian
git merge armbian/master
```

After Phase 1 the trees diverge too much to merge; fixes get cherry-picked by
hand, which is why `reference/` keeps Armbian's historical per-kernel patches.
