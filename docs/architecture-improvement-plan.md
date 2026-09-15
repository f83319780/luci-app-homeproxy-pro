# 架构重构改进建议（对照 `homeproxy_architecture_refactor_agent_guide.md`）

> **配套文档**：`docs/重构实施间断性指导建议.md`（28 项核心观点 + 7 个 PR 路线）是本文的
> **后续阶段指引**。本文记录的是"怎么把项目修到能跑、可维护"的实施账本；
> 那一份记录的是"接下来按什么边界推进"的判断基准。两份结论一致（当前架构成熟度 80–85%）。
>
> 分歧处理原则：**具体改动细节以本文为准**（本文有逐项现状证据与 commit 记录）；
> **优先级与边界规则以那一份为准**（尤其第 28 项 Architecture Guard）。
>
> 现状对齐见 §0.4（28 项逐条对照）与 §0.5（7 个 PR 路线映射）。

## 文档分工与口径

本仓库有三份架构文档，职责不同，**不要互相替代**：

| 文档 | 定位 | 回答的问题 | 权威性 |
|---|---|---|---|
| `homeproxy_architecture_refactor_agent_guide.md` | 规格 / 执行手册 | "目标架构长什么样、分哪 9 个 PHASE、ABSOLUTE RULES 是什么" | 目标定义。其 PHASE 清单按 1.14 时代的仓库快照写就，其中列出的文件路径（如 `parse_uri.uc`）已被 PR-02 移动，**引用时以本文的现状证据为准** |
| 本文 `architecture-improvement-plan.md` | 实施账本 | "每一 PHASE 现在到底做到哪、证据是什么、commit 是哪个、还缺什么" | **改动细节的唯一权威**：具体文件、行号、字段、commit |
| `重构实施间断性指导建议.md` | 判断基准 | "接下来按什么边界推进、什么该冻结、什么优先" | **优先级与边界的唯一权威**：尤其第 28 项 Architecture Guard |

**测量口径说明（两份文档"结论一致"的确切含义）**：本文 §0.1 的 PHASE 表算术平均
（PR-05 之前 83.5%，之后 **87.5%**）是**实施进度**；指导建议的 **80–85%** 是**架构边界成熟度**。
两者不矛盾：前者按"每层建好了没有"打分，后者按"边界锁死了没有"打分，
差值恰好等于 §0.4 里未完成的那几项（PR-06/07 与 on-target CI）。
用一句话说：**功能账 ~88%，边界账 80–85%**。

评审对象：`szwjp/luci-app-homeproxy-pro`，分支 `main`。
本文覆盖 `ca01141`（PR-01）→ `7e561e0`（HEAD，pinned-ucode 轮）区间的实施记录；
早期 P0/PHASE 6-7 证据取自基线 `599a10b` / `19eb77c` / `0b…`（各处单独标注）。
评审方式：全量阅读 + 目标设备实测 + 本机 pinned-ucode testbed（见 §2.3.2）。
状态标记：**PASS / FAIL / NOT RUN**。

---

## 0. 结论摘要

### 0.1 完成度

按下面 PHASE 表的 10 行（PHASE 0–9）**取算术平均**：

| | PHASE 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 平均 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| PR-05 之前 | 100 | 95 | 90 | 95 | 95 | 95 | 65 | 40 | 45 | 95 | **81.5%** |
| PR-05 之后 | 100 | 95 | 90 | 95 | 95 | 95 | 65 | **80** | 45 | 95 | **85.5%** |
| P0 修复之后 | 100 | 95 | 90 | 95 | 95 | 95 | **90** | 80 | 45 | 95 | **88.0%** |
| PHASE 8 第一批之后 | 100 | 95 | 90 | 95 | 95 | 95 | 90 | 80 | **70** | 95 | **90.5%** |
| PHASE 8 第二批之后 | 100 | 95 | 90 | 95 | 95 | 95 | 90 | 80 | **75** | 95 | **91.0%** |
| PHASE 8 第三批之后 | 100 | 95 | 90 | 95 | 95 | 95 | 90 | 80 | **85** | 95 | **92.0%** |
| PHASE 8 第四批之后 | 100 | 95 | 90 | 95 | 95 | 95 | 90 | 80 | **92** | 95 | **92.7%** |

> PHASE 6 在 PR-05 之后一度下调到 **65**：§2.14 的 P0 说明「回滚安全网」在运行时这一段
> 并不可靠（该缺陷早于 PR-05）。§2.14.6 修好并真机验证之后回到 **90**。

> **口径修正**：本文件此前写"约 95%"，与它自己的 PHASE 表对不上。按表计算 PR-05 之前是
> **81.5%**，落在指导建议"整体架构成熟度 80–85%"的区间内 —— 两份文档本来就没有分歧，
> 是这里的叙述数字写飘了。PR-05 之后 **85.5%**，P0 修复之后 **88.0%**，
> PHASE 8 第一批之后 **90.5%**，第二批 **91.0%**，第三批 **92.0%**，第四批 **92.7%**。

已落地的部分（PHASE 1/2/3/4/5 收尾、§4 安全 8/9、PHASE 9 收尾 5/6、PHASE 7 抽离）：

- PHASE 4：`generator/*.uc` 七模块拆分 + 10 行 CLI 壳 + sed 注入清除，详见 §2.4；
- §4 安全 8/9：ACL 拆分、路径白名单、订阅响应上限、URL 脱敏、renderStatus XSS 防御、
  acllist 错误上报、poll 泄漏修复、证书上传竞态修复，详见 §4 表格；
- PHASE 9 补齐 5/6：`client.json` 快照、TLS/Transport 直测、`subscription/fetcher` 单测、
  `migrate_config` 36 项、`firewall_pre` 8 场景 + CI 快照循环补 `client`，仅剩 on-target CI job，
  详见 §2.9；
- **PHASE 1 Domain Model 收尾**：`load_sections()` 走 `normalize_section()`，
  5 个 `cfg.enabled !== '1'` 站点全改 `!cfg.enabled`，14 个 `cfg['.name']` 站点全改 `cfg.name`，
  `Node.raw` / `Config.endpoints` / 3 个 `ConfigQuery` 死 helper 删掉，详见 §2.1；
- **PHASE 2 Parser 目录化 + 归一化 + 校验分离**：`scripts/parser/{uri,protocols,
  validator,normalize,mapping,flatten}.uc` 建好，Loader 的 `PROTOCOL_OPTIONS` 现在从 `parser/mapping.uc`
  导入，详见 §2.2；
- **PHASE 5 Subscription Pipeline 收尾**：`parser/flatten.uc` 补 canonical ↔ flat
  闭环；`Repository = { apply_nodes, apply_main_node_refs, scrub_stale_urltest_refs }`
  接收 canonical Node，把 6 处 `uci.set/commit` 收敛；`update_subscriptions.uc` 改用
  `Loader.load()` 读 subscription，自己零 UCI 写入，详见 §2.5；
- **PHASE 3 Protocol Adapter 收尾**：`Inbound` 领域模型 + `InboundFactory`，
  WireGuard 走 `EndpointFactory`，`generator/server.uc` 只剩编排；
  同时修掉 PR-01～03 引入的 12 处缺陷（详见 §2.3.1 —— 它们此前从未被 CI 跑到，
  因为 CI 的 toolchain 构建步骤一直失败，本次一并修好）；
- **PHASE 7 Runtime 抽离（PR-05）**：`init.d/homeproxy` 517 → 253 行，
  `scripts/runtime/{service,dns,firewall,net}.sh` 承接 dnsmasq / fw4 / tproxy-TUN / 服务与
  procd 注册；离机差分 trace 测试证明行为逐字未变，真机 192.168.1.102 验证了 procd 生命周期，
  详见 §2.7 与 §2.10。

剩余部分见 §0.2。

| PHASE | 内容 | 状态 | 说明 |
|---|---|---|---|
| 0 | Baseline | ✅ 完成 | 文档化充分 |
| 1 | Domain Model | ✅ ~95% | PR-01 已落地（commit `ca01141`）：`load_sections()` 走 `normalize_section()`，所有 list-section 形状统一（`.name`/`.index`/`.type` 已 drop、`name` 暴露、`enabled` 强制 boolean）；`Node.raw` / `Config.endpoints` / `ConfigQuery.{node_ids,main_node_id,endpoints}` 全删；剩余 = server inbound 领域化（PR-04） |
| 2 | Parser | ✅ ~90% | PR-02 已落地（commit 33994fa）：`scripts/parser/{uri,protocols,validator,normalize,mapping}.uc` 建好；`loader.uc` 的 `PROTOCOL_OPTIONS` 现在从 `parser/mapping.uc` 导入；剩余 = Repository 切到 canonical Node 写（PR-03）+ validator 扩展（missing_credential / invalid_tls，后续 PR） |
| 3 | Protocol Adapter | ✅ ~95% | PR-04 已落地（commit f657063）：`Inbound` 领域模型 + `INBOUND_CREDENTIALS`/`INBOUND_OPTIONS`/`INBOUND_COMMON`/`INBOUND_TLS_SERVER` 四张表；`InboundFactory` 与 `OutboundFactory` 同形；WireGuard endpoint 也搬进 `EndpointFactory`，Generator 不再持有协议构建逻辑；`generator/server.uc` 165 → 60 行；顺带修掉 fixture 的 `listen_port` 缺陷并新增 inbound golden 快照 |
| 4 | Generator 拆分 | ✅ ~95% | `generator/` 子树七模块（`common/dns/inbound/outbound/route/ruleset/client`）+ `server.uc`，10 行 CLI 壳直接 `Loader.load(HP_DIR+'/config')`，`__LOADER_DIR__` / `HP_TEST_HOOK` / `__HP_TEST_DOMAIN_MODEL__` 全部从源码清除；golden 字节级一致（client 6773 / custom 1860 / wireguard 3755 / partial_invalid 3494）；`direct_overrides` 改成编排器持有的显式参数 |
| 5 | Subscription Pipeline | ✅ ~95% | PR-03 已落地（commit e88f7c7）：`parser/flatten.uc` 补 canonical ↔ flat 闭环；`Repository` 现在接收 canonical Node 并把 6 处 `uci.set/commit` 收敛成 3 个公开方法（`apply_nodes` / `apply_main_node_refs` / `scrub_stale_urltest_refs`）；`update_subscriptions.uc` 改用 `Loader.load()` 读 subscription，自己零 UCI 写入；剩余 = decoder 的 SIP008 tag 抽出独立 normalizer（可选） |
| 6 | Candidate Config | 🟢 ~90% | 生成期失败链成立；运行期的 P0（§2.14）**已修复并真机验证**（commit `bb4e216`）：门改为 procd 视角 + 监听归属 + 连续稳定采样，known-good 只在门通过后写入，回滚被真实触发并成功。剩余 = 回滚路径尚无自动化 on-target job |
| 7 | Runtime | ✅ ~80% | **PR-05 已落地**：`init.d/homeproxy` 517 → 253 行，dnsmasq / fw4 / tproxy-TUN / 版本闸门 / cron / 运行时文件 / procd 实例注册 / 生成事务全部搬到 `scripts/runtime/{service,dns,firewall,net}.sh`（+ 既有 `config.sh`/`health.sh`）。剩余 = 观点 18 的健康分级（listener / functional）与观点 21 的显式状态机，见 §2.10.3 与 §2.10.5 |
| 8 | LuCI | 🟢 ~85% | **PR-06 三批已落地**（9 个 commit，见 §2.11.8）：① 协议收敛为**一张有序表**，`snell` 重新可选、`chacha20` 移除；② **快照覆盖率修复**（node 13→117、client 29→206，此前两个表单的快照形同虚设）；③ mux / TUIC / hysteria / password 校验体抽成共享渲染器，其中 **TUIC 顺带统一了拥塞控制标签、password 校验体顺带补上了 node 表单缺失的 2022-blake3 密钥长度校验**；④ **RPC 单一入口 `rpcCall()`**，12 处 declare → 1 处；⑤ 删死代码 `decodeBase64Str`；⑥ 三条前端不变量测试（协议 83 项 / RPC 21 项 / 校验器 29 项，均反向验证过）+ 共享模块加载器。⑦ **client.js 的 `routing_rule`↔`dns_rule` 合并成一个 builder**（两块共 674 行、其中 184 行逐字节相同 → 1671 行，净减 121，client 快照逐字节未变）。剩余 = GridSection 脚手架 ×5 与动态 load ×13 的样板、`proxy_list`↔`direct_list` 表单块（≈32 行）、跨文件状态三件套（`getServiceStatus`/`renderStatus`/poll 守卫）。**浏览器人工回归始终未做**，这是唯一 agent 做不到的部分 |
| 9 | Test / CI | 🟢 ~95% | pin ucode + 语法金丝雀 + 取消全部 SKIP + golden 快照（含真实 `sing-box check`）+ 协议清单不变量 + 运行时事务测试 + shell 语法检查；本轮补齐 `client.json` 快照、TLS/Transport 直测、`subscription/fetcher` 单测、`migrate_config` 36 项、`firewall_pre` 8 场景、CI 快照循环含 `client`；仅剩 on-target CI job（需常驻测试设备或 QEMU-in-CI）。**2026-09 手工 on-target 实测已全绿**：`tests/ucode/run.sh` 在 192.168.1.102 上 `rc=0`、`FAIL` 0 行、`NOT RUN` 0 行（含 `firewall_post.ut` 的真实 fw4 渲染——该项在离机环境永远是 NOT RUN），见 §2.10.4 |

**关键判断（已修正）**：文档"最终成功标准"里那条链
`Subscription Failure → Candidate Rejected → Old Config Preserved → Old Runtime Preserved`
**只在生成期成立，运行期不成立** —— PR-05 验证轮的真机实测发现了健康门的 P0（**§2.14**）：
能过 `check` 但起不来的配置被判为健康，坏配置还会写进 known-good。
§2.6 的机制描述本身没错，但它依赖的健康判据不够强。**PHASE 4 Generator 拆分、§4 安全 8/9、PHASE 9 收尾 5/6、
PHASE 1 Domain Model 收尾（PR-01）、PHASE 2 Parser 目录化 + 归一化 + 校验分离（PR-02）、
PHASE 5 Subscription Pipeline 收尾（PR-03）、PHASE 3 Protocol Adapter 收尾（PR-04）、
PHASE 7 Runtime 抽离（PR-05）也已落地**（commits `ca01141` + 33994fa + e88f7c7 +
f657063 + PR-05），所以剩下的不再是"能不能跑"，也不是"覆盖够不够"：
**实施账上 PHASE 8 已开工（协议真源 + 快照覆盖率 + 第一批去重）**，而**结构账上还欠一件事 —— 边界没有锁死**
（§0.4 的 ❌ 三项 = PR-06 / PR-07 / on-target CI）。这正是指导建议 §九 的判断：
"把已经存在的层次真正变成不可越界的架构边界"。

### 0.2 剩余大项与工时估算

按 agent 连续跟进（含在目标设备上验证）计。**估算口径**：一个 agent 的净工作时长，含改代码、
跑套件、在设备上复现/验证、更新 golden 快照与文档；不含人工 code review 的等待时间。

| # | 大项 | 规模 | 风险 | 估算（agent 工时） |
|---|---|---|---|---|
| ~~A~~ | ~~PHASE 4 Generator 拆分（`generator/*.uc` + 去掉 sed 注入）~~ | ~~大~~ | ~~中（回归面大，但有 golden 快照兜底）~~ | ~~6 – 10~~ ✅ 已落地（commit `0c67d77`） |
| ~~J~~ | ~~§2.14 的 P0：健康门判据（稳定存活 + listener 健康 + known-good 刷新时机）~~ | ~~中~~ | ~~高~~ | ~~3 – 6~~ ✅ 已落地（commit `bb4e216`，见 §2.14.6–§2.14.8）：离机故障注入回归 + 真机 192.168.1.102 完整闭环 |
| B | PHASE 8 LuCI 模块化（~~协议真源~~ ✅ ~~RPC 单一入口~~ ✅ ~~node↔server 大块去重~~ ✅ ~~client.js 规则段落~~ ✅） | 小 | 高（浏览器流程无法自动化验证） | ~~9 – 15~~ **1 – 2**（剩脚手架样板与状态三件套） |
| ~~C~~ | ~~§4 安全（ACL 拆分、路径后端白名单、订阅响应上限、日志脱敏、innerHTML/poll/临时文件竞态）~~ | ~~中~~ | ~~中（路径白名单可能影响既有配置）~~ | ~~5 – 9~~ ✅ 已落地 8/9 项（commit `d9a4dac` + `0bd1b65`）；剩"前端 RPC 无统一封装"留作后续 PR |
| ~~D~~ | ~~PHASE 1 Domain Model 收尾（dns/routing/server 领域化 + 删 raw/死代码）~~ | ~~中~~ | ~~中~~ | ~~4 – 7~~ ✅ 已落地（commit `ca01141`，PR-01 §A + §B）；server inbound 领域化留在 H（PR-04） |
| ~~E~~ | ~~PHASE 2 Parser 目录化 + normalize/validator + 唯一字段映射~~ | ~~中~~ | ~~中~~ | ~~4 – 7~~ ✅ 已落地（commit 33994fa，PR-02）；Repository 切换到 canonical Node 写留在 H（PR-03）；validator 扩展（missing_credential / invalid_tls）留作后续 PR |
| ~~F~~ | ~~PHASE 7 Runtime 抽离（`service`/`dns`/`firewall`）~~ | ~~中~~ | ~~高（只能真机验证 procd）~~ | ~~4 – 8~~ ✅ 已落地（PR-05，见 §2.7 / §2.10）；离机差分 trace 测试 + 真机 192.168.1.102 procd 生命周期验证；剩健康分级与状态机（§2.10.3 / §2.10.5） |
| ~~G~~ | ~~PHASE 9 收尾（`client.json` 快照、TLS/Transport 单测、on-target CI、剩余 quirk 测试、无测试文件补齐）~~ | ~~中~~ | ~~低–中（on-target 部分需要设备/硬件）~~ | ~~5 – 9~~ ✅ 已落地 5/6（commit `db1d200` `ac910b6` `b23f9c3` `e17b75d` `b0e4a33`）；仅剩 on-target CI job（需常驻测试设备或 QEMU-in-CI） |
| ~~H1~~ | ~~PHASE 5 收尾（normalizer/validator、6 处 `uci.set/commit` 收敛、Repository canonical Node 写）~~ | ~~中~~ | ~~低–中~~ | ~~5 – 8~~ ✅ 已落地（commit e88f7c7，PR-03） |
| ~~H2~~ | ~~PHASE 3 server inbound 领域化（`generator/server.uc` 走 Domain Model / Adapter）~~ | ~~中~~ | ~~中~~ | ~~3 – 5~~ ✅ 已落地（commit f657063，PR-04） |
| I | 文档与注释债务（~~`architecture-review.md` 部分结论已失效~~ 该文件已随本次改动删除、README、头注释） | 小 | 低 | 1 – 2 |
| | **合计（协议真源亦已完成）** | | | **5 – 9**（未完成：B 剩 4 – 7、I 1 – 2） |

**最小可用集合**（只求"稳、能跑、可维护"）：
~~**A + C + G ≈ 16 – 28 工时**~~ ✅ **A / C / G 已完成**（`0c67d77`、`d9a4dac`+`0bd1b65`、
`db1d200`+`ac910b6`+`b23f9c3`+`e17b75d`+`b0e4a33`），**D 也已完成**（`ca01141`），
**E 也已完成**（33994fa），**F 也已完成**（PR-05，见 §2.10）。
原定的三步顺序已走完：A → C → G → D → E → H1 → H2 → F。
**下一批只剩 B**（LuCI 模块化，必须配人工回归，9 – 15 工时）与 I（文档债务，1 – 2 工时）。
按 §0.5 的建议，PR-07 Architecture Guard 应插在 B 之前做——它成本最低、且能保护 B 的改动。

**无法由 agent 单独闭环的部分**（必须有人/设备参与，估时不含在上表内）：
- 浏览器里点一次"导入分享链接"（RPC 后端已在设备上验证通过，剩余只有 DOM/Promise 接线）。
- ~~真机 flash 一次、跑一遍 `reload`/回滚（procd 行为）。~~ **PR-05 验证轮已在
  192.168.1.102 上跑通 `start` / `reload`+健康门 / `stop`**（§2.10.7）；**回滚分支**与
  `service_triggers` 触发的 reload 仍需人工。
- LuCI 各表单的人工目视确认（快照只能证明结构没变，不能证明可用）。
- 若要让 CI 覆盖 on-target 用例，需要一台常驻测试设备或 QEMU-in-CI 环境。

### 0.3 P0 清单（6 项，全部已修复）

1. ~~**P0-1 目标设备 ucode 无法解析重构模块 ⇒ 生成器 / 订阅更新无法编译 ⇒ 服务无法启动**~~
   **已修复**（§1.1 `export function` 缺 `;`、§1.1b 对象解构），目标设备全套 ucode 测试已 **PASS**（见附录）。
   防回归也已落地：`build-ucode-*.sh` **pin 到目标快照所用的 ucode revision**，
   `tests/ucode/run.sh` 把 `config/*.uc` 纳入 import 检查、**取消全部 target-only SKIP**、
   并新增 `test_ucode_grammar.sh` 语法金丝雀（见 §2.9）。
2. ~~**P0-2 WireGuard 节点在 `Node` 化之后必然生成非法配置**~~ **已修复**（§1.2）+ 新 fixture 守护。
3. ~~**P0-3 前端 `parseShareLink` 与后端 `parse_uri` 双实现且已经漂移**~~ **已修复**（§1.3，改为后端 RPC）。
4. **P0-4 订阅更新时新增字段写不进已有节点** **已修复**（§1.4）。
5. ~~**P0-5 单个非法节点 `die()` 掉整份配置**~~ **已修复**（§1.5）。
6. **P0-6 各协议 outbound 存在 sing-box 1.14 不接受的字段** —— 由新的 golden schema 检查发现，
   **已修复**（§1.6）。

### 0.4 指导建议 28 项逐条对照

指导建议是**优先级与边界规则**的权威，本文是**改动细节**的权威。本节把 28 项逐条落到本文的
证据行上，使两份文档可以互相校验。**判定口径**：✅ = 已达成且有本期证据；🟡 = 部分达成，
缺口已定位；❌ = 未开始。

> 复核时间：`7e561e0`。所有 ✅ 都可在本文件对应章节找到 commit 或 `file:line` 证据；
> 所有 🟡/❌ 都在 §0.2 或 §2.10–§2.13 里有对应的工作项。

