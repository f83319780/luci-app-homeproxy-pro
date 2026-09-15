# 架构重构改进建议（对照 `homeproxy_architecture_refactor_agent_guide.md`）

> **配套文档**：`docs/重构实施间断性指导建议.md`（28 项核心观点 + 7 个 PR 路线）是本文的
> **后续阶段指引**。本文记录的是"怎么把项目修到能跑、可维护"的实施账本；
> 那一份记录的是"接下来按什么边界推进"的判断基准。两份结论一致（当前架构成熟度 80–85%）。
>
> 分歧处理原则：**具体改动细节以本文为准**（本文有逐项现状证据与 commit 记录）；
> **优先级与边界规则以那一份为准**（尤其第 28 项 Architecture Guard）。

评审对象：`szwjp/luci-app-homeproxy-pro`，分支 `main`，HEAD `ad43ee2`。
评审方式：全量阅读 + 目标设备实测（ImmortalWrt，`ucode-2026.01.16~85922056-r1`）。
状态标记：**PASS / FAIL / NOT RUN**。

---

## 0. 结论摘要

### 0.1 完成度

按文档的 9 个 PHASE 取平均，目前约 **90%**（PHASE 6 已接近完成，PHASE 9 到 95%，
PHASE 4 已落地 —— `generator/*.uc` 七模块拆分 + 10 行 CLI 壳 + sed 注入清除，详见 §2.4；
§4 安全 8/9 项已落地 —— ACL 拆分、路径白名单、订阅响应上限、URL 脱敏、renderStatus XSS
防御、acllist 错误上报、poll 泄漏修复、证书上传竞态修复，详见 §4 表格；
PHASE 9 本轮补齐 5/6 —— `client.json` 快照、TLS/Transport 直测、`subscription/fetcher` 单测、
`migrate_config` 36 项、`firewall_pre` 8 场景 + CI 快照循环补 `client`，仅剩 on-target CI job，
详见 §2.9；
**PHASE 1 Domain Model 收尾已落地** —— `load_sections()` 走 `normalize_section()`，
5 个 `cfg.enabled !== '1'` 站点全改 `!cfg.enabled`，14 个 `cfg['.name']` 站点全改 `cfg.name`，
`Node.raw` / `Config.endpoints` / 3 个 `ConfigQuery` 死 helper 删掉，详见 §2.1；
**PHASE 2 Parser 目录化 + 归一化 + 校验分离已落地** —— `scripts/parser/{uri,protocols,
validator,normalize,mapping}.uc` 建好，Loader 的 `PROTOCOL_OPTIONS` 现在从 `parser/mapping.uc`
导入，Repository 切到 canonical Node 写在 PR-03，详见 §2.2）。
剩余部分见 §0.3。

