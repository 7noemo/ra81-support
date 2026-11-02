# Redmi AX3000 (RA81) — mainline OpenWrt board support

Board support package that makes the **Redmi AX3000 (RA81)** build and boot on
mainline OpenWrt / ImmortalWrt (the `qualcommax` target), instead of the
vendor QSDK tree.

This repo only carries what upstream does **not** have: the device tree, the
two calibration blobs, and an install script. It does not fork OpenWrt.

```
dts/ipq5018-redmi-ax3000.dts     full device tree for the mainline layout
files/board-redmi_ax3000.*       BDF (board-2.bin) for 2.4G and 5G
scripts/install-into-openwrt.sh  idempotent injection into a source tree
```

## Hardware

| Part | Detail |
|------|--------|
| SoC | IPQ5018 (marketed as IPQ5000), 2× Cortex-A53 |
| 2.4 GHz | IPQ5018 built-in radio (AHB, 2×2) |
| 5 GHz | QCN6102, 2×2 @160 MHz, runs as a WCSS **userpd** (multipd) |
| Switch | QCA8337 — port1-3 = LAN1-3, port4 = WAN, port5 = GE PHY, port6 = SGMII CPU |
| RAM / Flash | 256 MiB / 128 MiB NAND, stock A/B rootfs layout |
| Serial | UART on GPIO20/21, 115200 8n1 |

MAC addresses live in `0:art` (0x0 → gmac1, 0x6 → gmac0), same offsets as the
Redmi AX5400.

## Why this exists

ImmortalWrt master ships ~30 IPQ5018 boards (including the Redmi AX5400) but
not the RA81. The platform side is fine — only three things are missing:

1. **No device tree.** Written from scratch against the mainline layout
   (`ipq5018.dtsi` + `ipq5018-ess.dtsi` + `ipq5018-qcn6122.dtsi`), using the
   RA5400 tree as the structural reference and the RA81 stock partition table
   from `cat /proc/mtd`.
2. **No BDF.** The 2.4G blob is the M81/M79 pair (`qmi-board-id` 36 and 16),
   the 5G blob is `qmi-board-id` 96 — matching what the QCN6102 reports.
3. **No device definition.** A `Device/redmi_ax3000` plus one `02_network`
   case, both injected by the script.

## Ethernet: stmmac + DSA, not qca-nss-dp

Mainline (ImmortalWrt master, kernel 6.18) moved IPQ5018 ethernet to
**stmmac** with the QCA8337 handled by **DSA** (`qca8k`). The RA81 tree here
follows that: `gmac0` → internal GE PHY → switch PHY4, `gmac1` → SGMII →
switch CPU port, and `lan1/lan2/lan3/wan` are DSA ports.

This is a deliberate choice, and it has one consequence:

> **NSS hardware offload is not available on this tree.** NSS needs
> `qca-nss-dp` to hook the data path; mainline replaced it with stmmac, and
> `package/kernel/qca-nss-dp` no longer exists on master. For NSS you need the
> `openwrt-25.12` (kernel 6.12) branch — see the separate NSS experiment repo.
>
> On a gigabit-only box like the RA81 the practical loss is small: stmmac +
> software NAT already saturates a 1 GbE line. NSS mainly pays off for Wi-Fi
> offload and >1G ports.

## 2.4 GHz and `board_id`

The 2.4G radio needs a `board_id` that matches the PA variant on the board:
M81 (RA81) = `0x24`, M79 (CR880x) = `0x10`. Getting this wrong is the classic
"2.4 GHz disappears / very weak" symptom.

Mainline ath11k **does not read `qcom,board_id` from DT** — it takes the value
from the QMI CALIB data inside `0:art`, which every unit carries
pre-calibrated. That is correct for a real RA81, so this tree does not patch
ath11k. Both board-ids are present in the shipped BDF, so the same image also
works on CR880x.

If you hit a unit whose art reports the wrong id, the fallback is to patch
`ath11k` to accept a DT override — the old QSDK `board_id-ahb-c000000.wifi`
firmware trick does not exist on mainline.

## Usage

```bash
git clone https://github.com/7noemo/immortalwrt.git -b master openwrt
cd openwrt
git clone https://github.com/7noemo/ra81-support.git
./ra81-support/scripts/install-into-openwrt.sh .
make menuconfig     # Target: Qualcomm Atheros 802.11ax WiSoC-s → ipq50xx → Redmi AX3000
make -j$(nproc)
```

Or just use the ready-made firmware repo:
**https://github.com/7noemo/Redmi-AX3000-ImmortalWrt**

## Flashing

Stock bootloader + UBI is required. The image expects the **stock partition
table** (22 partitions, `rootfs` at `0xa80000`, 36 MiB). It installs into slot
A and leaves slot B untouched, so a stock rollback via the Xiaomi repair tool
stays possible.

Get in via the CR880x/RA81 U-Boot, write the factory UBI once, then use
`sysupgrade` normally.

> Flashing is always at your own risk. Keep a full NAND dump before the first
> write.

## Credits & licence

- Device tree layout derived from `hzyitc/openwrt-redmi-ax3000`
  (GPL-2.0-or-later), rewritten for the mainline stmmac+DSA layout.
- BDF blobs are the vendor calibration data redistributed the same way
  OpenWrt's `ipq-wifi` package does. They remain property of their origin.
- Everything in this repo: **GPL-2.0-or-later**.

PRs that move any of this upstream into `immortalwrt/immortalwrt` are welcome;
the goal is for this repo to become unnecessary.