| # | 观点 | 判定 | 本期证据（本文 §／commit／file:line） | 归属 |
|---|---|---|---|---|
| 01 | 已从"脚本堆叠"转为分层架构 | ✅ | `scripts/{config,parser,generator,subscription,runtime}` 六目录；§2.1–§2.5 | — |
| 02 | 最大风险是边界未收敛；冻结 Generator | 🟡 | 冻结已生效：PR-05 全程**未改 `generator/` 一个字节**（§2.4 `0c67d77` 之后无结构性改动）；**边界仍未锁死** | PR-07 |
| 03 | Domain Model 是唯一内部事实来源 | 🟡 | `Node`/`Inbound` 是真领域对象（`model.uc:209,305`）；`dns/routing` 仍只是 `normalize_section()` 归一化后的 dict，**不是**领域对象（§2.1 §A 选了括号里的第二条路） | 后续 |
| 04 | Domain Model 不知道 sing-box JSON | ✅ | `config/` 下无 sing-box JSON 构造；JSON 概念只出现在 `model.uc` 的**注释**里；构造集中在 `config/adapter.uc` | PR-07 守护 |
| 05 | `raw` 只能作兼容层，不得成为逃生通道 | 🟡 | `Node.raw` 已删（§2.1 §B）；**`tls.raw` 仍在且已是死字段** —— 见 §2.13.1 | PR-07 后的小 PR |
| 06 | Parser 是"输入格式 → Normalized Node"纯转换器 | ✅ | `parser/` 全目录对 `cursor()`/`uci.get` 零命中（唯一 `uci.` 命中是 `flatten.uc:201` 的注释与 `protocols.uc` 的注释） | PR-07 守护 |
| 07 | 统一输出 Canonical Node，协议特例进 `protocol_options` | ✅ | `parser/normalize.uc` + `parser/mapping.uc` 唯一映射表（§2.2 §B） | — |
| 08 | Parse / Normalize / Validate 明确分层 | 🟡 | 三层已分目录（§2.2 §A）；但 validator 只覆盖 `invalid_host`/`invalid_port`，缺 `missing_credential`/`invalid_tls` | 小 PR |
| 09 | Adapter 只做协议差异，不读 UCI，纯函数 `create(node, context)` | ✅ | `config/adapter.uc` 对 `uci.`/`cursor()` 零命中；`OutboundFactory`/`InboundFactory`/`EndpointFactory` 同形（§2.3 §B） | PR-07 守护 |
| 10 | Generator 保持"Domain → sing-box JSON"单向职责 | ✅ | `generator/` 全目录对 `uci.`/`cursor()` **零命中**（本期实测） | PR-07 守护 |
| 11 | Generator 拆分已足够，进入冻结 | ✅ | §2.4：八模块 + 43/37 行 CLI 壳；本期未再拆分 | 政策 |
| 12 | WireGuard 等特殊协议走 Domain/Adapter，不在 Generator 特判 | ✅ | §2.3 §B `EndpointFactory`；`generator/outbound.uc` 的 `generate_endpoint()` 只剩委托 | — |
| 13 | Subscription 形成完整纯流水线 | ✅ | §2.5：`fetch → decode → parse → normalize → validate → filter → repository` | — |
| 14 | Pure stage 不得修改 UCI | ✅ | `subscription/{decoder,fetcher,filter}.uc` 对 `uci.` 零命中；`parser/flatten.uc` 唯一命中是注释 | PR-07 守护 |
| 15 | `update_subscriptions.uc` 退化为 Orchestrator | ✅ | 全文 `uci.set/commit/delete` **零命中**（§2.5 §C 本轮勘误）；只留 `cursor()` 交给 Repository | — |
| 16 | Repository 是唯一持久化边界 | ✅ | 订阅链路上 `subscription/repository.uc` 是唯一 UCI 写入者（37 处 `uci.`） | PR-07 守护 |
| 17 | Candidate / Transaction / Rollback 三层概念 | ✅ | §2.6：文件快照路线（`runtime/config.sh` + known-good），**未**依赖"跨进程未提交 UCI 可见" | — |
| 18 | Runtime 健康应超越"进程活着" | ✅ | 该观点对应的 P0 已修复（§2.14，commit `bb4e216`）：判据 = procd 视角（`running` + 无失败 `exit_code`）+ **listener 归属**（`netstat -p` 属主必须是 sing-box）+ **连续 N 次稳定采样**。**Process / Configuration / Listener 三级已落地**；Functional Health 仍缺（有意为之：探针目标不可达 ≠ 本地配置坏，不应触发回滚） | — |
| 19 | `init.d/homeproxy` 继续减负 | ✅ | **PR-05 已落地**：517 → **253 行**；`runtime/{service,dns,firewall,net}.sh` 承接 dnsmasq / fw4 / tproxy-TUN / 版本闸门 / cron / 运行时文件 / procd 注册 / 生成事务（§2.7、§2.10） | — |
| 20 | 已有 `procd respawn`，不重复实现 supervision | ✅ | `procd_set_param respawn` ×3（`init.d:263,313,320`）；全文件无 `while true`/`sleep` 守护循环 | — |
| 21 | Known-Good 成为正式 Runtime 状态 | 🟡 | known-good 副本 + 回滚**机制**已在（§2.6）并在真机验证轮跑通刷新；但**没有**显式 `KNOWN_GOOD→CANDIDATE→VALIDATING→ACTIVATING→HEALTHY` 状态机 | PR-05 续（§2.10.5） |
| 22 | 前端最大问题是模块重复而非功能不足 | ✅ | §2.8 重复表；本轮复核见 §2.11 | PR-06 |
| 23 | 前端协议定义与 Backend Domain Model 对齐 | 🟡 | **协议表已收敛为一张**（`homeproxy.js` 的 `protocols`），并有 `tests/frontend-protocol-inventory.js`（83 项，已做反向验证）与后端 `PROTOCOL_TO_UCI`/`INBOUND_CREDENTIALS` 对齐。`snell` 版本看起来是分叉、实测是**两侧能力不同**（出站 {4,6}、入站 {5,6}），已就地记录理由。剩余 = 前端其余重复（hysteria / TUIC / 校验体 / 规则段落）。RPC 单一入口已落地（`de436df`） | PR-06 续 |
| 24 | 不做无证据支持的 frontend 大规模 rewrite | ✅ | §4 只做有实证 sink 的定向加固（`renderStatus` allow-list + poll 守卫），未做 DOM 全面替换 | 政策 |
| 25 | 从功能测试升级到架构不变量测试 | 🟡 | `test_protocol_inventory.sh` 已是跨层不变量（122 项）；**边界类检查为零** | PR-07 |
| 26 | Golden / Snapshot 继续作为重构安全网 | ✅ | `snapshots/{node,client,server}.json` + `generator/{outbounds,inbounds}.json`（§2.9） | — |
| 27 | Full on-target test 是 CI 的重要剩余缺口 | ❌ | 仍无 on-target CI job。**该观点有两处已过期**，见 §2.13.3 | PR-07 |
| 28 | 必须建立 Architecture Guard | ❌ | 无任何边界检查存在 | **PR-07（建议先做）** |

**统计**：✅ 19 项、🟡 7 项、❌ 2 项。两个 ❌ 就是 §0.5 里完全未开始的 PR-07 与 on-target CI。
🟡 的 7 项里：03 与 05 属于 "Domain Model 完整化" 的尾巴（`tls.raw` 死字段见 §2.13.1，
`dns/routing` 领域对象化）；18 与 21 是 PR-05 没做完的可靠性半场（健康分级、状态机）；
02 与 25 要等 PR-07 的 Guard 才有意义；08 是一个独立的 validator 小项。
**PR-05 让 ✅ 从 17 项升到 18 项，把 ❌ 之外的 🟡 从 8 项压到 7 项**。

### 0.5 指导建议 7 个 PR 路线 ↔ 本文映射

| PR | 指导建议的目标 | 状态 | 本文对应 | commit / 备注 |
|---|---|---|---|---|
| PR-01 | Domain Model Completion | ✅ 已落地 | §2.1 | `ca01141`；尾巴 = `tls.raw` 死字段（§2.13.1）与 `dns/routing` 领域对象化（观点 03） |
| PR-02 | Parser Normalization | ✅ 已落地 | §2.2 | `33994fa`；尾巴 = validator 扩展（观点 08） |
| PR-03 | Subscription Transaction Boundary | ✅ 已落地 | §2.5 | `e88f7c7` |
| PR-04 | Protocol Adapter Completion | ✅ 已落地 | §2.3 | `f657063` |
| PR-05 | Runtime Reliability 2.0 | 🟢 抽离半场已落地 | §2.7 / §2.10 | `c2aeac5`； 已落地：`init.d` 517→253 行 + `runtime/{service,dns,firewall,net}.sh`；离机差分 trace 等价测试 + 真机 192.168.1.102 procd 生命周期验证。**运行期 P0（§2.14）已随本项一并修复并真机验证**（commit `bb4e216`）；剩余半场 = 观点 21 的显式状态机与 Functional Health，见 §2.10.5 / §2.14.5 |
| PR-06 | LuCI Modularization | 🟡 第一批已落地 | §2.11 | `767a46d` `c3603f6` `6aa0408` `5aa378e`：协议真源 + 快照覆盖率 + mux 去重 + 死代码。剩余见 §2.11.6。**仍需人工浏览器回归** |
| PR-07 | Architecture Guard + CI | ⬜ 未开始 | §2.12 | **建议作为下一个 PR**，理由见 §2.12 |

**推荐顺序：PR-07 → PR-06 → PR-05 剩余半场**（PR-05 的抽离部分已落地）。三条理由：

1. **指导建议自己的判断**：§九 的结论是"把已经存在的层次真正变成不可越界的架构边界"，
   观点 02/28 把边界收敛列为最大风险。PR-07 正是这一项。
2. **成本与收益比最高**：§2.12.2 的实测证明七条边界**当前已经是干净的**（generator / parser /
   adapter / subscription-pure 全部零 UCI 命中，runtime 零 UCI 写入），所以 PR-07 是**纯增量**——
   不需要改一行业务代码，只是把已经做到的用 CI 钉住。
3. **先锁边界再动结构**：PR-06 要动前端 ~4.5k 行，PR-05 剩余半场要动 `runtime/health.sh` 与
   `init.d` 的 reload 路径。先有 Guard，这两次改动才不会把 PR-01～05 的成果推回去。
   PR-05 的抽离已经落地且**实测证明边界是干净的**，趁现在把 Guard 加上成本最低。

**注意（时序风险）**：PR-07 的 UCI 白名单必须**为 `runtime/` 预留**目录——PR-05 的四个新模块
正是按"设备侧、允许 `config_get`"设计的，见 §2.12.4。

---

## 1. P0 — 阻断性问题

### 1.1 目标设备 ucode 无法解析新模块（已实测）

**证据**（把仓库当前文件原样送到目标设备 `root@192.168.1.1`，用设备自带 ucode 做 module import）：

```
config/loader.uc             rc=255   Expecting ';'
subscription/filter.uc       rc=255   Expecting ';'
subscription/decoder.uc      rc=255   Expecting ';'
subscription/fetcher.uc      rc=255   Expecting ';'
subscription/repository.uc   rc=255   Expecting ';'
config/model.uc              rc=0
config/adapter.uc            rc=0
homeproxy.uc / parse_uri.uc  rc=0
```

最小 A/B（模块形式）：

```
export function f(){ return 1; }    → rc=255  Expecting ';'
export function f(){ return 1; };   → rc=0
```

**根因**：该 ucode 要求 `export function ... }` 必须以 `;` 结束（`};`）。这不是设备怪癖——仓库存量文件
（`homeproxy.uc:17,21,42,...`、`parse_uri.uc:24,38,...`、`migrate_config.uc`）**全部**写的是 `};`；
只有重构新增的模块漏了。

**影响**：`generate_client.uc:20` 与 `generate_server.uc:17` 都 `import { Loader } from './config/loader.uc'`。
模块编译失败 ⇒ 生成器非零退出 ⇒ `init.d/homeproxy:105,240` 拿不到配置文件 ⇒ 客户端/服务端都起不来。
（修复前 HEAD `599a10b` 在目标设备上完全不可用；§1.1 + §1.1b 修复后已实测恢复。）

**修复**：给以下 7 处补 `;`（改成 `};`）：

| 文件 | 行（闭括号） | 函数 |
|---|---|---|
| `root/etc/homeproxy/scripts/config/loader.uc` | 111 / 132 | `load_tls` / `load_transport` |
| `root/etc/homeproxy/scripts/subscription/filter.uc` | 55 / 76 | `check` / `apply_policy` |
| `root/etc/homeproxy/scripts/subscription/decoder.uc` | 58 | `decode` |
| `root/etc/homeproxy/scripts/subscription/fetcher.uc` | 33 | `fetch` |
| `root/etc/homeproxy/scripts/subscription/repository.uc` | 93 | `apply` |

**防回归（重要）**：
- `tests/ucode/run.sh:69` 把 `*/config/*.uc` 从语法检查循环里排除了，且 import 循环（`:88-101`）也不含 `config/*.uc`。
  `config/loader.uc` 只被 generator 测试间接覆盖。**把 `config/*.uc` 加进 import 循环**。
- `tests/toolchain/build-ucode-linux.sh:61` 的 `clone ucode` **没有 pin 版本**（`git clone --depth 1`）。
  CI 用的 ucode 可能比目标设备宽松，于是 CI 绿、设备红——正好是文档里"不得伪造 PASS"要防的情况。
  **pin 到 ImmortalWrt 实际打包的 ucode 版本，并在 `tests/run.sh:47` 旁边加一条 ucode 版本断言。**

### 1.1b 同类第二处语法阻断：对象解构（修完 1.1 后在设备上继续跑才暴露）

补完上面 7 处 `;` 之后，`tests/ucode/run.sh` 在目标设备上仍然失败，这次是
`update_subscriptions.uc:159`：

```
const { added, removed } = repository_apply(
        ^-- Syntax error: Expecting variable name
```

目标设备的 ucode **不支持对象解构赋值**（`const { a, b } = ...`），而 `b524492`（B1.2 抽出
Fetcher + Repository）引入了它。这是全仓唯一一处解构（`grep -rn "const {" root/` 只有这一行）。

**影响**：`update_subscriptions.uc` 是订阅更新（cron / 手动）的入口，编译失败 ⇒ 订阅永远不更新。
该文件被 `tests/ucode/run.sh:41-45` 标为 target-only，CI（`ON_TARGET=0`）把它 SKIP 掉，
所以这是第二次"CI 全绿、设备红"。

**修复**：改成按名取值。与 §1.1 一起构成
`fix(ucode): make the refactored modules parse on the target ucode`。

### 1.2 WireGuard 节点在 Node 化之后必然失败 ✅ 已修复

**证据**：`generate_endpoint(node)` 读的是扁平 UCI 键：

```js
// generate_client.uc:244-278
address:     node.wireguard_local_address,
private_key: node.wireguard_private_key,
peers: [{ public_key: node.wireguard_peer_public_key, ... }]
```

但 `da9b5c8`（"cut the legacy bridge, all call sites now pass a Node"）把所有调用点从
`uci.get_all(...)` 改成了 `ConfigQuery.node_by_id(dm, ...)`：

```js
// generate_client.uc:745-748, 770-773, 784-786, 815-817, 840-844
const main_node_cfg = ConfigQuery.node_by_id(dm, main_node);
if (main_node_cfg && main_node_cfg.type === 'wireguard')
        push(config.endpoints, generate_endpoint(main_node_cfg));
```

而 `Node.create()`（`model.uc:86-115`）**没有** `wireguard_*` 字段，`loader.uc` 也没有把它们放进
`PROTOCOL_OPTIONS`。差异确认（同一函数在两个 revision 的入参）：

```
622360f:  const main_node_cfg = uci.get_all(uciconfig, main_node) || {};   // 扁平 UCI，字段齐全
HEAD   :  const main_node_cfg = ConfigQuery.node_by_id(dm, main_node);      // Node，wireguard_* 全为 null
```

**影响**：WireGuard 主节点 / UDP 节点 / urltest 成员都会生成 `address:null, private_key:null,
peers:[{public_key:null}]` 的 endpoint，`removeBlankAttrs()` 把 null 去掉后 sing-box check 必然拒绝
（peer 缺 `public_key`）⇒ `generate_client.uc` 退出 1 ⇒ 服务起不来。而 `node.js:462-463` 是**可以选
WireGuard** 的，所以这是用户可达路径。

**修复**（原计划两条路，实际采用第 2 条的数据化变体，不引入新工厂）：
1. ~~在 `model.uc` 增加 `endpoint` 子对象 + `loader.uc` 增加对应读取，把 WireGuard 也纳入 Adapter
   （新增 `generate_endpoint` 的 Adapter 化，例如 `EndpointFactory.create(node)`），彻底符合 PHASE 3。~~
2. 已实施：`loader.uc` 的 `PROTOCOL_OPTIONS` 增加 `wireguard` 行（`local_address` / `private_key` /
   `peer_public_key` / `pre_shared_key` / `reserved` / `mtu` / `persistent_keepalive_interval`），
   `generate_endpoint()` 改读 `node.protocol_options` 与 `node.common`
   （顺带修掉同样读错的 `tcp_fast_open` / `tcp_multi_path` / `udp_fragment`——它们也在
   `node.common` 而不是 Node 顶层），tag 从 `node['.name']` 改为 `node.id`。
   仍保留独立的 `generate_endpoint()`；等 PHASE 3 收尾时再抽 `EndpointFactory`。

**防回归（已落地）**：新增 `tests/fixtures/generators/wireguard.uci`（单 WireGuard 主节点），
`test_generators.sh` 增加 `run_case wireguard`，并**额外断言**生成的配置里确实带着
fixture 的 private key、peer public key 和 local address list——只靠 `sing-box check` 不够，
一个完全没有 server 的配置也可能"合法"。已做反证：把 `generate_endpoint` 改回读空表后该用例 FAIL。

### 1.3 前端 `parseShareLink` 是第二个 backend，且已经漂移 ✅ 已修复

**证据**：
- `node.js:22-409`（约 388 行）逐协议重写了 `parse_uri.uc:434-499`（约 500 行）的全部 12 个 scheme。
- 已实际漂移（**修正**：初版报告里"anytls 默认端口不一致"是错的——后端 `parseURL()` 对 `http://`
  也会补 80，两端其实一致；真正漂移的是 vmess）：
  - 前端 vmess 分支**没有** `vmess_global_padding`，后端 `parse_uri.uc:397` 有 `'1'`。
    已在目标设备实测确认：后端 `parse_uri()` 返回 `vmess_global_padding="1"`。
- 校验强度不一致：后端 `parse_uri.uc:487-497` 用 `/sbin/validate_data` 校验 host/port；
  前端只做 truthiness。
- 导入路径 `node.js:1152-1163` 直接 `uci.add/uci.set` + `uci.save()`，**后端 parser 从不参与**。

**影响**：同一份 URI，走订阅和走"导入分享链接"得到的节点不同；前端写进 UCI 的东西没有后端校验，
一个坏节点会触发 §1.5 的 `die()`。这正违反文档"前端 validation 不能取代后端 validation"和
"Frontend 不是第二个 Backend"。

**已实施的修复**：
1. `luci.homeproxy` 新增 RPC `node_parse`（`args: { uri }`），内部 `import { parse_uri } from
   '/etc/homeproxy/scripts/parse_uri.uc'`，URI 长度上限 4096，异常与不支持的类型都返回
   `{ config: null, error }`。同时把 `singbox_get_features` 的探测逻辑抽成 `collectFeatures()`，
   由 RPC 服务端自己取特性，**不接受客户端传入的 features**（否则 QUIC 协议会被错误拒绝）。
   —— 已在设备上验证该 import 形式可用（`parse_uri` 里的裸 `homeproxy` import 会按被导入模块的
   目录解析），并验证了 `vmess`/`anytls`/`hy2`/垃圾输入 四类结果。
2. `homeproxy.js` 新增 `parseShareLink(uri)`（`rpc.declare` → `node_parse`），`node.js` 删除
   388 行 JS 副本（1363 → 974 行），导入处理器改为 `Promise.all(links.map(hp.parseShareLink))`
   后再写 UCI。表单快照（node/server）保持 PASS，证明渲染未变。
3. 不再需要"前端副本 + 一致性测试"的折中方案。

### 1.4 订阅更新时"新增字段"永远写不进已有节点 ✅ 已修复

**证据**：`subscription/repository.uc:66-74` 只遍历**旧 section 的 key**：

```js
map(keys(cfg), (v) => {
        if (v in node_cache[cfg.grouphash][cfg['.name']])
                uci.set(uciconfig, cfg['.name'], v, ...);
        else
                uci.delete(uciconfig, cfg['.name'], v);
});
```

`tests/ucode/test_subscription_repository.uc:132-144` 把这个行为当作"quirk"锁定下来：

```js
/* ... fields that are new in the cache (port, in this fixture) are NOT added to an existing section. */
expect('kept: port not added (quirk)', 'port' in cfg, false);
```

**影响**：机场新增 `plugin` / `tls_sni` / `packet_encoding` 等字段时，老节点永远拿不到新值；
用户只能删掉整个订阅重新导入。而且这个 quirk 被测试固化了，将来修正会"测试失败"。

**已实施的修复**：更新分支改为先写入新配置的**全部**字段（含旧 section 没有的），
再删除新配置不再携带的字段，并跳过 `.` 开头的 section 伪键（旧的 `.name` 删除调用语义上是错的）。
测试从 `expect('kept: port not added (quirk)', ... false)` 改为
`expect('kept: new field added', cfg.port, '443')`——目标设备 14 checks / 0 failures。

### 1.5 单个非法节点 `die()` 掉整份配置 ✅ 已修复

**证据**：`config/adapter.uc:301-308`

```js
const problems = [...Node.validate(node), ...protocol_problems(node)];
if (length(problems))
        die(`node '${node.id}': ${join(', ', problems)}\n`);
```

`die()` 直接终止 `generate_client.uc`。

**影响**：任一节点缺 uuid / 端口越界 / TLS 无 SNI，整份 sing-box 配置就生成失败，服务**完全起不来**，
而不是"跳过这个坏节点、其余正常工作"。考虑到 §1.3 前端导入不做后端校验，这条很容易被触发。

**已实施的修复**：
- `adapter.uc` 拆出 `problems(node)` / `buildable(node)` / `tryCreate(node, mark)`，
  `create()` 仍 `die()`（路由/DNS 真正解析经过的节点必须致命），但 **urltest 候选列表改用可构建性过滤**。
- `generate_client.uc` 新增 `keep_candidate()` / `buildable_candidates()`，三处候选列表
  （main urltest、main UDP urltest、custom routing_node 的 urltest）都会剔除无法构建的节点并 `warn()`；
  若过滤后整个组为空，则 `die()` 给出明确原因（而不是发出一个没有成员的 urltest）。
- WireGuard 的必填字段（local_address / private_key / peer_public_key）补进 `protocol_problems()`，
  所以它也会被这条路径正确剔除。
- 新增 `tests/fixtures/generators/partial_invalid.uci`（urltest 组里一个好节点 + 一个缺 uuid 的坏节点），
  断言：生成成功、坏节点不在组里、好节点在组里、并且**有对应的 warning**。
  设备实测：`PASS: partial_invalid (3512 bytes)`。

---

### 1.6 各协议 outbound 含 sing-box 1.14 拒绝的字段 ✅ 已修复（本轮新增发现）