| PHASE | 内容 | 状态 | 说明 |
|---|---|---|---|
| 0 | Baseline | ✅ 完成 | 文档化充分 |
| 1 | Domain Model | ✅ ~95% | PR-01 已落地（commit `ca01141`）：`load_sections()` 走 `normalize_section()`，所有 list-section 形状统一（`.name`/`.index`/`.type` 已 drop、`name` 暴露、`enabled` 强制 boolean）；`Node.raw` / `Config.endpoints` / `ConfigQuery.{node_ids,main_node_id,endpoints}` 全删；剩余 = server inbound 领域化（PR-04） |
| 2 | Parser | ✅ ~90% | PR-02 已落地（commit 33994fa）：`scripts/parser/{uri,protocols,validator,normalize,mapping}.uc` 建好；`loader.uc` 的 `PROTOCOL_OPTIONS` 现在从 `parser/mapping.uc` 导入；剩余 = Repository 切到 canonical Node 写（PR-03）+ validator 扩展（missing_credential / invalid_tls，后续 PR） |
| 3 | Protocol Adapter | 🟡 ~85% | 客户端 outbound 已数据表化；WireGuard / ssh / 4 个 1.14 字段缺陷已修；**server inbound 仍未领域化**，`generate_endpoint` 仍是独立函数，`direct_overrides` 已随 PHASE 4 改成显式参数 |
| 4 | Generator 拆分 | ✅ ~95% | `generator/` 子树七模块（`common/dns/inbound/outbound/route/ruleset/client`）+ `server.uc`，10 行 CLI 壳直接 `Loader.load(HP_DIR+'/config')`，`__LOADER_DIR__` / `HP_TEST_HOOK` / `__HP_TEST_DOMAIN_MODEL__` 全部从源码清除；golden 字节级一致（client 6773 / custom 1860 / wireguard 3755 / partial_invalid 3494）；`direct_overrides` 改成编排器持有的显式参数 |
| 5 | Subscription Pipeline | 🟡 ~75% | fetcher/decoder/filter/repository 已拆，已事务化 + 先抓取后 reload；缺 normalizer/validator，urltest 校准仍在 repository 之外提交 |
| 6 | Candidate Config | 🟢 ~85% | known-good / 生成失败回退 / 健康门 / 回滚已落地并有 16 项测试；缺 on-target procd 验证 |
| 7 | Runtime | 🟡 ~40% | `runtime/{config,health}.sh` 已抽、重复 `sing-box check` 已去；`dns`/`firewall`/`service` 仍在 init.d（517 行） |
| 8 | LuCI | 🟡 ~45% | TLS/Transport 已抽到 `homeproxy.js`；双 parser 已消除；协议表前后端仍 6 份不同步，`node.js`↔`server.js` 仍有 ~229 行重复 |
| 9 | Test / CI | 🟢 ~95% | pin ucode + 语法金丝雀 + 取消全部 SKIP + golden 快照（含真实 `sing-box check`）+ 协议清单不变量 + 运行时事务测试 + shell 语法检查；本轮补齐 `client.json` 快照、TLS/Transport 直测、`subscription/fetcher` 单测、`migrate_config` 36 项、`firewall_pre` 8 场景、CI 快照循环含 `client`；仅剩 on-target CI job（需常驻测试设备或 QEMU-in-CI） |

**关键判断（已更新）**：文档"最终成功标准"里那条链
`Subscription Failure → Candidate Rejected → Old Config Preserved → Old Runtime Preserved`
**已经成立**（§2.6 已实施）。**PHASE 4 Generator 拆分、§4 安全 8/9、PHASE 9 收尾 5/6、
PHASE 1 Domain Model 收尾（PR-01）、PHASE 2 Parser 目录化 + 归一化 + 校验分离（PR-02）
也已落地**（commits `ca01141` + 33994fa），所以剩下的不再是"能不能跑"，也不是"覆盖够不够"，
而是纯粹的结构性债务：
**可维护性**（PHASE 8 LuCI 模块化）与**领域化收尾**（PHASE 3 server inbound / PHASE 5
Repository canonical Node 写）。

### 0.3 剩余大项与工时估算

按 agent 连续跟进（含在目标设备上验证）计。**估算口径**：一个 agent 的净工作时长，含改代码、
跑套件、在设备上复现/验证、更新 golden 快照与文档；不含人工 code review 的等待时间。

| # | 大项 | 规模 | 风险 | 估算（agent 工时） |
|---|---|---|---|---|
| ~~A~~ | ~~PHASE 4 Generator 拆分（`generator/*.uc` + 去掉 sed 注入）~~ | ~~大~~ | ~~中（回归面大，但有 golden 快照兜底）~~ | ~~6 – 10~~ ✅ 已落地（commit `0c67d77`） |
| B | PHASE 8 LuCI 模块化（协议 registry 单一真源 + `components/`+`shared/` + 去重） | 大 | 高（浏览器流程无法自动化验证） | 9 – 15 |
| ~~C~~ | ~~§4 安全（ACL 拆分、路径后端白名单、订阅响应上限、日志脱敏、innerHTML/poll/临时文件竞态）~~ | ~~中~~ | ~~中（路径白名单可能影响既有配置）~~ | ~~5 – 9~~ ✅ 已落地 8/9 项（commit `d9a4dac` + `0bd1b65`）；剩"前端 RPC 无统一封装"留作后续 PR |
| ~~D~~ | ~~PHASE 1 Domain Model 收尾（dns/routing/server 领域化 + 删 raw/死代码）~~ | ~~中~~ | ~~中~~ | ~~4 – 7~~ ✅ 已落地（commit `ca01141`，PR-01 §A + §B）；server inbound 领域化留在 H（PR-04） |
| ~~E~~ | ~~PHASE 2 Parser 目录化 + normalize/validator + 唯一字段映射~~ | ~~中~~ | ~~中~~ | ~~4 – 7~~ ✅ 已落地（commit 33994fa，PR-02）；Repository 切换到 canonical Node 写留在 H（PR-03）；validator 扩展（missing_credential / invalid_tls）留作后续 PR |
| F | PHASE 7 Runtime 抽离（`service`/`dns`/`firewall`） | 中 | 高（只能真机验证 procd） | 4 – 8 |
| ~~G~~ | ~~PHASE 9 收尾（`client.json` 快照、TLS/Transport 单测、on-target CI、剩余 quirk 测试、无测试文件补齐）~~ | ~~中~~ | ~~低–中（on-target 部分需要设备/硬件）~~ | ~~5 – 9~~ ✅ 已落地 5/6（commit `db1d200` `ac910b6` `b23f9c3` `e17b75d` `b0e4a33`）；仅剩 on-target CI job（需常驻测试设备或 QEMU-in-CI） |
| H | PHASE 3 / PHASE 5 收尾（server inbound 领域化、`direct_overrides` 数据化、normalizer/validator、持久化收敛） | 中 | 低–中 | 5 – 8 |
| I | 文档与注释债务（~~`architecture-review.md` 部分结论已失效~~ 该文件已随本次改动删除、README、头注释） | 小 | 低 | 1 – 2 |
| | **合计（A / C / D / E / G 已完成）** | | | **18 – 33** |

