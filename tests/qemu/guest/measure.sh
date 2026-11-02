# shellcheck shell=sh
# Measurement helpers shared by metrics.sh and the simulated-chip tests.
# Every function writes "@@M@@ <key> <value>" lines via metric().
TR=/sys/kernel/tracing
DRIVER_MODS='uwe5622_bsp_sdio|sprdwl_ng|sprdbt_tty'

# meminfo_snap <file>: settle, drop caches, save /proc/meminfo + slabinfo
meminfo_snap() {
	sync
	echo 3 > /proc/sys/vm/drop_caches
	sleep 2
	cat /proc/meminfo > "$1.meminfo"
	cat /proc/slabinfo > "$1.slab" 2>/dev/null || : > "$1.slab"
}
_mi() { awk -v k="$2:" '$1 == k {print $2}' "$1.meminfo"; }

# mem_delta <prefix> <before> <after>: memory the step between the two
# snapshots cost, in kB (positive = more memory in use afterwards).
mem_delta() {
	p=$1 a=$2 b=$3
	metric "$p.memavailable_kb" $(( $(_mi "$a" MemAvailable) - $(_mi "$b" MemAvailable) ))
	total=0
	for k in Slab SUnreclaim VmallocUsed Percpu KernelStack; do
		d=$(( $(_mi "$b" $k) - $(_mi "$a" $k) ))
		key=$(echo "$k" | tr 'A-Z' 'a-z')
		metric "$p.${key}_kb" "$d"
		case $k in SUnreclaim | VmallocUsed | Percpu | KernelStack) total=$((total + d)) ;; esac
	done
	# Unreclaimable kernel memory pinned by the step: the gated number
	metric "$p.pinned_kb" "$total"
	# Top slab caches by growth (num_objs * objsize)
	awk 'NR == FNR { if (FNR > 2) a[$1] = $3 * $4; next }
	     FNR > 2 { d = ($3 * $4 - a[$1]) / 1024; if (d >= 4) printf "%d %s\n", d, $1 }' \
		"$a.slab" "$b.slab" | sort -rn | head -n 10 | while read -r kb name; do
		metric "$p.slab.$name" "$kb"
	done
}

kthreads() { # pids of kernel threads (no mm: empty cmdline)
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] && [ ! -s "$d/cmdline" ] && echo "${d#/proc/}"
	done | sort -n
}
# cpu_ticks <pid>: utime + stime in USER_HZ ticks
cpu_ticks() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $12 + $13}'; }
irq_total() { awk 'NR > 1 { for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i } END { print s + 0 }' /proc/interrupts; }
cpu_busy_jiffies() { awk '/^cpu / { print $2 + $3 + $4 + $7 + $8 }' /proc/stat; }
cpu_all_jiffies() { awk '/^cpu / { s = 0; for (i = 2; i <= NF; i++) s += $i; print s }' /proc/stat; }

# idle_window <prefix> <seconds> [new-kthread-pids...]: sit idle and record
# interrupts, timer/hrtimer expiries and work items per second, split into
# all and driver-owned (callback symbol in one of the driver modules), and
# the CPU time of the given kernel threads.
idle_window() {
	p=$1 secs=$2
	shift 2
	tracing=0
	if [ -d "$TR/events/timer" ]; then
		tracing=1
		echo 0 > $TR/tracing_on
		echo > $TR/trace
		echo 2048 > $TR/buffer_size_kb
		for e in timer/timer_expire_entry timer/hrtimer_expire_entry workqueue/workqueue_execute_start; do
			echo 1 > "$TR/events/$e/enable"
		done
	fi
	for pid in "$@"; do echo "$pid $(cpu_ticks "$pid")"; done > /tmp/kt.before
	i0=$(irq_total) b0=$(cpu_busy_jiffies) a0=$(cpu_all_jiffies)
	[ $tracing = 1 ] && echo 1 > $TR/tracing_on
	sleep "$secs"
	[ $tracing = 1 ] && echo 0 > $TR/tracing_on
	i1=$(irq_total) b1=$(cpu_busy_jiffies) a1=$(cpu_all_jiffies)
	metric "$p.irq_per_s" "$(awk -v d=$((i1 - i0)) -v s="$secs" 'BEGIN { printf "%.2f", d / s }')"
	metric "$p.cpu_busy_pct" "$(awk -v b=$((b1 - b0)) -v a=$((a1 - a0)) 'BEGIN { printf "%.3f", a ? 100 * b / a : 0 }')"
	if [ $tracing = 1 ]; then
		for e in timer/timer_expire_entry timer/hrtimer_expire_entry workqueue/workqueue_execute_start; do
			echo 0 > "$TR/events/$e/enable"
		done
		cat $TR/trace > "$ATT/trace-$p.txt"
		awk -v m="$DRIVER_MODS" '$4 ~ "^\\[(" m ")\\]$" { print $3 }' /proc/kallsyms | sort -u > /tmp/drvsyms
		# callback of each event: "function=foo" (timers) or "function foo"
		# (work); %ps appends " [module]" for module symbols. A callback is
		# the driver's if its module is one of ours or its name is one of
		# the driver modules' symbols.
		sed -nE 's/.* (hrtimer_expire_entry|timer_expire_entry|workqueue_execute_start):.*function[= ]([A-Za-z0-9_.]+)( \[([A-Za-z0-9_]+)\])?.*/\1 \2 \4/p' \
			"$ATT/trace-$p.txt" |
			awk -v m="^($DRIVER_MODS)\$" 'NR == FNR { s[$1] = 1; next } { print $1, $2, ($3 ~ m || ($2 in s)) ? "drv" : "-" }' \
				/tmp/drvsyms - > /tmp/events
		for kind in timer_expire_entry hrtimer_expire_entry workqueue_execute_start; do
			all=$(grep -c "^$kind " /tmp/events)
			drv=$(grep -c "^$kind .* drv\$" /tmp/events)
			metric "$p.$kind.all_per_s" "$(awk -v d="$all" -v s="$secs" 'BEGIN { printf "%.2f", d / s }')"
			metric "$p.$kind.driver_per_s" "$(awk -v d="$drv" -v s="$secs" 'BEGIN { printf "%.2f", d / s }')"
		done
		# which driver callbacks fired, for the log
		awk '$3 == "drv" { c[$1 " " $2]++ } END { for (k in c) print c[k], k }' /tmp/events |
			sort -rn | head -n 15 | while read -r n kind fn; do
			diag "$p: $fn ($kind) fired $n times in ${secs}s"
		done
	fi
	ms=0
	while read -r pid t0; do
		t1=$(cpu_ticks "$pid")
		[ -n "$t1" ] && ms=$((ms + (t1 - t0) * 10))
	done < /tmp/kt.before
	metric "$p.driver_kthread_cpu_ms" "$ms"
}
