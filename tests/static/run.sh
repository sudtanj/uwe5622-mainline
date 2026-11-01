#!/usr/bin/env bash
# Static analysis of the driver, one tool per invocation.
#
#   tests/static/run.sh <clang|smatch|cocci|cppcheck> <kernel-version> <workdir>
#
# Writes into <workdir>/out-<tool>/:
#   findings.txt   one finding per line, checkout prefix stripped, sorted
#   classes.txt    "<count> <class>" per finding class (warning flag, smatch
#                  severity, coccinelle script or cppcheck id)
#   static-<tool>.tap  TAP: one test per gate in tests/static/gates.txt
#
# Findings are informational except for the gates: a gate is a class that
# was clean (or at a known count) and must not get worse. See docs/TESTING.md.
set -euo pipefail

TOOL=${1:?tool}
VER=${2:?kernel version}
WORK=${3:?workdir}
. "$(dirname "$0")/../lib/kernel.sh"
. "$(dirname "$0")/../lib/tap.sh"

KDIR=$WORK/linux-$VER
OUT=$WORK/out-$TOOL
mkdir -p "$OUT"
JOBS=$(nproc)
GCC_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
CLANG_ARGS=(ARCH=arm64 LLVM=1)

strip_src() { sed -E "s#^($UWE_SRC|\./)/?##"; }

case "$TOOL" in
clang)
	kernel_fetch "$VER" "$WORK"
	kernel_prepare "$KDIR" "${CLANG_ARGS[@]}"
	driver_clean
	set +e
	make -C "$KDIR" "${CLANG_ARGS[@]}" M="$UWE_SRC" -j"$JOBS" W=1 KBUILD_MODPOST_WARN=1 \
		"${UWE_DRIVER_CONFIG[@]}" modules > "$OUT/build.log" 2>&1
	status=$?
	set -e
	grep -E ': (warning|error):' "$OUT/build.log" | strip_src | sort -u > "$OUT/findings.txt" || true
	# class = the -W flag (or "error")
	sed -nE 's/.*: error: .*/error/p; s/.*: warning: .*\[(-W[^]]+)\]$/\1/p' "$OUT/findings.txt" \
		| sort | uniq -c | sort -rn > "$OUT/classes.txt"
	[[ $status -eq 0 ]] || { tail -40 "$OUT/build.log"; echo "build_failed" > "$OUT/build-failed"; }
	;;
smatch)
	kernel_fetch "$VER" "$WORK"
	kernel_prepare "$KDIR" "${GCC_ARGS[@]}"
	if [[ ! -x $WORK/smatch/smatch ]]; then
		git clone --depth 1 https://repo.or.cz/smatch.git "$WORK/smatch" \
			|| git clone --depth 1 https://github.com/error27/smatch "$WORK/smatch"
		make -C "$WORK/smatch" -j"$JOBS" smatch >/dev/null
	fi
	driver_clean
	set +e
	make -C "$KDIR" "${GCC_ARGS[@]}" M="$UWE_SRC" -j"$JOBS" C=2 \
		CHECK="$WORK/smatch/smatch -p=kernel" KBUILD_MODPOST_WARN=1 \
		"${UWE_DRIVER_CONFIG[@]}" modules > "$OUT/build.log" 2>&1
	status=$?
	set -e
	grep -E ' (warn|error): ' "$OUT/build.log" | grep -vE '^make|^\s' | strip_src | sort -u > "$OUT/findings.txt" || true
	sed -nE 's/.* (warn|error): .*/smatch-\1/p' "$OUT/findings.txt" | sort | uniq -c | sort -rn > "$OUT/classes.txt"
	[[ $status -eq 0 ]] || { tail -40 "$OUT/build.log"; echo "build_failed" > "$OUT/build-failed"; }
	;;
