#!/usr/bin/env bash
# Device-tree checks for the Zero 3 overlay against a real kernel DTB.
#
#   tests/dt/check-overlay.sh <kernel-version> <workdir>
#
# 1. Build sun50i-h618-orangepi-zero3.dtb from the kernel with symbols (-@).
# 2. Compile dts/sun50i-h618-orangepi-zero3-uwe5622.dtso and apply it with
#    fdtoverlay.
# 3. fdtget assertions: mmc1 enabled with the intended properties, the power
#    sequence and both regulators present and wired by phandle.
# 4. dt-validate (dtschema) on the base and the merged DTB against the
#    kernel's bindings: the overlay must not add schema errors.
# 5. Informational: does dts/patches/ still apply to this kernel?
#
# Output: <workdir>/out-dt/{dt.tap,merged.dts,validate-*.txt}
set -euo pipefail
VER=${1:?kernel version}
WORK=${2:?workdir}
. "$(dirname "$0")/../lib/kernel.sh"
. "$(dirname "$0")/../lib/tap.sh"

KDIR=$WORK/linux-$VER
OUT=$WORK/out-dt
mkdir -p "$OUT"
MK=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
DTB_REL=allwinner/sun50i-h618-orangepi-zero3.dtb
OVL_SRC=$UWE_SRC/dts/sun50i-h618-orangepi-zero3-uwe5622.dtso

kernel_fetch "$VER" "$WORK"
make -C "$KDIR" "${MK[@]}" defconfig >/dev/null
make -C "$KDIR" "${MK[@]}" -j"$(nproc)" DTC_FLAGS=-@ "$DTB_REL"
BASE=$KDIR/arch/arm64/boot/dts/$DTB_REL
cp "$BASE" "$OUT/base.dtb"

tap_begin "$OUT/dt.tap"

# Overlay, preprocessed exactly like scripts/build-against-kernel.sh does.
cpp -nostdinc -I"$KDIR/include" -I"$KDIR/arch/arm64/boot/dts" -undef -D__DTS__ \
	-x assembler-with-cpp "$OVL_SRC" -o "$OUT/overlay.pp.dts"
if "$KDIR/scripts/dtc/dtc" -@ -W no-unit_address_vs_reg -I dts -O dtb \
	-o "$OUT/overlay.dtbo" "$OUT/overlay.pp.dts" 2> "$OUT/dtc-overlay.txt"; then
	tap_ok "overlay compiles with the kernel's dtc"
else
	tap_fail "overlay compiles with the kernel's dtc" "$(cat "$OUT/dtc-overlay.txt")"
fi
if [[ -s $OUT/dtc-overlay.txt ]]; then
	tap_fail "overlay compiles without dtc warnings" "$(head -20 "$OUT/dtc-overlay.txt")"
else
	tap_ok "overlay compiles without dtc warnings"
fi

M=$OUT/merged.dtb
if fdtoverlay -i "$OUT/base.dtb" -o "$M" "$OUT/overlay.dtbo" 2> "$OUT/fdtoverlay.txt"; then
	tap_ok "fdtoverlay applies the overlay to $DTB_REL"
else
	tap_fail "fdtoverlay applies the overlay to $DTB_REL" "$(cat "$OUT/fdtoverlay.txt")"
	tap_end
	exit 0
fi
dtc -q -I dtb -O dts -o "$OUT/merged.dts" "$M"

sym() { fdtget -t s "$1" /__symbols__ "$2"; }
get() { fdtget "$@" 2>/dev/null; }
eq() { # eq "desc" expected actual
	if [[ $2 == "$3" ]]; then tap_ok "$1"; else tap_fail "$1" "expected: '$2'" "actual:   '$3'"; fi
}
phandle_of() { get -t u "$M" "$1" phandle; }

