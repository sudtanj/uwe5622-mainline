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

## Transport interface

The three modules talk to the chip only through `struct sprdwcn_bus_ops`
(`unisocwcn/include/wcn_bus.h`), reached via the `sprdwcn_bus_*()` inline
wrappers in the same header. A wrapper whose hook is `NULL` (or with no
transport registered) returns 0 and does nothing. Wi-Fi (`unisocwifi/`)
and BT (`tty-sdio/`) never call into `unisocwcn/sdio/`; they use the
wrappers plus the power API in `include/marlin_platform.h`
(`start_marlin()`/`stop_marlin()` and helpers exported from
`platform/wcn_boot.c`). Since Phase 2 the WCN core (`platform/`, `sleep/`)
does not include `sdio/sdiohal.h` either.

### Registering a transport

- Default: `marlin_probe()` calls `marlin_bus_attach(wcn_sdio_bus_ops())`
  (`platform/wcn_boot.c`), which does `module_ops_register(ops)`, then
  `ops->register_rescan_cb(marlin_scan_finish)`, then `ops->preinit()`.
- `modprobe uwe5622_bsp_sdio transport=external`: the core does not touch
  SDIO. Another module calls
  `int wcn_bus_register_transport(struct sprdwcn_bus_ops *ops)`
  (same three steps; returns `-ENODEV` before the core has probed, `-EBUSY`
  in SDIO mode or when a transport is already registered) and, before it
  unloads, `void wcn_bus_unregister_transport(struct sprdwcn_bus_ops *ops)`
  (calls `ops->deinit()`). Both are `EXPORT_SYMBOL_GPL`. Register before
  loading `sprdwl_ng`/`sprdbt_tty`; unregister only after they are
  unloaded (the pointer is read without a lock).
- Channels registered before a transport exists: the core registers its AT,
  loopcheck and assert channels at probe. `sprdwcn_bus_chn_init()` with no
  transport records the `struct mchn_ops_t` (`wcn_bus_chn_defer()`);
  `marlin_bus_attach()` replays them with `ops->chn_init()` after `preinit`,
  and `wcn_bus_unregister_transport()` calls `ops->chn_deinit()` for them
  before `deinit`, keeping them recorded for the next transport. A channel's
  own `sprdwcn_bus_chn_deinit()` removes it from the record. With the SDIO
  transport the record is always empty (it attaches first), so nothing changes.
- Helpers exported for a transport (declared in `wcn_bus.h`, in
  `unisocwcn/wcn_bus.c`): `bus_chn_init(ops, hif_type)` /
  `bus_chn_deinit(ops)` (record the channel's `struct mchn_ops_t` and, if
  `pool_size > 0`, create its mbuf pool), `buf_list_alloc()` /
  `buf_list_free()` (that pool), `chn_ops(chn)` (the registered callbacks).
  The SDIO transport simply forwards `chn_init`, `chn_deinit`,
  `list_alloc`, `list_free` to these (`sdio/sdio_v3.c`).

### Hooks the upper layers use

| Hook | Called by | Contract |
|---|---|---|
| `preinit` / `deinit` | core probe/remove, register/unregister | bring the transport up/down |
| `register_rescan_cb(fn)` | attach | store `fn`; call it when the "card" is present after `rescan` |
| `driver_register` / `rescan` | `chip_power_on()` | make the chip visible; `rescan` must lead to `fn()` within `CARD_DETECT_WAIT_MS` (3000 ms) or power-on fails |
| `driver_unregister` / `remove_card` | `chip_power_off()`, power-on error path | SDIO on Allwinner: no-ops |
| `chn_init(ops)` / `chn_deinit(ops)` | Wi-Fi `sprdwl_intf_init()`, BT `mtty` init (`tty.c`), core `wcn_txrx.c`, `wcn_procfs.c` | register a channel (see table below) |
| `list_alloc` / `list_free` | TX users | take/return mbufs from the channel's pool |
| `push_list(chn, head, tail, num)` | everyone | TX channel (< 12): send the list, then give it back with `chn_ops(chn)->pop_link(chn, head, tail, num)`; RX channel (>= 12): the owner returns an RX list it was given, the transport frees it |
| `push_list_direct` | Wi-Fi data TX (`wl_intf.c`, BT off) | send before returning and do NOT call `pop_link`; the caller returns the buffers (see "Who calls `pop_link`") |
| `direct_read/write(addr, buf, len)` | firmware download, `check_cp_ready()`, dumps | chip memory access |
| `read_l/write_l(addr, buf)` | boot handshake | 32-bit chip register access (`sprdwcn_bus_reg_read/write`) |
| `readbyte/writebyte` | `sleep/`, SWD debug | SDIO AON byte registers; only reached on Zero 3 through the debug/sleep paths (`sdio_int` is inactive without an `int_ap` GPIO) |
| `runtime_get/put` | after boot / at power-off | may be no-ops |
| `allow_sleep/sleep_wakeup(subsys)` | Wi-Fi TX | chip sleep handshake; may be no-ops in a mock |
| `get_rx_mode`, `get_hif_type`, `get_irq_type`, `get_blk_size`, `get_tx_mode` | Wi-Fi `mm.c`, `wl_intf.c`, core | SDIO returns `HW_TYPE_SDIO` (0) for `get_hif_type`; Wi-Fi selects its SDIO channel table only for 0 |
| `get/set_carddump_status`, `get_rx_total_cnt`, `dump_regs`, `hw_reset` | assert/dump/debug paths | optional |

