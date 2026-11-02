# Testing

There is no UWE5622 hardware in CI, and QEMU has no Allwinner H616/H618
machine and no SDIO device model. The tests therefore cover what can be
checked without the chip: static analysis, the device tree against the real
Zero 3 DTB, the modules under a debug kernel, unit tests of the pure
helpers, and a **simulated chip** that plays the firmware over the driver's
transport interface. All of it is `.github/workflows/test.yml`
(push, pull request, Mondays 04:41 UTC, manual dispatch with an optional
kernel version; default is the newest 6.18.x longterm).

Results are TAP (`ok` / `not ok`), summarised per job in the step summary by
`tests/lib/tap-summary.sh`. Logs, TAP files, kmemleak reports and traces are
uploaded as artifacts (`qemu-log-*`, `static-*`, `dt`, `metrics-*`).

## Jobs and what they prove

| Job | Proves | Cannot prove |
|---|---|---|
| `static (clang)` | the modules build with `W=1` under clang; per-class warning counts | runtime behaviour |
| `static (smatch)` | smatch findings by class | same |
| `static (cocci)` | the kernel's coccinelle scripts | same |
| `static (cppcheck)` | cppcheck message ids | same |
| `device tree` | the overlay compiles with the kernel's dtc, applies to the real `sun50i-h618-orangepi-zero3.dtb`, enables `mmc1` with the intended pwrseq (PG18, `ext_clock`), regulators and supplies, changes nothing else, and `dt-validate` reports nothing new; Armbian's patch in `dts/patches/` still applies | that the wiring is right on the board |
| `qemu kernel` | a 6.18 arm64 kernel (debug and perf flavour) builds and the three modules plus the test modules build against it | |
| `qemu ... lifecycle` | load, parameters, `transport=external`, unload, 20x (5x with Wi-Fi) load/unload loops with no chip: no splats, no kmemleak reports | behaviour with a chip |
| `qemu ... kunit` | KUnit suites for the ini parser, regdomain lookup and the WCN log ring | |
| `qemu ... sim` | probe, scan, connect, disconnect, repeated sessions, fault injection and surprise removal against the simulated chip, KASAN, UBSAN, lockdep, kmemleak and debugobjects clean | the real firmware protocol, RF, timing, SDIO |
| `qemu perf ... metrics` | memory and idle cost of the modules; see below | |

"Debug" is KASAN (generic, inline), UBSAN, KFENCE, lockdep, kmemleak,
debugobjects, atomic-sleep and hung-task checks (`tests/qemu/config/debug.config`).
"Perf" has none of them so numbers are comparable with a real kernel.

