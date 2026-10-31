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
| `uwe5622_bsp_sdio` | `unisocwcn/` | ~40 000 | "WCN core": powers the chip, uploads firmware, owns the SDIO transport, multiplexes channels for Wi-Fi, BT and GNSS, loop-check watchdog, debug dumps |
| `sprdwl_ng` | `unisocwifi/` | ~35 000 | Wi-Fi: `cfg80211` ops, command/event protocol, TX/RX paths, reorder/defrag, SoftAP, NAN, RTT, vendor commands |
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

### Code that is dead for this board

A large share of the tree is for other customers of the vendor BSP and is
compiled out or unreachable in the Allwinner SDIO build:

- Hisilicon, Amlogic and Rockchip board glue (`CONFIG_HISI_BOARD`,
  `CONFIG_AML_BOARD`, `CONFIG_RK_BOARD`)
- USB, PCIe and SIPC transports (`unisocwcn/usb`, `unisocwcn/pcie`,
  `unisocwcn/sipc`); only `unisocwcn/sdio` is used
- GNSS (`unisocwcn/gnss`, `CONFIG_WCN_GNSS`), which no Zero 3 image exposes
- Firmware-from-hex-array download, integrated (non-SDIO) chip variants
  (`SC2342_INTEG`, `UMW2653`), PMIC control
- Leftover references to vendor-kernel symbols (`sunxi_wlan_*`,
  `rockchip_wifi_set_carddetect`, `get_custom_mac_address`): all either
  commented out or behind `#ifdef`s that are not set here

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

### Phase 1 — carve out the Allwinner SDIO build

Delete what the Allwinner SDIO configuration never compiles, then drop the
`#ifdef` forest that remains. Expected outcome: roughly half the lines, same
binary behaviour. Each step is verified by CI and, where it affects runtime, a
hardware test (see `HARDWARE.md`).

- Remove non-SDIO transports, GNSS, other-vendor board glue, hex firmware path
- Replace vendor logging macros with `dev_*`/`pr_*`
- Fix everything `W=1` and `sparse` report; make `checkpatch --strict` clean on
  touched files

### Phase 2 — restructure

- One `struct device`-centred driver model: SDIO function probe → power →
  firmware → channels → Wi-Fi/BT children, with symmetric remove
- Clear boundary between transport (`sdio`), protocol (`cmdevt`) and
  `cfg80211` glue; no cross-directory `extern`s
- Firmware event parsing moved behind length-checked accessors; unit-testable
  pieces (command encode/decode, TLV parsing) written so they can run under KUnit
- Bluetooth: evaluate exposing HCI through the kernel's `hci_uart`/`serdev`-style
  interface instead of a raw TTY plus an out-of-tree `hciattach` binary

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