`mchn_ops_t.pop_link(chn, head, tail, num)` is the only upcall: the
transport calls it from process context (the SDIO transport calls it from
its RX/TX threads with a per-channel mutex held), one call per channel at
a time.
### Who calls `pop_link`: `push_list` versus `push_list_direct`

The two TX hooks differ in who returns the buffers, and getting this wrong
is a use-after-free (found by the simulator: first IPv6 frame after
`ip link set wlan0 up`, KASAN in `sprdwl_handle_pop_list()`).

- `push_list(chn, head, tail, num)`: asynchronous. The transport owns the
  list until it has sent it, then calls `chn_ops(chn)->pop_link(chn, head,
  tail, num)` (from its TX thread, process context, per-channel callback
  mutex held). The owner frees its buffers in `pop_link` and the mbufs go
  back with `buf_list_free()` (`sprdwl_handle_pop_list()` does both).
- `push_list_direct(chn, head, tail, num)`: synchronous. The transport sends
  the list before returning (SDIO: `sdiohal_list_direct_write()` returns 0
  even if the bus write failed) and **must not call `pop_link`**. Ownership
  is back with the caller on return, and the caller returns the buffers
  itself: `sprdwl_intf_tx_list()` queues `sprdwl_add_topop_list()` right
  after a successful direct push, which frees the skbs and the mbufs on the
  Wi-Fi work queue. If the transport also pops, the second pop reads skbs
  that the first one freed.

Wi-Fi data TX picks the hook with `coex_bt_on` (`wl_intf.c`): BT off uses
`push_list_direct`, BT on uses `push_list`. So a transport (or simulator)
must implement `push_list_direct` as "send, return 0, do not pop", and
`push_list` as "send, then pop once".

`pop_link` ordering for `push_list`: lists must be popped in the order they
were pushed, and each pop must cover a run of whole messages that were pushed
consecutively (SDIO may merge several pushed lists into one pop, never split
a pushed list or reorder). `sprdwl_handle_pop_list()` cuts the run from the
head message of the popped list to its tail out of the in-flight list with
`list_cut_position()`, which only works for such runs. `mbuf->buf` and
`mbuf->len` must be left as the sender set them: `buf` points just after the
pointer the sender stored in the 8 bytes in front of it (`GET_MSG_BUF()`), and
the pop reads that pointer to find its message.

For command channels (`push_list` only) the owner frees `mbuf->buf` when
`pop_link` is called; a command never popped stays on `cmd_to_free` until
the Wi-Fi module is removed.


### Buffer layout

Every buffer starts with a 4-byte public header (`PUB_HEAD_RSV`,
`struct sdio_puh_t` in `wcn_bus.h`, little-endian bitfields: `pad:6`,
`check_sum:1`, `len:16`, `eof:1`, `subtype:4`, `type:4`).

- TX: the sender allocates `len + 4` bytes, leaves the first 4 bytes for the
  transport and sets `mbuf->buf` to the start, `mbuf->len` to the payload
  length *without* the header (`if_tx_one()` in `unisocwifi/wl_intf.c`,
  `marlin_sdio_write()` in `tty-sdio/tty.c`, `at_cmd_send()` in
  `platform/loopcheck.c`). The SDIO transport fills the header with
  `type = 0`, `subtype = chn`. After sending, the list goes back via
  `pop_link`; Wi-Fi/BT free `mbuf->buf` there and return the mbufs to the pool.
