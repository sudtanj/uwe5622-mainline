#!/usr/bin/env bash
# Pack the guest's initramfs.
#
#   tests/qemu/build-initramfs.sh <modules-dir> <out.cpio.gz>
#
# Contents: Ubuntu's static busybox, the arm64 iw / rfkill / wpa_supplicant
# binaries of the runner with the shared libraries they need (the runner
# is arm64, so its binaries run in the guest unchanged), the modules, and
# the guest scripts from tests/qemu/guest/. Run on the ubuntu-24.04-arm
# runner after "apt-get install busybox-static iw rfkill wpasupplicant".
set -euo pipefail
MODS=${1:?modules dir}
OUTF=${2:?output .cpio.gz}
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

mkdir -p "$R"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,run,etc,lib/modules/uwe,lib/firmware,tests}
cp /bin/busybox "$R/bin/busybox"
file "$R/bin/busybox" | grep -q 'statically linked' || { echo "busybox is not static" >&2; exit 1; }

# Copy a dynamically linked binary and every library ldd lists for it.
copy_dyn() {
	local bin lib
	bin=$(command -v "$1") || { echo "missing on runner: $1 (skipped)" >&2; return 0; }
	bin=$(readlink -f "$bin")
	cp "$bin" "$R/usr/sbin/$1"
	for lib in $(ldd "$bin" | grep -oE '/[^ ]+'); do
		cp -L --parents "$lib" "$R/" 2>/dev/null || true
	done
}
for b in iw rfkill wpa_supplicant wpa_cli; do copy_dyn "$b"; done
# glibc's loader is always looked up at the path compiled into binaries.
ld=$(ls /lib/ld-linux-aarch64.so.1 2>/dev/null || true)
[[ -n $ld ]] && cp -L --parents "$ld" "$R/"

cp "$MODS"/*.ko "$R/lib/modules/uwe/"
cp "$HERE"/guest/*.sh "$R/tests/"
cp "$HERE/guest/init" "$R/init"
chmod +x "$R/init" "$R"/tests/*.sh
# Optional data files the tests use (e.g. the .ini the KUnit suites parse).
[[ -d $HERE/guest/data ]] && cp -r "$HERE/guest/data" "$R/tests/data"

(cd "$R" && find . -print0 | cpio --null -o -H newc --quiet) | gzip -9 > "$OUTF"
ls -l "$OUTF"
