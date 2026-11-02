#!/usr/bin/env bash
# Build the QEMU guest kernel and the driver modules against it.
#
#   tests/qemu/build-kernel.sh <kernel-version> <workdir> <debug|perf>
#
# The kernel is configured from "make allnoconfig" plus
# tests/qemu/config/common.config and <flavour>.config, built natively on
# the arm64 runner into an O= directory, <workdir>/kbuild-<flavour>. After
# the build everything an external module build does not need (objects,
# vmlinux, .cmd files) is deleted, so the directory is small enough for
# actions/cache; a restored directory with a matching config is reused.
#
# Then the three driver modules, and any test modules under tests/ that
# have a Kbuild file, are built against it (M=, same Kconfig selection as
# dkms.conf), and copied to <workdir>/out-<flavour>/modules/.
set -euo pipefail
VER=${1:?kernel version}
WORK=${2:?workdir}
FLAVOUR=${3:?debug or perf}
. "$(dirname "$0")/../lib/kernel.sh"
CFG_DIR=$UWE_SRC/tests/qemu/config
KSRC=$WORK/linux-$VER
KOBJ=$WORK/kbuild-$FLAVOUR
OUT=$WORK/out-$FLAVOUR
mkdir -p "$KOBJ" "$OUT/modules"

kernel_fetch "$VER" "$WORK"

# The configuration that should result; compared with what the cached tree
# was built with.
want_config() {
	cat "$CFG_DIR/common.config" "$CFG_DIR/$FLAVOUR.config"
}

configure() {
	make -C "$KSRC" O="$KOBJ" allnoconfig >/dev/null
	want_config >> "$KOBJ/.config"
	make -C "$KSRC" O="$KOBJ" olddefconfig 2>&1 | grep -v "override: reassigning" || true
	# Every requested option must survive olddefconfig (a dropped one
	# means a missing dependency in the fragment).
	local line sym val got bad=0
	while IFS= read -r line; do
		if [[ $line =~ ^(CONFIG_[A-Z0-9_]+)=(.*)$ ]]; then
			sym=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
		elif [[ $line =~ ^#\ (CONFIG_[A-Z0-9_]+)\ is\ not\ set$ ]]; then
			sym=${BASH_REMATCH[1]} val=n
		else
			continue
		fi
		got=$(sed -nE "s/^$sym=(.*)/\1/p" "$KOBJ/.config")
		[[ -z $got ]] && got=n
		if [[ $got != "$val" ]]; then
			echo "config: $sym wanted '$val', got '$got'" >&2
			bad=1
		fi
	done < <(want_config)
	[[ $bad == 0 ]]
}

stamp=$(want_config | sha256sum | cut -d' ' -f1)
if [[ -f $KOBJ/arch/arm64/boot/Image && -f $KOBJ/Module.symvers &&
	$(cat "$KOBJ/.uwe-config-stamp" 2>/dev/null) == "$stamp" ]]; then
	echo "==> reusing cached $FLAVOUR kernel ($KOBJ)"
else
	echo "==> building $FLAVOUR kernel linux-$VER"
	rm -rf "$KOBJ" && mkdir -p "$KOBJ"
	configure
	if ! make -C "$KSRC" O="$KOBJ" -j"$(nproc)" Image modules > "$OUT/kernel-build.log" 2>&1; then
		tail -80 "$OUT/kernel-build.log"
		exit 1
	fi
	# Keep what M= builds need: .config, generated headers, host tools in
	# scripts/, Module.symvers, Image, System.map.
	find "$KOBJ" \( -name '*.o' -o -name '*.a' -o -name '.*.cmd' -o -name '*.mod.c' \
		-o -name '*.mod' -o -name '.tmp_*' \) -type f -delete
	rm -f "$KOBJ/vmlinux" "$KOBJ/vmlinux.unstripped" "$KOBJ/arch/arm64/boot/Image.gz"
	echo "$stamp" > "$KOBJ/.uwe-config-stamp"
fi
cp "$KOBJ/arch/arm64/boot/Image" "$KOBJ/.config" "$KOBJ/System.map" "$OUT/"
du -sh "$KOBJ" | sed 's/^/==> kernel build dir: /'

echo "==> building driver modules against the $FLAVOUR kernel"
driver_clean
make -C "$KOBJ" M="$UWE_SRC" -j"$(nproc)" "${UWE_DRIVER_CONFIG[@]}" modules 2>&1 | tee "$OUT/modules-build.log"
[[ ${PIPESTATUS[0]} -eq 0 ]]
cp "$UWE_SRC"/unisocwcn/uwe5622_bsp_sdio.ko "$UWE_SRC"/unisocwifi/sprdwl_ng.ko \
	"$UWE_SRC"/tty-sdio/sprdbt_tty.ko "$OUT/modules/"
# Test modules (simulated chip, KUnit suites): each directory with a Kbuild
# file is built against the same kernel, with the driver's Module.symvers
# so they can link against uwe5622_bsp_sdio.
for kb in "$UWE_SRC"/tests/*/Kbuild; do
	[[ -e $kb ]] || continue
	d=$(dirname "$kb")
	echo "==> building test modules in ${d#"$UWE_SRC"/}"
	make -C "$KOBJ" M="$d" -j"$(nproc)" KBUILD_EXTRA_SYMBOLS="$UWE_SRC/Module.symvers" \
		UWE_SRC="$UWE_SRC" modules 2>&1 | tee -a "$OUT/modules-build.log"
	[[ ${PIPESTATUS[0]} -eq 0 ]]
	cp "$d"/*.ko "$OUT/modules/"
done
ls -l "$OUT/modules"