- RX: the transport allocates the mbufs and buffers, `mbuf->buf` points at
  the 4-byte header, payload follows; the payload length is `puh->len`
  (`mbuf->len` is the buffer size). For RX channel `c` the header has
  `subtype = c - 12`. The owner returns the list with `push_list(c, ...)`.

### Channels (Allwinner SDIO build)

TX channels are 0..11 (`subtype = chn`), RX channels 12..25
(`subtype = chn - 12`) (`sdiohal_hwtype_to_channel()`,
`sdio/sdiohal_common.c`).

| Chn | Dir | Owner | Purpose | Pool |
|---|---|---|---|---|
| 0 | TX | core `WCN_AT_TX` (`platform/wcn_procfs.c`) | AT commands to firmware | 5 |
| 3 | TX | BT `BT_TX_CHANNEL` (`tty-sdio/tty.h`) | HCI host→controller | 64 |
| 8 | TX | Wi-Fi `SDIO_TX_CMD_PORT` (`unisocwifi/wl_intf.h`) | commands | 10 |
| 10 | TX | Wi-Fi `SDIO_TX_DATA_PORT` | data frames | 800 |
| 12 | RX | core `WCN_LOOPCHECK_RX` | loopcheck replies | 1 |
| 13 | RX | core `WCN_AT_RX` | AT command replies | 1 |
| 14 | RX | core `WCN_ASSERT_RX` | firmware assert text | 1 |
| 15 | RX | core `WCN_RING_RX` (`platform/wcn_txrx.c`) | firmware log | 1 |
| 17 | RX | BT `BT_RX_CHANNEL` | HCI controller→host | 1 |
| 22 | RX | Wi-Fi `SDIO_RX_CMD_PORT` | command responses and events | 1 |
| 23 | RX | Wi-Fi `SDIO_RX_PKT_LOG_PORT` | packet log | 1 |
| 24 | RX | Wi-Fi `SDIO_RX_DATA_PORT` | data frames | 1 |

RX "pool" sizes are what the owners request; SDIO allocates RX buffers itself.

### Firmware boot handshake

`start_marlin(subsys)` → `marlin_set_power(subsys, 1)` (`wcn_boot.c`). On
the first power-on, with `power_lock` held:

1. `chip_power_on()`: regulators/GPIOs (no-ops on Zero 3), then
   `driver_register()`, `rescan()`; wait up to 3000 ms for the rescan
   callback.
2. Sets the subsystem bit in `power_state`, queues `download_wq`
   (`pre_btwifi_download_sdio()`) and waits up to `POWERUP_WAIT_MS`
   (30 s) for `download_done`.
3. `wcn_get_chip_name()` → `marlin_get_wcn_chipid()`: `read_l(CHIPID_REG
   = 0x4083c208)`; UWE5622 answers `0x2355B000`..`0x2355B003` (AA..AD).
4. `btwifi_download_firmware()`: reads up to `FIRMWARE_MAX_SIZE`
   (0xe7400) bytes of `wcnmodem.bin` with `kernel_read()` from
   `/lib/firmware/uwe5622/` then `/lib/firmware/` (not `request_firmware()`:
   `is_btwf_in_sysfs` is forced on Allwinner). If the first two bytes are
   0, an 8-byte function mask is skipped. Image formats (`struct head`
   `{char magic[4]; u32 version; u32 img_count;}` followed by entries):
   - `"WCNM"`: `struct imageinfo {char tag[4]; u32 offset; u32 size;}`;
     the entry tagged `MLAA`/`MLAB`/`MLAC`/`MLAD` for the chip id is
     written to `CP_START_ADDR` (0x40500000).
   - `"WCNE"`: `struct combin_img_info {u32 addr; u32 offset; u32 size;}`;
     each entry is written to its `addr`.
   - otherwise the whole buffer is written to `CP_START_ADDR`.
   Writes are `direct_write()` calls of at most `PACKET_SIZE` (32 KiB)
   at increasing addresses.
5. `marlin_start_run()`: `read_l(CP_RESET_REG = 0x40088288)`, clear bit 0
   (`RESET_BIT`), `write_l` it back (releases the chip CPU), `read_l` again.
6. `check_cp_clock_mode()`: `write_l(SPI_BASE_ADDR = 0x408a0000,
   (0x5030 << 16) | BIT(31))`, sleep 4–6 ms, `read_l` it; bit 15 of the
   low half selects "TSX" vs "TCXO" in the log only.