**最小可用集合**（只求"稳、能跑、可维护"）：
~~**A + C + G ≈ 16 – 28 工时**~~ ✅ **A / C / G 已完成**（`0c67d77`、`d9a4dac`+`0bd1b65`、
`db1d200`+`ac910b6`+`b23f9c3`+`e17b75d`+`b0e4a33`），**D 也已完成**（`ca01141`），
**E 也已完成**（33994fa）。原定的三步顺序已走完：A → C → G → D → E。
**下一批从 H 开始**（PHASE 3 server inbound 领域化 + PHASE 5 Repository canonical Node 写），
再 F（等有 on-target CI 再做），最后 B（LuCI 模块化，必须配人工回归）。

**无法由 agent 单独闭环的部分**（必须有人/设备参与，估时不含在上表内）：
- 浏览器里点一次"导入分享链接"（RPC 后端已在设备上验证通过，剩余只有 DOM/Promise 接线）。
- 真机 flash 一次、跑一遍 `reload`/回滚（procd 行为）。
- LuCI 各表单的人工目视确认（快照只能证明结构没变，不能证明可用）。
- 若要让 CI 覆盖 on-target 用例，需要一台常驻测试设备或 QEMU-in-CI 环境。

### 0.2 P0 清单（6 项，全部已修复）

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
* `parser/validator.uc`（~75 行）：`validate(config, log)` + `check(config)`，把 §0.2 末尾的
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

### 2.3 PHASE 3 — Adapter 收尾

现状：`adapter.uc` 用 `COMMON_FIELDS` + `CLAIM_FIELDS` + `OPTION_FIELDS` + `REQUIRED_CREDENTIALS`
四张表替代了 110 行三元表达式，这是本次重构最成功的部分，值得保留。

遗留：
1. **WireGuard endpoint 未 Adapter 化**（§1.2）。
2. ~~`direct_overrides` 仍是模块级全局副作用（`generate_client.uc:202,292-296`，route builder 在
   `:912,924,1014` 读它）。文档建议的 `Node.raw.direct_overrides` / 数据化没有落地。
   建议改成 `generate_outbound()` 返回 `{outbound, override}`，或在 route 层直接查
   `node.protocol_options.override_address`（数据已经在 Node 里了，`loader.uc:254-257`）。~~ ✅
   已在 PHASE 4 中落地（commit `0c67d77`）—— `generate_outbound(node, mark, direct_overrides)`
   把 override 写进 caller 持有的 map，route builder 从同一个 map 读出 route-options action，
   不再有模块级状态。
3. `CLAIM_FIELDS` 与 `OPTION_FIELDS.hysteria/hysteria2` 里 `auth`/`auth_str` 重复出现
   （`adapter.uc:150-154` 与 `:227-237`），`CLAIM_FIELDS` 的那两份是死代码（会被 OPTION_FIELDS 覆盖）。
