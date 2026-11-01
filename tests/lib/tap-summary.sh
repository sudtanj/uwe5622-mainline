#!/usr/bin/env bash
# Summarise one or more TAP files: print a table, append it to
# $GITHUB_STEP_SUMMARY when set, and exit 1 if any test failed.
#
#   tests/lib/tap-summary.sh "Title" file.tap [file.tap...]
#
# "not ok ... # TODO" is an expected failure (known driver bug) and does not
# fail; "ok ... # TODO" is an unexpected pass and is reported as a warning so
# tests/known-failures.txt gets pruned. A file without a plan line ("1..N"),
# e.g. because the guest crashed, counts as a failure.
set -uo pipefail
title=$1
shift
out=$(mktemp)
pass=0 fail=0 skip=0 xfail=0 xpass=0 broken=0
{
	echo "### $title"
	echo
	echo "| Result | Test | Source |"
	echo "|---|---|---|"
} > "$out"
for f in "$@"; do
	src=$(basename "$f")
	if [[ ! -s $f ]]; then
		echo "| :x: missing | no TAP output | $src |" >> "$out"
		broken=$((broken + 1))
		continue
	fi
	grep -qE '^1\.\.[0-9]+' "$f" || {
		echo "| :x: incomplete | no plan line (run aborted or guest crashed) | $src |" >> "$out"
		broken=$((broken + 1))
	}
	while IFS= read -r line; do
		desc=$(sed -E 's/^(not ok|ok) [0-9]+ (- )?//; s/ # (TODO|SKIP).*//' <<<"$line" | sed 's/|/\\|/g')
		case "$line" in
		"not ok"*"# TODO"*) xfail=$((xfail + 1)); r=":warning: xfail" ;;
		"ok"*"# TODO"*) xpass=$((xpass + 1)); r=":sparkles: xpass"
			[[ -n ${GITHUB_ACTIONS:-} ]] && echo "::warning::unexpected pass, remove from tests/known-failures.txt: $desc" ;;
		"ok"*"# SKIP"*) skip=$((skip + 1)); r=":fast_forward: skip" ;;
		"not ok"*) fail=$((fail + 1)); r=":x: fail"
			[[ -n ${GITHUB_ACTIONS:-} ]] && echo "::error::$src: $desc" ;;
		"ok"*) pass=$((pass + 1)); r=":white_check_mark: ok" ;;
		esac
		echo "| $r | $desc | $src |" >> "$out"
	done < <(grep -E '^(not ok|ok)( |$)' "$f")
done
{
	echo
	echo "**$pass passed, $fail failed, $xfail known failures, $xpass unexpected passes, $skip skipped, $broken incomplete**"
	echo
} >> "$out"
cat "$out"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && cat "$out" >> "$GITHUB_STEP_SUMMARY"
rm -f "$out"
[[ $fail -eq 0 && $broken -eq 0 ]]
