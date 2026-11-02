#!/bin/bash
#
# Install Redmi AX3000 (RA81) board support into an OpenWrt / ImmortalWrt tree.
#
# Usage:  ./scripts/install-into-openwrt.sh /path/to/openwrt
#
# Supported trees:
#   - ImmortalWrt master / openwrt-25.12 and any OpenWrt 24.10+
#     (layout: target/linux/qualcommax/{dts,image,ipq50xx})
#
# What it does (all idempotent, safe to run twice):
#   1. installs dts/ipq5018-redmi-ax3000.dts
#   2. installs the two BDF blobs into package/firmware/ipq-wifi/src/
#   3. registers ipq-wifi-redmi_ax3000 in the ipq-wifi Makefile
#   4. appends Device/redmi_ax3000 to target/linux/qualcommax/image/ipq50xx.mk
#   5. adds the redmi,ax3000 case to ipq50xx base-files 02_network
#
# Everything is verified at the end; the script exits non-zero if a single
# piece did not land, so a CI job fails in seconds instead of after 2 hours
# of compiling a firmware without Wi-Fi.

set -e

TOPDIR="${1:-.}"
SELF="$(cd "$(dirname "$0")/.." && pwd)"

QCA="$TOPDIR/target/linux/qualcommax"
IPQ50XX="$QCA/ipq50xx"
IPQWIFI="$TOPDIR/package/firmware/ipq-wifi"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