MMC=$(sym "$M" mmc1)
PIO=$(sym "$M" pio)
RTC=$(sym "$M" rtc)
VCC5V=$(sym "$M" reg_vcc5v)
PWRSEQ=/wifi-pwrseq
VCC33=/vcc33-wifi
VCCIO=/vcc-wifi-io
tap_diag "mmc1=$MMC pio=$PIO rtc=$RTC reg_vcc5v=$VCC5V"

eq "mmc1 is mmc@4021000" "/soc/mmc@4021000" "$MMC"
eq "base DTB leaves mmc1 disabled (overlay is needed)" "disabled" "$(get -t s "$OUT/base.dtb" "$MMC" status)"
eq "mmc1 status = okay" "okay" "$(get -t s "$M" "$MMC" status)"
eq "mmc1 bus-width = 4" "4" "$(get -t u "$M" "$MMC" bus-width)"
if get "$M" "$MMC" non-removable >/dev/null; then tap_ok "mmc1 non-removable"; else tap_fail "mmc1 non-removable"; fi
if get "$M" "$MMC" mmc-ddr-1_8v >/dev/null; then tap_ok "mmc1 mmc-ddr-1_8v"; else tap_fail "mmc1 mmc-ddr-1_8v"; fi
eq "mmc1 pinctrl unchanged from base (mmc1_pins)" \
	"$(get -t u "$OUT/base.dtb" "$MMC" pinctrl-0)" "$(get -t u "$M" "$MMC" pinctrl-0)"

tap_check "power sequence node /wifi-pwrseq exists" fdtget -p "$M" "$PWRSEQ"
eq "pwrseq compatible" "mmc-pwrseq-simple" "$(get -t s "$M" "$PWRSEQ" compatible)"
eq "mmc1 mmc-pwrseq -> wifi-pwrseq" "$(phandle_of "$PWRSEQ")" "$(get -t u "$M" "$MMC" mmc-pwrseq)"
eq "pwrseq reset-gpios = <&pio 6 18 GPIO_ACTIVE_LOW> (PG18)" \
	"$(phandle_of "$PIO") 6 18 1" "$(get -t u "$M" "$PWRSEQ" reset-gpios)"
eq "pwrseq clocks = <&rtc 1> (osc32k-out)" "$(phandle_of "$RTC") 1" "$(get -t u "$M" "$PWRSEQ" clocks)"
eq "pwrseq clock-names" "osc32k-out" "$(get -t s "$M" "$PWRSEQ" clock-names)"
eq "pwrseq post-power-on-delay-ms = 200" "200" "$(get -t u "$M" "$PWRSEQ" post-power-on-delay-ms)"
eq "rtc provides clock output 1 (#clock-cells = 1)" "1" "$(get -t u "$M" "$RTC" '#clock-cells')"

tap_check "3.3 V regulator node /vcc33-wifi exists" fdtget -p "$M" "$VCC33"
tap_check "1.8 V regulator node /vcc-wifi-io exists" fdtget -p "$M" "$VCCIO"
for r in "$VCC33:3300000:vcc33-wifi" "$VCCIO:1800000:vcc-wifi-io"; do
	IFS=: read -r path uv name <<<"$r"
	eq "$name compatible regulator-fixed" "regulator-fixed" "$(get -t s "$M" "$path" compatible)"
	eq "$name min = max = $uv uV" "$uv $uv" \
		"$(get -t u "$M" "$path" regulator-min-microvolt) $(get -t u "$M" "$path" regulator-max-microvolt)"
	if get "$M" "$path" regulator-always-on >/dev/null; then tap_ok "$name always-on"; else tap_fail "$name always-on"; fi
