#!/usr/bin/env bash
# Boot the guest kernel in QEMU and turn its output into TAP + metrics.
#
#   tests/qemu/run.sh <Image> <initramfs> <mem-MB> <tests> <outdir> [timeout-s] [extra cmdline]
#
#   tests    comma-separated guest scripts (tests/qemu/guest/<name>.sh)
#
# The machine is QEMU "virt" with 4 Cortex-A53 cores, the Orange Pi Zero 3's
# CPU, under TCG (KVM cannot emulate a different CPU model). Output:
#   <outdir>/console.log   full serial console (= kernel log)
#   <outdir>/qemu.tap      guest results plus host-side checks:
#                          booted, finished, no splats per test phase
#   <outdir>/metrics.txt   "key value" lines from the guest
#   <outdir>/<files>       attachments (kmemleak reports, traces, dmesg)
set -uo pipefail
IMAGE=${1:?Image}
INITRD=${2:?initramfs}
MEM=${3:?memory MB}
TESTS=${4:?tests}
OUT=${5:?outdir}
TIMEOUT=${6:-1800}
EXTRA=${7:-}
. "$(dirname "$0")/../lib/tap.sh"
mkdir -p "$OUT"
LOG=$OUT/console.log

accel="tcg,thread=multi"
cmdline="console=ttyAMA0 panic=-1 printk.devkmsg=on loglevel=7 kmemleak=on uwe.tests=$TESTS $EXTRA"
echo "==> qemu: -m $MEM, tests=$TESTS, timeout ${TIMEOUT}s"
start=$(date +%s)
timeout --foreground -k 10 "$TIMEOUT" qemu-system-aarch64 \
	-M virt -cpu cortex-a53 -smp 4 -m "$MEM" -accel "$accel" \
	-nographic -no-reboot -monitor none -serial stdio \
	-kernel "$IMAGE" -initrd "$INITRD" -append "$cmdline" \
	< /dev/null 2>&1 | tr -d '\r' > "$LOG"
rc=${PIPESTATUS[0]}
echo "==> qemu exited with $rc after $(( $(date +%s) - start ))s"

# Results block printed by the guest after the tests; if the guest died
# before printing it, fall back to the live "@@TAP@@" lines.
results=$OUT/results.txt
if grep -q '^@@RESULTS-END@@' "$LOG"; then
	sed -n '/^@@RESULTS-BEGIN@@/,/^@@RESULTS-END@@/p' "$LOG" | sed '1d;$d' > "$results"
else
	sed -n 's/.*@@TAP@@ //p' "$LOG" > "$results"
fi
grep '^@@M@@ ' "$results" | sed 's/^@@M@@ //' > "$OUT/metrics.txt"
# attachments
awk -v out="$OUT" '
	/^@@FILE-BEGIN@@ / { f = out "/" $2; printf "" > f; next }
	/^@@FILE-END@@/ { close(f); f = ""; next }
	f != "" { print >> f }' "$LOG"

tap_begin "$OUT/qemu.tap"
if grep -q '@@BEGIN@@' "$LOG"; then
	tap_ok "guest booted to the test init ($(grep -o '@@BEGIN@@.*' "$LOG" | head -1 | cut -c11-))"
else
	tap_fail "guest booted to the test init" "$(tail -40 "$LOG")"
fi

# Guest TAP lines, renumbered; tap.sh applies tests/known-failures.txt.
desc=""
diags=()
flush() {
	[[ -z $desc ]] && return
	if [[ $st == ok ]]; then
		if [[ $desc == *" # SKIP "* ]]; then tap_skip "${desc%% # SKIP *}" "${desc#* # SKIP }"; else tap_ok "$desc"; fi
		for d in "${diags[@]}"; do tap_diag "$d"; done
	else
		tap_fail "$desc" "${diags[@]}"
	fi
	desc="" diags=()
}
while IFS= read -r line; do
	case "$line" in
	"ok - "*) flush; st=ok desc=${line#ok - } ;;
	"not ok - "*) flush; st=fail desc=${line#not ok - } ;;
	"# "*) if [[ -n $desc ]]; then diags+=("${line#\# }"); else tap_diag "${line#\# }"; fi ;;
	esac
done < "$results"
flush

# Kernel splats, attributed to the phase (guest "@@PHASE name" marker in
# the kernel log) they appeared in.
SPLAT='(BUG:|WARNING:|KASAN:|UBSAN:|Unable to handle kernel|Internal error:|Oops|kernel BUG|Kernel panic|possible recursive locking|possible circular locking|inconsistent lock state|suspicious RCU usage|INFO: task .* blocked|soft lockup|hard LOCKUP|ODEBUG:|list_add corruption|list_del corruption|sleeping function called from invalid context|DEBUG_LOCKS_WARN_ON|refcount_t:|stack-protector|Call trace:)'
awk -v re="$SPLAT" -v out="$OUT/splats.txt" '
	BEGIN { phase = "boot"; order[++n] = phase; seen[phase] = 1 }
	/@@PHASE / { sub(/.*@@PHASE /, ""); phase = $1; if (!(phase in seen)) { seen[phase] = 1; order[++n] = phase }; next }
	/@@RESULTS-BEGIN@@/ { exit }
	/@@/ { next }
	$0 ~ re { cnt[phase]++; if (cnt[phase] <= 3) { ctx[phase] = ctx[phase] $0 "\n"; grab[phase] = 25 } ; print phase ": " $0 > out; next }
	grab[phase] > 0 { grab[phase]--; ctx[phase] = ctx[phase] $0 "\n" }
	END {
		for (i = 1; i <= n; i++) {
			p = order[i]
			printf "PHASE\t%s\t%d\n", p, cnt[p] + 0
			if (cnt[p]) { gsub(/\n/, "\nCTX\t", ctx[p]); printf "CTX\t%s\n", ctx[p] }
		}
	}' "$LOG" > "$OUT/phases.txt"
cur=""
ctx=()
emit_phase() {
	[[ -z $cur ]] && return
	if [[ $cnt == 0 ]]; then tap_ok "no kernel splats during $cur"; else tap_fail "no kernel splats during $cur" "$cnt splat lines, first ones with context:" "${ctx[@]:0:80}"; fi
	cur="" ctx=()
}
while IFS=$'\t' read -r kind a b; do
	case $kind in
	PHASE) emit_phase; cur=$a cnt=$b ;;
	CTX) [[ -n $a ]] && ctx+=("$a") ;;
	esac
done < "$OUT/phases.txt"
emit_phase

if grep -q '^@@END@@' "$LOG"; then
	tap_ok "guest finished all tests and powered off"
elif [[ $rc == 124 || $rc == 137 ]]; then
	tap_fail "guest finished all tests and powered off" "timed out after ${TIMEOUT}s; last console lines:" "$(tail -30 "$LOG")"
else
	tap_fail "guest finished all tests and powered off" "qemu exit $rc; last console lines:" "$(tail -30 "$LOG")"
fi
tap_end >/dev/null
exit 0