把 golden 快照喂给真实的 `sing-box check`（详见 §2.9）后，一次就暴露出 4 个字段级缺陷。
它们都属于同一类：**Adapter 表里的字段 sing-box 1.14 根本不接受**，而此前没有任何测试会执行到它们
（fixture 大多没有设置这些选项）。每一个都会让整份配置被 sing-box 拒绝 ⇒ 服务起不来。

| # | 协议 | 字段 | sing-box 1.14 的行为 | 触发条件 | 修复 |
|---|---|---|---|---|---|
| 1 | vless | `udp_over_tcp` | `json: unknown field`（只有 shadowsocks/socks 支持） | 节点类型从 shadowsocks 改成 vless 后，残留的 `udp_over_tcp` UCI 选项 | 从 `PROTOCOL_OPTIONS.vless` / `OPTION_FIELDS.vless` 移除；UI 本来也只对 socks/shadowsocks 显示 |
| 2 | hysteria (v1) | `obfs` | 必须是**字符串**（obfs 口令）；对象形式报 `cannot unmarshal object ... of type string` | 任何设置了 `hysteria_obfs_password` 的 v1 节点 | 改为直接发口令字符串；同时不再映射 v1 不存在的 `hysteria_obfs_type` |
| 3 | snell | `mode` | outbound 与 inbound 都 `unknown field`（曾是 v6-only 选项，目标 sing-box 不支持 v6） | 从 v6 切回 v4/v5 后残留的 `snell_mode`；或 v6 节点本身 | 从 loader/adapter/`generate_server.uc`/两个表单中移除 |
| 4 | ssh | `private_key` | 需要**单个字符串**，但表单用 DynamicList 存储（每行一个 UCI list 条目），发出的是数组 | 任何 SSH 节点 | `ssh_private_key()` 用 `join('\n', ...)` 还原成完整密钥 |

顺带修正：**socks** 的 `udp_over_tcp`（表单有、sing-box 也接受）此前 Adapter 从未发出，
设置被静默忽略，现已补上。

**防回归**：`tests/ucode/test_golden_outbounds.sh` 现在不只是比对快照，还会把所有 14 个协议的
outbound 包成一份配置交给 `sing-box check`。快照只能发现"变化"，这一步才能发现"值本身是错的"。
本节 4 个缺陷全部由它捕获。SSH fixture 用的是**一次性测试密钥**（非真实凭据）。

---

## 2. 架构改进（逐 PHASE）

### 2.1 PHASE 1 — Domain Model 收尾 ~~（PR-01）~~ ✅ 已落地（commit `ca01141`）

> ~~现状：只有 `Node` 是真正的领域对象；`dm.dns.servers/rules`、`dm.routing.nodes/rules/rulesets`、
> `dm.server.inbounds` 都是**原样 UCI section dict**，generator 里到处是 `cfg.enabled !== '1'`、
> `cfg['.name']`、`cfg.groups` 这种 UCI 形状的判断（`generate_client.uc:520,551,797,1010,1096` 等），
> `ConfigQuery.find_by_name()` 也专门服务于这种扁平 dict（`model.uc:180-185`）。~~
>
> ~~建议：~~
> ~~1. 为 `dns_server` / `dns_rule` / `routing_node` / `routing_rule` / `ruleset` 各建一个轻量领域对象
>    （或在 Loader 中统一 `load_sections` 时归一化 `.enabled` 为布尔、保留 `.name` 为 `id`）。
>    这一步做完，`generate_client.uc` 里的 `cfg.enabled !== '1'` 全部消失。~~
> ~~2. **删掉 `Node.raw`**（`model.uc:114`，全仓无人读，只在注释里被引用），或者按 §1.2 用它修 WireGuard。
>    留一个"无人读的 opaque bag"只会让下一个人以为里面是权威数据。~~
> ~~3. 清理死代码：`ConfigQuery.node_ids`、`main_node_id`、`endpoints`（`model.uc:187-205`）全仓无调用点，
>    而 `endpoints` 的注释说"A3/A4 填充"，A3/A4 早已落地。~~
> ~~4. `Config.create` 的注释（`model.uc:68-72`）说 dns/routing/endpoints/access_control/server
>    "the loader does not read these yet"——A1.2 之后已经不成立，属于**误导性注释**，必须更新。~~

**落地形态**（commit `ca01141`）：

§A — Loader 归一化。`config/loader.uc` 新增 `normalize_section(cfg)`：
* 丢弃 UCI 伪字段（`.name` / `.index` / `.type`），避免下层继续读裸 UCI 形状。
* 把 section name 暴露为 `name`（等同原 `.name` 的字符串值）。
* 若存在 `enabled`，强制转为布尔；缺省保持缺省（与原先 `cfg.enabled !== '1'` 的"缺省即禁"语义一致）。

`load_sections()` 走 `normalize_section()`，于是
`dm.dns.servers/rules`、`dm.routing.nodes/rules/rulesets`、`dm.server.inbounds` 全部变成统一形状。
`ConfigQuery.find_by_name()` 改为按 `it.name === name` 查。

Generator 侧所有 `cfg['.name']` / `cfg.enabled !== '1'` 都改了：
* `generator/dns.uc` ×3（tag / eval_tag / dns.rules 入口）
* `generator/route.uc` ×1
* `generator/outbound.uc` ×2（enabled + tag）
* `generator/ruleset.uc` ×4（enabled + tag + 两条 warn）
* `generator/server.uc` ×4（snell tag + generic tag + user.name + enabled）

行为不变：`'cfg-' + cfg.name + '-...'` 等同 `'cfg-' + cfg['.name'] + '-...'`；
`!cfg.enabled` 等同 `cfg.enabled !== '1'`（`null !== '1'` 与 `!undefined` 都是 truthy）。
Generator golden 字节级一致（client / custom / wireguard / partial_invalid，
路径差异除外），待目标设备 `tests/ucode/run.sh` 实跑复证。

§B — 删死代码：
* `Node.raw` 全部移除：definition、`loader.uc` 的 `raw: section`、以及 `adapter.uc` /
  `loader.uc` 残留的"Adapter 不读 `node.raw`"注释（comment 重写为"PR-01 删掉了 legacy opaque bag"）。
* `Config.endpoints` placeholder + `ConfigQuery.endpoints()` 一起删：A3/A4 早就落地，
  placeholder 从未被填充，helper 永远返回 `[]`，只服务于"断言为空"的测试。
* `ConfigQuery.node_ids` / `ConfigQuery.main_node_id` 删：零生产调用点；保留
  `node_by_id` / `find_by_name` / `main_udp_node_id` 三个仍在用的。
* `Config.create` 注释重写为"`Loader` 从 UCI 填充这五个子对象"。

**防回归**：`tests/ucode/test_domain_model_skeleton.uc` 现在跑 17 项新断言：
* 4 个 `*.name` 显式等于 fixture 的 section name（`ds_main` / `dr_hijack` / `rr_sniff` /
  `rs_cn` / `rn_main` / `s_vless`）。
* `dns.rules[0].enabled === true`（fixture 写 `'1'`，loader 必须 coerce 成 boolean）。
* 5 段循环断言 `.name` / `.index` / `.type` 都**不在**归一化后的 shape 里。
* `enabled`（若存在）必须是 boolean。
* `find_by_name(routing.nodes, 'rn_main')` 返回的 node 字段为 `urltest`。

`Config.endpoints` / `ConfigQuery.endpoints / node_ids / main_node_id` 的断言已删。
本机 `python3 tests/i18n-coverage.py` 724/724 PASS；
`node tests/luci-form-snapshot.js` node / client / server 三份快照一致。

不在本 PR 范围：server inbound 仍读扁平 UCI（`generator/server.uc`）—— 那是 PR-04
（Protocol Adapter Completion）的范围，不动。

### 2.2 PHASE 2 — Parser 目录化 + 归一化 + 校验分离 ~~（PR-02）~~ ✅ 已落地（commit 33994fa）

> ~~现状：`parse_uri.uc`（500 行，顶层）已经按协议拆函数，质量不错。但：~~
> ~~- 没有 `parser/{uri,protocols,normalize,validator}.uc` 目录结构；~~
> ~~- 输出是**扁平 UCI 键**（`shadowsocks_encrypt_method`、`tls_sni`、`vless_flow`、`snell_userkey`…），
>   不是 Domain `Node`；归一化职责被隐式推给了 `loader.uc` 的 `PROTOCOL_OPTIONS`；~~
> ~~- 校验只有末尾 12 行（`parse_uri.uc:487-497`），没有独立 validator，也没有 per-protocol 必填校验
>   （那部分在 `adapter.uc:52-90`，属于 Adapter 层，可接受）。~~
>
> ~~建议：~~
> ~~1. 搬到 `scripts/parser/`：`uri.uc`（dispatch）、`protocols.uc`（`parse_*`）、`normalize.uc`、`validator.uc`。~~
> ~~2. 定义**唯一的协议字段映射表**，方向为 `canonical → uci_option`，从它同时派生：~~
>    ~~- parser 的归一化输出（canonical）~~
>    ~~- loader 的 `PROTOCOL_OPTIONS`（canonical → UCI）~~
>    ~~- adapter 的取值~~
>    ~~现在这张映射在三处重复：`parse_uri.uc`（输出扁平键）、`loader.uc:168-256`、`model.uc:43-57`。~~
> ~~3. 归一化后的 Node 与 §1.3 的 RPC 复用同一份 parser，前端不再有第二实现。~~

**落地形态**（commit 33994fa）：

§A — `scripts/parser/` 目录化。`parse_uri.uc`（顶层，500 行）拆成：

* `parser/uri.uc`（~85 行）：`parse_uri()` dispatcher，仅保留 dispatch + 通用 `[host]`/`:` 清理 +
  label fallback。`features` / `log` 默认值仍在这里。
* `parser/protocols.uc`（~440 行）：11 个 `parse_<scheme>_uri()` 函数，按 `parse_uri.uc` 原文
  搬迁；3 处历史 `[1]/[0]` 索引只在审查时校对，不动行为。
* `parser/validator.uc`（~75 行）：`validate(config, log)` + `check(config)`，把 §0.3 末尾的
  inline host/port 校验抽出来；每个错误带 `kind` 字段（`invalid_host` / `invalid_port`），
  后续 PR 可加 `missing_credential` / `invalid_tls` 不需要再改 dispatcher / protocols。
* `parser/normalize.uc`（~140 行）：`normalize(flat)` 把扁平 UCI 键 dict 转换成 Adapter 真正
  用的 canonical `Node` 形状（`common` / `credentials` / `tls` / `transport` / `multiplex` /
  `protocol_options`），与 Loader 的 `load_*` 同形。`null` 输入透传 `null`。

§B — 唯一字段映射表。新增 `parser/mapping.uc`：

* 导出 `PROTOCOL_TO_UCI`（canonical → UCI），把原 `loader.uc:161-285` 的 `PROTOCOL_OPTIONS`
  整张表搬过来，**含注释**。`loader.uc` 现在改成
  `import { PROTOCOL_TO_UCI as PROTOCOL_OPTIONS } from '../parser/mapping.uc';`，
  本地副本删除。
* 同一模块底部导出反向表 `UCI_TO_PROTOCOL`，由 `PROTOCOL_TO_UCI` 翻转生成
  （避免手写漂移）。

§C — 调用点全部迁移：

* `update_subscriptions.uc`：`import { parse_uri } from './parser/uri.uc';`。
* `root/usr/share/rpcd/ucode/luci.homeproxy`：`import { parse_uri } from
  '/etc/homeproxy/scripts/parser/uri.uc';`，§1.3 的 `node_parse` RPC 走同一份 parser。
* `tests/ucode/run.sh`、`test_protocol_inventory.sh`、`test_domain_model_skeleton.sh`：
  改 stage 目录（`$WORK/parse_uri/parser/`），旧的 `parse_uri.uc` 顶层文件路径全部删除。
* `htdocs/luci-static/resources/{homeproxy.js, view/homeproxy/node.js}`：两处注释里
  的 `(parse_uri.uc)` 改写为 `(parser/uri.uc)`（脚本 import 路径未动）。

**防回归**（commit 33994fa 新增 test）：

* `tests/ucode/test_parser_normalize.uc`：35 项断言，覆盖：
  - `normalize(null)` → `null`
  - shadowsocks 整轮：`shadowsocks_encrypt_method` / `shadowsocks_plugin` /
    `shadowsocks_plugin_opts` → `credentials.method` / `protocol_options.plugin` /
    `protocol_options.plugin_opts` / `protocol_options.udp_over_tcp*`。
  - vless：flow / packet_encoding / tls.* / transport.*（含 ws headers 重组）。
  - hysteria2：`hop_interval` / `obfs_type` / `up_mbps` 落到 `protocol_options`；
    显式断言**只**含映射过的键（不在 PROTOCOL_TO_UCI 里的字段在 normalize 时丢弃，
    等价于 Loader 的 "stale UCI option" 拦截）。
  - direct：`override_address` / `override_port` 落到 `protocol_options`。
  - 空串 / `null` UCI 值在 `protocol_options` 里被丢弃。

旧的 `tests/ucode/test_parse_uri.uc` 内容不变（153 项断言），只改了顶部注释与
`import` 路径（`from 'parser/uri.uc'`）。

**不在本 PR 范围**：

* Repository（`subscription/repository.uc`）仍按扁平 UCI 写 UCI；下一步切换到
  canonical Node 写、配合 `parser/mapping.uc` 做 flatten，是 PR-03 的范围。
* Validator 当前只覆盖 host / port 两项；`missing_credential` /
  `invalid_tls` 是后续可加项（per guidance §08），不阻塞本 PR。
* parser/protocols.uc 三个 `[1]/[0]` 历史纠错（vless / trojan / vmess 的
  `?ed=` ws 路径）保留原状 —— 只是 PR 期间重读确认没动，不是新增修复。

字节级一致性：parser 输出形状不变（仍扁平 UCI），Repository 契约不变，
`tests/fixtures/generators/*.uci` + 4 份 golden 快照无影响。
本机 `python3 tests/i18n-coverage.py` 724/724 PASS；
`tests/luci-form-snapshot.js` node / client / server 三份快照一致。

### 2.3 PHASE 3 — Adapter 收尾 ~~（PR-04）~~ ✅ 已落地（commit f657063）

> ~~现状：`adapter.uc` 用 `COMMON_FIELDS` + `CLAIM_FIELDS` + `OPTION_FIELDS` + `REQUIRED_CREDENTIALS`
> 四张表替代了 110 行三元表达式，这是本次重构最成功的部分，值得保留。~~
>
> ~~遗留：~~
> ~~1. **WireGuard endpoint 未 Adapter 化**（§1.2）。~~
> ~~2. `direct_overrides` 仍是模块级全局副作用……~~ ✅ 已在 PHASE 4 中落地（`0c67d77`）：
> `generate_outbound(node, mark, direct_overrides)` 把 override 写进 caller 持有的 map，
> route builder 从同一个 map 读出 route-options action，不再有模块级状态。
> ~~3. `CLAIM_FIELDS` 与 `OPTION_FIELDS.hysteria/hysteria2` 里 `auth`/`auth_str` 重复出现……~~
> ~~4. `generate_server.uc` **完全没有走 Domain Model / Adapter**……建议增加
> `EndpointFactory`/`InboundFactory` 与 `Node` 对称的 server 模型。~~

**落地形态**（commit f657063）：

§A — `Inbound` 领域模型（`config/model.uc`）。与 `Node` 对称，同样不知道 sing-box JSON：

* `Inbound.create()`：`id` / `name` / `type` / `enabled` / `address` / `port` / `firewall`
  + 6 个子对象 `common` / `credentials` / `tls` / `tls_server` / `transport` / `multiplex`
  / `protocol_options`。
* `Inbound.validate()`：协议无关的 port 校验（listen address 缺省是合法的，sing-box 默认全接口）。
* `Inbound.tag()`：`'cfg-' + id + '-in'`（用 UCI section name 而不是 label，改 label 不改 tag）。
* 四张表：`INBOUND_CREDENTIALS`（canonical → UCI，服务端版本：无 ssh 材料、无 snell userkey）、
  `INBOUND_OPTIONS`（每协议选项，注意**不是** client `PROTOCOL_TO_UCI` 的超集：服务端多
  `anytls_padding_scheme` / `hysteria_masquerade` / `hysteria_obfs_min|max_packet_size` /
  `hysteria_ignore_client_bandwidth` / `tuic_auth_timeout`，少 port-hopping 系列）、
  `INBOUND_COMMON`（监听层共享字段）、`INBOUND_TLS_SERVER`（服务端专属 TLS 尾巴：key material、
  ACME 全套、REALITY 服务端握手、ECH key —— 共 25 个键）。

§B — `InboundFactory` + `EndpointFactory`（`config/adapter.uc`）：

* `InboundFactory` = `{ problems, buildable, tryCreate, create }`，与 `OutboundFactory` 同形。
  四张 sing-box 侧表：`INBOUND_COMMON_FIELDS` / `INBOUND_COMMON_OMIT`（snell 不得拿到
  `udp_fragment` / `udp_timeout` / `network`）/ `INBOUND_NO_USERS`（snell、shadowsocks 不得有
  `users[]`）/ `INBOUND_OPTION_FIELDS`。最后统一走 `removeBlankAttrs()`，所以返回的就是最终产物，
  可以直接进 golden 快照。
* `INBOUND_TLS_SERVER` 的反向重命名只在 `build_tls_server_extras()` 一处发生 —— 共享的
  `buildTLSObject()`（被 `test_tls_transport.uc` 直接锁定）签名不动。
* `EndpointFactory` = WireGuard endpoint 的构建，从 `generator/outbound.uc` 搬过来。
  `generator/outbound.uc` 的 `generate_endpoint()` 现在只是一层委托，Generator 不再持有
  任何协议的构建逻辑。
* 顺带把 `parse_port()` 从 `generator/common.uc` 搬到 `homeproxy.uc`：Adapter 需要它，
  而 adapter 不能反向 import generator。

§C — `loader.uc::load_server()` 现在产 `Inbound` 对象（`load_inbound()` + 通用的
`load_table()`），不再是 `load_sections()` 的裸 section dict。

§D — `generator/server.uc` 从 165 行缩到 60 行：只做 `enabled` 过滤、log 块、`InboundFactory.create()`，
以及"没有 inbound 就返回 null（= 服务端禁用）"这条编排决策。

§E — 修掉一个**潜藏的 fixture 缺陷**：`tests/fixtures/generators/server.uci` 一直写
`option listen_port`，而表单（`server.js:216,221`）和生成器（`cfg.port`）用的都是
`address` / `port`。于是生成的 server 配置**根本没有 listen_port**，`sing-box check` 也接受了，
没有任何测试发现。fixture 改成 `address` + `port`（并让 `s_snell` 不带 address，
覆盖 `listen` 默认 `::` 的路径），同时新增
`tests/ucode/test_golden_inbounds.sh` + `tests/snapshots/generator/inbounds.json`
把 7 个协议的 inbound 输出钉住 —— 这一类"字段名写错但 schema 不报错"的问题以前没有任何防线。

§F — 防回归：
* `tests/ucode/test_inbound_adapter.uc`（82 项）：snell / shadowsocks 不得有 `users[]`；
  vless / vmess 的 `flow` / `alterId` 只能在 `users[]` 里；snell 的监听层字段集合；
  服务端 TLS 尾巴（含 REALITY 服务端 private_key + handshake，且**不能**出现客户端侧
  `insecure` / `utls` / `public_key`）；hysteria v1 `obfs` 是字符串而 v2 是对象；
  每协议 credential 必填校验；multiplex 服务端形状（无 `protocol` / `max_connections` 等拨号侧字段）。
* `tests/ucode/test_protocol_inventory.sh` 增加第 4 项不变量：`INBOUND_OPTIONS` 的每个协议
  都必须有 `INBOUND_CREDENTIALS` 行（反方向不成立：trojan / shadowtls / http / mixed / naive /
  socks 有 credential 没有 per-protocol option）。
* `tests/ucode/run.sh` 通过 `tests/ucode/test_generators.sh` 复用同一个 fixture，
  `server` case 现在真的会带 `listen_port`。

**字节级一致性**（对比基线 `19eb77c` 的 server 输出）：7 个 inbound 逐个 diff，
除 (a) fixture 修正带来的 `listen` / `listen_port` 新增、(b) ACME `data_directory` 的
路径差异（work dir 不同，属于允许的 path-only 差异）以外**完全相同**，
包括 snell 的 `psk` / `version` / `obfs_mode`、shadowsocks 的 `method` / `password`、
hysteria2 的 obfs 对象、tuic 的 4 个字段、所有 `users[]`、`tls`、`transport`、`multiplex`。

**不在本 PR 范围**：
* `CLAIM_FIELDS` 里 hysteria 的 `auth` / `auth_str` 与 `OPTION_FIELDS` 重复这件事（本 PR
  未动 client outbound 侧；server 侧的 `INBOUND_CLAIM_FIELDS` 与 `INBOUND_OPTION_FIELDS`
  是分开的，不存在这个重复）。
* 服务端 inbound 的 `sing-box check` 之外的语义正确性（例如某个字段的取值是否被 sing-box
  在运行时接受）仍只能在真机验证。

### 2.3.1 PR-04 顺带修复：本机测试套件暴露的既有缺陷

PR-04 推进过程中第一次在装有 ucode testbed 的机器上完整跑 `tests/ucode/run.sh`，
暴露出 PR-01 / PR-02 / PR-03 引入的、**CI 从未跑到**的缺陷（CI 的
"Build ucode toolchain" 步骤一直失败，见 §2.9）。逐条修复：