7. `marlin_write_cali_data()`: poll `read_l(SYNC_ADDR = 0x405E73B0)` every
   20 ms until it reads `0xF0F0F0F1` (`SYNC_CALI_WAITING`); then
   `write_l(SYNC_ADDR + 0x1c, sdio_config)` (`sdio_config_en = 1`,
   `wake_host_level_duration_10ms = 2`, see
   `marlin_send_sdio_config_to_cp_vendor()`) and
   `write_l(SYNC_ADDR, 0xF0F0F0F2)` (`SYNC_CALI_WRITE_DONE`). After 11
   polls without the value it gives up silently and continues.
8. `check_cp_ready()`: `direct_read(SYNC_ADDR, 80 bytes)`
   (`struct wcn_sync_info_t`) every 20 ms until `init_status` (first
   word) is `0xF0F0F0FF` (`SYNC_ALL_FINISHED`); after 11 tries it sets
   card-dump status and returns, so step 2 times out after 30 s and
   power-on fails.
9. `runtime_get()`; `get_cp2_version()` sends `"at+spatgetcp2info\r\n\0"`
   (20 bytes) on channel 0 and waits up to 3 s for any reply on channel 13;
   `switch_cp2_log(false)` sends `"at+armlog=0\r\n"` in a 32-byte buffer and
   waits up to 3 s on channel 13. Missing replies only log an error.
10. `complete(download_done)`; `marlin_set_power()` returns 0. With one
    subsystem on, `start_loopcheck()` sends `"at+loopcheck\r\n\0"` on
    channel 0 after 1 s and then every 5 s; no reply on channel 12 within
    3 s triggers `mdbg_assert_interface("loopcheck fail")` (dump/reset path).

Later `start_marlin()` calls only set the subsystem bit; the last
`stop_marlin()` calls `chip_power_off()`.

### Wi-Fi protocol on top

Messages on channels 8/22 start (after the 4-byte bus header) with
`struct sprdwl_cmd_hdr` (`unisocwifi/msg.h`): `common` byte
(`type:3` = 0 cmd / 1 event / 2 data / 3 data-special / 5 pkt-log,
`rsp:1`, `ctx_id:3`), `cmd_id`, `__le16 plen` (including the header),
`__le32 mstime`, `s8 status`, `rsp_cnt`, 2 reserved bytes, payload. A
command response is sent back with the same `cmd_id`, type cmd, and
`status` 0 on success. `sprdwl_core_init()` (`main.c`) issues, in order,
`WIFI_CMD_SYNC_VERSION` (9), `WIFI_CMD_DOWNLOAD_INI` (76, several
chunks), `WIFI_CMD_GET_INFO` (1), then interface setup commands. Data TX
on channel 10 needs credits: the firmware grants them with event
`WIFI_EVENT_SDIO_FLOWCON` (0xB3) whose first 4 payload bytes are per-AC
credit counts (`sprdwl_sdio_process_credit()`, `tx_msg.c`), or in the
`rsvd5` byte of RX data-special descriptors.

## Optimizations

Changes made for memory and CPU cost on the Orange Pi Zero 3 (1-4 GB RAM,
4 x A53, SDIO 2.0 link). None was measured on a board: the numbers below are
computed from the sources, and "Needs a board" says what to check.

| Item | Before | After | Why |
|---|---|---|---|
| Wi-Fi TX message pool (`SPRDWL_TX_QOS_POOL_SIZE`, `wl_core.h`) | 20000 `struct sprdwl_msg_buf` allocated at load | 4096 | The SDIO data channel has 800 buffers (`sdiohal_ctl.c`); the pool also grows on demand past 80% (`tx_msg.c`). About 2 MB less RAM and 16000 fewer `kzalloc()` calls at `modprobe`. |
| Wi-Fi RX message lists (`SPRDWL_RX_MSG_NUM`, two lists) | 2 x 20000 | 2 x 2048 | One entry is a chain of SDIO buffers handed over by the RX thread, not a packet. About 4 MB less RAM. |
| Wi-Fi TX thread priority (`tx_msg.c`) | `set_user_nice(-20)` | `-5` | -20 is the highest CFS weight and competes with the SDIO threads; the bus is the bottleneck, not CPU. |
| `sdiohal` TX/RX threads | `sched_set_fifo_low()` | unchanged | They sleep on semaphores, so they do not spin; FIFO keeps bus latency low. |
| Busy waits in process context (`wcn_boot.c`, `wcn_dump.c`) | `mdelay(1)`, `udelay(200/300)` | `usleep_range()` | All run under a mutex next to sleeping SDIO register accesses; they spun a core for 1 ms to 600 us per call. `slp_sdio.c` keeps `udelay(65)`: it may run in atomic context. |
| Firmware liveness check (`loopcheck.c`) | AT command every 5 s | every 15 s, `round_jiffies_relative()` | Fewer SDIO wake-ups while idle. A dead firmware is still reported through the assert channel; the check only bounds detection of a silent hang to 15 s + 3 s. |
| `at_cmd_send()` | leaked its buffer when the bus list could not be allocated or pushed | frees it | Found while reading the loopcheck path. |

