#!/bin/sh
# KUnit suites (tests/kunit/) run at insmod of uwe5622_kunit.ko; each test
# case becomes one TAP line "kunit: <suite>: <case>" with KUnit's
# assertion messages as diagnostics. Debug kernel only: some cases poke
# known overflows that only KASAN contains.
. /tests/lib.sh

check "kunit: insmod uwe5622_bsp_sdio (provides marlin_get_* to the ini parser)" load uwe5622_bsp_sdio
if ! [ -f $M/uwe5622_kunit.ko ]; then
	nok "kunit: uwe5622_kunit.ko built"
	exit 0
fi
check "kunit: insmod uwe5622_kunit" load uwe5622_kunit
for s in uwe5622_rf_ini uwe5622_regdom uwe5622_bufring; do
	f=/sys/kernel/debug/kunit/$s/results
	if ! [ -r "$f" ]; then
		nok "kunit: suite $s ran" "no $f"
		continue
	fi
	cp "$f" "$ATT/kunit-$s.txt"
	# test-case lines are indented one level (4 spaces) inside the suite
	awk '
		/^    # Subtest:/ { next }
		/^    (KTAP version|1\.\.)/ { next }
		/^    / && !/^    (not ok|ok) [0-9]+ / { sub(/^    (# )?/, ""); d = d "D\t" $0 "\n"; next }
		/^    (not ok|ok) [0-9]+ / {
			st = ($1 == "ok") ? "ok" : "fail"
			line = $0
			sub(/^    (not ok|ok) [0-9]+ /, "", line)
			skip = (line ~ /# SKIP/) ? 1 : 0
			sub(/ *#.*/, "", line)
			if (skip) st = "skip"
			printf "R\t%s\t%s\n%s", st, line, (st == "fail" ? d : "")
			d = ""
		}' "$f" > /tmp/kunit.parsed
	n=0
	pending=""
	flush() {
		[ -z "$pending" ] && return
		case $pst in
		ok) ok "kunit: $s: $pending" ;;
		skip) skip "kunit: $s: $pending" "skipped by the test" ;;
		*) nok "kunit: $s: $pending" "$(cat /tmp/kunit.diag)" ;;
		esac
		pending=""
	}
	while IFS="$(printf '\t')" read -r kind a b; do
		case $kind in
		R) flush; n=$((n + 1)); pst=$a pending=$b; : > /tmp/kunit.diag ;;
		D) echo "$a" >> /tmp/kunit.diag ;;
		esac
	done < /tmp/kunit.parsed
	flush
	[ "$n" -gt 0 ] || nok "kunit: suite $s reported test cases" "$(head -n 20 "$f")"
done
check "kunit: rmmod uwe5622_kunit" rmmod uwe5622_kunit