done
eq "mmc1 vmmc-supply -> vcc33-wifi" "$(phandle_of "$VCC33")" "$(get -t u "$M" "$MMC" vmmc-supply)"
eq "mmc1 vqmmc-supply -> vcc-wifi-io" "$(phandle_of "$VCCIO")" "$(get -t u "$M" "$MMC" vqmmc-supply)"
eq "vcc33-wifi fed from reg_vcc5v" "$(phandle_of "$VCC5V")" "$(get -t u "$M" "$VCC33" vin-supply)"
eq "vcc-wifi-io fed from vcc33-wifi" "$(phandle_of "$VCC33")" "$(get -t u "$M" "$VCCIO" vin-supply)"
# Nothing else in the base tree may change: compare all nodes but the new ones.
strip_new() { grep -vE 'vcc33-wifi|vcc-wifi-io|wifi-pwrseq|wifi_pwrseq|reg_vcc33_wifi|reg_vcc_wifi_io' ; }
dtc -q -I dtb -O dts -s "$OUT/base.dtb" | awk '/mmc@4021000 \{/,/};/ {next} 1' | strip_new > "$OUT/base.cmp"
dtc -q -I dtb -O dts -s "$M" | awk '/mmc@4021000 \{/,/};/ {next} 1' | strip_new \
	| awk '/^\t(vcc33-wifi|vcc-wifi-io|wifi-pwrseq) \{/,/^\t};/ {next} 1' > "$OUT/merged.cmp"
if diff -u "$OUT/base.cmp" "$OUT/merged.cmp" > "$OUT/unrelated.diff"; then
	tap_ok "overlay changes nothing outside mmc1 and its new nodes"
else
	tap_fail "overlay changes nothing outside mmc1 and its new nodes" "$(head -30 "$OUT/unrelated.diff")"
fi

# dtschema
if make -C "$KDIR" "${MK[@]}" dt_binding_schemas > "$OUT/schemas.log" 2>&1 ||
	make -C "$KDIR" "${MK[@]}" dt_binding_check DT_SCHEMA_FILES=trivial-devices.yaml >> "$OUT/schemas.log" 2>&1; then
	SCHEMA=$(find "$KDIR/Documentation/devicetree/bindings" -name processed-schema.json | head -1)
fi
if [[ -n ${SCHEMA:-} ]]; then
	# Normalise away file names so base and merged messages compare.
	norm() { sed -E "s#^[^:]*\.dtb: ##" | sort -u; }
	dt-validate -s "$SCHEMA" "$OUT/base.dtb" 2>&1 | norm > "$OUT/validate-base.txt" || true
	dt-validate -s "$SCHEMA" "$M" 2>&1 | norm > "$OUT/validate-merged.txt" || true
	comm -13 "$OUT/validate-base.txt" "$OUT/validate-merged.txt" > "$OUT/validate-new.txt"
	tap_diag "dt-validate: base $(wc -l < "$OUT/validate-base.txt") messages, merged $(wc -l < "$OUT/validate-merged.txt")"
	if [[ -s $OUT/validate-new.txt ]]; then
		tap_fail "dt-validate: overlay adds no schema errors" "$(head -30 "$OUT/validate-new.txt")"
	else
		tap_ok "dt-validate: overlay adds no schema errors"
	fi
	if grep -qiE 'mmc@4021000|wifi|pwrseq' "$OUT/validate-merged.txt"; then
		tap_fail "dt-validate: no messages about mmc1, pwrseq or the wifi regulators" \
			"$(grep -iE 'mmc@4021000|wifi|pwrseq' "$OUT/validate-merged.txt" | head -20)"
	else
		tap_ok "dt-validate: no messages about mmc1, pwrseq or the wifi regulators"
	fi
else
	tap_fail "dt-validate: processed schema built" "$(tail -30 "$OUT/schemas.log")"
fi

# Informational: Armbian's full-DTB patch kept in dts/patches/.
for p in "$UWE_SRC"/dts/patches/*.patch; do
	[[ -e $p ]] || continue
	if patch -d "$KDIR" -p1 --dry-run -s < "$p" > "$OUT/patch.txt" 2>&1; then
		tap_ok "dts/patches/$(basename "$p") applies to linux-$VER"
	else
		tap_skip "dts/patches/$(basename "$p") applies to linux-$VER" "does not apply cleanly (informational)"
	fi
done
tap_end
