# shellcheck shell=sh
# Helpers for the guest test scripts (busybox ash). Results go to $RES as
# TAP lines without numbers ("ok - desc", "not ok - desc", "# diag") and
# metrics ("@@M@@ key value"); tests/qemu/run.sh numbers them, applies
# tests/known-failures.txt and adds the host-side checks (splats, crash).
RES=/tmp/results
ATT=/tmp/attach
KML=/sys/kernel/debug/kmemleak
M=/lib/modules/uwe
mkdir -p "$ATT"
touch "$RES"

_r() { echo "$*" >> "$RES"; echo "@@TAP@@ $*"; }
ok() { _r "ok - $1"; }
nok() {
	_r "not ok - $1"
	shift
	for l in "$@"; do
		printf '%s\n' "$l" | while IFS= read -r x; do _r "# $x"; done
	done
}
skip() { _r "ok - $1 # SKIP $2"; }
diag() { _r "# $*"; }
# check "description" cmd args...: ok if the command exits 0
check() {
	d=$1
	shift
	if "$@" > /tmp/check.out 2>&1; then ok "$d"; else nok "$d" "command failed: $*" "$(tail -n 5 /tmp/check.out)"; fi
}
# check_not "description" cmd args...: ok if the command fails
check_not() {
	d=$1
	shift
	if "$@" > /tmp/check.out 2>&1; then nok "$d" "command succeeded: $*"; else ok "$d"; fi
}
# eq "description" expected actual
eq() { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected: '$2'" "actual:   '$3'"; fi; }
metric() { echo "@@M@@ $1 $2" >> "$RES"; }
# Marks the start of a test phase in the kernel log; run.sh attributes
# splats to the phase they appear in.
phase() { echo "@@PHASE $1" > /dev/kmsg; }
cmdline_get() { sed -n "s/.*$1=\([^ ]*\).*/\1/p" /proc/cmdline; }
now_ns() { awk '/^now at/ {print $3; exit}' /proc/timer_list; }

mod_loaded() { [ -e "/sys/module/$1/initstate" ]; }
# Remember module symbols at load time: kmemleak reports are written after
# rmmod, when their frames are only raw addresses.
snap_syms() { awk '$4 ~ /^\[/ && $2 ~ /^[tTdDbBrR]$/ { print $1, $3 }' /proc/kallsyms >> /tmp/modsyms; }
load() {
	m=$1
	shift
	insmod "$M/$m.ko" "$@"
	r=$?
	snap_syms
	return $r
}
unload_all() {
	for m in sprdbt_tty sprdwl_ng uwe5622_sim uwe5622_bsp_sdio; do
		mod_loaded "$m" && rmmod "$m"
	done
	return 0
}
no_driver_modules() {
	for m in uwe5622_sim sprdbt_tty sprdwl_ng uwe5622_bsp_sdio; do
		mod_loaded "$m" && return 1
	done
	return 0
}

# kmemleak: forget everything allocated so far, then later report only
# what leaked since.
kml_reset() {
	[ -w "$KML" ] || return 0
	echo scan > "$KML"
	echo clear > "$KML"
}
# kml_check "description" tag
kml_check() {
	if [ ! -w "$KML" ]; then
		skip "$1" "kernel built without kmemleak"
		return
	fi
	# objects must survive two scans (and be older than 5 s) to be reported
	echo scan > "$KML"
	sleep 6
	echo scan > "$KML"
	cat "$KML" > "$ATT/kmemleak-$2.txt"
	symbolise_kml "$ATT/kmemleak-$2.txt"
	n=$(grep -c 'unreferenced object' "$ATT/kmemleak-$2.txt")
	if [ "$n" = 0 ]; then
		ok "$1"
	else
		nok "$1" "$n unreferenced objects; first reports:" "$(head -n 40 "$ATT/kmemleak-$2.txt")"
	fi
	echo clear > "$KML"
}

# Quiet the console, then print results and attachments between markers.
report() {
	echo 1 > /proc/sys/kernel/printk
	dmesg > "$ATT/dmesg.txt"
	echo "@@RESULTS-BEGIN@@"
	cat "$RES"
	echo "@@RESULTS-END@@"
	for f in "$ATT"/*; do
		[ -f "$f" ] || continue
		echo "@@FILE-BEGIN@@ ${f##*/}"
		cat "$f"
		echo "@@FILE-END@@"
	done
	echo "@@END@@"
}

# symbolise_kml <file>: replace raw module addresses in backtrace lines
# ("0xffff80007b116054") with "<symbol>+<off>" using /tmp/modsyms. 16-digit
# lowercase hex compares as a string; the closest lower symbol within 1 MiB wins.
symbolise_kml() {
	[ -s /tmp/modsyms ] || return 0
	awk 'NR == FNR { n++; a[n] = $1; s[n] = $2; next }
	{
		if (match($0, /0xffff[0-9a-f]+$/)) {
			addr = substr($0, RSTART + 2, RLENGTH - 2)
			best = ""
			for (i = 1; i <= n; i++)
				if (a[i] <= addr && (best == "" || a[i] > a[best])) best = i
			if (best != "" && substr(a[best], 1, 11) == substr(addr, 1, 11))
				sub(/0xffff[0-9a-f]+$/, s[best] " [module " addr "]")
		}
		print
	}' /tmp/modsyms "$1" > "$1.sym" && mv "$1.sym" "$1"
}
