<div align="center">

# luci-app-homeproxy-pro

**The modern ImmortalWrt proxy platform for ARM64 / AMD64**

基于 sing-box 1.14 内核的现代代理平台 — 简洁、高效、开箱即用。

</div>

## 项目定位

本项目是试验性产品，对 [homeproxy](https://github.com/szwjp/luci-app-homeproxy) 架构重构版：以 sing-box **1.14** 内核为唯一目标，
充分利用 1.14 引入的新特性，不再兼容 1.13 及更早内核。

## 运行要求

- ImmortalWrt / OpenWrt ≥ 24.10（`apk` 或 `opkg` 均可安装）
- **sing-box ≥ 1.14.0 是硬要求**：ImmortalWrt 25.12 源对应 sing-box 1.14.0-r1，
  而 OpenWrt 24.10 官方源没有这个版本——包能装上，服务起不来，需要换源或自建 feed
- 低于 1.14 时服务拒绝启动并记录明确日志

## 按功能性对比

| 维度 | upstream 形态 | pro 形态 |
|---|---|---|
| 后端架构 | 单文件巨型（`generate_client.uc` 1217 行 / 40 KB；`parse_uri.uc` ~400 行 / 15 KB） | orchestrator + 5 子层（`parser` / `config` / `generator` / `subscription` / `runtime`）+ 公共库（`homeproxy.uc` / `firewall_utils.uc`）+ table-driven adapters |
| 前端架构 | 单一 66 KB `client.js` | `client.js` thin 入口 + 8 个 Tab 模块（`access` / `common` / `dns` / `nodes` / `routing` / `subscription` / `tun_dns` / `udp_nat`）+ 共享 helpers + 集中 `RPC.declare` |
| reload 事务 | 写完直接 restart | 生成 → `sing-box check` → 新实例 probe → 健康门（连续采样）→ 提为 known-good；不健康自动回滚 |
| 健康门 | `ubus` + `pgrep` 简单轮询 | `hp_wait_service` 连续 N 次采样（默认 3/30s）+ `netstat -p` 端口归属校验；不健康自动 rollback |
| 防火墙渲染 | stub（设备侧强约束） | 强制 + 渲染层（PR-06） |
| 后端字段校验 | 仅前端 | 前后端两道：UI 是 UX，后端强制（review H1） |
| 资源更新策略 | jsdelivr 单一镜像 | 多镜像 fallback（`fastly.jsdelivr.net` / `gcore.jsdelivr.net` / `cdn.jsdelivr.net` / `raw.githubusercontent.com`）+ UI「上次成功时间」（review M7） |
| 订阅 token 脱敏 | 调用点记得才脱敏 | `wGETVerbose()` 内部下沉到源头（review H3） |
| 架构守卫 | 无 | `tests/arch-guard.sh` 25 个 guard / 115 个 check（PR-07 起；guard 编号 1-19, 21-26） |
| 测试规模 | 7 个脚本 / 约 27 个 check | 52 个测试脚本（`tests/` 下共 69 个文件）：ucode 套件 + 5 个 frontend 验证器 + golden snapshot + mocks；arch-guard 单跑 113 个 check |
| CI | `build` + `i18n` 两条平行 workflow | `build` 依赖 `arch-test`；`arch-test` 7 步：翻译 fast gate → toolchain cache/构建 → `tests/run.sh`（唯一套件入口，含 arch-guard）→ 模板检查 |
| ECH 上传 | 仅后端 case 缺失 | 补齐 `client_ech_conf`（P0-4） |
| capabilities | 含 `CAP_SYS_PTRACE` + `CAP_NET_RAW` | 仅 `CAP_NET_ADMIN` + `CAP_NET_BIND_SERVICE`；`inheritable` 保留 ambient 子集以支撑跨 fork 传承（review H2） |
| 默认测试主机 | 硬编码作者内网 IP | 改为空，未设时 fail-fast 拒绝运行（不去猜测地址，review M1） |
| 文档 | 标准（README + CONTRIBUTING + SECURITY） | 精简（README only），本地 `docs/` 自留 |

**一句话总结**：pro 的核心价值是**把"单文件能跑"变成"orchestrator + table-driven adapter + 可独立测试的模块"**，并把约束、质量、回滚三件事从靠人盯变成靠代码执行。

## 已知限制

- **试验性**：不承诺 API/配置稳定，重大变更可能在 minor 版本里发生。
- **真机实测单平台**：本仓库只在 x86-64 软路由上做过端到端验证。
- 本包不会编译 sing-box。系统固件必须自带 sing-box 1.14+;否则依赖解析直接失败。

## 贡献

欢迎 issue / PR。架构边界规则是可执行的，固化在 `tests/arch-guard.sh`（PR 必跑，
每条规则都注明对应的 guard）；架构层面的变更请先开 issue 讨论，避免在
PR review 里来回拉扯。

## 漏洞上报

代理类项目请不要在公开 issue 里讨论可被利用的细节（如订阅 token 格式、capabilities
边界、XSS 载荷等）。安全相关问题请通过 GitHub Security Advisabilities 渠道提交，
或联系 maintainer 私下沟通。

## License

[GPL-2.0-only](LICENSE) — 版权归 ImmortalWrt.org 与各贡献者。
