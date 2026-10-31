#!/usr/bin/env bash
#
# Build the uwe5622 modules out of tree against an upstream kernel release.
#
# Usage:
#   scripts/build-against-kernel.sh <version> [workdir]
#
#   version   kernel release, e.g. 6.18.60, 7.3.1, 7.3, 7.4-rc1, next-20261030
#   workdir   where the kernel source is downloaded and prepared (default: ./build)
#
# Environment:
#   KERNEL_URL     tarball URL (default: derived from <version>)
#   ARCH           target architecture (default: arm64)
#   CROSS_COMPILE  toolchain prefix (default: aarch64-linux-gnu-)
#   JOBS           parallel jobs (default: nproc)
#   WARN=1         build the driver with W=1 (extra compiler warnings)
#   SPARSE=1       also run sparse (C=1) on the driver
#   DTS=0          skip compiling the device-tree overlay
#
# The kernel tree is only downloaded and prepared once per version; re-running
# the script for the same version rebuilds just the driver. Nothing is installed.
set -euo pipefail

VER=${1:?usage: $0 <kernel-version> [workdir]}
WORK=${2:-$PWD/build}
SRC=$(cd "$(dirname "$0")/.." && pwd)

ARCH=${ARCH:-arm64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}
KDIR=$WORK/linux-$VER

# Kbuild variables that select the Allwinner SDIO variant of the driver and
# build all three modules: uwe5622_bsp_sdio (WCN core), sprdwl_ng (Wi-Fi),
# sprdbt_tty (Bluetooth TTY over SDIO). Same selection as dkms.conf.
DRIVER_CONFIG=(CONFIG_AW_WIFI_DEVICE_UWE5622=y CONFIG_WLAN_UWE5622=m CONFIG_TTY_OVERY_SDIO=m)

log() { printf '\n==> %s\n' "$*"; }

tarball_url() {
	case "$VER" in
	next-*) echo "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/linux-next-$VER.tar.gz" ;;
	*-rc*) echo "https://git.kernel.org/torvalds/t/linux-$VER.tar.gz" ;;
	*) echo "https://cdn.kernel.org/pub/linux/kernel/v${VER%%.*}.x/linux-$VER.tar.xz" ;;
	esac
}

fetch_kernel() {
	local url=${KERNEL_URL:-$(tarball_url)}
	local tarball="$WORK/${url##*/}"
	mkdir -p "$WORK"
	log "Downloading $url"
	wget -q --show-progress --progress=dot:giga -O "$tarball" "$url"
	log "Extracting"
	local tmp="$WORK/extract-$VER"
	rm -rf "$tmp" && mkdir -p "$tmp"
	tar -C "$tmp" -xaf "$tarball"
	# linux-next snapshots extract as linux-next-<ver>, releases as linux-<ver>
	mv "$tmp"/linux-* "$KDIR"
	rmdir "$tmp"
	rm -f "$tarball"
}

prepare_kernel() {
	log "Preparing $KDIR ($ARCH defconfig + modules_prepare)"
	make -C "$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" defconfig >/dev/null
	# Everything the driver needs that arm64 defconfig might not enable.
	"$KDIR/scripts/config" --file "$KDIR/.config" \
		--enable MODULES \
		--module CFG80211 \
		--enable RFKILL \
		--enable MMC --enable MMC_SUNXI \
		--enable REGULATOR --enable REGULATOR_FIXED_VOLTAGE \
		--enable PWRSEQ_SIMPLE \
		--enable OF --enable GPIOLIB \
		--enable TTY \
		--disable WERROR
	make -C "$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" olddefconfig >/dev/null
	make -C "$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" modules_prepare
	make -C "$KDIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" scripts_dtc
	touch "$KDIR/.uwe5622-prepared"
}

build_driver() {
	local extra=()
	[[ ${WARN:-0} == 1 ]] && extra+=(W=1)
	[[ ${SPARSE:-0} == 1 ]] && extra+=(C=1)
	log "Building driver modules against linux-$VER ${extra[*]:-}"
	# The kernel tree is only "prepared", not built, so it has no Module.symvers
	# and modpost cannot resolve symbols the modules import from the kernel.
	# Turn that into warnings and verify the imports ourselves below.
	make -C "$KDIR" M="$SRC" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" \
		KBUILD_MODPOST_WARN=1 "${DRIVER_CONFIG[@]}" "${extra[@]}" modules 2>&1 | tee "$WORK/build-$VER.log"
	[[ ${PIPESTATUS[0]} -eq 0 ]]
	check_imports
	log "Modules"
	ls -l "$SRC"/unisocwcn/*.ko "$SRC"/unisocwifi/*.ko "$SRC"/tty-sdio/*.ko
	if command -v modinfo >/dev/null; then
		for ko in "$SRC"/unisocwcn/*.ko "$SRC"/unisocwifi/*.ko "$SRC"/tty-sdio/*.ko; do
			printf '%s: vermagic=%s\n' "$(basename "$ko")" "$(modinfo -F vermagic "$ko")"
		done
	fi
}

# Every symbol modpost could not resolve must be one the kernel exports
# (EXPORT_SYMBOL*). Anything else is a real error: a symbol that does not
# exist in this kernel version, or exists but is not available to modules.
check_imports() {
	local exports="$KDIR/.uwe5622-exports"
	local undefined missing
	undefined=$(sed -nE "s/.*WARNING: modpost: .*symbol '([A-Za-z0-9_]+)' undefined!.*/\1/p" "$WORK/build-$VER.log" | sort -u)
	[[ -n $undefined ]] || return 0
	if [[ ! -s $exports ]]; then
		log "Indexing exported symbols of linux-$VER"
		grep -rhoE 'EXPORT_SYMBOL[A-Z_]*\(\s*[A-Za-z0-9_]+' \
			--include='*.c' --include='*.S' --include='*.h' \
			"$KDIR"/{arch/$ARCH,block,crypto,drivers,fs,init,io_uring,ipc,kernel,lib,mm,net,security,sound,virt} 2>/dev/null \
			| sed -E 's/.*\(\s*//' | sort -u > "$exports"
	fi
	missing=$(comm -23 <(echo "$undefined") "$exports")
	if [[ -n $missing ]]; then
		echo "ERROR: symbols not exported by linux-$VER:" >&2
		echo "$missing" | sed 's/^/  /' >&2
		return 1
	fi
	log "Imports from the kernel: $(echo "$undefined" | wc -l) symbols, all exported"
}

build_overlay() {
	[[ ${DTS:-1} == 1 ]] || return 0
	local dtso out
	for dtso in "$SRC"/dts/*.dtso; do
		[[ -e $dtso ]] || continue
		out="$WORK/$(basename "${dtso%.dtso}").dtbo"
		log "Compiling overlay $(basename "$dtso")"
		# Same preprocessing kbuild applies to .dts files, so dt-bindings headers work.
		cpp -nostdinc -I"$KDIR/include" -I"$KDIR/arch/$ARCH/boot/dts" -undef -D__DTS__ \
			-x assembler-with-cpp "$dtso" -o "$out.tmp.dts"
		"$KDIR/scripts/dtc/dtc" -@ -I dts -O dtb -o "$out" "$out.tmp.dts"
		rm -f "$out.tmp.dts"
		ls -l "$out"
	done
}

[[ -d $KDIR ]] || fetch_kernel
[[ -e $KDIR/.uwe5622-prepared ]] || prepare_kernel
build_driver
build_overlay
log "Done: linux-$VER"