| 缺陷 | 引入于 | 症状 | 修复 |
|---|---|---|---|
| `loader.uc::normalize_section()` 用 `k[0]` 取字符串首字符 | PR-01 `ca01141` | 目标 ucode 报 "left-hand side expression is not an array or object"。`normalize_section()` 在 `load_sections()` 里，**每次客户端生成都会走到** —— 等于 PR-01 之后所有生成都直接失败 | 改用 `substr(k, 0, 1)`（`repository.uc` 一直是这个写法） |
| `parser/uri.uc` 漏 import `isEmpty` | PR-02 `33994fa` | 分享链接解析路径直接 Reference error | import 补上 |
| `parser/validator.uc` 用 `errors.push({...})` | PR-02 `33994fa` | ucode 没有数组方法，报 "left-hand side is not a function"；只在真有校验失败时触发 | 改成 `errors = [...errors, {...}]`（ucode 惯用法） |
| `parser/uri.uc` 写 `validate(config, log) \|\| config` | PR-02 `33994fa` | 校验返回 `null` 时 `\|\| config` 又把**非法 config** 交回去了，validator 完全失效 | 改成先判 `null` 再取 label |
| `anytls` / `http` 两个 parser 凭记忆重写而非搬运 | PR-02 `33994fa` | `anytls` 丢 `tls_insecure`、错加 `tls_sni`/`tls_alpn`；`http` 多出 `tls_sni`/`tls_alpn` | 从 `19eb77c` 逐字恢复；并用脚本比对全部 11 个 `parse_*` 函数体与原文一致 |
| `repository.uc` 用对象解构 `const { … } = ctx` | PR-03 `e88f7c7` | 目标 ucode 明确拒绝（grammar canary 就是测这个），订阅更新路径在真机上会直接失败 | 逐字段取值 |
| `repository.uc` 漏 import `isEmpty` | PR-03 `e88f7c7` | `apply_main_node_refs()` Reference error | import 补上 |
| `parser/flatten.uc` 用 `undefined` | PR-03 `e88f7c7` | ucode 无 `undefined` 全局，直接 Reference error | 只判 `null` |
| `flatten_transport()` 一律写 `http_path` | PR-03 `e88f7c7` | ws 传输的 path 会变成 `http_path`，与 parser 的 `ws_path` 不一致 —— 下一轮订阅更新会把该节点的 `ws_path` 删掉 | 按 transport 类型分别写 `ws_path` / `http_path` |
| `PROTOCOL_TO_UCI.hysteria` 缺 `protocol` | PR-03 `e88f7c7` | `hysteria_protocol`（节点表单 `node.js:182` 会写）在 canonical 映射里没有位置，同样会在下一轮订阅更新时被删掉 | 补 `protocol: 'hysteria_protocol'` |
| `test_generators.sh` / `test_golden_outbounds.sh` 未 stage `parser/` | PR-02 `33994fa` | Loader 的 `'../parser/mapping.uc'` 解析失败，5 个 generator case 全红 | stage `parser/` 为 `config/` 的兄弟目录 |
| `test_protocol_inventory.sh` 仍从 `loader.uc` import `PROTOCOL_OPTIONS` | PR-02 `33994fa` | 同名导出已搬到 `parser/mapping.uc` | 改 import 来源 |
| `test_parser_normalize.uc` 断言 `transport.host` 对 ws 成立 | PR-02 | 断言写错（ws 的 host 在 `headers.Host`） | 修正断言并写明原因 |
| `test_domain_model_skeleton.uc` 用 `type(x) !== 'boolean'` | PR-01 `ca01141` | ucode 的 `type(true)` 返回 `'bool'` | 改成 `'bool'` |
| `test_subscription_repository.uc` 用 `match(s, 'plain string')` | PR-03 `e88f7c7` | ucode 的 `match()` 只接受正则，字符串直接返回 `null`；断言恒假 | 改用正则字面量 |
| sandbox 里没有 `config homeproxy 'config'` section | — | libuci 对不存在的 named section 会建匿名 section，`main_node` 断言读不回来 | seed 补上该 section |

结果：`tests/ucode/run.sh` 的失败集合与基线 `19eb77c` **完全一致**
（当时仅剩 4 项本机环境限制；其中 3 项在 §2.3.2 里被证明是真缺陷并修掉，
只剩 grammar canary 一项属于"本机工具链比目标宽松"的正常提示），62 项 PASS，零回归。

同时修掉了让 CI 长期失效的根因：`tests/toolchain/build-ucode-linux.sh` 构建
liblucihttp 时没传 `-I$PREFIX/include`（ucode/module.h）和 `-L$PREFIX/lib`（bare `-lucode`），
所以 "Build ucode toolchain" 一直在第一步就失败，`run.sh` 从未在 CI 里跑过。
macOS 版本的脚本一直有这两个 flag。**这是 PR-01～03 的缺陷能一路推到 main 的直接原因。**

### 2.3.2 目标方言（pinned ucode）下暴露的缺陷

修好 CI 工具链之后，第一次在**按 pin 的 revision** 构建的 ucode 上跑完整套测试
（本地另建一份 `~/.local/ucode-strict`，与 CI 的方言一致），又剥出一批
**让包在真机上根本加载不了**的既有缺陷。它们全部早于 PR-04，且此前从未被任何一次
CI 跑到（§2.3.1 已说明 CI 为何失效）。

| 缺陷 | 规模 | 后果 | 修复 |
|---|---|---|---|
| `export function ... }` 缺结尾 `;` | 19 处：`homeproxy.uc`×2、`generator/{client,common×7,dns,inbound,outbound×3,route,ruleset×2,server}.uc`、`fetcher` mock×2 | 目标 ucode 直接 `Syntax error: Expecting ';'`。`homeproxy.uc` 是整条 import 链的根，**一个分号就能让客户端生成完全失效**；`generator/*` 同样整体不可加载 | 补齐 19 个 `;`（commit `4cd98d6`） |
| `update_subscriptions.uc` 从 `luci.sys` import `init_action` | 1 处 | openwrt/luci 与 immortalwrt/luci 的 `modules/luci-base/ucode/sys.uc` 都**没有**这个导出（只有 `process_list`/`conntrack_list`/`init_list`/`init_index`/`init_enabled`）。import 解析失败 ⇒ **订阅更新在路由器上完全无法运行** | 改用 `executeCommand('/etc/init.d/homeproxy', 'reload')`，并检查退出码、把 stderr 写进日志（比原来只调用不检查更强） |
| `#!` 在 module 模式下非法 | 2 个测试 harness | `firewall_pre.uc` / `migrate_config.uc` 生产上以 program 方式运行（`ucode <file>`），shebang 合法；但目标 ucode 在 **import** 时报 `Unexpected character`，随后引发一连串级联词法错误 | 测试 staging 时删掉 shebang，并加上与其他 staged 改写同样的 anchor guard |
| `executeCommand()` 用 `>&N` 重定向到 mkstemp 的 fd | 1 处 | 子 shell 看不到那些 fd 时 `/bin/sh` 直接报 `Bad fd number`（dash）/ `Bad file descriptor`（bash），**命令根本没执行**，调用者拿到空 stdout + exit 2。CI 的 `/bin/sh` 是 dash，所以整套 executeCommand 断言失败 | 改成 `mkdtemp()` + 按**路径**重定向（`>dir/stdout 2>dir/stderr`），纯 POSIX，在 ash/dash/bash 下行为一致；保留 512 KiB 读取上限与返回值契约。顺带删掉只为那两个 fd 存在的 `closeFD()` |
| `test_firewall_template.sh` 需要真机 `fw4` 模块 | 1 个测试 | 无法渲染，测试从基线起就一直失败。但**它要防的那个 bug 其实不需要 fw4**：`{%-` 会裁掉前面的空白，所以 `{%-` 之前有任何文本都会把第一条生成的语句粘成注释，于是所有 homeproxy chain/set 被静默丢弃 | 拆成两层：① 源码级断言（`{%-` 之前除 shebang 外必须为空）永远运行，用它精确复现该前置条件；② 渲染 + 结构断言在 `fw4` 可用时运行，否则诚实报 `NOT RUN` 并说明原因。**没有**用 fw4 stub —— 那会变成在断言一个真 fw4 从未产出的规则集 |

**验证方式**：新建 `~/.local/ucode-strict`（`tests/toolchain/build-ucode-macos.sh`
按 pin 构建，再用 `install_name_tool -add_rpath` 补上 macOS 脚本同样漏掉的
`CMAKE_INSTALL_RPATH`），整套在**目标方言**下运行：

```
65 PASS, 0 FAIL, 1 NOT RUN（fw4 渲染，设备专属）
```

宽松工具链下的唯一失败仍是 grammar canary —— 那是它的职责（它在报告"这个
toolchain 太宽松"），`tests/README.md` 已补充"遇到该提示应先重建工具链，
而不是按 `HP_ALLOW_PERMISSIVE_UCODE=1`，否则 canary 的反向探针会因错误的原因通过"。

### 2.4 PHASE 4 — Generator 拆分 ~~（当前 0%，但收益最直接）~~ ✅ 已落地（commit `0c67d77`）

> ~~`generate_client.uc` 1191 行，内部段落非常清晰，可以**按现有 `/* xxx start */` 注释机械拆分**，
> 风险低、review 容易：~~
>
> | ~~目标文件~~ | ~~现有行区间~~ | ~~内容~~ |
> |---|---|---|
> | ~~`generator/common.uc`~~ | ~~394-411, 1180-1191~~ | ~~`config.log`、`config.ntp`、`$schema`、写盘 + `sing-box check`~~ |
> | ~~`generator/dns.uc`~~ | ~~413-648~~ | ~~DNS servers / rules / final（最大一块）~~ |
> | ~~`generator/inbound.uc`~~ | ~~650-708~~ | ~~`config.inbounds`~~ |
> | ~~`generator/outbound.uc`~~ | ~~244-278, 710-850~~ | ~~`generate_endpoint`、默认/main/urltest outbounds~~ |
> | ~~`generator/route.uc`~~ | ~~852-1132~~ | ~~route rules + final~~ |
> | ~~`generator/ruleset.uc`~~ | ~~1094-1165~~ | ~~rule_set + `http_clients` 归一化~~ |
> | ~~`generator/client.uc`~~ | ~~394-1191 的编排~~ | ~~只做 orchestration~~ |
>
> ~~配套（比拆文件更重要）：~~
> ~~1. **去掉 sed 注入式测试**。把 `generate_client.uc` 变成~~
>    ~~`generator/client.uc`（`export function generate(config, opts)`）+ 一个 10 行的 CLI 壳。~~
>    ~~这样 `Loader.load('__LOADER_DIR__')` 和 `/* HP_TEST_HOOK */` 都可以删掉，~~
>    ~~测试直接 `import { generate } from ...; generate(Loader.load(fixture_dir))`。~~
>    ~~现在的 `__LOADER_DIR__` / `HP_TEST_HOOK` / `__HP_TEST_DOMAIN_MODEL__` 机制已经部分腐朽~~
>    ~~（`test_demo_architecture.sh:158-159` 的两条 sed 是**空操作**，见 §3.1）。~~
> ~~2. **删掉重复的 `sing-box check`**：`generate_client.uc:1187` 与 `init.d:110` 检查同一份文件；~~
>    ~~`generate_server.uc:170` 与 `init.d:245` 同理。文档明确"不要重复实现已有的 sing-box check"。~~
>    ~~建议生成器只负责"原子写入 candidate + 序列化"，check 交给 runtime（或反之）。~~

**落地形态**（commit `0c67d77`）：

- `root/etc/homeproxy/scripts/generator/` 共 8 个模块 / 1811 行；`scripts/generate_client.uc` 从 1240 行降到 37 行的 CLI 壳，`scripts/generate_server.uc` 从 175 行降到 30 行。
- 模块清单：
  - `common.uc`（165）：`parse_port` + 五个 selector helper（`get_outbound` / `get_resolver` / `get_ruleset` / `get_direct_override` / `isDirectOutboundTag`）+ `attachSchema` + `attachExperimental`。
  - `dns.uc`（336）：`initDns`（公共：`default-dns` + `system-dns`）+ `append_proxy_dns`（main-dns / china-dns / NAPTR / CN-IP fallback）+ `append_custom_dns`（用户 dns_server / dns_rule）。
  - `inbound.uc`（94）：dns-in / mixed-in / redirect-in / tproxy-in / tun-in。
  - `outbound.uc`（334）：`generate_endpoint`（WireGuard）、`generate_outbound`（调 Adapter、写 `direct_overrides`）、`buildMainOutbounds` / `buildCustomOutbounds` + `keep_candidate` 剪枝。
  - `route.uc`（301）：`initRoute` + `build_route_proxy`（resolve + geoip-cn + main override + remote rule_sets）+ `build_route_custom`。
  - `ruleset.uc`（117）：`build_user_rulesets` + `build_http_clients`（sing-box 1.14 download_detour → http_client 归一化）。
  - `client.uc`（299）：编排器，`build_ctx` 后串行调用各模块。
  - `server.uc`（165）：server inbound dispatcher（snell 单独 shape + generic users[]/TLS/transport）。
- `direct_overrides` 已改为编排器持有的显式 `parameter`（不再是模块级副作用）；`generate_outbound(node, mark, direct_overrides)` 把节点直接路由 + override 同步写进 caller 的 map，route builder 之后从同一个 map 读出 route-options action。
- **sed 注入彻底清除**：`__LOADER_DIR__` / `HP_TEST_HOOK` / `__HP_TEST_DOMAIN_MODEL__` 三个 token 在源码中已不存在（`grep` 全空）。测试 staging 改为 `Loader.load(HP_DIR + '/config')` —— 测试自己改写 `homeproxy.uc` 的 `HP_DIR` 常量，shell 用它解析 UCI 目录，**无需任何源文件 sed**。
- **重复 `sing-box check` 已在 PHASE 6 解决**：generator 做原子写 + check；`init.d/homeproxy` 不再 check（comment "the only `sing-box check` in this path"）；runtime 通过 `hp_ensure_live` 探测 live 文件存在性。
- **回归**：byte-level 一致 —— client 6773 / custom 1860 / server 3865（差异为 `data_directory` 路径，9 字节）/ wireguard 3755 / partial_invalid 3494，与 baseline 一字不差；golden protocol snapshot（14 项）、protocol inventory（122 项）、domain model skeleton（63 项）、subscription filter/decoder/repository、homeproxy helper、executeCommand 失败路径全部 PASS。`firewall template rendering` 失败是预先就有的环境限制（绝对路径 `/etc/homeproxy/...` 只能 target 解析），跟本次重构无关。

### 2.5 PHASE 5 — Subscription Pipeline 收尾 ~~（PR-03）~~ ✅ 已落地（commit e88f7c7）

> ~~已完成：`fetcher/decoder/filter/repository` 四个模块 + 单测，是本次做得最扎实的一块。~~
>
> ~~遗留：~~
> ~~1. 规则要求"只有 Repository 负责持久化"，但 `update_subscriptions.uc` 自己还有 6 处~~
>    ~~`uci.set` + `uci.commit`（`:178,186,205,212,221,236`）用于清理 urltest 失效成员。~~
>    ~~建议把这些搬进 `repository.uc`（例如 `reconcile_main_node()`），并合并成**一次 commit**。~~
> ~~2. 缺少 `normalizer.uc`（decoder 里对 SIP008 打 tag 的逻辑可以独立）与 `validator.uc`~~
>    ~~（目前"合法性"只由 `parse_uri` 末尾顺带完成）。~~
> ~~3. `update_subscriptions.uc:29` 自己持有 `uci.cursor()` 并重复读取~~
>    ~~`subscription.*` / `config.*`（`:38-51`）。既然 `config/loader.uc` 已经是唯一 UCI 读取层，~~
>    ~~这里应该复用 `Loader`（否则"Loader 拥有唯一 cursor"的注释是假的，见 §4）。~~
> ~~4. **`stop → fetch → commit → start` 反模式**（§6）。~~

**落地形态**（commit e88f7c7）：

§A — `parser/flatten.uc` 补全 canonical ↔ flat 闭环（PR-02 的 `normalize.uc` 的反向函数）。
完整 mirror `normalize` 的子对象构造（`common` / `credentials` / `tls` / `transport` /
`multiplex` / `protocol_options`），从同一个 `parser/mapping.uc` 的 `PROTOCOL_TO_UCI` 派生。
元数据字段（`label` / `grouphash`）透传；`isExisting` 是 Repository 的 within-run
marker，**不**写入 UCI。空 / null canonical 值被丢弃（Loader 把 null 与缺省等同看待，
round-trip 无损）。

§B — `subscription/repository.uc` 重写为命名空间 `Repository = { apply_nodes,
apply_main_node_refs, scrub_stale_urltest_refs }`，接收 canonical Node，内部 flatten
后写 UCI。`apply_nodes` 取代了原 `apply()`；`apply_main_node_refs` 把 §2.5 #1 提到的 6 处
`uci.set/commit`（main_urltest_nodes 清理 / main_node 切换 / main_udp_urltest_nodes 清理
/ main_udp_node 切换 / reset-to-nil / routing_node urltest_nodes scrub）全部收敛：
* sites 1-5 → `apply_main_node_refs(uci, uciconfig, ucimain, ucinode, ctx, log)`，单次
  commit / 每个分支（按需），返回 `{main_node, main_udp_node, log}` 给 orchestrator
  回放 log。
* site 6 → `scrub_stale_urltest_refs(uci, uciconfig, log)`，逐 `routing_node` 处理，
  每个 scrubbed section 各 commit 一次（旧代码也是这个粒度）。

§C — `update_subscriptions.uc` 重写：
* 顶部不再 `cursor().get()` 重复读 `subscription.*` / `config.*`，改用
  `Loader.load().access_control.subscription`（plan §2.5 #3）。
* Pipeline：`parse_uri` → `apply_policy`（仍是 flat 形式，apply_policy 单测不动）→
  `normalize` → Repository。
* 自身零 UCI 写入（2026-09 复核：全文 `grep -n "uci\.set\|uci\.commit\|uci\.delete"`
  **零命中**）。回滚走的是 §2.6 的文件快照而不是 UCI 写：`:96` `readfile(CONFIG_FILE)`
  取快照，失败时 `:255` `writefile(CONFIG_FILE, config_backup)` 还原。
  （**勘误**：本文件此前写作"唯一一处 `uci.set` 是 `config_backup` 异常回滚"，
  与代码不符 —— 该路径本来就没有 `uci.set`。）它仍持有 `cursor()`（`:65-66`）
  并把 cursor 交给 Repository，这是"cursor 就是 UCI 写入契约"的有意设计。
* Repository 的 `main_refs.log` 在 orchestrator 回放（`"Main node is gone, switching to ..."`
  / `"No available node, disable tproxy."` 行为不变）。

§D — 防回归：
* `tests/ucode/test_parser_flatten.uc`（新增）：13 个 scheme × 至少 5 个 key 字段的
  round-trip 等式 + 4 个 explicit 子对象断言（vless reality / shadowsocks plugin /
  grouphash 透传 / isExisting 不透出）+ 空 canonical 值丢弃。**只有"parser 与 flatten
  输出字段一致"才会通过** —— 这是协议选项映射表（`parser/mapping.uc`）"不漂移"
  的硬约束。
* `tests/ucode/test_subscription_repository.uc`（扩展）：从 5 个检查（4 个 apply_nodes 路径
  + 新增 / 保留 / 删除计数）扩展到 17 项，覆盖：
  - 原 4 个 `apply_nodes` 路径（user 不动 / updated / dropped / new）
  - `apply_main_node_refs` 的 3 条分支（urltest 列表剪枝 / 目标丢失切换 / 无节点 reset-to-nil）
  - `scrub_stale_urltest_refs` 的 1 条路径（urltest_nodes 死引用清理）
* `tests/ucode/test_subscription_filter.uc` 不变（`apply_policy` 仍是 flat 接口）；
  这是有意为之 —— `apply_policy` 的契约是"在 parser 之后、normalize 之前"对
  flat UCI 字段做小动作。
* `tests/README.md` 增补 `test_parser_flatten.uc` 行 + 扩写 `test_subscription_repository.uc`
  描述。
* `tests/ucode/run.sh`：parser stage 同步，`test_parser_flatten.uc` 加入跑测；
  module import 校验列表加 `parser/flatten`。

**字节级不变量**：Repository 写入 UCI 的字段集合等于 parser 写入的字段集合（除
grouphash / label 这种元数据）；`/etc/config/homeproxy` 形状与 PR-02 完全一致。
Golden 快照无影响。

本机 `python3 tests/i18n-coverage.py` 724/724 PASS；
`tests/luci-form-snapshot.js` node / client / server 三份快照一致。

**不在本 PR 范围**：
* Repository 现在 canonical → flatten 一次往返；将来若 PR 之后改用 batch API
  （一次 uci.set 多 key），可在此基础上减少 `cursor()` 调用次数。
* decoder 的 SIP008 tag 生成 / `subscription/decoder.uc` 没有抽到独立 `normalizer`。
  PR-03 的"normalizer / validator 接入 pipeline"指的是 parser 那侧的
  `parser/normalize` / `parser/validator`，不是 subscription 那侧 —— 后面如果需要再拆。

### 2.6 PHASE 6 — Candidate Configuration + Rollback（最高优先级的新功能）✅ 已实施（见下）

> **已实施**：`scripts/runtime/config.sh` 提供 known-good / ensure-live / rollback / same-file 原语，
> `scripts/runtime/health.sh` 提供实例健康探测。`init.d/homeproxy` 改为：
> 先生成（生成器本身是"写临时文件 → check → 原子 rename"，失败则旧文件原样保留）→
> 校验失败就在 `stop` **之前**中止 reload（旧配置继续运行）→ 通过后 `stop; start` →
> **健康门**：实例没起来就把 known-good 副本放回并用 `HP_USE_KNOWN_GOOD=1` 重新 start
> （必须绕过重新生成，否则生成器会按同一份 UCI 再造出刚失败的那份配置）→ 成功后才刷新 known-good 副本。
> 订阅侧：见 §2.5 的实施说明（先抓取、失败恢复配置文件、成功才 reload）。
> `tests/runtime/test_config_transaction.sh` 覆盖 16 项；`init.d` 本身只在设备上执行（procd 无法离机测）。

这是文档的核心可靠性目标，目前完全缺失。现状：

```
init.d/homeproxy:378-412 reload_service():
    generate_client.uc            # 内部已经 mv 覆盖了 live 文件（generate_client.uc:1191）
    $PROG check sing-box-c.json   # 再检查一次
    ... (失败则 return 1，不重启)
    stop                          # stop_service 里 rm -f sing-box-c.json (init.d:363-364)
    start                         # start_service 里重新 generate，失败则 return 1
```

失败路径分析（真的会掉服务）：
- 若新配置非法：`generate_client.uc` 自己先失败，live 文件保持旧内容 → init.d 的 check 通过（旧文件）
  → 继续 `stop` → `stop` **删掉了唯一的配置文件** → `start` 重新生成又失败 → 服务停摆。
- 全程没有备份 `/etc/config/homeproxy`，也没有备份旧 `sing-box-c.json`。

建议的最小可用设计（不需要新框架）：

```
runtime/candidate.uc 或 init.d 内的小函数:
 1. generate → $RUN_DIR/candidate/sing-box-c.json      (不再直接覆盖 live)
 2. sing-box check candidate                            (唯一一次 check)
 3. cp live → $RUN_DIR/rollback/sing-box-c.json         (保留回滚素材)
 4. mv candidate → live  (原子)
 5. 用 procd 的 instance reload 而不是 stop+start         (避免 firewall/dnsmasq/ip rule 全量拆除重建)
 6. health: 轮询 mixed_port / `ubus call service list`   (runtime/health.uc)
 7. 失败 → mv rollback → live，再次 reload，并 log 记录回滚 (runtime/rollback.uc)
```

订阅侧同样：
```
 1. fetch/decode/parse/filter 全部在内存完成（已经是这样）
 2. cp /etc/config/homeproxy → /etc/config/homeproxy.bak
 3. 单次 commit
 4. 失败 → restore .bak，log 回滚
```
并把 `update_subscriptions.uc:83-86` 的"更新前先 stop"改成"成功后再 reload"，
避免整个抓取期间（可能数十秒）代理处于停止状态。

> 文档特别提醒的"不得假设未 commit 的 candidate 会被另一个 ucode cursor 自动看到"——本仓库目前
> 没有踩这个坑（`repository.uc` 是在同一个 cursor 上 set 完再 commit），设计新事务时请保持这一点。

