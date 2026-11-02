#!/bin/sh
# Resource cost of the driver with no chip present (run on the "perf"
# kernel): memory pinned by loading the modules, load time per module, and
# idle wakeups / CPU with the modules loaded versus without. The simulated
# chip tests add the same numbers with an interface up (sim.* keys).
. /tests/lib.sh
. /tests/measure.sh
IDLE=$(cmdline_get uwe.idle)
IDLE=${IDLE:-60}
BSP=uwe5622_bsp_sdio WIFI=sprdwl_ng BT=sprdbt_tty

phase metrics-baseline
sleep 5
idle_window idle.baseline "$IDLE"
kthreads > /tmp/kt0
meminfo_snap /tmp/m0

phase metrics-load
for m in $BSP $WIFI $BT; do
	t0=$(now_ns)
	if load $m; then
		t1=$(now_ns)
		metric "load_ms.$m" $(( (t1 - t0) / 1000000 ))
	else
		nok "metrics: insmod $m"
	fi
done
sleep 5
meminfo_snap /tmp/m1
mem_delta mem.load /tmp/m0 /tmp/m1
kthreads > /tmp/kt1
new=$(comm -13 /tmp/kt0 /tmp/kt1 | tr '\n' ' ')
n=0
for pid in $new; do
	n=$((n + 1))
	diag "kernel thread started by the modules: $pid $(cat /proc/$pid/comm 2>/dev/null)"
done
metric mem.load.kthreads "$n"

phase metrics-idle
idle_window idle.loaded "$IDLE" $new

phase metrics-unload
unload_all
meminfo_snap /tmp/m2
# memory not returned after rmmod (leaks show up here first)
mem_delta mem.unload_residue /tmp/m0 /tmp/m2
ok "metrics collected"