4. `generate_server.uc` **完全没有走 Domain Model / Adapter**：它从 `dm.server.inbounds` 拿到的是
   扁平 UCI dict，然后逐字段 `cfg.snell_version` / `cfg.shadowsocks_encrypt_method`（`:61-158`）。
   server 端等于没重构。建议增加 `EndpointFactory`/`InboundFactory` 与 `Node` 对称的 server 模型。

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

### 2.5 PHASE 5 — Subscription Pipeline 收尾

已完成：`fetcher/decoder/filter/repository` 四个模块 + 单测，是本次做得最扎实的一块。

遗留：
1. 规则要求"只有 Repository 负责持久化"，但 `update_subscriptions.uc` 自己还有 6 处
   `uci.set` + `uci.commit`（`:178,186,205,212,221,236`）用于清理 urltest 失效成员。
   建议把这些搬进 `repository.uc`（例如 `reconcile_main_node()`），并合并成**一次 commit**。
2. 缺少 `normalizer.uc`（decoder 里对 SIP008 打 tag 的逻辑可以独立）与 `validator.uc`
   （目前"合法性"只由 `parse_uri` 末尾顺带完成）。
3. `update_subscriptions.uc:29` 自己持有 `uci.cursor()` 并重复读取
   `subscription.*` / `config.*`（`:38-51`）。既然 `config/loader.uc` 已经是唯一 UCI 读取层，
   这里应该复用 `Loader`（否则"Loader 拥有唯一 cursor"的注释是假的，见 §4）。
4. **`stop → fetch → commit → start` 反模式**（§6）。

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

### 2.7 PHASE 7 — Runtime 抽离🟡 部分实施

> **已实施**：抽出 `scripts/runtime/config.sh`（配置事务）与 `scripts/runtime/health.sh`（健康探测），
> `init.d/homeproxy` 只保留 procd 外壳 + dnsmasq/fw4/ip rule 编排，并去掉了重复的 `sing-box check`。
> **未实施**：`runtime/{service,dns,firewall}.uc` 的进一步抽离（把 dnsmasq 片段生成、tproxy/tun 规则
> 也搬出 init.d）。原因：这部分与 procd 生命周期耦合最紧，且离机无法验证——按"不要为了拆文件而拆文件"
> 的原则留待有 on-target CI 时再做。

`init.d/homeproxy` 417 行里混了 5 类职责：服务生命周期、版本闸门、dnsmasq 片段生成、
ip rule/route（tproxy/tun）、ujail/procd 参数、fw4 调用。建议按文档抽到
`scripts/runtime/{service,firewall,dns,health,rollback}.uc`，init.d 只留 procd 壳。

注意约束（文档也强调了）：
- 不能破坏 procd / respawn / start/stop/reload；
- `service_triggers` 的 `procd_add_reload_trigger` 与 `procd_add_interface_trigger`（`:414-417`）要保持；
- `stop_service` 现在会 flush/delete 13 个 chain + 11 个 set（`:344-352`），拆分时必须保持
  "逐个删除、不批量"的语义（`fw4_names.sh` 注释已解释原因）。

### 2.8 PHASE 8 — LuCI 模块化

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
（该文件已随之删除，见 §0.3 附录 I：它的结论已被本文与设备实测取代）。

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
- `test_subscription_decoder.uc:44-53` 断言 `{servers:[...]}` / URI-array JSON 解码为 0 节点（"quirk"）——**仍未处理**。

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
17. ⬜ refactor(parser): parser/ dir + single canonical field mapping         # §2.2
18. ⬜ refactor(gen): server inbound through domain model + InboundFactory    # §2.3
19. ⬜ refactor(runtime): extract runtime/{service,dns,firewall}.uc           # §2.7
20. ⬜ refactor(luci): shared/rpc.js + components/ + protocol registry        # §2.8
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

**下一步（PR-03 / PR-04 / F / B）**：17 → 18 → 19 → 20，按指导文档 §七的 PR 路线，
先做 PR-03 Subscription Transaction Boundary（Repository 改写 canonical Node，
按 parser/mapping.uc 做 flatten；urltest 校准的 6 处 `uci.set/commit` 全部移到
repository.uc；normalizer / validator 接入 pipeline），再做 PR-04 Server Inbound 走
Domain Model（修 PR-01 §B 留给 §2.3 的 server inbound 领域化），再 F（等有 on-target CI
再做），最后 B（LuCI 模块化，必须配人工回归）。
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