> ⚠️ **本节有一个已实测的漏洞，见 §2.14**：上面这条链里的「健康门 → 通过则刷新 known-good」
> 这一步，判据是「进程存在」。对「能过 `sing-box check` 但起不来」的配置，它会被 procd respawn
> 的窗口骗过：reload 报 `Reload completed.`、服务却是死的、known-good 被写成坏配置。
> 所以本节的失败链**生成期成立、运行期不成立**，修法见 §2.14.5。

### 2.7 PHASE 7 — Runtime 抽离 ~~🟡 部分实施~~ ✅ 已落地（PR-05，见 §2.10）

> **~~未实施~~ 已实施**：~~`runtime/{service,dns,firewall}.uc` 的进一步抽离（把 dnsmasq 片段生成、
> tproxy/tun 规则也搬出 init.d）。原因：这部分与 procd 生命周期耦合最紧，且离机无法验证——按
> "不要为了拆文件而拆文件"的原则留待有 on-target CI 时再做。~~
> **PR-05 已落地**：`init.d/homeproxy` 517 → **253 行**，抽到
> `scripts/runtime/{service,dns,firewall,net}.sh`。落地形态、验证方式与剩余半场见 §2.10。

> **已实施（PR-05 之前）**：抽出 `scripts/runtime/config.sh`（配置事务）与
> `scripts/runtime/health.sh`（健康探测），`init.d/homeproxy` 去掉重复的 `sing-box check`。

`init.d/homeproxy` 原本 517 行里混了 5 类职责（实测分布，见 §2.10.1）：服务生命周期 75、
版本闸门 13、配置事务 95、dnsmasq 57、fw4/nft 25、ip/tproxy/tun 68、健康 26、其它 158。
PR-05 之后 init.d 只剩生命周期编排 + 配置读取 + 三个 service 函数骨架。

注意约束（文档也强调了，PR-05 全部保持）：
- ~~不能破坏~~ procd / respawn / start/stop/reload —— 真机实测通过（§2.10.7）；
- `service_triggers` 的 `procd_add_reload_trigger` 与 `procd_add_interface_trigger` 保持原样
  （`init.d:248-250`；与原版逐字一致，见 §2.10.6）；
- `stop_service` 会 flush/delete 13 个 chain + 11 个 set，**"逐个删除、不批量"的语义必须保持**
  （`fw4_names.sh` 注释已解释原因）—— 现在是 `runtime/firewall.sh::hp_firewall_teardown`，
  差分 trace 测试逐条比对了这 48 次 `nft` 调用（§2.10.4）。

**一条与 plan 原定目标不同的决定**：§2.7 原文写的是 `runtime/*.uc`，实际用的是 `runtime/*.sh`。
理由：被搬走的代码是 shell（`procd_*` / `ip` / `nft` / `dnsmasq` 片段生成），init.d 本身就是 shell，
改用 ucode 会引入一门新语言、多一层 `ucode` 运行时依赖，收益为零。既有的
`runtime/config.sh` / `health.sh` 也已经是 shell 先例。同时把 tproxy/TUN 单独拆成 `net.sh`
（68 行，与 service 的生命周期编排不同质），而不是硬塞进 `service.sh`。

### 2.8 PHASE 8 — LuCI 模块化

> **本节是 PR-06 开工前的现状分析，行号已过期。** 落地记录与当前状态见 §2.11.8：协议真源、
> 快照覆盖率、node↔server 的 mux/TUIC/hysteria/password 去重、RPC 单一入口、死代码都已落地；
> 下面这张"重复项"表里剩下的只有 client.js 内部那两块、GridSection 脚手架与动态 load 样板、
> 以及跨文件的状态三件套。保留本节是为了留住"当初为什么判断值得做"的依据，
> **不要**按它的行号去找代码。

已经做对的：TLS/Transport 表单块确实抽到了 `homeproxy.js:109-237` / `:243-323`，并被
`node.js:812`、`server.js:415` 复用。但目标目录 `view/homeproxy/{protocol,components,shared}/`
不存在，且还有真实重复：

| 重复项 | 位置 | 规模 |
|---|---|---|
| node.js ↔ server.js 协议块 | `server.js:251-448` vs `node.js:549-960` | ~229 行，76 条完全相同的 `_()` 字符串 |
| 已漂移 | snell：`node.js:925-926` 是 `'4','6' + "v4 only"`，`server.js:331-332` 是 `'5','6' + "v5 only"` | 真实行为不一致 |
| `client.js` 内 `routing_rule` ↔ `dns_rule` | `client.js:883-955` vs `:1385-1467` | ~80 行，差异仅 3 条描述 + 2 个字段 |
| Grid `load` 样板 | `client.js` 13 处（`:408,427,478,511,697,729,819,971,1083,1122,1214,1247,1542`） | ~150 行 |
| 服务状态三件套 | `client.js:20-60` vs `server.js:18-63` | 仅 tag/文案不同 |
| VIP 协议表 | 见 §2.8 protocol registry | 6 份 |

**协议 registry 是 6 份不同步的副本**：
`node.js:447-465`、`server.js:175-192`、`loader.uc:168-256`、`adapter.uc:52-75`、
`model.uc:43-57`、`parse_uri.uc:445-483`。已经造成的具体缺陷：
- `ssh` 在 `node.js:456` 可选，但 `loader.uc` / `adapter.uc` 的表里**没有 `ssh` 行**；
- `model.uc:54` 把 ssh 私钥映射到 `private_key`，而表单写的是 `ssh_priv_key`（`node.js:717`）
  ⇒ 后端永远读不到用户填的私钥；
- `wireguard` 在 `node.js:462-463` 可选，`loader.uc` 现在有 `wireguard` 行（本轮 §1.2 修复），
  但仍没有走进 `adapter.uc`——`generate_endpoint()` 是它的专用构建器；
- hysteria2 的 `auth_payload` 在 `loader.uc:239` 有，UI 没有对应字段。

建议：先做**一份权威协议表**（JS 侧导出给 LuCI，ucode 侧由同一份数据生成或由一致性测试守护），
再拆目录；否则拆完还是 6 份。

### 2.9 PHASE 9 — Test / CI ✅ 收尾已落地（`client.json` / TLS-Transport / fetcher / migrate / firewall_pre / CI）

现状分层（实测）：
- `python3 tests/i18n-coverage.py --warn-below 100` → **PASS**（724/724）
- `node tests/luci-form-snapshot.js` ~~node/server~~ node/client/server → **PASS**（与 `tests/snapshots/*.json` 一致）
- `sh tests/ucode/run.sh` → 本机 **NOT RUN**（无 ucode；已加 `command -v ucode` 守卫，
  现在明确打印 NOT RUN 并以退出码 2 结束，而不是把每个用例误报成 FAIL）
- 目标设备上 → **PASS**（`SUITE_RC=0`，`^FAIL` 计数 0）

已落地的（本轮）：
1. **取消 target-only SKIP**。原来有 4 项在开发机上以 `SKIP` 跳过，其中 `update_subscriptions.uc`
   和 `luci.homeproxy` 正是漏掉语法错误的地方。现在：`update_subscriptions.uc` / `firewall_pre.uc`
   正常编译（`luci.sys` 来自工具链，`homeproxy` 由 `-L` 解析）；
   `luci.homeproxy` 用 sed 把绝对 `/etc/homeproxy/...` import 改写到 checkout 后编译；
   `firewall_post.ut` 渲染也能跑（`utpl` 是 `ucode` 的符号链接，工具链会装）。
   工具链缺 `utpl` 之类的缺口现在直接 **FAIL**，不再静默降级。
2. **语法金丝雀**：新增 `tests/ucode/test_ucode_grammar.sh`，断言工具链 ucode **拒绝**
   `export function ... }`（缺 `;`）与对象/数组解构，**接受**仓库实际用到的
   `?.`/`??`/对象展开/计算键/模板字符串。它既在 `build-ucode-*.sh` 的 verify 阶段运行，
   也是 `tests/ucode/run.sh` 的第一步。可用 `HP_ALLOW_PERMISSIVE_UCODE=1` 降级为警告。
3. **ucode 版本 pin**：`build-ucode-linux.sh` / `-macos.sh` 的 `UCODE_REV` 固定为
   `85922056ef7abeace3cca3ab28bc1ac2d88e31b1`，即设备上 `ucode-2026.01.16~85922056` 对应的 revision。
   原因：上游在 85922056 之后**放宽**了 `export function` 的分号要求
   （对比两版上游自带测试 `tests/custom/04_modules/02_export_function_declaration`：
   `85922056` 用 `};`，当前 main pin 的 `b885dd0f` 用 `}`），
   而 `openwrt/openwrt@main`、`immortalwrt/immortalwrt@master` 现在都 pin `b885dd0f`。
   所以"从 master 构建"必然无法复现目标语法——这正是 CI 全绿而设备全红的原因。
   pin + 金丝雀两者一起，既复现目标，又能在有人改 pin 时立刻报警。
4. `config/*.uc` 已加入 run.sh 的 import 检查（之前只在 generator 测试里被间接覆盖）。

本轮补齐的：
5. ✅ **vacuous 断言已删除**（§3.1）：`test_demo_architecture.sh` 及其 `HP_TEST_HOOK` 已移除。
6. ✅ **协议覆盖不变量**：`tests/ucode/test_protocol_inventory.sh`，122 项断言，跨
   `parse_uri` / `CREDENTIALS` / `PROTOCOL_OPTIONS` / `REQUIRED_CREDENTIALS` / `OPTION_FIELDS`
   / golden 快照 / endpoint-only 协议。ssh 与 wireguard 的缺口正是这类。
7. ✅ **golden JSON 快照**：`tests/snapshots/generator/outbounds.json`（14 协议），
   并额外跑真实 `sing-box check`（找出 §1.6 的 4 个缺陷）。
8. ~~⬜ `client.json` 表单快照：`luci-form-snapshot.js` 仍只接受 `node|server`，`client.js` 无快照。~~ ✅ 已落地（commit `db1d200`）—— `luci-form-snapshot.js` 接受 `node|client|server`，新增 `tests/snapshots/client.json`（677 行）；mock 补 `tools.firewall.addIPOption/addMACOption` 与 `hp_has_tproxy`/`hp_has_tun`/`hp_has_ip_full`；`tests/run.sh` 与 `.github/workflows/arch-test.yml` 的快照循环都加了 `client`。
9. ~~⬜ TLS/Transport 单测：仍没有直接调用 `load_tls/load_transport/buildTLSObject/buildTransportObject` 的测试
   （目前由 golden 快照 + generator fixture 间接覆盖）。~~ ✅ 已落地（commit `ac910b6`）——
   `tests/ucode/test_tls_transport.uc`，37 项断言直调 `buildTLSObject` / `buildTransportObject`：
   服务端不得有 `insecure` / `utls`、reality 的 `public_key` 只在客户端 / `private_key` 只在服务端、
   ECH 客户端与服务端字段分叉、`cert_path` 走 `validateHomeProxyPath` 白名单。
10. ✅ demo 测试的两条空操作 sed 随测试一起删除。
11. ✅ `tests/README.md` 已彻底改写，不再残留 `demo/architecture/` 的描述。
12. ✅ `tests/ucode/run.sh` 新增 **shell 语法检查**（`init.d/*` + `homeproxy/scripts/*.sh` +
    `homeproxy/scripts/runtime/*.sh`），补上了这类文件此前完全不被检查的空白。
13. ✅ `tests/ucode/test_subscription_fetcher.uc` + `mocks/homeproxy_fetcher.uc`：7 项断言，
    覆盖空/非空响应与**日志脱敏**（`https://***@host/path?***`）。顺带修掉 `fetcher.uc` 里
    `wGETVerbose` **漏 import** 的真实缺陷——该函数从未被 import，只因没有任何测试驱动过
    `update_subscriptions.uc` 才一直没暴露（commit `b23f9c3`）。
14. ✅ `tests/ucode/test_migrate_config.sh` + `.uc`：36 项断言，跑在沙箱 UCI 上，覆盖
    1.14 DNS 改名、`dns_server.address` 拆分、`rcode://` 转 predefined、`rule_set_ipcidr_match_source`
    改名、`block-out`/`block-dns` → `action='reject'`、`auto_firewall` 重分发、`block-dns`
    默认服务器替换（commit `e17b75d`）。
15. ✅ `tests/ucode/test_firewall_pre.sh`：`firewall_pre.uc` 的 8 个行为场景（tun 放行对、
    逐 server 放行、显式 network 收窄、**非法 port/network 必须 WARN 且跳过**、
    `firewall='0'` 退出、tun+server 共存）。非法值一旦被直接插进 nft 语句，
    nft 会因一行报错丢掉**整份** ruleset（commit `b0e4a33`）。

本轮已补上测试的文件：~~`client.js`~~（表单快照）、~~`migrate_config.uc`~~、
~~`firewall_pre.uc`~~、~~`subscription/fetcher.uc`~~。

仍然无**直接**测试的文件（已在 `tests/README.md` 里逐条给出理由）：
`status.js`（LuCI 视图，只有浏览器里可观测）、`update_resources.sh`、
`update_crond.sh`、`clean_log.sh`（网络往返 / 固定调用列表 / `while true` 循环，
离线只能覆盖法参数分支，已由 shell 语法检查兜住）。
`init.d/homeproxy` 现在有 shell 语法检查 + 事务语义测试，但 procd 行为仍需 on-target CI；
`luci.homeproxy` 的 RPC 已在设备上跑过真实 rpcd（见附录）。

### 2.10 PR-05 — PHASE 7 Runtime 抽离 ✅ 已落地（commit `c2aeac5`）

对应指导建议 PR-05 的**抽离半场**（观点 19）与观点 20 的复核。可靠性另一半（观点 18 健康分级、
观点 21 显式状态机）见 §2.10.3 / §2.10.5，**未做**。

#### 2.10.1 抽离前的职责实测分布（517 行的账）

把 `init.d/homeproxy` 的 517 行逐行归入唯一一类（合计校验 = 517）：

| 类别 | 行区间 | 行数 |
|---|---|---|
| (a) procd 生命周期 | 6；8-9；238-265；288-315；318-321；450-455；502-503；514-517 | 75 |
| (b) 版本/工具链闸门 | 64-76 | 13 |
| (c) 生成配置事务 | 18-21；115-142；268-286；401-402；430-448；477-494；496-500 | 95 |
| (d) dnsmasq | 35-54；155-188；397-399 | 57 |
| (e) fw4/nft | 23-24；343-348；379-395 | 25 |
| (f) ip/tproxy/tun | 190-236；365-377；407-414 | 68 |
| (g) 健康 | 457-475；505-511 | 26 |
| (h) 其它（常量、`log()`、UCI 读取、WAN 等待、cron、cache.db 准备、chown） | 见 §2.7 脚注 | 158 |

这张表就是"该搬什么"的依据：**(b)(d)(e)(f) 加 (c) 的胶水**是纯设备侧编排，可以整块外移；
**(a) 是不可约的 init 内核**，必须在 init.d 里。

#### 2.10.2 落地形态

`init.d/homeproxy` **517 → 253 行**（纯代码 145 行）；新增四个模块，加上既有两个共六个：

| 模块 | 行数 / 纯代码 | 承接 |
|---|---|---|
| `runtime/service.sh` | 259 / 153 | `hp_require_singbox`（版本闸门）、`hp_sync_autoupdate_cron` / `hp_clear_autoupdate_cron`、`hp_prepare_runtime_files`（cache.db / ruleset / certs / 日志截断 / chown）、`hp_procd_client_instance` / `hp_procd_server_instance` / `hp_procd_log_cleaner`、`hp_start_generated_config`（生成 → ensure-live → known-good 事务） |
| `runtime/dns.sh` | 107 / 57 | `hp_dnsmasq_resolve_dir`、`hp_dnsmasq_write_snippets`、`hp_dnsmasq_remove_snippets` |
| `runtime/firewall.sh` | 67 / 32 | `hp_restore_upnp_mappings`、`hp_firewall_apply`、`hp_firewall_teardown` |
| `runtime/net.sh` | 129 / 79 | `hp_net_wait_wan`、`hp_net_setup`（tproxy + TUN）、`hp_net_teardown`、`hp_net_remove_tun` |
| `runtime/config.sh`（既有） | 76 / 28 | 事务原语：known-good / ensure-live / rollback / same-file |
| `runtime/health.sh`（既有） | 54 / 25 | 实例健康探测 + 轮询 |

**分层约定（写进了 `service.sh` 头注释）**：`config.sh` / `health.sh` 保持**纯**（只取显式路径参数，
不碰 procd/ubus/UCI），所以能离机单测；PR-05 新增的四个模块**是设备侧的**——它们调用 `log`、
`config_get`、`procd_*`，因此要求调用方已 `config_load` 且处于 procd init 上下文。
这个区分是刻意的，PR-07 的 UCI 白名单必须按它来写（§2.12.4）。

**留在 init.d 的东西**：`USE_PROCD` / `START` / `STOP`、`start|stop|reload|service_stopped` /
`service_triggers` 骨架、决定"客户端 / 服务端 / 都不做"的配置读取、以及那条安全顺序
（先生成 → 后拆除 → 证明起来了 → 否则回滚）。`reload_service` **97 行逐字未改**（§2.10.6 有 diff 证明）。

#### 2.10.3 剩余半场 1 — 健康仍然只有"进程活着"（观点 18）

`runtime/health.sh` 现在只有 `hp_instance_running`（`pgrep -f "run --config <path>"`，退化到
`ubus call service list` + `jsonfilter`）与 `hp_wait_instance`。对照指导建议的四级阶梯：

| 级别 | 状态 | 说明 |
|---|---|---|
| Process Health | ✅ 已有 | `health.sh:23-38` |
| Configuration Health | 🟡 部分 | 生成期 `sing-box check`（`generate_client.uc:39` / `generate_server.uc:33`，**init.d 内 0 次**）；但健康门本身不重新校验 |
| Listener Health | ❌ 缺 | 没有"mixed_port / tproxy_port / dns_port 在 listen"的检查。这是**可离机测试**的一级：`ss -ltn` / `netstat -ltn` 的输出可以 stub |
| Functional Health | ❌ 缺 | 没有真实探针 |

**设计取舍（重要）**：建议 Listener Health 直接接入健康门（进程活着但端口没听 = 配置有问题，
应当回滚）；**Functional Health 默认只告警、不触发回滚**——探测目标不可达 ≠ 本地配置坏，
把它接进回滚会让一次上游抖动变成一个可回滚事件。这条边界要写进 PR-05 续的实现里。

#### 2.10.4 验证方式 1：离机差分 trace 等价测试（新增，永久回归）

抽离类重构的唯一可信证明是"可观测行为没变"。新增
`tests/runtime/test_runtime_extraction.sh`（346 行）：

1. 用桩命令（`ip` / `nft` / `fw4` / `utpl` / `ucode` / `sing-box` / `uci` / `uname` / `chown` / `sleep`）
   + 桩 `procd_*` + 桩 `config_get` + 夹具 UCI，把 init.d **source 进同一个 shell**（与 rc.common 同构）；
2. 跑三个场景：A `tun` + `bypass_mainland_china` + 仅客户端；B `redirect_tproxy` + `gfwlist` + ipv6 +
   服务端 + 自动更新 cron；C 两边都没配置（早期返回）；
3. 每个场景记录**命令序列 + 参数 + `log` 文本 + 文件产物内容**，与
   `tests/fixtures/runtime/trace.pre-pr05.txt`（**360 行，从 PR-05 之前的 517 行 init.d 采集**）逐字 diff。

结果：**PASS — 三个场景 360 行 trace 完全一致**。

它同时是这类重构的**永久防线**：谁再动 `runtime/*.sh` 的编排顺序，trace 就会红。可信度来自两点：

- **反向验证过**：第一次跑出的是 FAIL —— 我把版本闸门写成了 `"$prog" version -n`（绝对路径），
  而原版是裸 `sing-box`（走 PATH）。trace 立刻把它抓出来了，已改回。这正是 §3.1 要求的
  "测试必须能失败"。
- **桩的忠实度**：`ip` 桩对 `rule del` 必须返回非零，否则 `while ip rule del …; do :; done`
  去重循环永不终止（第一次实现就踩了这个坑，见脚本注释）。

`tests/ucode/run.sh` 与 `tests/run.sh` 都已接入这个测试。注意 `arch-test.yml:94` 调的是
`tests/ucode/run.sh` 而**不是** `tests/run.sh`，所以只放进后者等于 CI 不跑——两个入口都加了。

#### 2.10.5 剩余半场 2 — Known-Good 不是状态机（观点 21）

机制在（known-good 副本、ensure-live 回退、健康门后刷新、失败回滚），但**状态是隐含在控制流里的**，
没有显式状态机。本轮复核暴露两个具体问题：

1. **known-good 放在 tmpfs。** `GOOD_DIR="$RUN_DIR/known-good"`，而 `RUN_DIR=/var/run/homeproxy`、
   设备上 `/var → tmp`（实测：`tmpfs on /tmp type tmpfs`，`df /var/run` 报 `tmpfs 1.9G`）。
   所以 **known-good 不跨重启存活**，而全仓没有任何地方重新播种它。保护范围实际上只有"单次开机周期内"。
   PR-05 续需要先决定这是有意还是缺口；若要跨重启，就把它落盘（例如 `/etc/homeproxy/known-good/`）
   或在首次成功启动后播种。
2. **回滚只见 "配置不同" 不见 "状态"。** 建议的显式状态机
   `KNOWN_GOOD → CANDIDATE → VALIDATING → ACTIVATING → HEALTHY`（+ 失败 `→ ROLLBACK → KNOWN_GOOD`）
   是 PR-05 续的骨架。

#### 2.10.6 未改动的部分（逐字一致的证明）

| 检查 | 方法 | 结果 |
|---|---|---|
| `reload_service()` 97 行 | `awk` 提取旧/新函数体后 `diff` | **一字不差** |
| `service_triggers()` | 同上 | **一字不差** |
| 四条边界的所有命令 | 差分 trace（§2.10.4） | **360 行一致** |
| 旧函数名残留 | `grep -rn "restore_upnp_mappings\b"`（排除 `hp_` 前缀） | 无 |
| `generator/` 是否被波及 | 冻结检查 | 未改一个字节 |

#### 2.10.7 验证方式 2：真机 192.168.1.102 procd 生命周期

在测试机（ImmortalWrt 25.12.1 x86/64）上安装 **PR-05 的 diff**（`init.d/homeproxy` +
`runtime/*.sh` + `fw4_names.sh`）后实测：

