#!/bin/sh
# Wi-Fi against the simulated chip (tests/sim/uwe5622_sim.ko): probe, scan,
# connect, disconnect, repeated cycles, fault injection, surprise removal.
. /tests/lib.sh
BSP=uwe5622_bsp_sdio WIFI=sprdwl_ng SIM=uwe5622_sim
IFN=wlan0
CYCLES=$(cmdline_get uwe.sim_cycles)
CYCLES=${CYCLES:-3}
INJ=/sys/module/$SIM/parameters/inject
stat() { sed -n "s/.* $1 \([0-9]*\).*/\1/p" /sys/module/$SIM/stats 2>/dev/null; }

# bring_up: load bsp (external transport), sim, wifi; wait for wlan0
bring_up() {
	load $BSP transport=external || return 1
	load $SIM || return 1
	load $WIFI || return 1
	i=0
	while [ $i -lt 60 ] && [ ! -e /sys/class/net/$IFN ]; do sleep 1; i=$((i + 1)); done
	[ -e /sys/class/net/$IFN ]
}
tear_down() {
	ip link set $IFN down 2> /dev/null
	unload_all
}
scan_has() {
	timeout 25 iw dev $IFN scan 2> /tmp/scan.err | grep -q "SSID: $1" && return 0
	diag "scan for $1 failed: $(cat /tmp/scan.err)"
	dmesg | grep -i -E "sprdwl|scan|uwe5622_sim" | tail -n 15 | while IFS= read -r l; do diag "$l"; done
	return 1
}


kml_reset
phase sim-probe
check "sim: bsp (external) + sim + wifi load and wlan0 appears" bring_up
if [ ! -e /sys/class/net/$IFN ]; then
	nok "sim: wlan0 present, remaining sim tests skipped" "$(dmesg | tail -n 40)"
	tear_down
	exit 0
fi
diag "sim stats after probe: $(cat /sys/module/$SIM/stats)"
check "sim: GET_INFO answered (wiphy registered)" sh -c 'ls /sys/class/ieee80211 | grep -q .'
eq "sim: wlan0 MAC from the simulated firmware" "02:55:57:45:aa:01" "$(cat /sys/class/net/$IFN/address)"
check "sim: iw dev lists wlan0" sh -c "iw dev | grep -q $IFN"
check "sim: iw phy lists bands" sh -c 'iw phy | grep -q "Band 1"'
check "sim: ip link set wlan0 up" ip link set $IFN up
check "sim: wlan0 up (operstate/flags)" sh -c "ip link show $IFN | grep -q UP"

phase sim-scan
# diagnostics for the first scan: driver debug log, where iw is blocked
echo 4 > /sys/module/$WIFI/parameters/debug_level
T=/sys/kernel/tracing
echo 1 > $T/events/cfg80211/enable 2> /dev/null
echo 1 > $T/tracing_on 2> /dev/null
iw event -t > /tmp/ev.out 2>&1 &
EVP=$!
timeout 25 iw dev $IFN scan > /tmp/scan.out 2>&1 &
SCANP=$!
sleep 8
for p in $(pidof iw); do
	diag "iw $p wchan: $(cat /proc/$p/wchan 2>&1) stack: $(cat /proc/$p/stack 2>&1 | tr '\n' ';')"
done
diag "scan dump while iw waits: $(timeout 10 iw dev $IFN scan dump 2>&1 | grep -c 'SSID:') SSIDs"
echo 1 > /proc/sys/kernel/sysrq
echo w > /proc/sysrq-trigger
for s in /proc/[0-9]*/stat; do
	p=${s#/proc/}
	p=${p%/stat}
	case "$(cut -d' ' -f3 "$s" 2> /dev/null)" in D) diag "D-state $p $(cat /proc/$p/comm): $(cat /proc/$p/stack 2>&1 | tr '\n' ';')" ;; esac
done
wait $SCANP
echo 1 > /sys/module/$WIFI/parameters/debug_level
kill $EVP 2> /dev/null
diag "iw event: $(head -c 800 /tmp/ev.out | tr '\n' '|')"
tail -n 40 $T/trace 2> /dev/null | while IFS= read -r l; do diag "trace: $l"; done
echo 0 > $T/events/cfg80211/enable 2> /dev/null
diag "first scan output: $(head -c 600 /tmp/scan.out | tr '\n' '|')"
dmesg | tail -n 150 > "$ATT/scan-debug.txt"
check "sim: scan sees uwe-sim-open" scan_has uwe-sim-open
check "sim: scan sees uwe-sim-two" sh -c 'timeout 25 iw dev wlan0 scan | grep -q "SSID: uwe-sim-two"'
check "sim: scan sees uwe-sim-three on channel 11 (2462 MHz)" sh -c 'timeout 25 iw dev wlan0 scan | grep -A3 "^BSS 02:55:57:45:00:03" | grep -q "freq: 2462"'
check "sim: scan result carries the signal level" sh -c 'timeout 25 iw dev wlan0 scan | grep -q "signal: -40"'
[ "$(stat scans)" -ge 1 ] && ok "sim: firmware saw SCAN commands ($(stat scans))" || nok "sim: firmware saw SCAN commands"