die() { red "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------- sanity ----
[ -d "$QCA" ]     || die "no $QCA - this does not look like an OpenWrt tree with qualcommax"
[ -d "$IPQ50XX" ] || die "no $IPQ50XX - qualcommax has no ipq50xx subtarget"
[ -d "$IPQWIFI" ] || die "no $IPQWIFI - ipq-wifi package missing"

# Master moved the DTS files to target/linux/qualcommax/dts/, while 24.10/25.12
# still keep them under files/arch/arm64/boot/dts/qcom/. Support both.
if [ -d "$QCA/dts" ]; then
	DTS_OUT="$QCA/dts"
elif [ -d "$QCA/files/arch/arm64/boot/dts/qcom" ]; then
	DTS_OUT="$QCA/files/arch/arm64/boot/dts/qcom"
else
	die "cannot locate the qualcommax DTS directory (neither dts/ nor files/arch/arm64/boot/dts/qcom/)"
fi

# Master/25.12 both drive IPQ5018 ethernet through stmmac + DSA qca8k. If a
# tree still uses qca-nss-dp, the DTS below will not bring ethernet up.
if [ -f "$IPQ50XX/config-default" ] && \
   ! grep -qE 'CONFIG_NET_DSA_QCA8K|CONFIG_STMMAC_ETH' "$IPQ50XX/config-default"; then
	red "WARNING: no DSA qca8k / stmmac in $IPQ50XX/config-default"
	red "         this port targets the mainline stmmac+DSA layout."
fi

echo ">>> target tree : $QCA"
echo ">>> dts dir    : $DTS_OUT"
echo ">>> source     : $SELF"

# ------------------------------------------------------------------ dts ----
install -m 0644 "$SELF/dts/ipq5018-redmi-ax3000.dts" "$DTS_OUT/ipq5018-redmi-ax3000.dts"
green "OK  dts -> ${DTS_OUT#$TOPDIR/}/ipq5018-redmi-ax3000.dts"

# ------------------------------------------------------------------ bdf ----
install -m 0644 "$SELF/files/board-redmi_ax3000.ipq5018" "$IPQWIFI/src/board-redmi_ax3000.ipq5018"
install -m 0644 "$SELF/files/board-redmi_ax3000.qcn6122" "$IPQWIFI/src/board-redmi_ax3000.qcn6122"
green "OK  bdf -> ipq-wifi/src/board-redmi_ax3000.{ipq5018,qcn6122}"

# ------------------------------------------------------- ipq-wifi Makefile --
python3 - "$IPQWIFI/Makefile" <<'PY'
import sys, re, pathlib

p = pathlib.Path(sys.argv[1])
s = p.read_text()

if "redmi_ax3000" in s:
    print("SKIP ipq-wifi Makefile already carries redmi_ax3000")
    sys.exit(0)

# 1) register in BOARD_NAMES (keep the list alphabetical: redmi_ax3000 < redmi_ax6)
m = re.search(r'^BOARD_NAMES\s*:=\s*\\\n', s, re.M)
if not m:
    sys.exit("FAIL: BOARD_NAMES block not found in ipq-wifi/Makefile")

anchor = "\tredmi_ax6 \\\n"
if anchor in s:
    s = s.replace(anchor, "\tredmi_ax3000 \\\n" + anchor, 1)
else:
    # fall back to inserting right after the BOARD_NAMES opener
    s = s[:m.end()] + "\tredmi_ax3000 \\\n" + s[m.end():]

# 2) emit the package
line = "$(eval $(call generate-ipq-wifi-package,redmi_ax3000,Redmi AX3000))\n"
ref = "$(eval $(call generate-ipq-wifi-package,xiaomi_redmi-ax5400,Xiaomi Redmi AX5400))\n"
if ref in s:
    s = s.replace(ref, ref + line, 1)
else:
    s = s.rstrip("\n") + "\n" + line

p.write_text(s)
print("OK  ipq-wifi/Makefile patched")
PY
green "OK  ipq-wifi-redmi_ax3000 registered"

# ------------------------------------------------------------ device def ----
python3 - "$IPQ50XX/image/ipq50xx.mk" <<'PY'
import sys, pathlib

p = pathlib.Path(sys.argv[1])
s = p.read_text()

if "Device/redmi_ax3000" in s:
    print("SKIP ipq50xx.mk already defines redmi_ax3000")
    sys.exit(0)

block = """
# ---------------------------------------------------------------- Redmi AX3000
# IPQ5018 + QCA8337 + QCN6102 (5G as a WCSS userpd).
# Stock NAND layout is 128 MiB with A/B rootfs; we always install into slot A
# (mtd18 "rootfs") and keep slot B read-only for a stock rollback.
define Device/redmi_ax3000
\t$(call Device/FitImage)
\t$(call Device/UbiFit)
\tDEVICE_VENDOR := Redmi
\tDEVICE_MODEL := AX3000
\tDEVICE_ALT0_VENDOR := Xiaomi
\tDEVICE_ALT0_MODEL := CR880x
\tDEVICE_ALT0_VARIANT := (same image, BDF covers M79/M81)
\tSOC := ipq5018
\tDEVICE_DTS := ipq5018-redmi-ax3000
\tDEVICE_DTS_CONFIG := config@mp03.1
\tBLOCKSIZE := 128k
\tPAGESIZE := 2048
\tKERNEL_SIZE := 36864k
\tNAND_SIZE := 128m
\tDEVICE_PACKAGES := ath11k-firmware-ipq5018-qcn6122 \\
\t\tipq-wifi-redmi_ax3000
endef
TARGET_DEVICES += redmi_ax3000
"""

p.write_text(s.rstrip("\n") + "\n" + block)
print("OK  ipq50xx.mk patched")
PY
green "OK  Device/redmi_ax3000 appended"

# ------------------------------------------------------------- 02_network ----
python3 - "$IPQ50XX/base-files/etc/board.d/02_network" <<'PY'
import sys, pathlib

p = pathlib.Path(sys.argv[1])
s = p.read_text()

if "redmi,ax3000" in s:
    print("SKIP 02_network already knows redmi,ax3000")
    sys.exit(0)

# Same DSA topology as xiaomi,redmi-ax5400: qca8337 with gmac1 as CPU port.
case = """\tredmi,ax3000)
\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"
\t\tucidef_set_network_device_conduit "lan1" "eth1"
\t\tucidef_set_network_device_conduit "lan2" "eth1"
\t\tucidef_set_network_device_conduit "lan3" "eth1"
\t\tucidef_set_network_device_conduit "wan" "eth1"
\t\t;;
"""

marker = "\txunison,exigo-hub-d50-5g)"
if marker in s:
    s = s.replace(marker, case + marker, 1)
else:
    # last resort: insert before the closing brace of the first case block
    idx = s.find("\tesac\n")
    if idx < 0:
        sys.exit("FAIL: cannot find a case block in 02_network")
    s = s[:idx] + case + s[idx:]

p.write_text(s)
print("OK  02_network patched")
PY
green "OK  redmi,ax3000 interfaces"

# --------------------------------------------------------------- verify ----
echo ""
echo ">>> verification"
fail=0
check() {
	if [ -e "$2" ]; then
		echo "  OK   $1"
	else
		red "  FAIL $1 ($2)"; fail=1
	fi
}
check "dts"                  "$DTS_OUT/ipq5018-redmi-ax3000.dts"
check "2.4G bdf"             "$IPQWIFI/src/board-redmi_ax3000.ipq5018"
check "5G bdf"               "$IPQWIFI/src/board-redmi_ax3000.qcn6122"
grep -q "redmi_ax3000" "$IPQWIFI/Makefile"                       || { red "  FAIL ipq-wifi Makefile"; fail=1; }
grep -q "Device/redmi_ax3000" "$IPQ50XX/image/ipq50xx.mk"        || { red "  FAIL ipq50xx.mk"; fail=1; }
grep -q "redmi,ax3000" "$IPQ50XX/base-files/etc/board.d/02_network" || { red "  FAIL 02_network"; fail=1; }

if [ "$fail" -ne 0 ]; then
	die "board support did not land completely"
fi

green ">>> Redmi AX3000 support installed"
echo "    build with: make image PROFILE=redmi_ax3000"