| 步骤 | 证据 |
|---|---|
| `start` | `rc=0`；`ubus call service list` 显示 **`sing-box-c` running pid 28624** 与 **`log-cleaner` running pid 28625** —— 这两行是 PR-05 最关键的结论：**procd 接受在 sourced 模块里注册的实例** |
| 实例 argv | `["/usr/bin/sing-box","run","--config","/var/run/homeproxy/sing-box-c.json"]` —— 与 `health.sh` 的 pgrep 模式完全对齐 |
| TUN | `singtun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 9000 state UP` |
| ip rule | `32765: from all fwmark 0x66 lookup 100`（0x66 = 102 = `tun_mark`） |
| 产物 | `known-good/sing-box-c.json`、`cache.db`、`fw4_{forward,input,post}.nft`、`sing-box-c.json`（owner `sing-box`）、`/etc/homeproxy/ruleset`（custom 模式） |
| dnsmasq | `dnsmasq-homeproxy.conf` = `conf-dir=…/dnsmasq-homeproxy.d`；`redirect-dns.conf` = `no-poll / no-resolv / server=127.0.0.1#5333`（custom 分支） |
| `reload` | `rc=0`；健康门通过；known-good 刷新；日志 `Reload completed.` |
| `stop` | `rc=0`；实例清空、`singtun0` 删除（`service_stopped` 生效）、ip rule 消失、dnsmasq 片段删除、live 配置删除、**known-good 按设计保留**、`fw4_*.nft` 归零、日志 `Service stopped.` |

**为了不把测试机弄断网，两处刻意的隔离（必须记下来，否则会被误读成"全链路已验证"）**：

- `fw4` 与 `nft` 用 PATH 桩替换为**记录型 no-op**：真实 `fw4 reload` 会装入 homeproxy 的
  nft 规则集，把测试机自己的出站流量送去 tproxy/tun，可能直接切断我的 SSH。
  因此**防火墙规则的实际生效没有在真机验证**；被验证的是"渲染 + 调用顺序"（差分 trace 已覆盖）。
- 版本闸门用 PATH 桩把 `sing-box version -n` 报成 `1.14.0`。原因：设备上装的是 **sing-box 1.13.16**
  且是 musl 系统（官方 release 是 glibc，跑不起来；apk 源实测不可达，无法升级）。
  被闸门拦住的只是启动前置条件，**被验证的代码是原样的**；生成器用的是设备自带的
  1.13 时代 generator（与 1.13.16 匹配）。

**设备已完全还原**：`/etc/init.d/homeproxy` 与 `/etc/config/homeproxy` 的 md5 与备份逐字相同
（`dc7fdad5…` / `04c771c5…`），`runtime/`、`fw4_names.sh`、`ruleset/` 已删除，dnsmasq 已归位，
`sing-box` 保持 1.13.16 未动。备份留在设备 `/root/hp-pr05-backup/`（含 1.13.16 二进制，
不需要时 `rm -rf /root/hp-pr05-backup` 即可）。

#### 2.10.8 本轮复核发现、但**没有**在 PR-05 里改的实现问题

抽离是行为保持的，所以下面这些**原有**问题被原样搬了过来。它们是 PR-05 续的输入：

1. **`runtime/*.sh` 的函数不用 `local`**（`config.sh` / `health.sh` 全都没有）。`live` / `good` /
   `name` / `config` / `tries` / `state` 会泄漏到调用者作用域。今天恰好无害（`reload_service`
   在 `:479-480` 先 `local good`/`local live` 再调用，且传的正是同样的值），但只要 init.d 将来引入
   同名全局就会被静默覆盖。设备实测 `local x=1` 在 busybox ash 下正常（`A=[1]`），改起来是纯收益。
   **PR-05 新增的四个模块已经全部用 `local`**，旧的两个没有动（保持 diff 最小）。
2. **`hp_instance_running` 的 pgrep 模式与 procd 命令文本强耦合**：`run --config <path>`
   必须同时匹配 `health.sh:28` 与 `service.sh` 里的 `procd_append_param command run --config …`。
   改任一处都会让健康门**静默失效**（退化成"总是超时 → 总是回滚"）。建议加一条断言把两者绑在一起测。
3. **dnsmasq 卸载不对称**：`hp_dnsmasq_remove_snippets` 无条件 `rm -rf`，即使 `start` 从未写入
   （例如 `outbound_node == nil` 时）。影响很小，但是"删除不存在的东西"这类噪音的来源。
4. **（已在 §2.14 修复）健康门判据**：`hp_instance_running` 原来的 `pgrep` 优先在真机上是错的
   （陈旧进程会覆盖 procd 的「未运行」）。commit `bb4e216` 把 procd 视角升为权威，
   并给测试 harness 补上保真度（见 §2.14.7）。

5. **`hp_prepare_runtime_files` 的 `chown` 在 custom 模式下必然报 warning**：它 `chown` 了
   `$HP_DIR/cache.db`，而 `cache.db` 只在 `bypass_mainland_china` 下创建。真机日志里可见
   `Warning: failed to change the ownership of the runtime files to sing-box.`。
   **这是 PR-05 之前就有的行为**（该行逐字未改，差分 trace 的场景 A/B 未覆盖 custom + 无 cache.db
   这个组合，所以没被抓成差异）。

### 2.11 PR-06 — LuCI 模块化（🟡 第一批已落地，见 §2.11.8；本节其余部分仍是设计基准）

对应指导建议观点 22 / 23 / 24。**只做重复消除与协议真源，不做"因为 innerHTML 看着危险"的重写**
（观点 24：没有实证 sink 就不重写）。

#### 2.11.1 现状规模（实测）

| 文件 | 行数 |
|---|---|
| `view/homeproxy/client.js` | 1811 |
| `view/homeproxy/node.js` | 973 |
| `view/homeproxy/server.js` | 787 |
| `homeproxy.js` | 600 |
| `view/homeproxy/status.js` | 296 |
| **合计** | **4467** |

#### 2.11.2 真问题 1：协议表前后端共 **24 份**（12 份前端 + 12 份后端）

前端 12 处协议字面量列表：`node.js` 的 type `ListValue`(58-77)、password `required_type`(111)、
TLS `type_depends`(568)、`tls_forced_types`(569)、`multiplex` depends(476-479)；
`server.js` 的 type `ListValue`(197-214)、password `required_type`(245)、`type_depends`(467)、
`tls_forced_types`(468)、`multiplex` depends(434-437)；`homeproxy.js` 的 transport depends(121-123)、
`packet_encoding` depends(231-232)。

后端 12 张表：`model.uc` 的 `CREDENTIALS`(42-62)、`INBOUND_CREDENTIALS`(72-87)、
`INBOUND_OPTIONS`(97-138)；`adapter.uc` 的 `REQUIRED_CREDENTIALS`(47-66)、`OPTION_FIELDS`(197-311)、
`INBOUND_COMMON_OMIT`(511-513)、`INBOUND_NO_USERS`(520)、`INBOUND_OPTION_FIELDS`(574-625)、
`REQUIRED_INBOUND_CREDENTIALS`(697-714)；`parser/mapping.uc` 的 `PROTOCOL_TO_UCI`(30-123)；
`parser/protocols.uc` 的 12 个 `parse_*_uri`；`parser/uri.uc` 的 17 个 scheme 标签。
（`config/loader.uc` **没有自己的协议表** —— 它 `import PROTOCOL_TO_UCI as PROTOCOL_OPTIONS`，
这一点 PR-02 做对了。）

**已经造成/暴露的具体分歧**（逐条有证据）：

| 分歧 | 证据 | 后果 |
|---|---|---|
| `snell` 在后端全链路支持，但**不在 `node.js` 的 type 列表里** | `node.js:58-77` 无 snell，但 `node.js:101` 有 `o.depends('type','snell')`、`:533-563` 有完整 Snell 块；后端 `model.uc:52`、`adapter.uc:54/209/603/704`、`mapping.uc:39-48`、`protocols.uc:140` 全有 | **UI 里根本选不到 Snell**（死代码 + 用户可见的能力缺失） |
| `shadowtls` 有后端 inbound 支持，但**不在 `server.js` 的 type 列表里** | `model.uc:80`、`adapter.uc:706`、`adapter.uc:536` vs `server.js:197-214` | 同上 |
| Snell 版本前后端**真实不一致** | `node.js:536-538` 是 `'4'`（默认 `'4'`）、"v4 only"(`:553`)；`server.js:353-355` 是 `'5'`（默认 `'5'`）、"v5 only"(`:360`) | 同一概念两套取值 |
| `shadowsocks` 加密方法列表不一致 | `node.js:262-274` 额外列出 aes-128/192/256-ctr、*-cfb、chacha20、chacha20-ietf、rc4-md5；`server.js:368-371` 只有 `hp.shadowsocks_encrypt_methods` | 客户端能选、服务端不能 |
| `wireguard` / `direct` 无 adapter 表行 | `node.js:74` / `:59` vs `adapter.uc:90-95`（`if` 特判）/ `:376` | 与观点 12 冲突（特殊协议走 Adapter） |
| mux/TCP-Brutal 门控不一致 | `node.js:515-530` 无条件；`server.js:444-461` 在 `if (features.hp_tcp_brutal)` 内 | 服务端缺 feature 时表单仍显示 |

#### 2.11.3 真问题 2：`node.js` ↔ `server.js` 有 322 行逐字重复

去空白后按行多重集统计：**node.js 的 785 行纯代码里有 322 行（41%）在 server.js 里逐字出现**
（占 server.js 634 行纯代码的 51%）。最大连续块：

| node.js | server.js | ≈行数 | 内容 |
|---|---|---|---|
| 191-232 | 297-338 | 42 | Hysteria auth / obfs / min-max packet size |
| 369-396 | 398-425 | 28 | TUIC uuid + congestion + 0-RTT + heartbeat，接 vless_flow / vmess_alterid |
| 511-530 | 440-459 | 20 | mux padding + TCP-Brutal |
| 108-117 | 242-251 | 10 | password 校验体 |
| 659-669 | 742-752 | 11 | `tcp_fast_open` / `tcp_multi_path` / `udp_fragment` |
| 1-16 | 1-16 | 16 | SPDX 头 + require 块 |
| … | … | ~100 | 其它 ≥3 行的连续块 |

再加上跨文件的状态三件套：`getServiceStatus`（`client.js:49-57` vs `server.js:50-58`，只差实例名）、
`renderStatus`（`:59-76` vs `:60-74`，只差 label）、状态栏 + poll 守卫（`:120-145` vs `:143-166`）。

#### 2.11.4 真问题 3：`client.js` 内部重复 ≈184 行

`routing_rule`（644-985，342 行）与 `dns_rule`（1167-1497，331 行）的去空白交集 **184 行（占前者 65%）**，
只有 3 处描述文本与 2 个字段不同。另有：GridSection 7 属性脚手架 ×5、Label+Enable 组 ×4、
`delete this.keylist` 动态 load 覆盖 ×13（每次 12-14 行）、proxy 域名列表(1699-1742) 与
direct 域名列表(1748-1784) 36 行里 32 行相同（只差 `'proxy_list'` / `'direct_list'`）。

#### 2.11.5 不是问题、不要动的部分（观点 24）

- `homeproxy.js` 已经承担了共享职责：`renderTransportOptions`(109-237)、`renderTlsOptions`(243-323)
  被 `node.js:423`、`server.js:429` / `node.js:566`、`server.js:465` 复用；另有 20 个 helper 被各视图复用。
- **`innerHTML` 只有 1 个活 sink 且已加固**：`client.js:142` / `server.js:163` 的
  `renderStatus(res, features.version)`，版本串受 `^[\w.\-+]+$` 白名单（`client.js:67-69`）。
  其余 `innerHTML` 全是静态字面量（`homeproxy.js:127-147` 的提示常量、`status.js:50/53` 的 `_('passed')`）。
- `status.js:246-258` 的 `o.rawhtml = true` 今天只喂 DOM 节点（`getResVersion` 用 `E()` 拼），
  没有字符串注入路径 —— 记一笔，不改。
- `homeproxy.js:399-412` 的 `decodeBase64Str` **没有任何视图调用**（后端有自己的实现）—— 死代码，
  可以在 PR-06 顺手删，但不是重写的理由。

#### 2.11.6 PR-06 的收敛目标（按优先级）

1. **一份协议真源**：后端已有 `parser/mapping.uc`；前端不应再手写 type 列表。可选路线：
   由后端 capability manifest 生成静态 metadata（build-time），或由一致性测试守护一份共享表。
   **先做"能失败的测试"再抽象**——因为今天已经有 6 类分歧，测试本身就能立刻抓到。
2. **抽 `components/` 与 `shared/`**：把 `node.js`↔`server.js` 的 322 行重复收进共享 builder，
   把跨文件状态三件套收进一个 `shared/status.js`。
3. ~~**`shared/rpc.js`**：现在 12 处 `rpc.declare`，其中 **9 处把失败吞成 `L.resolveDefault(…, {})`**~~ ✅ **已落地（commit `de436df`）**：`homeproxy.js` 的 `rpcCall()` 成为唯一声明与调用入口，12 处 declare → 1 处；失败改为 resolve 到显式 fallback 并**按方法只提示一次**（5s 轮询不会刷屏），后端"正常返回一个 error"仍算成功、由调用方处理（所以"链接无效"不会弹警告）。新增 `tests/frontend-rpc-inventory.js`（21 项，已反向验证）；它必须在匹配前**剥掉块注释** —— 第一版就被 `homeproxy.js` 里引用旧写法的那段文档注释误报，正是 §2.12 记的守卫陷阱。原文如下（保留作为记录）：
   （`homeproxy.js:415/433`、`client.js:20`、`server.js:18/83`、`status.js:35/64/71/164`）。
   统一封装 + 统一错误上报是 §4 "前端 RPC 无统一封装"那一条的落点。
4. **删死代码**：`decodeBase64Str`、UI 里选不到的协议分支。

#### 2.11.7 验收

- 表单快照（`node` / `client` / `server`）在三份 `tests/snapshots/*.json` 上必须继续 PASS；
  若**有意**改变 UI，按 §3.2 的规矩在同一 commit 里更新快照并写明原因。
- 协议真源落地后，需要一条"前端 type 列表 ⊆ 后端 `PROTOCOL_TO_UCI`"的断言（PR-07 的 Guard 可直接覆盖）。
- 浏览器人工目视：快照只能证明结构没变，**不能证明可用**。

#### 2.11.8 第一批落地记录（commits `767a46d` `c3603f6` `6aa0408` `5aa378e`）

落地了 2.11.6 里的第 1 条（协议真源）与第 4 条（死代码），并**先修好了这次改动赖以验证的
快照覆盖率**。截至第三批：第 1、3、4 条已完成，第 2 条完成一半（node↔server 的
mux / TUIC / hysteria / password 校验体已抽；client.js 内部与跨文件状态三件套未做，见 (f)）。

##### (a) 快照覆盖率：先说这个，因为它是前提

`tests/luci-form-snapshot.js` 的 `Option.toJSON()` 显式跳过了 `subsection` 键，而
`SectionValue` 类型的选项把**嵌套表单**放在 `o.subsection` 里。node.js 的整个表单体就是
这样建的（`s.taboption('node', form.SectionValue, '_node', form.GridSection, 'node')` →
`renderNodeSettings(o.subsection, …)`），client.js 的规则段落同理。结果是**这些选项从不出现在
快照里**：

| 目标 | 修复前 | 修复后 | 快照体积 |
|---|---|---|---|
| `node.json` | 13 个选项 | **117** | 3.5 KB → 34.6 KB |
| `client.json` | 29 | **206** | 8.6 KB → 56.3 KB |
| `server.json` | 95 | 95 | 25.9 KB → 27.8 KB |

差异是**纯增量**（三个目标各自"旧有新无"的选项数都是 0），所以只是开始记录本来就在渲染的东西。
在此之前，PHASE 8 最典型的改动（协议选择器）只在 `server.json` 里可见 —— 也就是说
"快照守住前端重构"这个说法，对 node/client 两个表单是**不成立**的。这条已写进
`tests/README.md`。

##### (b) 协议真源（2.11.6 第 1 条）

`homeproxy.js` 现在只有**一张有序表** `protocols`：每项 `{ type, label, sides, feature? }`，
`feature` 可以是数组（全部满足）。两侧表单都调 `hp.renderProtocolOptions(s, { features, side })`。
表的顺序刻意选成"按 side 过滤后能逐字复现两边原来的顺序"，因此 diff 只剩两处有意变更：

| 变更 | 证据 | 性质 |
|---|---|---|
| `snell` 在 node 表单里**重新可选** | 它此前已有完整表单块、`CREDENTIALS` 行、`OPTION_FIELDS` 行、`mapping` 行和 golden outbound，只是不在 type 列表里 ⇒ 块是死代码、能力不可见 | **修 bug**（用户可见的能力缺失） |
| node 表单不再提供 `chacha20` | 目标 sing-box 1.14.1 实测：`chacha20` 被拒（`unknown method`），而 `chacha20-ietf`、CFB/CTR 系列、`rc4-md5` 全部接受；旧列表让用户能选到一个**会让生成配置校验失败**的方法 | **修 bug** |

`server.json` 在这次改动后**逐字节未变**。`shadowtls` 保持客户端专属并在表里写明理由：
后端确实建模了入站侧（`INBOUND_CREDENTIALS` / `REQUIRED_INBOUND_CREDENTIALS` / `INBOUND_CLAIM_FIELDS`），
但**入站生成路径没有 fixture 与 golden 覆盖**，按 ABSOLUTE RULE 15 不得对外提供；
要开先把覆盖补上。

##### (c) 新增 `tests/frontend-protocol-inventory.js`（83 项断言）

快照只能证明"结构变了"，证明不了"表是对的"，所以另写一条直接读表的测试：

- 客户端侧每个 type ∈ 后端 `PROTOCOL_TO_UCI`；服务端侧每个 type ∈ `INBOUND_CREDENTIALS`
  （服务端专属的 `naive` / `mixed` 本来就没有出站映射，检查必须分侧，否则会误报）；
- 每个**出站可构建**的协议（`OPTION_FIELDS` ∪ `REQUIRED_CREDENTIALS`）都能在 node 表单里选到
  —— 这一条正是 `snell` 缺失时会红的方向；
- 两侧渲染顺序被钉住（快照看不到 node 的选择器，这是唯一防线）；
- 后端建模但 UI 不提供的协议必须列进 `DELIBERATE` 白名单并写明原因，**否则测试失败**
  （`shadowtls` / `wireguard` / `direct` 三条）。

**反向验证过**：把 `snell` 从表里删掉 → 4 项失败，并直接给出
`unoffered protocol 'snell' is a documented decision: models it in the backend but no form offers it`。
已接入 `tests/run.sh` 与 `arch-test.yml`（只需要 node）。

##### (d) mux 去重（2.11.3 那一类）

`renderMuxOptions()` 承接两侧共有的部分：`multiplex` 标志与依赖集、`multiplex_padding`、
TCP-Brutal 三件套。客户端的拨号旋钮（protocol / max_connections / min_streams / max_streams）
留在 node.js —— adapter 的入站 multiplex 本来就没有这些字段。

顺带修掉一处真实分歧：**服务端**把 TCP-Brutal 组门控在 `features.hp_has_tcp_brutal` 上，
**客户端**却无条件构建，于是在不支持 TCP-Brutal 的 sing-box 上 node 表单仍然显示该选项。
现在共用渲染器在两侧都门控。

快照证据：`server.json` **逐字节未变**；`node.json` 只差 mux 字段顺序（共享组现在在标志原位发出，
padding/Brutal 因此排在拨号旋钮之前），**选项集合与总数不变（117）**——这是"有意的顺序变更"的
可复核形态，而不是靠改期望值掩盖回归。

##### (e) 死代码

`decodeBase64Str` 在 frontend 全目录无任何调用点（后端 `homeproxy.uc` 自己解码，node 表单走 RPC
解析器），已删除 —— 一个无人读取、且与安全相关操作重复的实现留着只会误导。

##### (f) 仍然剩下的（PR-06 续）

1. **其余去重**：hysteria（node 191-232 ↔ server 297-338，42 行）、TUIC（369-396 ↔ 398-425，28 行）、
   password 校验体（108-117 ↔ 242-251，两侧 `required_type` 集合**不同**，需要按 side 参数化）、
   TLS 证书路径与上传按钮（582-589 ↔ 663-670）、client.js 内部 `routing_rule`↔`dns_rule`（交集 184 行）、
   GridSection 脚手架 ×5、动态 load 覆盖 ×13；
2. **跨文件状态三件套**：`getServiceStatus` / `renderStatus` / 状态栏+poll 守卫
   （`client.js` 与 `server.js`，只差实例名与 label）；
3. **`shared/rpc.js`**：12 处 `rpc.declare`，其中 9 处把失败吞成 `L.resolveDefault(…, {})`
   （`homeproxy.js:415/433`、`client.js:20`、`server.js:18/83`、`status.js:35/64/71/164`）；
4. **`snell` 版本**：~~分叉~~ 实测是**两侧能力不同** —— 出站接受 {4, 6}（版本 5 报
   `unsupported version: 5`），入站接受 {5, 6}（版本 4 被拒，v6 需要 ≥12 字节 psk）。
   已在两处就地写下理由，避免将来被"统一"掉。

**验收状态**：三份快照 PASS（且现在真的覆盖了 node 表单）；`frontend-protocol-inventory` 83/83；
i18n 724/724；`test_config_transaction` 24/24；`test_runtime_extraction` PASS。
**浏览器人工回归仍未做**，且无法由 agent 完成 —— 快照只能证明选项树是有意变更的。

### 2.12 PR-07 — Architecture Guard + CI（未开始；建议作为下一个 PR）

对应指导建议**第 28 项**，也是本文件头部"分歧处理原则"里被点名优先的那一条。

#### 2.12.1 为什么它排在最前

1. 指导建议 §九 的结论是"把已经存在的层次真正变成不可越界的架构边界"，观点 02/28 把边界收敛
   列为最大风险。
2. **成本最低**：§2.12.2 的实测证明七条边界**今天就是干净的**。PR-07 是纯增量——不改一行业务代码，
   只是把 PR-01～05 已经做到的用 CI 钉住。
3. **保护后面的改动**：PR-06 要动 4467 行前端，PR-05 续要动 `health.sh` 与 reload 路径。
   先有 Guard，这两次改动才不会把前面的成果推回去。

#### 2.12.2 现状证据：七条边界今天都是干净的（`7e561e0` + PR-05）

| 边界 | 作用域 | 实测 |
|---|---|---|
| generator 不得碰 UCI | `scripts/generator/**` | `uci.` / `cursor(` **零命中** |
| adapter 不得碰 UCI | `scripts/config/adapter.uc` | **零命中** |
| parser 不得碰 UCI | `scripts/parser/**` | 只有注释命中（`flatten.uc:201`、`protocols.uc:20`） |
| 订阅纯阶段不得写 UCI | `scripts/subscription/{decoder,fetcher,filter}.uc` | **零命中** |
| Domain Model 不得反向依赖 | `scripts/config/{model,loader}.uc` | `model.uc` 只 import `homeproxy`；`loader.uc` 只 import `uci` + `../parser/mapping.uc`；**都不 import `adapter.uc` 或 `generator/`** |
| Domain Model 不得出现 sing-box 顶层 section 名 | `scripts/config/{model,loader}.uc` | `inbounds` / `outbounds` / `experimental` / `rule_set` / `urltest` / `selector` 作为键 **零命中** |
| runtime / init.d 不得写 UCI | `root/etc/init.d/homeproxy` + `scripts/runtime/*.sh` | 写入（`uci set/commit/delete/add/rename`）**零命中**；`init.d:41` 的 `uci -q show` 是只读，需白名单 |
| **（增补）持久化只允许两处** | 全仓 | 真正的 UCI 写入只有 `subscription/repository.uc`（观点 16 的边界）与 `migrate_config.uc`（一次性迁移） |