The guest is QEMU `virt`, 4 Cortex-A53 cores (the Zero 3's CPU), 1 GB or 2 GB,
under TCG: KVM cannot emulate a different CPU model. A Wi-Fi probe takes
20-30 s under KASAN for that reason.

### Splats

`tests/qemu/run.sh` attributes every kernel log line matching
`BUG: WARNING: KASAN: UBSAN: lockdep ... ODEBUG: Call trace:` to the guest
phase it appeared in (`@@PHASE name` markers written to `/dev/kmsg`) and
emits one TAP test per phase, "no kernel splats during <phase>".

## The simulated chip

`tests/sim/uwe5622_sim.ko` is loaded after `uwe5622_bsp_sdio transport=external`
and registers with `wcn_bus_register_transport()`
(`docs/ARCHITECTURE.md`, "Transport interface"). It implements, as the
firmware would:

- the boot handshake: chip id `0x2355B001`, CP reset, calibration sync
  word, "all finished", AT replies for loopcheck, cp2 info, log switch
- Wi-Fi commands on channel 8, answered on channel 22 with the same
  `cmd_id`/`mstime`: GET_INFO carries MAC, capabilities, `TX_NO_CREDIT`;
  SCAN produces beacon frames of three APs (`uwe-sim-open` ch 1,
  `uwe-sim-two` ch 6, `uwe-sim-three` ch 11) and SCAN_DONE; CONNECT gives a
  connect event, DISCONNECT a disconnect event; GET_STATION a rate and signal
- TX data on channel 10 is counted and handed back

`/sys/module/uwe5622_sim/stats` shows counters. Faults are written to
`/sys/module/uwe5622_sim/parameters/inject`: `silent`, `talk`, `drop=<id>`,
`fail_push`, `short`, `badlen`, `garbage`, `unknown_event`,
`truncated_connect`, `truncated_scan`, `scan_flood`, `bad_ctx`.
`rx_delay_ms` delays every command answer.

Limitations: there is no RX data path (frames sent by the host are counted,
not looped back, so there is no ping), no encryption handshake (only open
networks), no BT HCI, no firmware download verification, and the credit
scheme is disabled. The message layouts come from reading the driver, not
from Unisoc documentation.

## Metrics

The perf job writes `metrics.json` (artifact `metrics-perf`) and a table in
the step summary:

- memory pinned by loading the modules (unreclaimable slab, vmalloc incl.
  module text, per-CPU, kernel stacks; `MemAvailable` drop; top slab caches)
- memory still pinned after rmmod
- load time per module, `.text/.data/.bss` of the `.ko` files
- idle interrupts per second, driver timers, hrtimers and work items per
  second (from tracepoints, attributed by callback symbol), CPU time of
  kernel threads started by the modules

`tests/qemu/metrics.py compare` diffs against the newest unexpired
`metrics-perf` artifact of a main run and fails the job only if the pinned
module memory grows by more than 20 % and 64 kB. Everything else is
informational. With no chip the numbers are the cost of loading; the pools
the driver sizes at chip bring-up show only in the simulated-chip runs.

## Known driver bugs

`tests/known-failures.txt` lists tests that fail because of a driver bug;
they run as `not ok # TODO` and do not fail CI, and an unexpected pass is
flagged so the entry gets removed. Bugs found by these tests and since
fixed: the OTT platform-device leak, the `prepare_addba()` index overflow,
the ini parser overruns, `mdbg_ring_write_ext()` running past the ring.

## Running a job by hand

Needs an arm64 Linux machine (the guest kernel is built natively) with
`build-essential flex bison bc libssl-dev libelf-dev cpio busybox-static iw
rfkill wpasupplicant qemu-system-arm python3`.

```sh
W=/tmp/w
tests/qemu/build-kernel.sh 6.18.60 $W debug
tests/qemu/build-initramfs.sh $W/out-debug/modules $W/out-debug/initramfs.cpio.gz
tests/qemu/run.sh $W/out-debug/Image $W/out-debug/initramfs.cpio.gz 1024 sim /tmp/out 2400
cat /tmp/out/qemu.tap
```

`tests` is a comma-separated list of `tests/qemu/guest/*.sh` scripts
(`lifecycle`, `kunit`, `sim`, `metrics`). Static: `tests/static/run.sh clang
6.18.60 $W`. Device tree: `tests/dt/check-overlay.sh 6.18.60 $W`.

## Findings from the simulated chip

- **TX data completion crashes.** The first data frame the host sends
  (with IPv6 on, the MLD report when `wlan0` comes up) is handed back by the
  transport with `pop_link()` as the contract requires, and
  `sprdwl_handle_pop_list()` (`unisocwifi/wl_intf.c`) then reports a KASAN
  slab-use-after-free reading `mbuf->buf - 8` of the skb it is completing, at
  the head/tail lookup at its start, followed by an oops. The sim test keeps IPv6
  off and sends no frames; `uwe.tx_data=1` on the kernel command line enables
  a test that does. Not yet determined whether the driver frees the skb on
  another path first or the sim breaks an unwritten rule of the SDIO transport.
- **Seam.** The core registers its channels while it probes; an external
  transport that registers afterwards used to miss them. Fixed by 39f12dc
  (replay in `wcn_bus_register_transport()`).
- No test of the data path (RX, ping, throughput per Mbit) exists until the
  above is understood and the sim grows an RX path with the driver's RX
  descriptor layout.