cocci)
	kernel_fetch "$VER" "$WORK"
	: > "$OUT/findings.txt"
	: > "$OUT/build.log"
	# Every kernel semantic patch that has a report mode, run like
	# "make coccicheck MODE=report M=..." does, but one script at a time so
	# each finding can be attributed to its script.
	while IFS= read -r cocci; do
		name=${cocci#"$KDIR"/scripts/coccinelle/}
		echo "== $name" >> "$OUT/build.log"
		timeout 600 spatch -D report --very-quiet --no-show-diff --no-includes --include-headers \
			-I "$KDIR/include" -I "$KDIR/arch/arm64/include" \
			-I "$UWE_SRC/unisocwcn/include" \
			--jobs "$JOBS" --chunksize 1 --cocci-file "$cocci" --dir "$UWE_SRC" \
			> "$OUT/one.txt" 2>> "$OUT/build.log" || echo "   (spatch exit $?)" >> "$OUT/build.log"
		grep -E '^[^ ]+:[0-9]+:' "$OUT/one.txt" | grep -v '^reference/' | strip_src \
			| sed "s#\$# [$name]#" >> "$OUT/findings.txt" || true
	done < <(grep -rl --include='*.cocci' '^virtual report' "$KDIR/scripts/coccinelle" | sort)
	grep -v '/reference/' "$OUT/findings.txt" | sort -u -o "$OUT/findings.txt"
	sed -nE 's/.*\[([^]]+)\]$/\1/p' "$OUT/findings.txt" | sort | uniq -c | sort -rn > "$OUT/classes.txt"
	;;
cppcheck)
	set +e
	cppcheck --version
	cppcheck -q -j "$JOBS" --enable=warning,performance,portability --inconclusive \
		--std=c11 --platform=unix64 --max-configs=1 \
		--suppress=missingInclude --suppress=missingIncludeSystem \
		-D__KERNEL__ -D__linux__ -DMODULE -DCONFIG_UWE5622 -DCONFIG_WCN_SDIO -DCONFIG_WCN_SLP \
		-DCONFIG_WCN_SWD -DCONFIG_WCN_BOOT -DCONFIG_WCN_UTILS -DCONFIG_AW_BOARD \
		-DCONFIG_WCN_POWER_UP_DOWN -DCONFIG_BT_WAKE_HOST_EN -DCONFIG_WL_WAKE_HOST_EN \
		-DCONFIG_WCN_LOOPCHECK -DCONFIG_SDIO_TX_ADMA_MODE -DCONFIG_SDIO_RX_ADMA_MODE \
		-DCONFIG_SDIO_INBAND_INT -DOTT_UWE -DCP2_RESET_SUPPORT \
		-I "$UWE_SRC/unisocwcn/include" -I "$UWE_SRC/unisocwcn/platform" \
		--template='{file}:{line}: {severity}: {message} [{id}]' \
		"$UWE_SRC/unisocwcn" "$UWE_SRC/unisocwifi" "$UWE_SRC/tty-sdio" > "$OUT/build.log" 2>&1
	set -e
	grep -E '^[^ ]+:[0-9]+: ' "$OUT/build.log" | strip_src | sort -u > "$OUT/findings.txt" || true
	sed -nE 's/.*\[([A-Za-z0-9_]+)\]$/\1/p' "$OUT/findings.txt" | sort | uniq -c | sort -rn > "$OUT/classes.txt"
	;;
*) echo "unknown tool $TOOL" >&2; exit 2 ;;
esac

total=$(wc -l < "$OUT/findings.txt")
echo "== $TOOL: $total findings"
cat "$OUT/classes.txt"

# Gates: "<tool> <class> <max>" lines in tests/static/gates.txt.
tap_begin "$OUT/static-$TOOL.tap"
if [[ -e $OUT/build-failed ]]; then
	tap_fail "$TOOL: driver builds" "see build.log"
else
	tap_ok "$TOOL: tool ran ($total findings, informational)"
fi
while read -r gtool class max; do
	[[ -z $gtool || $gtool == \#* || $gtool != "$TOOL" ]] && continue
	n=$(awk -v c="$class" '$2 == c { print $1 }' "$OUT/classes.txt")
	n=${n:-0}
	if [[ $n -le $max ]]; then
		tap_ok "$TOOL: $class <= $max (found $n)"
	else
		tap_fail "$TOOL: $class <= $max (found $n)" \
			"$(grep -F -- "$class" "$OUT/findings.txt" | head -20)"
	fi
done < "$(dirname "$0")/gates.txt"
tap_end

{
	echo "#### $TOOL: $total findings against linux-$VER"
	echo
	echo '```'
	head -40 "$OUT/classes.txt"
	echo '```'
} > "$OUT/summary.md"