#### 2.12.3 七条检查（命名对齐指导建议第 28 项）

指导建议给了六个名字，另加一条直接实现观点 16：

```
check-generator-boundary     scripts/generator/**                     禁止 uci.* / cursor(
check-adapter-boundary       scripts/config/adapter.uc                禁止 uci.* / cursor(
check-parser-boundary        scripts/parser/**                        禁止 uci.* / cursor(
check-subscription-boundary  scripts/subscription/{decoder,fetcher,filter}.uc  禁止 uci.* / cursor(
check-domain-boundary        scripts/config/{model,loader}.uc         禁止 import adapter/generator；
                                                                      禁止 sing-box 顶层 section 名当键
check-runtime-boundary       init.d/homeproxy + scripts/runtime/*.sh  禁止 UCI 写入（只读 show 白名单）
check-persistence-boundary   全仓                                      UCI 写入只允许 repository.uc /
                                                                      migrate_config.uc
```

#### 2.12.4 实现形态（含两个必须处理的坑）

- **位置**：新增 `tests/arch-guard.sh`（POSIX sh，**不需要 ucode/node**）。
- **接线**：`tests/ucode/run.sh`（→ `arch-test.yml:94` 会在每个 PR 跑到）**和** `tests/run.sh`
  （本地没装 ucode 也有覆盖）。只放后者等于 CI 不跑——这是本轮实测发现的接线事实。
- **坑 1：必须能处理注释。** 直接 grep 会有三处误报：`model.uc:11-17`、`flatten.uc:201`、
  `update_subscriptions.uc:199` 都在注释里提到被禁的 API。方案：用 awk 状态机剥掉 `/* … */`；
  **不剥 `//`**（ucode 里有 `/:\/\//` 这类正则字面量，盲剥会截断代码行），改为**断言 `//` 注释里
  不得出现被禁 token**——目前 `scripts/` 下只有一条 `//` 注释（`adapter.uc:138`），且不含被禁 token。
- **坑 2：Guard 自己必须能失败。** 参照 `test_ucode_grammar.sh` 的 accept/reject 探针设计，
  Guard 要带自检：为每条规则喂一个合成违规片段并断言被抓住（reject 探针），再喂一个干净片段断言通过。
  否则它就是 §3.1 里那种"永远不可能失败"的测试。
- **白名单要预留 `runtime/`**：PR-05 的四个新模块按"设备侧、允许 `config_get`"设计
  （§2.10.2）。Guard 必须允许 `runtime/**` 与 init.d 读 UCI（`config_get` / `uci show`），
  只禁写。若写成"runtime 完全不许碰 UCI"，PR-05 的成果会被自己的 Guard 判红。

#### 2.12.5 验收

- 七条检查在当前 HEAD 全绿（§2.12.2 已实测，Guard 落地后应复现同样的零命中）。
- 自检：每条规则的合成违规都能被抓住。
- **反向证明**：故意在一个受保护目录里加一行 `uci.set(...)`，CI 必须红。这一步要留证据。

#### 2.12.6 与 on-target CI 的关系

观点 27 的"完整测试不依赖开发者手工设备"仍**未闭环**：`tests/run.sh` 在没有本地
ucode/sing-box 时会 SSH 到 `$HP_TEST_HOST`（默认已改为测试机 `root@192.168.1.102`，见 §2.13.2），
而 `arch-test.yml` 在 CI 里是自建 toolchain 就地跑（**没有** on-target job）。
真要闭环需要一台常驻设备或 QEMU-in-CI。这一项与 PR-07 同期做最省事，因为它需要 CI job 改动。

### 2.13 本轮复核新发现的缺口（不在 PR-05 范围内，未修）

#### 2.13.1 `Node.tls.raw` 是**死字段**（观点 05 的尾巴）

`config/loader.uc:99-105` 的 `load_tls()` 仍然返回一个 `raw` 子对象，注释写着
"kept verbatim: the server-side builder owns the key material format"：

```js
raw: {
    tls_reality_public_key: get('tls_reality_public_key'),
    tls_reality_short_id: get('tls_reality_short_id'),
    tls_utls: get('tls_utls'),
    tls_sni: get('tls_sni'),
    tls_insecure: get('tls_insecure')
}
```

但**全仓没有任何地方读它**：`grep -rn '\.raw\.' root/` 零命中（唯一命中是 `model.uc:15` 的注释）。
服务端 TLS 尾巴现在走的是 `Inbound.tls_server`（`loader.uc:349` `tls_server: load_table(get, INBOUND_TLS_SERVER)`），
由 `adapter.uc:632-639` 的 `build_tls_server_extras(tls_server)` 消费。

**结论**：这是 PR-01 删 `Node.raw` 时漏掉的残留，而且是**死代码**，删掉零风险。
它同时让观点 05（"`raw` 只能作兼容层"）从 🟡 走向 ✅。

#### 2.13.2 `tests/run.sh` 的默认测试主机指向**生产主路由**（本轮已修）

`tests/run.sh:16` 原本是 `HOST="${HP_TEST_HOST:-root@192.168.1.1}"`，而 `192.168.1.1` 是家里的
ImmortalWrt **主路由**；SSH 回退分支会把整个 checkout `tar` 上传并 `rm -rf` 目标目录后再解包。
把测试物料铺到生产路由器上是不该有的默认值。**本轮改为 `root@192.168.1.102`（测试机）**，
并在注释里写清为什么。这是 §4 之外的一个"默认值即安全隐患"的例子。

#### 2.13.3 ~~i18n 这道 CI 门**永远不可能失败**~~ ✅ 已修复

`tests/i18n-coverage.py` 只在 `--fail-below` 时 `return 1`；`--warn-below` 只打印
`::warning` 并 **`return 0`**。而四处调用用的都是 `--warn-below`，所以覆盖率的下降**不会被任何
地方拦住**。这属于 §3.1 同一类问题（"不可能失败的检查"）。

**已修复**，按"该拦的拦、不该拦的写明理由"分开处理：

| 调用点 | 现在 | 理由 |
|---|---|---|
| `.github/workflows/i18n.yml` | `--fail-below 100` | 它就是那道门 |
| `.github/workflows/arch-test.yml` | `--fail-below 100` | 该步骤的注释本来就写着"即使 i18n.yml 还在排队，这里也会失败"，而它做不到 |
| `tests/run.sh` | `--fail-below 100` + `FAILED=1` | 本地套件对快照是硬失败，对 i18n 不该例外 |
| `.github/workflows/build.yml` | 仍 `--warn-below 100` | **有意**：发布打包不该被翻译缺口卡住，PR 门已经拦了；这一步留着是为了记录数字 |

机制已验证：`--fail-below 100` → 当前 100% 时 exit 0；`--fail-below 100.01` → exit 1
（证明它现在能失败）；`--warn-below 100.01` → exit 0（证明旧的形状不能）。

#### 2.13.4 指导建议第 27 项有两处已经过期

该文写"当前本地环境未安装二者（ucode / sing-box），因此 full suite 无法在本机完成"，
并写 `tests/run.sh` 会 SSH 到 `root@192.168.1.1`。今天：

1. 本机/CI 已有**按 pin 构建的 ucode testbed**（§2.3.2，`~/.local/ucode-strict` / CI 的
   `~/.local/ucode-testbed`），full suite 可以在本地跑完（65 PASS / 0 FAIL / 1 NOT RUN）。
2. 测试机是 **192.168.1.102**，不是 `192.168.1.1`。

**已就地更正那一份的这两处事实**（只改事实描述，不动它的任何优先级判断）；
更正处也回指本文的 §2.3.2，两份文档的编号因此可以互相追踪。

#### 2.13.5 ~~其它文档漂移（建议随 PR-06/PR-07 一起清）~~ ✅ 已清

`tests/ucode/test_protocol_inventory.sh` 的头注释已改为 `parser/uri.uc` / `parser/mapping.uc`
（并指向 `tests/frontend-protocol-inventory.js` 覆盖它看不到的方向）；§2.8 已标注为
"PR-06 开工前的分析、行号已过期"。原始清单如下，作为记录：

- `tests/ucode/test_protocol_inventory.sh:8-10` 的头注释仍写 `parse_uri.uc` 与
  "`loader.uc` PROTOCOL_OPTIONS"，而正文已经改成 `parser/mapping.uc`。
- §2.8 表格里的行号仍是 PR-01～04 之前的位置（`parse_uri.uc:445-483`、`loader.uc:168-256`），
  这些文件/行段已不存在；PR-06 落地时应一并更新（§2.11 已给出新行号）。

### 2.14 ~~⚠️ 真机实测发现的 P0：健康门会把"起不来"的配置判为健康，并写进 known-good~~ ✅ 已修复（commit `bb4e216`）

这是**试图验证回滚分支时**发现的，不是推测。它推翻了本文此前"失败链已经成立"的说法
（§0.1 / §2.6）在**运行时**这一段的成立性 —— 生成期的失败链是对的，运行期的**不是**。

#### 2.14.1 实验

在 192.168.1.102 上（PR-05 payload + 已验证可正常启动的基线）：

1. 用 `socat` 占住 5399 的 TCP/UDP（v4+v6）；
2. `uci set homeproxy.infra.mixed_port=5399; uci commit`；
3. `/etc/init.d/homeproxy reload`。

#### 2.14.2 结果（三条互相印证的证据）

```
reload rc=0
守护日志:  Reloading service... / Service stopped. / sing-box 1.14.0 started. / Reload completed.
```

**`Reload completed.`** —— 即健康门通过、`hp_known_good` 已刷新。但紧接着：

```
$ ubus call service list '{"name":"homeproxy"}'
  "sing-box-c": { "running": false, "exit_code": 1, ... }

$ 连续 8 次采样 pgrep -fc "run --config .../sing-box-c.json"
  t+1s..t+8s: 全部 0
```

**服务实际是死的。** 而 known-good 里现在装的是那份起不来的配置：

```
$ sing-box check --config /var/run/homeproxy/known-good/sing-box-c.json
  OK                          # check 只做 schema/静态校验，不绑定端口
$ sing-box run   --config /var/run/homeproxy/known-good/sing-box-c.json
  FATAL start service: start inbound/mixed[mixed-in]: listen tcp 0.0.0.0:5399: bind: address already in use
```

#### 2.14.3 机理

`runtime/health.sh::hp_instance_running` 的判据是 **"存在一个匹配 `run --config <path>` 的进程"**。
sing-box 是**先绑定 dns-in（5333）成功、再绑定 mixed-in（5399）失败**才退出的，所以从 procd 拉起
进程到 FATAL 退出之间存在一个窗口；更有决定性的是 **`procd_set_param respawn`（`service.sh` 里三个
实例都设了）会连续重试**，于是这个窗口在 10 次 × 1s 的轮询期间反复出现。`hp_wait_instance`
只要命中一次就返回 0。

> 说明：机制这一层是**推断**——实验直接观测到的是"门通过了，但配置确实起不来"，
> 而"门之所以通过必然是因为至少一次轮询看到了活进程"是 `hp_wait_instance` 逻辑的唯一可能路径；
> respawn 是让那个窗口持续存在的现成机制。

#### 2.14.4 后果（为什么这是 P0 而不是"待优化"）

1. **reload 的契约破了**：文档与 §2.6 都声称"证明起来了，否则回滚"。对最常见的运行时失败
   （端口冲突、证书读不到、接口不存在），实际行为是**reload 报成功、服务却是死的**——
   比直接报失败更糟，因为没有人会去看。
2. **known-good 被污染**：坏配置被写成了回滚目标。下一次 reload 若真的触发回滚，
   回滚过去的正是那份起不来的配置。**PHASE 6 的整条安全网在这里失效。**
3. 这也解释了为什么**回滚分支在真机上极难触发**：不是"没测"，而是这条路被健康门的误判
   在它之前就短路了（真正能触发回滚的，只剩"进程根本起不来"这种更窄的失败）。

#### 2.14.5 修法（已实施）

1. **门要证明"稳定存活"，不只是"曾经活着"**：进程必须在 N 秒（建议 5s）观察窗内**持续**存在，
   且**没有**非零 `exit_code` —— `ubus call service list` 已经直接给了 `exit_code` 字段，
   现有代码完全没用上。
2. **加 Listener Health**（§2.10.3 那一级）：确认 `mixed_port` / `dns_port`（tproxy 模式再加
   `tproxy_port`）真的在 listen。端口冲突这类问题在这一步就会现形。
3. **known-good 只能在 1+2 都通过之后刷新**："先记录、后验证"是这次事故的放大环节。
4. **补一条回归测试**：故障注入（占住端口）→ reload → 断言 `reload` **非零**、
   服务**仍在用旧配置运行**、known-good **未被覆盖**。这条测试要在真机上跑，
   或先把 `hp_instance_running` 抽成可 stub 的判据再离机跑。

#### 2.14.6 修法落地（commit `bb4e216`）—— 一个症状拆成五个缺陷

上面 2.14.5 的四条是**计划**。实际动手时，真机测量把一个症状拆成了五个**互相独立**的缺陷，
少修任何一个门都不成立。五个都只有真机能发现：

| # | 缺陷 | 真机证据 | 修法 |
|---|---|---|---|
| 1 | 判据只有"存在匹配进程"，而 `pgrep -f` 被**陈旧进程**满足 | 实测：一个 pid（5373）一直不死，同时 procd 每秒重启一个崩溃实例 → 门在整个观察窗都"看到活着" | procd 的视角（`ubus service list`）升为唯一权威；`pgrep` 降级为"ubus 不可用"时的兜底 |
| 2 | "端口在听" ≠ "**我们在听**" | 注入故障时 5399 **确实在听**——属主是占位者 socat | 用 `netstat -p` 的属主列要求该端口属于 sing-box |
| 3 | 门放错了位置：`USE_PROCD=1` 下 procd 是在 `start_service` **返回之后**（rc.common 的 `procd_close_service`）才拉起实例的 | 门在真机上永远超时 | 门移入 `service_started()` —— rc.common 的 post-start 钩子 |
| 4 | `start()` 的返回值是 `procd_close_service` 的，不是 `start_service` 的 | reload 把"门失败"读成成功，直接打 `Reload completed.` | 失败写 `$RUN_DIR/failed-side`，`reload_service` 读文件判断 |
| 5 | 15s 预算短于 procd 的 respawn 回退（实测每次重试等 5s，重试耗尽后更久） | 回滚重启已经起来了，门却刚宣告失败 | 默认预算 30s；回滚重启单独给 60s |

**第 6 个缺陷是最后一轮真机跑才暴露的**：门校验的是 **UCI 描述的端口**，而不是
**正在运行的配置声明的端口**。回滚之后 live 文件是**较旧的 known-good 副本**，
于是门一直在等一个那份配置根本不会绑定的端口（5399），把一个已经成功的回滚判成失败。
现在端口由 `hp_config_ports()` 从 live 文件里读。

**同时修掉 `known-good` 的写入时机**：`hp_start_generated_config` 不再写 known-good，
候选配置只有在门通过之后才由 `hp_promote_known_good` 记录。此前 `start_service` 在门运行**之前**
就覆盖了它，所以回滚发现"失败配置已经是 known-good"，直接放弃——这才是 P0 的核心。

#### 2.14.7 测试（新增，都是能失败的测试）

| 测试 | 覆盖 |
|---|---|
| `tests/runtime/test_config_transaction.sh` +11 项 | 陈旧进程不得覆盖 procd；稳定性窗口不能被"一次走运的轮询"满足（交替样本必须失败、坏样本后能恢复）；监听归属三态（属于 sing-box / 被别人占 / 无属主列）；组合样本 |
| `tests/runtime/test_runtime_extraction.sh` 场景 D | 端到端回归：健康配置起来并被记录 → 换成一个 mixed_port 被占的候选 → **门必须拒绝、known-good 必须存活、回滚必须把服务带回来** |
| 基线文件 | `trace.pre-pr05.txt`（579 行）与 `trace.golden.txt`（805 行）用**同一套 harness** 采集，两者的 `diff` 就是本次有意的行为变更 |

**harness 自己有三个 bug**，它们各自藏住了上面的缺陷，一并修掉：按场景的夹具在
source 默认值**之前**赋值而被静默重置（所有场景其实跑同一份配置）；procd 被建模成
"注册即启动"（**正好藏住缺陷 3**）；管道两端并发写 trace 导致顺序不确定。

#### 2.14.8 真机实测结论

```
1) 健康 start        -> 门在稳定窗口后通过，记录 known-good
2) 占住 5399 + mixed_port=5399 + reload
                     -> 候选被拒（30s 预算耗尽，"did not come up"）
                     -> 回滚："Starting with the last known-good client configuration."
                     -> 约 3s 后 "sing-box 1.14.0 started." + "Rollback completed; ..."
                     -> reload rc=0
3) 结局              -> running=true；live 与 known-good 都是 5330（旧的好配置）；
                        5330/5333 的监听属主是 sing-box；无 failed-side 标记
```

**生成期 ✅ 成立；运行期 ✅ 现在也成立。**

---

## 3. 测试诚信问题（文档 FINAL SELF REVIEW 明确要求）

### 3.1 ~~`test_demo_architecture.sh` 的等价性断言是恒真的~~ ✅ 已删除并替换

> **已实施**：删除 `tests/ucode/test_demo_architecture.sh`、`tests/fixtures/architecture/`
> 与 `generate_client.uc` 里的 `/* HP_TEST_HOOK */` 标记（它只服务于那个测试）。
> 替换为两项真正有效的测试：
> * `tests/ucode/test_golden_outbounds.sh` —— 14 个协议各一份 outbound，冻结在
>   `tests/snapshots/generator/outbounds.json`，并额外把所有 outbound 交给真实 `sing-box check`
>   （这一步立刻找出了 §1.6 的 4 个字段缺陷）。
> * `tests/ucode/test_protocol_inventory.sh` —— 122 项跨层一致性断言。
> 源码头部与 `tests/README.md` 中"demo/architecture 必须保持同步"的过时描述也一并清掉。

```
tests/ucode/test_demo_architecture.sh:62   import { OutboundFactory as DemoOutboundFactory } from '<repo>/config/adapter.uc'
tests/ucode/test_demo_architecture.sh:118  const reference = removeBlankAttrs(generate_outbound(node));
tests/ucode/test_demo_architecture.sh:119  const candidate = DemoOutboundFactory.create(node, mark);
                                                        ↑ 从生产树 import
generate_client.uc:280-299                 function generate_outbound(node) { ... return OutboundFactory.create(node, self_mark); }
                                                        ↑ 同一个模块的同一个函数
```

即 `f(x) == f(x)`。测试脚本自己的注释也承认了（`:112-117` "both sides are the same code path"）。
它永远不可能失败，因此也永远不可能"抓到 tuic zero_rtt / ws transport.host 这两个 bug"——
`docs/architecture-review.md` 的 Bottom line 里那句话现在已经不成立
（该文件已随之删除，见 §0.2 附录 I：它的结论已被本文与设备实测取代）。

同时 `demo/architecture/` 目录**根本不存在**（`find demo` → no such directory），但：
- 源码头注释仍在说"the copy in demo/architecture/ must stay in lockstep"
  （`model.uc:9-11`、`loader.uc:9-13`、`adapter.uc:9-10`）；
- `tests/README.md:105,113-119`、`tests/fixtures/architecture/README.md:14` 仍在引用它；
- `docs/architecture-review.md:40-42,143` 仍在描述它（文件已删除）。

另外 `test_demo_architecture.sh:158-159` 的两条 sed 是**空操作**：
`const uci = cursor();` 在 `generate_client.uc` 里已不存在，`__HP_TEST_DOMAIN_MODEL__` 也只在
测试文件自身出现。

**建议**：二选一——(a) 恢复 `demo/architecture/` 作为独立参考实现并用它做对照；
(b) **删掉这个测试**，改用 §2.9 的 golden JSON 快照，并清掉全部 `demo/` 引用。
以当前仓库状态，(b) 更诚实、成本更低。

### 3.2 其它"把 bug 锁成契约"的断言

- ~~`test_subscription_repository.uc:138-144` 断言"新增字段不写入"（见 §1.4）。~~
  **已改**：现在断言 `cfg.port == '443'`，与 §1.4 的修复同一个 commit。
- ~~`test_subscription_decoder.uc:44-53` 断言 `{servers:[...]}` / URI-array JSON 解码为 0 节点（"quirk"）——**仍未处理**。~~
  ✅ **已修**（commit `1c327f2`）：那个"quirk"是真 bug —— SIP008 探针直接读 `nodes[0].server`，
  当首元素是字符串时 ucode 抛 `left-hand side expression is not an array or object`，抛出被 JSON 的
  try/catch 吞掉后走 base64 回退、再失败，于是 `{"servers":["vless://…"]}` 与 `["vless://…"]`
  两种**合法订阅形状被整份丢弃**。现在先判 `type(...) === 'object'`，混合列表也逐项守卫。
  三条 "quirk" 断言按本节规矩改成断言正确行为，并补了混合列表用例；目标机实测 29 项 0 失败。

修 bug 时这些测试会红——请在同一 commit 里改成断言正确行为，而不是保留 quirk。

### 3.3 脆弱锚点

`test_generators.sh:46-49,63` 和 `test_demo_architecture.sh:158-167` 依赖 sed 精确匹配源码行
（`export const HP_DIR = '/etc/homeproxy';`、`'__LOADER_DIR__'`、`/* HP_TEST_HOOK */`）。
§2.4 的"generator 变成可 import 的库"能一次性消除这类脆弱性。

---

## 4. 安全

