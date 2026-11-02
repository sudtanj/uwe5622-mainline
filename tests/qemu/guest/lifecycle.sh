#!/bin/sh
# Module lifecycle with no chip present: every module must load, fail to
# find hardware gracefully, unload, and leave nothing behind, many times.
. /tests/lib.sh
BSP=uwe5622_bsp_sdio WIFI=sprdwl_ng BT=sprdbt_tty
LOOPS=$(cmdline_get uwe.loops)
LOOPS=${LOOPS:-20}

kml_reset

# --- single load, inspect, unload ------------------------------------------
phase lifecycle-load
check "insmod $BSP" load $BSP
eq "$BSP: transport parameter defaults to sdio" sdio "$(cat /sys/module/$BSP/parameters/transport 2>&1)"
check "uwe_bsp platform device bound to its driver" test -e /sys/bus/platform/drivers/uwe_bsp/uwe_bsp
t0=$(now_ns)
check "insmod $WIFI (no chip: probe fails, module stays)" load $WIFI
t1=$(now_ns)
diag "insmod $WIFI took $(( (t1 - t0) / 1000000 )) ms (includes the 3 s SDIO card-detect timeout)"
check "$WIFI: unisoc_wifi platform driver registered" test -d /sys/bus/platform/drivers/unisoc_wifi
check_not "no wlan netdev without a chip" sh -c 'ls /sys/class/net | grep -q wlan'
check_not "no wiphy without a chip" sh -c 'ls /sys/class/ieee80211 2>/dev/null | grep -q .'
check "insmod $BT" load $BT
check "$BT: ttyBT device created" sh -c 'ls /sys/class/tty | grep -q ^ttyBT'
check "$BT: Bluetooth rfkill switch registered" \
	sh -c 'grep -lx bluetooth /sys/class/rfkill/*/type'
for m in $BSP $WIFI $BT; do
	diag "$m parameters: $(cd /sys/module/$m/parameters 2>/dev/null && for p in *; do printf '%s=%s ' "$p" "$(cat "$p" 2>/dev/null)"; done)"
done
if [ -e /sys/class/rfkill/rfkill0 ]; then
	check "rfkill: block Bluetooth with no chip" rfkill block bluetooth
	check "rfkill: unblock Bluetooth with no chip" rfkill unblock bluetooth
fi
check "rmmod $BT" rmmod $BT
check "rmmod $WIFI" rmmod $WIFI
check "rmmod $BSP" rmmod $BSP
check "no driver module left loaded" no_driver_modules
check_not "rfkill switch gone after rmmod" sh -c 'grep -lx bluetooth /sys/class/rfkill/*/type'
check_not "ttyBT gone after rmmod" sh -c 'ls /sys/class/tty | grep -q ^ttyBT'
check_not "uwe_bsp platform device gone after rmmod" test -e /sys/bus/platform/devices/uwe_bsp
check_not "unisoc_wifi platform device gone after rmmod" test -e /sys/bus/platform/devices/unisoc_wifi
check_not "mtty platform device gone after rmmod" test -e /sys/bus/platform/devices/mtty
kml_check "kmemleak: nothing leaked by one load/unload cycle" single

# --- module parameters -----------------------------------------------------
phase lifecycle-params
load $BSP
check "insmod $WIFI debug_level=4 disable_powersave=1 wfa_cap=1" \
	load $WIFI debug_level=4 disable_powersave=1 wfa_cap=1
P=/sys/module/$WIFI/parameters
eq "$WIFI debug_level reads back 4" 4 "$(cat $P/debug_level 2>&1)"
eq "$WIFI disable_powersave reads back 1" 1 "$(cat $P/disable_powersave 2>&1)"
eq "$WIFI wfa_cap reads back 1" 1 "$(cat $P/wfa_cap 2>&1)"
check "$WIFI debug_level writable at runtime" sh -c "echo 2 > $P/debug_level && grep -qx 2 $P/debug_level"
check "$WIFI tcp_ack_drop_cnt accepts 50" sh -c "echo 50 > $P/tcp_ack_drop_cnt && grep -qx 50 $P/tcp_ack_drop_cnt"
check_not "$WIFI tcp_ack_drop_cnt rejects 0" sh -c "echo 0 > $P/tcp_ack_drop_cnt"
check_not "$WIFI tcp_ack_drop_cnt rejects 100" sh -c "echo 100 > $P/tcp_ack_drop_cnt"
eq "$WIFI tcp_ack_drop_cnt unchanged after rejected writes" 50 "$(cat $P/tcp_ack_drop_cnt 2>&1)"
check "$WIFI tcp_ack_drop_enable toggles with no device" \
	sh -c "echo 0 > $P/tcp_ack_drop_enable && echo 1 > $P/tcp_ack_drop_enable"
rmmod $WIFI
rmmod $BSP
check "insmod $BSP transport=external" load $BSP transport=external
eq "$BSP transport reads back external" external "$(cat /sys/module/$BSP/parameters/transport 2>&1)"
check "insmod $WIFI with transport=external and no transport registered" load $WIFI
check_not "no wlan netdev without a transport" sh -c 'ls /sys/class/net | grep -q wlan'
check "insmod $BT with transport=external and no transport registered" load $BT
unload_all
check "no driver module left after the parameter tests" no_driver_modules
kml_check "kmemleak: nothing leaked by the parameter tests" params

# --- repeated load/unload ---------------------------------------------------
# cycle "label" module...: load in order, unload in reverse, $LOOPS times
cycle() {
	label=$1
	shift
	phase "lifecycle-loop-$label"
	fails=0
	i=0
	while [ $i -lt "$LOOPS" ]; do
		i=$((i + 1))
		for m in "$@"; do load "$m" > /dev/null 2>&1 || { fails=$((fails + 1)); echo "loop $i: insmod $m failed"; }; done
		rev=""
		for m in "$@"; do rev="$m $rev"; done
		for m in $rev; do rmmod "$m" > /dev/null 2>&1 || { fails=$((fails + 1)); echo "loop $i: rmmod $m failed"; }; done
		no_driver_modules || { fails=$((fails + 1)); echo "loop $i: modules left: $(lsmod)"; unload_all; }
	done
	if [ $fails = 0 ]; then ok "${LOOPS}x load/unload: $label"; else nok "${LOOPS}x load/unload: $label" "$fails failures"; fi
}
cycle "$BSP" $BSP
cycle "$BSP + $WIFI" $BSP $WIFI
cycle "$BSP + $BT" $BSP $BT
cycle "all three" $BSP $WIFI $BT
phase lifecycle-kmemleak
kml_check "kmemleak: nothing leaked by the load/unload loops" loops
