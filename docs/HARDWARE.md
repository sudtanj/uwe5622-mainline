# Hardware notes: Orange Pi Zero 3

Everything a kernel needs to bring the on-board UWE5622 up on the Zero 3, and
how to test a build on the board.

## Wiring (from the vendor and Armbian device trees)

| Signal | H618 pin / block | Notes |
|---|---|---|
| SDIO data/clock/cmd | `mmc1` (`mmc@4021000`), `mmc1_pins` | 4-bit bus, 1.8 V I/O (`mmc-ddr-1_8v`) |
| Chip reset (`WL_REG_ON`) | **PG18**, active low | Released by `mmc-pwrseq-simple`, 200 ms post-power-on delay |
| 32 kHz sleep clock | `rtc` clock output 1 (`osc32k-out`) | Also via the power sequence |
| 3.3 V supply | fixed regulator from 5 V | Always on |
| 1.8 V I/O supply | fixed regulator from the 3.3 V | Always on |
| Bluetooth | over the same SDIO link | No UART; `sprdbt_tty` exposes HCI as a TTY |

The driver is built **without** `CONFIG_WCN_PARSE_DTS`, so it does not need a
node of its own. Enabling `mmc1` with the power sequence (the overlay in `dts/`
or the patch in `dts/patches/`) is all the DT work.

## Firmware

Not included in this repository; the files are Unisoc's and carry no
redistribution licence. Armbian ships them in its `armbian-firmware` package,
sourced from <https://github.com/armbian/firmware> (`uwe5622/`):

| File | Install path | Purpose |
|---|---|---|
| `wcnmodem.bin` | `/lib/firmware/uwe5622/wcnmodem.bin` (fallback `/lib/firmware/`) | Chip firmware uploaded at power-up |
| `wifi_2355b001_1ant.ini` | `/lib/firmware/wifi_2355b001_1ant.ini` | Board RF tuning read by the Wi-Fi module |

Bluetooth additionally needs a userspace tool to attach the TTY to BlueZ.
Armbian uses a prebuilt `hciattach_opi` binary from the vendor BSP plus the
`aw859a-bluetooth.service` unit. Replacing that with an in-kernel HCI
transport is a Phase 2 item (see `ARCHITECTURE.md`).

## Testing a CI build on the board

Each CI run uploads `modules-linux-<version>` with the three `.ko` files and the
compiled overlay. The modules must match the running kernel exactly
(`uname -r` and the vermagic printed in the job log), which is the case when
the board runs a plain upstream kernel of that version.

```sh
# on the board, as root
mkdir -p /lib/modules/$(uname -r)/updates/uwe5622
cp *.ko /lib/modules/$(uname -r)/updates/uwe5622/
depmod -a
modprobe uwe5622_bsp_sdio && modprobe sprdwl_ng
dmesg | grep -iE 'wcn|sprd|marlin|sdio|mmc1' | tail -50
ip link            # expect wlan0
iw dev wlan0 scan | grep SSID | head
```

Unload order is the reverse: `modprobe -r sprdbt_tty sprdwl_ng uwe5622_bsp_sdio`.

Serial console (3-pin UART0 header, 115200 8N1) is strongly recommended while
testing: a crash in a kernel module takes the network with it, and the console
is the only place the oops is visible.

## What to capture for a bug report

- Full `dmesg` from boot to the failure (serial log preferred)
- `uname -r`, kernel config if custom, the CI run that produced the modules
- `cat /sys/kernel/debug/mmc1/ios` (SDIO clock/bus settings)
- For Wi-Fi protocol problems: `iw event -t` output during the failure
