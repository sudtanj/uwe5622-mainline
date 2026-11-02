#!/bin/sh
# Soak under the debug kernel with the simulated chip: scan / connect /
# ping / disconnect loops for uwe.soak seconds (default 600), CPU hotplug
# and s2idle suspend/resume while associated, a final unload. KASAN, lockdep,
# kmemleak and the hung-task detector watch throughout; the kernel log is
# checked per phase by run.sh.
. /tests/lib.sh
BSP=uwe5622_bsp_sdio WIFI=sprdwl_ng SIM=uwe5622_sim IFN=wlan0
SECS=$(cmdline_get uwe.soak)
SECS=${SECS:-600}
alive() { [ -e /sys/class/net/$IFN ] && timeout 60 iw dev $IFN scan 2> /dev/null | grep -q "SSID: uwe-sim-open"; }

kml_reset
phase soak-up
load $BSP transport=external && load $SIM && load $WIFI
i=0
while [ $i -lt 90 ] && [ ! -e /sys/class/net/$IFN ]; do sleep 1; i=$((i + 1)); done
[ -e /sys/class/net/$IFN ] || { nok "soak: wlan0 appeared"; exit 0; }
ip link set $IFN up
ip addr add 10.99.0.2/24 dev $IFN

phase soak-loop
start=$(awk '{print int($1)}' /proc/uptime)
n=0 fails=0
while [ $(( $(awk '{print int($1)}' /proc/uptime) - start )) -lt "$SECS" ]; do
	n=$((n + 1))
	alive || { fails=$((fails + 1)); echo "iteration $n: scan failed"; }
	timeout 60 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
	sleep 1
	iw dev $IFN link | grep -q Connected || { fails=$((fails + 1)); echo "iteration $n: not connected"; }
	k=0
	while [ $k -lt 5 ]; do k=$((k + 1)); ping -c 1 -W 1 10.99.0.1 > /dev/null 2>&1; done
	iw dev $IFN station dump > /dev/null 2>&1
	iw dev $IFN disconnect > /dev/null 2>&1
	sleep 1
done
diag "soak: $n iterations in $SECS s, $fails failures; $(cat /sys/module/$SIM/stats)"
[ $fails = 0 ] && ok "soak: $n scan/connect/ping/disconnect iterations over ${SECS}s" || nok "soak: $n scan/connect/ping/disconnect iterations over ${SECS}s" "$fails failures"

phase soak-hotplug
timeout 60 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
if [ -w /sys/devices/system/cpu/cpu3/online ]; then
	cyc=0 bad=0
	while [ $cyc -lt 10 ]; do
		cyc=$((cyc + 1))
		echo 0 > /sys/devices/system/cpu/cpu3/online || bad=$((bad + 1))
		ping -c 1 -W 1 10.99.0.1 > /dev/null 2>&1
		echo 1 > /sys/devices/system/cpu/cpu3/online || bad=$((bad + 1))
		ping -c 1 -W 1 10.99.0.1 > /dev/null 2>&1
	done
	[ $bad = 0 ] && ok "soak: 10 CPU offline/online cycles under traffic" || nok "soak: 10 CPU offline/online cycles under traffic" "$bad failures"
	check "soak: driver alive after hotplug" alive
else
	skip "soak: CPU hotplug" "cpu3 cannot be taken offline"
fi

phase soak-suspend
if [ -w /sys/class/rtc/rtc0/wakealarm ] && grep -q freeze /sys/power/state; then
	cyc=0 bad=0
	while [ $cyc -lt 3 ]; do
		cyc=$((cyc + 1))
		echo 0 > /sys/class/rtc/rtc0/wakealarm
		echo +5 > /sys/class/rtc/rtc0/wakealarm
		echo freeze > /sys/power/state || bad=$((bad + 1))
		sleep 2
	done
	[ $bad = 0 ] && ok "soak: 3 s2idle suspend/resume cycles while associated" || nok "soak: 3 s2idle suspend/resume cycles while associated" "$bad failed writes to /sys/power/state"
	check "soak: driver alive after resume" alive
else
	skip "soak: s2idle suspend/resume" "no rtc wakealarm or no freeze state"
fi

phase soak-down
ip link set $IFN down
unload_all
check "soak: everything unloads" no_driver_modules
kml_check "kmemleak: nothing leaked by the soak" soak
