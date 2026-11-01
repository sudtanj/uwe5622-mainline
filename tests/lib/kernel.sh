# shellcheck shell=bash
# Kernel source helpers shared by the tests/ scripts.
#
#   . tests/lib/kernel.sh
#   kernel_fetch 6.18.60 "$RUNNER_TEMP"      # -> $RUNNER_TEMP/linux-6.18.60
#   kernel_prepare "$KDIR" ARCH=arm64 LLVM=1  # defconfig + driver deps + modules_prepare
#   make -C "$KDIR" M="$UWE_SRC" "${UWE_DRIVER_CONFIG[@]}" ... modules

UWE_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Same selection as dkms.conf and scripts/build-against-kernel.sh.
UWE_DRIVER_CONFIG=(CONFIG_AW_WIFI_DEVICE_UWE5622=y CONFIG_WLAN_UWE5622=m CONFIG_TTY_OVERY_SDIO=m)

kernel_url() {
	local ver=$1
	case "$ver" in
	*-rc*) echo "https://git.kernel.org/torvalds/t/linux-$ver.tar.gz" ;;
	*) echo "https://cdn.kernel.org/pub/linux/kernel/v${ver%%.*}.x/linux-$ver.tar.xz" ;;
	esac
}

# kernel_fetch <version> <parent-dir>: download and extract once.
kernel_fetch() {
	local ver=$1 parent=$2 url tarball
	[[ -f $parent/linux-$ver/Makefile ]] && return 0
	url=$(kernel_url "$ver")
	tarball=$parent/${url##*/}
	mkdir -p "$parent"
	echo "==> downloading $url"
	wget -q --tries=5 --waitretry=10 -O "$tarball" "$url"
	tar -C "$parent" -xaf "$tarball"
	rm -f "$tarball"
}

# kernel_prepare <kdir> <make args...>: arm64 defconfig plus what the driver
# needs, then modules_prepare. Enough for an out-of-tree module build.
kernel_prepare() {
	local kdir=$1
	shift
	make -C "$kdir" "$@" -j"$(nproc)" defconfig >/dev/null
	"$kdir/scripts/config" --file "$kdir/.config" \
		--enable MODULES --module CFG80211 --enable RFKILL \
		--enable MMC --enable MMC_SUNXI --enable REGULATOR \
		--enable REGULATOR_FIXED_VOLTAGE --enable PWRSEQ_SIMPLE \
		--enable OF --enable GPIOLIB --enable TTY --disable WERROR
	make -C "$kdir" "$@" -j"$(nproc)" olddefconfig >/dev/null
	make -C "$kdir" "$@" -j"$(nproc)" modules_prepare
}

# Remove build products of the driver from the source tree.
driver_clean() {
	find "$UWE_SRC"/unisocwcn "$UWE_SRC"/unisocwifi "$UWE_SRC"/tty-sdio "$UWE_SRC"/tests \
		\( -name '*.o' -o -name '*.ko' -o -name '*.mod' -o -name '*.mod.c' -o -name '.*.cmd' \
		-o -name 'modules.order' -o -name 'Module.symvers' -o -name '*.mod.o' \) -delete 2>/dev/null || true
	rm -f "$UWE_SRC"/modules.order "$UWE_SRC"/Module.symvers
}
