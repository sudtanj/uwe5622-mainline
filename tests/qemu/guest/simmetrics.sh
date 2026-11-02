#!/bin/sh
# Resource cost of the driver with a (simulated) chip up and associated, on
# the perf kernel: memory pinned by bring-up (pools sized at chip start show
# here, not in metrics.sh), and idle wakeups / kthread CPU while associated.
. /tests/lib.sh
. /tests/measure.sh
BSP=uwe5622_bsp_sdio WIFI=sprdwl_ng SIM=uwe5622_sim IFN=wlan0
IDLE=$(cmdline_get uwe.idle)
IDLE=${IDLE:-60}

phase simmetrics-baseline
sleep 5
kthreads > /tmp/kt0
meminfo_snap /tmp/s0

phase simmetrics-up
load $BSP transport=external && load $SIM && load $WIFI
i=0
while [ $i -lt 90 ] && [ ! -e /sys/class/net/$IFN ]; do sleep 1; i=$((i + 1)); done
if [ ! -e /sys/class/net/$IFN ]; then
	nok "simmetrics: wlan0 appeared" "$(dmesg | tail -n 20)"
	exit 0
fi
ip link set $IFN up
timeout 60 iw dev $IFN connect uwe-sim-open > /dev/null 2>&1
sleep 5
meminfo_snap /tmp/s1
mem_delta sim.up /tmp/s0 /tmp/s1
kthreads > /tmp/kt1
new=$(comm -13 /tmp/kt0 /tmp/kt1 | tr '\n' ' ')
n=0
for pid in $new; do
	n=$((n + 1))
	diag "kernel thread: $pid $(cat /proc/$pid/comm 2> /dev/null)"
done
metric sim.up.kthreads "$n"
iw dev $IFN link | grep -q Connected && ok "simmetrics: associated" || nok "simmetrics: associated"

phase simmetrics-idle
idle_window sim.assoc "$IDLE" $new

phase simmetrics-traffic
ip addr add 10.99.0.2/24 dev $IFN
t0=$(now_ns)
c0=$(cpu_busy_jiffies)
n=0
while [ $n -lt 100 ]; do
	n=$((n + 1))
	ping -c 1 -W 1 10.99.0.1 > /dev/null 2>&1
done
t1=$(now_ns)
c1=$(cpu_busy_jiffies)
frames=$(sed -n 's/.* tx_frames \([0-9]*\).*/\1/p' /sys/module/$SIM/stats)
metric sim.tput.tx_frames "${frames:-0}"
metric sim.tput.ms_per_100_pings $(( (t1 - t0) / 1000000 ))
metric sim.tput.cpu_ticks_per_100_pings $((c1 - c0))

phase simmetrics-down
ip link set $IFN down
unload_all
meminfo_snap /tmp/s2
mem_delta sim.down_residue /tmp/s0 /tmp/s2
ok "simmetrics collected"