Looked at and left alone:

- Firmware load: on this build `is_btwf_in_sysfs` is forced to 1, so the
  firmware is read once with `kernel_read()` into a vmalloc buffer of
  `FIRMWARE_MAX_SIZE` (0xe7400) and, only when the image is larger than that,
  once more at the real size. The extra `vmalloc()` + `memcpy()` backup in
  `marlin_request_firmware()` belongs to the `request_firmware()` branch,
  which never runs here.
- Wi-Fi power save: the vendor clears `WIPHY_FLAG_PS_ON_BY_DEFAULT`
  (`cfg80211.c`), so power save is off until user space enables it with
  `iw dev wlan0 set power_save on`. Turning it on by default would save power
  but changes latency and association behaviour of the firmware; it is not
  changed without a board test. `disable_powersave` is a module parameter.

Needs a board: Wi-Fi throughput (iperf3 both ways) and `free -m` before and
after for the pool sizes; TX queue drops (`tx timeout drop` in dmesg) under
load; idle wake-ups and current with the 15 s loopcheck; `rmmod`/`modprobe`
loop.

## Bluetooth design note: HCI over serdev

Today `sprdbt_tty.ko` registers `ttyBT0`; user space must run `hciattach`
(H4, 115200 nominal, unused baud rate) to turn it into an `hciN`. All the
"serial" parameters are fiction: the data goes to SDIO channel 3/17.

The in-kernel way is `drivers/bluetooth/hci_uart` or, better, a driver that
registers a `struct hci_dev` directly (as `btusb`, `btmtksdio` do):

- `hci_dev->open/close` call `start_marlin(MARLIN_BLUETOOTH)` /
  `stop_marlin()`, replacing the rfkill hook in `rfkill.c`.
- `hci_dev->send(skb)` prepends the 4-byte bus header and pushes on channel 3
  (what `marlin_sdio_write()` does); the RX callback on channel 17 passes the
  packet to `hci_recv_frame()` after reading the H4 packet type byte, which
  is already the first byte of the payload.
- The firmware needs vendor commands before use (`woble.c`, sleep mode, MAC);
  they go in `hdev->setup`.

serdev is not applicable: it describes a UART child device in the device tree,
and this chip has no UART to the host. A `serdev` controller shim would only
rebuild the TTY layer in kernel. So the recommendation is a direct `hci_dev`
driver, about 300 lines replacing `tty.c`, `rfkill.c`, most of `lpm.c`.

Not done in this phase: it changes the user-visible interface (no `ttyBT0`,
no `hciattach` service), needs the Armbian image's BT service changed with it,
and must be tested with a real controller. Steps: (1) add the `hci_dev`
driver behind a module parameter next to the TTY one, (2) switch the image's
service to bluetoothd only, (3) remove the TTY path after a release.

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

The five warnings that were accepted at first (unchecked `kstrtol()`, the
big-endian `h_proto` comparison, two arrays of flexible structs) were fixed
in Phase 2, and `.github/known-warnings.txt` is now empty.

### Phase 2 — restructure (done except as noted)

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

Phase 1 removed and reformatted much of the tree, so merging Armbian's
repository now conflicts. Check its new commits and port the fixes that touch
code still here by hand (or `git cherry-pick` and resolve):

```sh
git remote add armbian https://github.com/armbian/uwe5622
git fetch armbian
git log --oneline HEAD..armbian/master
```

After Phase 1 the trees diverge too much to merge; fixes get cherry-picked by
hand, which is why `reference/` keeps Armbian's historical per-kernel patches.
