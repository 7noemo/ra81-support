# NSS 硬件加速在 RA81 上的可行性结论

> 结论先行：**目前没有一条可交付的开源路径能在 RA81 上启用 NSS offload。**
> 这不是"少写一个驱动"，而是内核数据面架构的冲突。下面是查证过程与证据，
> 留给以后的人少走弯路。

## 什么是 NSS，为什么它和主线冲突

NSS（Network Subsystem）是 Qualcomm 在 SoC 里的一颗网络协处理器，能把 NAT、
PPPoE、VLAN、QoS 甚至 Wi-Fi 转发卸载出去，CPU 只处理控制面。要用它，必须
同时满足三件事：

1. **固件**：`nss-firmware-<soc>`，按 SoC 分（IPQ8074 / IPQ6018 / IPQ5018）
2. **驱动**：`qca-nss-drv` + `qca-nss-ecm`（ECM = 连接管理器，决定哪些流可卸载）
3. **数据面**：`qca-nss-dp`（NSS Data Plane 以太网驱动）——**关键**

第 3 点是死结：NSS 只能挂在 `qca-nss-dp` 上。数据包必须经过 NSS-DP 的
`nss_dp_xmit` 才能被协处理器接管。

而 ImmortalWrt 从 24.10 起，把 IPQ5018 的以太网换成了上游内核的 **stmmac**
（master）或 **stmmac + DSA qca8k**（25.12）。stmmac 是标准内核网卡驱动，
数据包走 `dev_queue_xmit` → 内核协议栈，**没有 NSS 挂载点**。

## 三条路，逐条查证

### 路线 A：ImmortalWrt master（6.18）

```
target/linux/qualcommax/ipq50xx/config-default  ->  CONFIG_STMMAC_ETH=y
package/kernel/qca-nss-dp                        ->  404（已被移除）
package/kernel/qca-ssdk                          ->  只剩 patches/，无 Makefile
```

数据面已是 stmmac，且 NSS-DP 包根本不存在。**不通。**

### 路线 B：ImmortalWrt openwrt-25.12（6.12）

```
package/kernel/qca-nss-dp/Makefile   ->  存在，PKG_SOURCE openwrt/qca-nss-dp，2025-11-24
package/kernel/qca-ssdk              ->  Makefile + patches 完整
ipq50xx/config-default               ->  CONFIG_NET_DSA=y / CONFIG_NET_DSA_QCA8K=y
patches-6.12 (101 个)                ->  无 ess-switch / nss-dp 框架补丁
```

包是完整的，看起来有戏，但有两个硬伤：

- ipq50xx **全部设备走 DSA**，`ipq5018-ess.dtsi` 描述的是 stmmac 的 gmac0/gmac1，
  不是 QSDK 的 `ess-switch` / `qcom,nss-dp` 节点
- 内核补丁里**没有** ess-switch / nss-dp 框架支持。qca-nss-dp 编出来也挂不上，
  因为没有 `ess-switch` 设备可以 attach

要救这条路，得把 QSDK 的 ess-switch + nss-dp 框架补丁（几十个 patch，涉及
phylink、switchdev、DSA 互斥）移植回 6.12，再重写设备树，并处理与 DSA 的冲突。
**工程量以人月计，且 IPQ50xx 无人验证过。**

### 路线 C：hzyitc 的 QSDK 风格树（5.15）+ NSS 11.4

hzyitc 的 `ipq50xx-mainline-kernel-5.15-openwrt-23.05` 是唯一有 nss-dp 数据面的
现成树——他的 dts 里就是：

```dts
mac0: dp1 { compatible = "qcom,nss-dp"; ... };
mac1: dp2 { compatible = "qcom,nss-dp"; ... };
ess-switch@0x39c00000 { compatible = "qcom,ess-switch-ipq50xx"; ... };
```

数据面齐了，但 **NSS 固件没有 IPQ5018 版本**：

