<div align="center">

# luci-app-homeproxy

**The modern ImmortalWrt proxy platform for ARM64 / AMD64**

基于 sing-box 1.14 内核的现代代理平台 — 简洁、高效、开箱即用。

---

</div>

## 项目定位

本项目是 [luci-app-homeproxy](https://github.com/szwjp/homeproxy) 的**分拆版本线**：以 sing-box **1.14** 内核为唯一目标，充分结合 1.14 引入的新特性进行升级，不再兼容 1.13 及更早内核。

| 版本线 | 内核要求 | 演进方式 |
| --- | --- | --- |
| **homeproxy1.14**（本项目） | sing-box ≥ 1.14 | 1.14 特性驱动，配置生成直接使用 1.14 新格式 |

## 运行要求

- ImmortalWrt / OpenWrt ≥ 24.10+（apk 或 opkg 均可安装）
- sing-box ≥ 1.14.0（ImmortalWrt 25.12 源对应 sing-box 1.14.0-r1）
- 低于 1.14 时服务会拒绝启动并记录明确日志




<div align="center">

[![License](https://img.shields.io/badge/License-GPL--2.0--only-blue.svg)](LICENSE) 版权归 ImmortalWrt.org 与各贡献者

</div>