phase sim-connect
check "sim: iw connect to uwe-sim-open" sh -c "timeout 60 iw dev $IFN connect uwe-sim-open"
sleep 3
check "sim: link reports connected" sh -c "iw dev $IFN link | grep -q 'Connected to 02:55:57:45:00:01'"
eq "sim: carrier up after connect" 1 "$(cat /sys/class/net/$IFN/carrier 2>&1)"
check "sim: station info (signal)" sh -c "iw dev $IFN station get 02:55:57:45:00:01 | grep -q signal"
check "sim: iw disconnect" iw dev $IFN disconnect
sleep 2
check "sim: link reports not connected" sh -c "iw dev $IFN link | grep -q 'Not connected'"
eq "sim: carrier down after disconnect" 0 "$(cat /sys/class/net/$IFN/carrier 2>&1)"
diag "sim stats: $(cat /sys/module/$SIM/stats)"
tear_down
check "sim: everything unloads" no_driver_modules
check_not "sim: wlan0 gone after unload" test -e /sys/class/net/$IFN
kml_check "kmemleak: nothing leaked by a simulated session" sim-session

# --- repeated sessions ---------------------------------------------------------
phase sim-cycles
fails=0
n=0
while [ $n -lt "$CYCLES" ]; do
	n=$((n + 1))
	bring_up || { fails=$((fails + 1)); echo "cycle $n: bring_up failed"; }
	ip link set $IFN up
	scan_has uwe-sim-open || { fails=$((fails + 1)); echo "cycle $n: scan failed"; }
	timeout 60 iw dev $IFN connect uwe-sim-open || fails=$((fails + 1))
	sleep 2
	iw dev $IFN link | grep -q Connected || { fails=$((fails + 1)); echo "cycle $n: not connected"; }
	iw dev $IFN disconnect
	tear_down
done
if [ $fails = 0 ]; then ok "${CYCLES}x load, scan, connect, disconnect, unload"; else nok "${CYCLES}x load, scan, connect, disconnect, unload" "$fails failures"; fi
kml_check "kmemleak: nothing leaked by the repeated sessions" sim-cycles

# --- fault injection ---------------------------------------------------------------
phase sim-faults
bring_up
ip link set $IFN up
alive() { [ -e /sys/class/net/$IFN ] && scan_has uwe-sim-open; }
for f in short badlen garbage unknown_event truncated_connect truncated_scan bad_ctx scan_flood; do
	echo "$f" > $INJ
	sleep 2
	check "fault $f: driver survives and still scans" alive
done
# transport error on the next send: the driver must report it, not crash
echo fail_push > $INJ
timeout 25 iw dev $IFN scan > /dev/null 2>&1
sleep 1
check "fault fail_push: driver still alive" alive
# firmware stops answering: commands time out, nothing hangs forever
echo silent > $INJ
timeout 120 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
ok "fault silent: connect returned (rc=$?) instead of hanging"
echo talk > $INJ
sleep 2
check "fault silent: driver recovers when the firmware talks again" alive
# one command id (13 = DISCONNECT) never answered
echo drop=13 > $INJ
timeout 30 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
timeout 30 iw dev $IFN disconnect > /dev/null 2>&1
echo drop=-1 > $INJ
check "fault drop=13: driver still alive" alive
diag "sim stats after faults: $(cat /sys/module/$SIM/stats)"

phase sim-surprise
# the chip disappears while Wi-Fi is up and associated
ip link set $IFN up
timeout 60 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
sleep 2
check "surprise removal: rmmod $SIM while wifi is loaded" rmmod $SIM
sleep 1
ip link set $IFN down 2> /dev/null
ok "surprise removal: wlan0 survived link down without the transport"
tear_down
check "surprise removal: remaining modules unload" no_driver_modules
kml_check "kmemleak: nothing leaked by the fault tests" sim-faults

# --- TX data completion ---------------------------------------------------------------------
# IPv6 is on, so wlan0 sends MLD/RS frames as soon as it is up; add an IPv4
# address and ping so ARP goes out too. Every frame must reach the chip's
# data channel and its completion (pop_link, buffer and message recycling)
# must be clean: KASAN and kmemleak watch it.
phase sim-txdata
bring_up
ip link set $IFN up
timeout 25 iw dev $IFN scan > /dev/null 2>&1
timeout 60 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
sleep 2
ip addr add 10.99.0.2/24 dev $IFN
n=0
while [ $n -lt 20 ]; do
	n=$((n + 1))
	ping -c 1 -W 1 10.99.0.1 > /dev/null 2>&1
done
sleep 3
f=$(stat tx_frames)
[ "${f:-0}" -ge 20 ] && ok "sim: TX data frames reached the simulated chip ($f)" || nok "sim: TX data frames reached the simulated chip" "tx_frames=$f"
check "sim: wlan0 still there after TX traffic" test -e /sys/class/net/$IFN
tear_down
kml_check "kmemleak: nothing leaked by TX traffic" sim-txdata