| 项 | 现状 | 建议 / 落地 |
|---|---|---|
| ~~RPC ACL~~ | ~~`acl.d/luci-app-homeproxy.json:13` 仍是 `"luci.homeproxy": ["*"]`，且挂在 `read` 下，覆盖 5 个**写**方法（`acllist_write`、`certificate_write`、`log_clean`、`resources_update`、`singbox_generator`），并自动授权未来新增方法~~ | ~~拆成显式 read 方法列表 + write 方法列表~~ ✅ 已落地（commit `d9a4dac`）—— `read`/`write` 各自枚举 5 个方法；文件路径按读/写分别列出。 |
| ~~路径字段无后端校验~~ | ~~`tls_cert_path`（`loader.uc:88`）、`tls_key_path`（`homeproxy.uc:392-393`）、ruleset `path`/`initial_path`（`client.js:1508,1558`，`datatype='file'`）只在浏览器里用 `validateCertificatePath`（`homeproxy.js:512-518`）检查，后端直接喂给以 root 运行的 sing-box~~ | ~~在 Loader/Adapter 侧加白名单（允许 `/etc/homeproxy/...`），UI 校验只当 UX~~ ✅ 已落地（commit `d9a4dac`）—— 新增 `homeproxyuc:validateHomeProxyPath()` 接受 `/etc/homeproxy/...` 与 `/tmp/homeproxy_*`，buildTLSObject 与 build_user_rulesets 调用它；非法路径 → null → sing-box 拒绝（known-good 路径生效）。 |
| ~~订阅响应大小~~ | ~~`wGETVerbose`（`homeproxy.uc:107`）无 `--max-filesize`/无上限，只靠 `--timeout=10`；整个 body 经 `executeCommand` 落盘再读（上限 512KB 截断，但下载已完成），随后整份 `decodeBase64Str` + `split(\n)`~~ | ~~加 `--max-filesize`，并在 decode 前做长度上限~~ ✅ 已落地（commit `d9a4dac`）—— `wGETVerbose` 加 `--max-filesize=5m`；5 MiB 覆盖 10000 节点订阅（3 KB/node + base64 膨胀），更大几乎肯定是攻击或配错。 |
| ~~订阅凭据泄漏~~ | ~~`update_subscriptions.uc:97-140` 把完整 URL（可能含 token）写入 `/var/run/homeproxy/homeproxy.log`~~ | ~~记录时脱敏（去掉 query/userinfo）~~ ✅ 已落地（commit `d9a4dac`）—— 新增 `homeproxyuc:redactUrl()`，把 userinfo 替成 `***`、query 替成 `?***`；update_subscriptions.uc 与 subscription/fetcher.uc 走它；原 URL 仍喂给 wGET（只脱敏日志）。 |
| ~~`innerHTML`~~ | ~~无"订阅节点名/URL 进 innerHTML"的路径（已确认 label 都走 `o.value()`）。唯一活 sink 是 `client.js:109` / `server.js:137` 的 `renderStatus(res, features.version)`，把后端解析的 `sing-box version` 字符串直接拼进 HTML~~ | ~~改用 `E()`/`textContent`；`status.js:246-258` 的 `rawhtml` 也建议复查~~ ✅ 已落地（commit `0bd1b65`）—— `renderStatus()` 在 client.js/server.js 都加 `^[\w.\-+]+$` allow-list regex，不匹配回退 `'unknown'`。 |
| ~~错误被静默吞掉~~ | ~~`acllist_write` 返回 `{result:false,error}`（`luci.homeproxy:55-60`）但 `client.js:1680-1682,1712-1714` 完全忽略；`acllist_read` 的 error 同样被忽略~~ | ~~按 `homeproxy.js:494-498` 的模式上报~~ ✅ 已落地（commit `0bd1b65`）—— `load` 取出 `res.error` 走 `ui.addNotification`；`write`/`remove` 取出 `ret.error` 走 `throw` 让表单 save-error 流接住。 |
| 前端 RPC 无统一封装 | 11 处 `rpc.declare`，`L.resolveDefault(p,{})` 吞掉所有失败 | 抽 `shared/rpc.js`（后续 PR） |
| ~~轮询泄漏~~ | ~~`poll.add` 在 section render 内注册（`client.js:106-111`、`server.js:134-139`），`map.reset()` 会累积；`document.getElementById('service_status')` 未判空~~ | ~~移到 view 级注册一次~~ ✅ 已落地（commit `0bd1b65`）—— client.js/server.js 各自加 `let *_status_poll_registered = false` 模块级守卫；poll.add 移到 view 级，`getElementById` 加 null check。 |
| ~~证书上传竞态~~ | ~~固定 `/tmp/homeproxy_certificate.tmp`（`homeproxy.js:491`）被 4 个上传按钮共享~~ | ~~用唯一临时名~~ ✅ 已落地（commit `0bd1b65`）—— 前端 `homeproxy.js:uploadCertificate` 按 `filename` 派生 `/tmp/homeproxy_cert_<filenameUci>.tmp`；后端 `luci.homeproxy:certificate_write` 也按 `filename` 读对应路径；ACL 写列表枚举 4 条路径（与 `d9a4dac` 配套）。 |

---

## 5. 建议的 PR / commit 序列

按"先能让项目跑起来，再谈架构"排序：

```
P0
1. ✅ fix(ucode): make the refactored modules parse on the target ucode   # §1.1 + §1.1b
2. ✅ test(toolchain): pin ucode, drop target-only SKIPs, add grammar canary,
      import-check config/*.uc                                            # §2.9
3. ✅ fix(generator): model WireGuard endpoint fields on Node + fixture    # §1.2
4. ✅ fix(sub): update newly-added fields on existing subscription nodes    # §1.4
5. ✅ refactor(luci): parse share links through the backend (drop the JS copy)# §1.3
6. ✅ fix(generator): prune unbuildable urltest candidates instead of die() # §1.5
7. ✅ fix(protocol): drop/repair fields sing-box 1.14 rejects               # §1.6
      vless udp_over_tcp, hysteria obfs, snell mode, ssh private_key,
      socks udp_over_tcp (was silently ignored)
8. ✅ test(arch): protocol inventory invariant + golden outbound snapshot
      + real sing-box check on every golden outbound                       # §2.9

P1（可靠性 — 文档 PHASE 6/7 的核心目标）
9. ✅ reliability: known-good copy + fallback + health gate + rollback       # §2.6
10. ✅ reliability: restore /etc/config/homeproxy on a failed subscription update # §2.6
11. ✅ refactor(sub): stop-before-fetch -> fetch-then-reload                 # §2.5
12. ✅ reliability: single sing-box check per generation                     # §2.4
13. ✅ test: runtime config-transaction + health probe tests                 # §2.9
14. ⬜ reliability: exercise the reload/rollback path in an on-target CI job
      (procd cannot be driven off-device)

P2（结构）
15. ✅ refactor(gen): split generate_client.uc into generator/*.uc            # §2.4  (`0c67d77`)
16. ✅ refactor(gen): generator becomes an importable library (drop sed hooks)# §2.4  (`0c67d77`)
17. ✅ refactor(parser): parser/ dir + single canonical field mapping         # §2.2   (`33994fa`，即下面的 29)
18. ✅ refactor(gen): server inbound through domain model + InboundFactory    # §2.3   (`f657063`，即下面的 31)
19. ✅ refactor(runtime): extract runtime/{service,dns,firewall,net}.sh       # §2.7   (`c2aeac5`，见 §2.10)
       init.d 517 → 253 行；新增 runtime/{service,dns,firewall,net}.sh；离机差分 trace
       等价测试（tests/runtime/test_runtime_extraction.sh + fixtures/runtime/trace.pre-pr05.txt）
       + 真机 192.168.1.102 procd 生命周期验证
20. ⬜ refactor(luci): shared/rpc.js + components/ + protocol registry        # §2.11  (PR-06)
20b. ⬜ arch: architecture-guard checks in CI                                 # §2.12  (PR-07，建议先做)
21. ✅ security: split ACL wildcard; backend path allowlist                   # §4     (`d9a4dac`)
22. ✅ security: frontend XSS / poll / RPC-error / cert-tmp hardening         # §4     (`0bd1b65`)
23. ✅ test: client.json form snapshot                                        # §2.9   (`db1d200`)
24. ✅ test: TLS/Transport unit tests                                         # §2.9   (`ac910b6`)
25. ✅ test: subscription fetcher unit tests (+ fix a missing import)         # §2.9   (`b23f9c3`)
26. ✅ test: migrate_config regressions                                       # §2.9   (`e17b75d`)
27. ✅ test: firewall_pre behaviour + client snapshot in the CI job           # §2.9   (`b0e4a33`)
28. ✅ refactor(domain): PR-01 Domain Model Completion                        # §2.1   (`ca01141`)
      load_sections() 归一化（drop UCI pseudo-fields / coerce `enabled` to bool），
      5 × `cfg.enabled !== '1'` + 14 × `cfg['.name']` 改写，删 Node.raw /
      Config.endpoints / 三个 ConfigQuery 死 helper
29. ✅ refactor(parser): PR-02 Parser Normalization                           # §2.2   (`33994fa`)
      scripts/parser/{uri,protocols,validator,normalize,mapping}.uc；Loader 的
      PROTOCOL_OPTIONS 改为从 parser/mapping.uc 导入；update_subscriptions.uc
      和 §1.3 RPC 都改走 parser/uri.uc；新增 test_parser_normalize.uc 锁映射表契约
30. ✅ refactor(subscription): PR-03 Subscription Transaction Boundary         # §2.5   (`e88f7c7`)
      parser/flatten.uc 补 canonical ↔ flat 闭环；Repository = { apply_nodes,
      apply_main_node_refs, scrub_stale_urltest_refs } 接收 canonical Node
      并把 6 处 uci.set/commit 收敛；update_subscriptions.uc 改用 Loader.load()
      读 subscription，自己零 UCI 写入；新增 test_parser_flatten.uc 锁 round-trip
      等式，test_subscription_repository.uc 加 12 项 main_node / scrub 断言

31. ✅ refactor(adapter): PR-04 Protocol Adapter Completion                    # §2.3   (`f657063`)
      Inbound 领域模型 + INBOUND_{CREDENTIALS,OPTIONS,COMMON,TLS_SERVER} 四张表；
      InboundFactory 与 OutboundFactory 同形；WireGuard endpoint 搬进 EndpointFactory；
      generator/server.uc 165 → 60 行；修 fixture 的 listen_port 缺陷 + 新增
      inbound golden 快照；并修掉 PR-01～03 的 12 处未被 CI 覆盖的缺陷（§2.3.1）
32. ✅ ci(toolchain): fix the Linux ucode build (lucihttp include/link paths)   # §2.9   (`0dae4e6`)
      "Build ucode toolchain" 一直在第一步失败，run.sh 从未在 CI 执行过
33. ✅ fix(target): make the package loadable on the pinned ucode (12 defects)  # §2.3.2 (`4cd98d6`)
34. ✅ fix(homeproxy): executeCommand() redirects to files, not fds             # §2.3.2 (`ad2796a`)
35. ✅ test(firewall): check the {%- glue bug without needing the fw4 module    # §2.3.2 (`601cd9d`)
36. ✅ ci(toolchain): set CMAKE_INSTALL_RPATH so the binaries find libucode     # §2.3.2 (`7822e6f`)
37. ✅ docs: record the pinned-ucode round and the honest NOT RUN               # §2.3.2 (`7e561e0`)
39. ✅ fix(runtime): make the reload health gate prove stability, not existence  # §2.14  (`bb4e216`)
      一个症状拆成 6 个缺陷：pgrep 陈旧进程、监听归属、门放在 start_service 之内（procd 尚未启动）、
      rc.common 不传 start_service 状态、respawn 回退长于预算、门校验 UCI 端口而非运行中配置；
      并把 known-good 的写入推迟到门通过之后
      真机实测 P0：reload 报成功而服务是死的，坏配置写进 known-good。
      改成「持续存活 N 秒 + exit_code 为 0 + required listeners 在 listen」后再刷新 known-good，
      并补故障注入（占端口）回归测试。**建议先于 PR-07 / PR-06。**
38. ✅ refactor(runtime): PR-05 — extract dnsmasq/fw4/net/service out of init.d # §2.10
      init.d 517 → 253 行；新增 runtime/{service,dns,firewall,net}.sh；
      新增 tests/runtime/test_runtime_extraction.sh（差分 trace 等价，360 行，3 场景）
      + tests/fixtures/runtime/trace.pre-pr05.txt；tests/run.sh 默认测试机改为 192.168.1.102；
      真机 192.168.1.102 验证 start/reload/stop

**最高优先项已完成**：§2.14 的 P0 已修并真机验证（commit `bb4e216`）。下面按正常顺序走。

40. ✅ refactor(luci): one ordered protocol table for both forms              # §2.11.8 (`767a46d`)
      homeproxy.js 的 protocols 单表 + renderProtocolOptions；snell 重新可选（修 UI 能力缺失）；
      chacha20 移除（sing-box 1.14 实测拒绝）；新增 tests/frontend-protocol-inventory.js（83 项，已反向验证）
41. ✅ test(luci): make the form snapshots cover the nested sections            # §2.11.8 (`c3603f6`)
      Option.toJSON() 跳过 subsection，node 表单整个表单体与 client.js 规则段落从不进快照；
      node 13→117、client 29→206 个选项，diff 纯增量
42. ✅ refactor(luci): share the multiplex block between both forms             # §2.11.8 (`6aa0408`)
      renderMuxOptions；顺带把 TCP-Brutal 门控分歧修掉（node 原来无条件）；server.json 逐字节未变
43. ✅ refactor(luci): drop the unused base64 helper; record why snell differs  # §2.11.8 (`5aa378e`)
      删 decodeBase64Str；记录 snell 版本实测结论（出站 {4,6}、入站 {5,6}，不是分叉）

44. ✅ refactor(luci): one RPC boundary that reports failures                   # §2.11.8 (`de436df`)
      homeproxy.js 的 rpcCall()：12 处 declare → 1 处；9 处 L.resolveDefault(call(), {}) 全部改掉
      （它不捕获 rejection，rpcd 不可达时 then 永不执行且无人告知）；新增
      tests/frontend-rpc-inventory.js（21 项，反向验证，匹配前剥块注释）

45. ✅ refactor(luci): share the TUIC block between both forms                   # §2.11.8 (`fddd2dc`)
      共同部分（拥塞控制 / 0-RTT / heartbeat）+ uuid widget 由调用方传入；
      顺带统一拥塞控制标签（服务端原来显示原始值），server.json 只此一处变化
46. ✅ refactor(luci): share the Hysteria block between both forms                # §2.11.8 (`b9146b0`)
      两个渲染器（带宽对、auth/obfs 簇）分别在不同位置调用，以复现两侧原有顺序；
      三份快照逐字节未变——纯抽离
48. ✅ refactor(luci): one builder for the routing and DNS rule sections         # §2.11.8 (`0cd789d`)
      client.js 1792 → 1671 行（净减 121）；184 行逐字节重复只留一份；client 快照逐字节未变
49. ✅ fix(subscription): stop discarding JSON subscriptions of share links        # §3.2 (`1c327f2`)
      SIP008 探针读字符串属性抛错并被吞 → 两种合法订阅形状整份丢失；三条 "quirk" 断言改为正确行为
50. ✅ fix(runtime): edit the crontab without `sed -i`                            # §2.10.8 (`9f4e613`)
      裸 `sed -i` 是 busybox/GNU 扩展，BSD sed 上直接失败且只留一条 warning（陈旧 cron 项被留下）
51. ✅ test(runtime): make the extraction trace test host-independent             # §2.10.4 (`cbf98df`)
      busybox 无 `diff` → 改用 `cmp` 决策；绝对 `/etc/init.d/*` 与 `/etc/crontabs/root` 进沙箱；
      golden 重采（830 行）；macOS 与目标机一致
47. ✅ refactor(luci): share the password validator; fix the client's 2022 check  # §2.11.8 (`17428c7`)
      顺带补上 node 表单缺失的 2022-blake3 密钥长度校验（服务端本来就有），
      并抽出 tests/lib/luci-module.js；新增 tests/frontend-validators.js（29 项，反向验证）

**PHASE 8 续（PR-06 剩余）**：client.js 内部 `routing_rule`↔`dns_rule` 去重（≈184 行，
最大一块）+ GridSection 脚手架 ×5 与动态 load ×13 + TLS 证书块 + 状态三件套。
清单见 §2.11.8(f)。

**下一步（PR-07 → PR-06 续 → PR-05 剩余半场）**：
先做 **PR-07 Architecture Guard**（§2.12）——边界今天已经是干净的（§2.12.2 实测），
加 Guard 是纯增量且最便宜，还能保护后续改动；再做 **PR-06 LuCI 模块化**（§2.11，必须配人工回归）；
最后补 **PR-05 的可靠性半场**（§2.10.3 健康分级 + §2.10.5 显式状态机）。
`runtime/*.sh` 的 `local` 缺失、pgrep 模式耦合、known-good 在 tmpfs 这三个问题（§2.10.8）
可以搭在其中任何一个 PR 上，也可以单独一个小 PR。
```

---

## 6. 不建议做的事

1. **不要为了对齐目录树而拆文件**。文档自己也说"不要为了拆文件而拆文件"。
   `generate_client.uc` 该拆是因为它 1191 行且有清晰段落（§2.4）；
   而 `adapter.uc` 的数据表设计比"11 个 Adapter 类"更好，不要退回去。
2. **不要在 candidate/rollback 落地前继续做 generator 拆分**。先让失败路径安全，再动结构，
   否则每次拆分都在"服务可能起不来"的前提下做。
3. **不要保留两份 parser**（§1.3 已消除）。前端副本每加一个协议就多一份同步成本，而且已经漂移了。
4. **不要用"改 expected output"来让 §3.2 的 quirk 测试通过**——那是文档 ABSOLUTE RULES 第 10 条。
5. **不要在 CI 里把 SKIP 当成 PASS**（§2.9 已取消全部 target-only SKIP）。

---

## 附：本次实测记录

| 检查 | 结果 |
|---|---|
| `python3 tests/i18n-coverage.py --warn-below 100` | **PASS** 724/724，10 条 ignore |
| `node tests/luci-form-snapshot.js . node` / `client` / `server` | **PASS**（与 `tests/snapshots/*.json` 一致；删除 388 行前端 parser 后仍一致；`client` 快照于本阶段补齐） |
| `sh tests/ucode/run.sh`（本机） | **NOT RUN** — 无 ucode；已加守卫，现在明确输出 NOT RUN 并以退出码 2 结束 |

**修复前**（HEAD `599a10b`）：

| 检查 | 结果 |
|---|---|
| 目标设备 ucode module import：`config/loader.uc`、`subscription/{filter,decoder,fetcher,repository}.uc` | **FAIL** — `Expecting ';'` |
| 目标设备 ucode module import：`config/model.uc`、`config/adapter.uc`、`homeproxy.uc`、`parse_uri.uc` | **PASS** |
| 目标设备：`generate_client.uc` / `generate_server.uc` / `update_subscriptions.uc` 能否运行 | **FAIL**（loader.uc 无法编译 / 解构语法） |
| WireGuard 生成路径 | 静态确定的缺陷（`generate_endpoint` 读不到字段） |

**本轮全部修复后**（目标设备实跑 `sh tests/ucode/run.sh`，`SUITE_RC=0`，`grep -c '^FAIL'` = 0）：

| 检查 | 结果 |
|---|---|
| `== ucode grammar canary ==` | **PASS** — 7 个 accept + 3 个 reject 全部符合目标方言 |
| `== ucode syntax check ==`（含 `luci.homeproxy` 的绝对 import 改写；无 SKIP） | **PASS** — all ucode sources compile |
| fw4 chain/set inventory + firewall_post.ut 渲染（off-target 也可跑） | **PASS** |
| parse_uri unit / subscription filter / decoder / repository | **PASS** — 153 / 18 / 12 / 14 checks, 0 failures |
| homeproxy helper + executeCommand 失败路径 | **PASS** — 18 checks, 0 failures |
| generator regression（client / custom / server / **wireguard**） | **PASS** — 6776 / 1886 / 3798 / 3773 bytes + `sing-box check` |
| WireGuard 反证（把 `generate_endpoint` 改回读空表） | **FAIL**（符合预期：fixture 守护有效） |
| architecture demo equivalence | **PASS** — 11/11 nodes（注：该断言恒真，见 §3.1，不计入有效覆盖） |
| domain model skeleton | **PASS** — 63 checks, 0 failures |
| 后端 `parse_uri` 供前端调用（`node_parse` 的实际路径） | **PASS** — vmess `global_padding="1"`、anytls 默认 `port="80"`、无 `with_quic` 时 hy2 → `null`、垃圾输入 → `null` |
| 浏览器端"导入分享链接"交互 | **NOT RUN** — 无浏览器/LuCI 环境；仅做了 RPC 后端行为验证 + 表单快照 |

目标设备环境：ImmortalWrt x86_64，`ucode-2026.01.16~85922056-r1`，
`libucode20230711-2026.01.16~85922056-r1`，`ucode-mod-uci/-fs/-ubus/-uloop/-digest` 同版本，
`sing-box 1.14.0`。

---

## 附二：P0-5 / PHASE 6-7 / 测试替换 的验证记录

目标设备实跑 `sh tests/ucode/run.sh`：**`SUITE_RC=0`，`grep -c '^FAIL'` = 0**。

| 检查 | 结果 |
|---|---|
| `== ucode grammar canary ==` | **PASS** |
| `== ucode syntax check ==` | **PASS** — all ucode sources compile |
| `== shell syntax check ==`（`init.d/homeproxy` + `runtime/*.sh`，新增） | **PASS** |
| `== runtime configuration transaction ==`（新增） | **PASS** — 16 checks, 0 failures |
| fw4 chain/set inventory + firewall_post.ut 渲染 | **PASS** |
| parse_uri / subscription filter / decoder / repository | **PASS** — 153 / 18 / 12 / 14 checks |
| homeproxy helper + executeCommand 失败路径 | **PASS** — 18 checks |
| generator regression（client / custom / server / wireguard / **partial_invalid**） | **PASS** — 5 个 fixture + `sing-box check` |
| `== golden protocol snapshot ==`（新增） | **PASS** — 14 protocol outbounds match；**sing-box check accepted every golden outbound** |
| `== protocol inventory ==`（新增） | **PASS** — 122 checks, 0 failures |
| domain model skeleton | **PASS** — 63 checks, 0 failures |
| 本机 `python3 tests/i18n-coverage.py` | **PASS** 724/724 |
| 本机 `node tests/luci-form-snapshot.js` node/server | **PASS**（node.json 未变；server.json 因移除 snell_mode 少 29 行） |

**真实 rpcd 验证 `node_parse`**（把改造后的 `luci.homeproxy` 临时装入 `/usr/share/rpcd/ucode/`、
重启 rpcd、用 `ubus call` 调用、然后恢复原文件并 `cmp` 校验一致）：

| 输入 | 结果 |
|---|---|
| `trojan://pw@a.example.com:443#t` | **PASS** — 返回完整 config（type/address/port/password/tls） |
| vmess 分享链接 | **PASS** — 含 `"vmess_global_padding": "1"`（旧前端副本缺的正是这个字段） |
| `nonsense` | **PASS** — `{config: null, error: "unsupported or invalid share link"}` |
| 5000 字符超长输入 | **PASS** — `{config: null, error: "illegal share link"}`（长度上限生效） |
| 恢复原文件 | **PASS** — `cmp` 一致，rpcd 已重启 |

**仍然 NOT RUN 的**：
- 浏览器里"导入分享链接"的点击流程本身（无浏览器/LuCI 环境）。经 rpcd 验证后，剩余未覆盖的只有
  `node.js` 的 DOM/Promise 接线，以及 `rpc.declare` 在真实 LuCI 会话下的行为。
- `init.d/homeproxy` 的 procd 生命周期（start/stop/reload 的真机行为）。事务**语义**由
  `tests/runtime/test_config_transaction.sh` 覆盖，shell 语法由 run.sh 覆盖，但 procd 本身
  只能在设备上跑——建议后续加一个 on-target CI job。
- `sing-box check` 的 runtime 行为（只验证了 schema/初始化，未真正启动进程）。
