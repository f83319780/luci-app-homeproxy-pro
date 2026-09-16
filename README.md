<div align="center">

# luci-app-homeproxy-pro

**The modern ImmortalWrt proxy platform for ARM64 / AMD64**

基于 sing-box 1.14 内核的现代代理平台 — 简洁、高效、开箱即用。

</div>

## 项目定位

本项目是试验性产品，对 homeproxy 架构重构版：以 sing-box **1.14** 内核为唯一目标，
充分利用 1.14 引入的新特性，不再兼容 1.13 及更早内核。

**仅在生产路由器上尝试过本项目的用户，欢迎反馈实际问题**——本 README 是面向用户的入口，
架构设计与权衡见 [`docs/`](docs/)。

## 运行要求

- ImmortalWrt / OpenWrt ≥ 24.10（`apk` 或 `opkg` 均可安装）
- sing-box ≥ 1.14.0（ImmortalWrt 25.12 源对应 sing-box 1.14.0-r1）
- 低于 1.14 时服务拒绝启动并记录明确日志

## 安装

仓库只发布 `.apk` / `.ipk` 包（不要从源码构建——见下文「已知限制」）。

### ImmortalWrt（apk）

```sh
# 两个包：本体 + 中文语言包
apk add luci-app-homeproxy
apk add luci-i18n-homeproxy-zh-cn

# 卸载
apk del luci-app-homeproxy luci-i18n-homeproxy-zh-cn
```

`luci-i18n-homeproxy-zh-cn` 是独立包，**只装本体不装语言包界面会是英文**。

### OpenWrt（opkg）

```sh
opkg install luci-app-homeproxy_28.9.1.14-r2_all.ipk
opkg install luci-i18n-homeproxy-zh-cn_28.9.1.14-r2_all.ipk
```

包文件名形态见 [Releases](../../releases)。

## 与上游 homeproxy 的差异

| 项 | 上游 homeproxy | 本仓库 |
|---|---|---|
| 架构分层 | 一锅端（homeproxy.uc ~1200 行） | 6 层（parser / config / generator / subscription / runtime / orchestrator） |
| reload 事务 | 写完直接 restart | 生成 → 校验 → 停旧实例 → 健康门 → 提为 known-good，失败回滚 |
| 架构守卫 | 无 | `tests/arch-guard.sh` 16 条跨层不变量（PR-07） |
| 防火墙渲染 | stub（设备侧强约束） | 强制 + 渲染层（PR-06） |
| 后端字段校验 | 仅前端 | 前后端两道：UI 是 UX，后端强制（review H1） |
| 资源更新策略 | jsdelivr 单一镜像 | 计划中加多镜像 fallback + UI「上次成功时间」（review M7） |
| ECH 上传 | 仅后端 case 缺失 | 补齐 `client_ech_conf`（P0-4） |
| capabilities | 含 `CAP_SYS_PTRACE` + `CAP_NET_RAW` | 仅 `CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE`，`inheritable` 留空（review H2） |
| 订阅 token 脱敏 | 调用点记得才脱敏 | `wGETVerbose()` 内部下沉到源头（review H3） |
| 默认测试主机 | 硬编码作者内网 IP | 改为空，未设时 SKIP（review M1） |

## 从上游 homeproxy 迁移

> ⚠️ **迁移前必读**：节点和订阅不会被自动迁移，请先导出再安装。

```sh
# 1. 导出当前节点（不可恢复项）
uci export homeproxy > /tmp/homeproxy.before-pro.conf

# 2. 停掉上游 homeproxy 服务
/etc/init.d/homeproxy stop

# 3. 安装新包
apk add luci-app-homeproxy luci-i18n-homeproxy-zh-cn
# 或 opkg install ...

# 4. 手动重建：节点 / DNS / server / subscription
#    LuCI → 服务 → HomeProxy Pro 重建这四个 section
```

迁移工具 `migrate_config.uc` 会处理 1.14 的 DNS 重命名、`rcode://` → 预定义规则、
`block-out`/`block-dns` → `action='reject'` 等结构性变更，但**只动非破坏性的结构**，
节点、订阅和服务器配置需要你重建。

## 已知限制

- **试验性**：不承诺 API/配置稳定，重大变更可能在 minor 版本里发生。
- **真机实测单平台**：本仓库只在 x86-64 软路由上做过端到端验证。
- **不自举**：本包不会编译 sing-box。系统固件必须自带 sing-box 1.14+，
  否则依赖解析直接失败。
- **ucode 方言锁定**：ucode pin 到目标快照的 revision（`UCODE_REV` in
  `tests/toolchain/build-ucode-linux.sh`），不能换上游默认分支的 ucode——
  否则会编出设备上无法 parse 的代码。
- **CI 不跑设备侧**：on-target 套件需要 LAN 测试机和 SSH 私钥，是手动触发的
  workflow，不在 PR 反馈环里。

## 版本号语义

- `PKG_VERSION = YY.MM.PATCH.<sing-box_minor>`，例如 `28.9.1.14`：
  - `28.9` = 2028 年 9 月的快照
  - `.1` = 该月内的第 1 个发版
  - `.14` = 目标 sing-box minor 版本
- `PKG_RELEASE` 是该 `PKG_VERSION` 下的迭代号（`r1`, `r2`, ...），只在修补
  同一版本时递增。

发版周期与 tag 由 `.github/workflows/build.yml` 管，参见 [`docs/architecture-improvement-plan.md`](docs/architecture-improvement-plan.md)。

## 文档

- [`docs/architecture-improvement-plan.md`](docs/architecture-improvement-plan.md) — 实施账本（按 PHASE 记录所有 commit）
- [`docs/audit-report.md`](docs/audit-report.md) — 上一轮审计
- [`docs/next-step-plan.md`](docs/next-step-plan.md) — 本轮优先级排序
- [`docs/homeproxy_architecture_refactor_agent_guide.md`](docs/homeproxy_architecture_refactor_agent_guide.md) — 架构规格（ABSOLUTE RULES）
- [`docs/重构实施间断性指导建议.md`](docs/重构实施间断性指导建议.md) — 下一阶段判断基准
- [`tests/README.md`](tests/README.md) — 测试套件使用说明（面向维护者）

## 贡献

欢迎 issue / PR。架构边界规则以 `agent_guide` 的 ABSOLUTE RULES 为准；
改动细节以 `architecture-improvement-plan.md` 为唯一权威。架构层面的变更请先开
issue 讨论，避免在 PR review 里来回拉扯。

## 漏洞上报

代理类项目请不要在公开 issue 里讨论可被利用的细节（如订阅 token 格式、capabilities
边界、XSS 载荷等）。安全相关问题请通过 GitHub Security Advisabilities 渠道提交，
或联系 maintainer 私下沟通。

## License

[GPL-2.0-only](LICENSE) — 版权归 ImmortalWrt.org 与各贡献者。