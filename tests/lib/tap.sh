# shellcheck shell=bash
# Minimal TAP producer shared by the host-side test scripts.
#
#   . tests/lib/tap.sh
#   tap_begin out.tap            # start (or append to) a TAP file
#   tap_ok   "description"       # pass
#   tap_fail "description" [diag lines...]
#   tap_check "description" cmd args...   # ok if cmd exits 0
#   tap_skip "description" "reason"
#   tap_end                      # writes the plan line
#
# A test whose description matches a line of tests/known-failures.txt is a
# known driver bug: it is reported with the TAP "# TODO" directive, so it does
# not fail the job, and tests/lib/tap-summary.sh flags it if it starts passing.

TAP_N=0
TAP_FILE=/dev/null
TAP_KNOWN=${TAP_KNOWN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/known-failures.txt}

tap_begin() {
	TAP_FILE=$1
	TAP_N=0
	: > "$TAP_FILE"
	echo "TAP version 13" | tee -a "$TAP_FILE"
}

_tap_todo() {
	[[ -f $TAP_KNOWN ]] || return 1
	local pat
	while IFS= read -r pat; do
		[[ -z $pat || $pat == \#* ]] && continue
		[[ $1 == $pat ]] && return 0
	done < "$TAP_KNOWN"
	return 1
}

_tap_line() {
	local st=$1 desc=$2 dir=""
	TAP_N=$((TAP_N + 1))
	_tap_todo "$desc" && dir=" # TODO known driver bug (tests/known-failures.txt)"
	echo "$st $TAP_N - $desc$dir" | tee -a "$TAP_FILE"
}

tap_ok() { _tap_line "ok" "$1"; }

tap_fail() {
	_tap_line "not ok" "$1"
	shift
	local l
	for l in "$@"; do echo "# $l" | tee -a "$TAP_FILE"; done
}

tap_check() {
	local desc=$1
	shift
	if "$@"; then tap_ok "$desc"; else tap_fail "$desc" "command failed: $*"; fi
}

tap_skip() {
	TAP_N=$((TAP_N + 1))
	echo "ok $TAP_N - $1 # SKIP $2" | tee -a "$TAP_FILE"
}

tap_diag() { echo "# $*" | tee -a "$TAP_FILE"; }

tap_end() { echo "1..$TAP_N" | tee -a "$TAP_FILE"; }