```
qosmio/nss-packages  NSS-11.4-K5.15  ->  grep ipq5018/ipq50xx: 无任何结果
qosmio/nss-packages  NSS-12.4-K6.x   ->  nss-firmware-ipq5018（DEPENDS TARGET_qualcommax_ipq50xx）
qosmio/nss-packages  NSS-12.5-K6.x   ->  nss-firmware-ipq50xx（NSS_SOC=MP, IPQ_PLATFORM=IPQ5018）
```

IPQ5018 的 NSS 固件只在 **12.x**（配 6.x 内核）里。5.15 + 11.4 的组合拿不到固件。
**不通。**

### 路线 D：qosmio 的 OpenWrt fork + NSS 12.5

NSS 12.4/12.5 有 IPQ5018 固件，但它依赖的内核补丁在 **qosmio 自己的 openwrt fork**
里（README 原文：*"these require kernel patches which are part of the main OpenWrt
tree"*，指的是他的树，不是 immortalwrt）。而且：

> README 原文：`IPQ50xx (Untested)`

把 RA81 的设备树、BDF、分区表、交换芯片配置全部移植到另一个 fork，并成为该
fork 上第一个跑 IPQ5018 的人——风险极高，且上游没有维护承诺。**理论可行，不建议。**

## 汇总

| 路线 | 数据面 | NSS 固件 | 内核补丁 | 结论 |
|------|--------|----------|----------|------|
| A master 6.18 | stmmac | 无包 | — | 不通 |
| B 25.12 6.12 | DSA | 有包 | 无 ess/nss 补丁 | 要人月级移植 |
| C 5.15 + NSS 11.4 | nss-dp ✓ | 无 IPQ5018 | ✓ | 不通 |
| D qosmio fork 6.x | nss-dp ✓ | ✓ | ✓（他的树） | untested，高风险 |

**没有交集。** 这就是为什么这个仓最终没有交付 NSS 固件——不是没试，是四条路
都堵死了，硬做一个出来只会得到一个刷进去没网、还查不出原因的半成品。

## 那千兆口怎么办：软件加速

RA81 是 **全千兆口**（1×WAN + 3×LAN），瓶颈根本不在 CPU 转发能力：

- IPQ5018 双核 A53 @1GHz，纯软 NAT 约 **1.2–1.5 Gbps**
- 千兆线速实际上限 ≈ **940 Mbps**
- 也就是说，软转发本身已经**超过线速 30%+**

所以做这几件事的收益，比 NSS 更直接、更稳：

1. **软件 flow offload**（`fw4` flowtable）—— 首包走协议栈，后续包走 flowtable
   快路径，NAT 转发可到线速且几乎不吃 CPU。已在固件里默认开启。
2. **BBR** 拥塞控制 —— 改善长肥管道与大 RTT 下的吞吐（已内置 `kmod-tcp-bbr`）。
3. **RPS/XPS** —— 把软中断分散到两个核，避免单核打满（已在 `99-ra81-tuning` 里设）。
4. **SQM/CAKE** —— 真正影响体验的是 bufferbloat，不是峰值带宽（已内置 LuCI SQM）。

NSS 真正值钱的场景是 **Wi-Fi offload**（把 160MHz 的 5G 转发也卸载）和
**2.5G/万兆口**。前者需要 QSDK 版 ath11k（主线 ath11k 没有 NSS offload 代码），
后者 RA81 的硬件就没有。所以对这台机器，NSS 的边际收益本来就很小。

## 如果将来要做

值得盯的两个信号：

1. `openwrt/qca-nss-dp` 仓库重新出现 ipq50xx 的 `ess-switch` 绑定，或
2. 上游 qualcommax 重新引入 `TARGET_qualcommax_ipq50xx` 的 nss-dp 变体

任一出现，这个仓会跟进。届时需要的额外工作：nss-dp 版 dts（可参考 hzyitc 的
写法）、关闭 DSA、启用 ess-switch、qca-ssdk 的 ipq50xx profile。
