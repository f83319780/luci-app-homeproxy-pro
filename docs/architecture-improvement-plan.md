# 架构重构改进建议（对照 `homeproxy_architecture_refactor_agent_guide.md`）

评审对象：`szwjp/luci-app-homeproxy-pro`，分支 `main`，HEAD `ad43ee2`。
评审方式：全量阅读 + 目标设备实测（ImmortalWrt，`ucode-2026.01.16~85922056-r1`）。
状态标记：**PASS / FAIL / NOT RUN**。

---

## 0. 结论摘要

### 0.1 完成度

按文档的 9 个 PHASE 计数，大约完成 **45% ~ 50%**，与你的估计一致。但要注意分布：

| PHASE | 内容 | 状态 | 说明 |
|---|---|---|---|
| 0 | Baseline | ✅ 完成 | 文档化充分 |
| 1 | Domain Model | 🟡 ~80% | `Node` 已建；`dns/routing/access_control/server` 仍是 raw UCI dict；`Node.raw` 完全无人读 |
| 2 | Parser | 🟡 ~50% | 已按协议拆成 `parse_<proto>_uri()`；但无 `parser/` 目录、无 normalize/validator 层、输出仍是扁平 UCI 键 |
| 3 | Protocol Adapter | 🟡 ~75% | 客户端 outbound 已数据表化；**WireGuard endpoint 未走 Adapter 且已损坏**；server 端完全没做 |
| 4 | Generator 拆分 | ❌ ~0% | `generate_client.uc` 仍是 1191 行单体，`generate/` 目录不存在 |
| 5 | Subscription Pipeline | 🟡 ~70% | fetcher/decoder/filter/repository 已拆；缺 normalizer/validator；orchestrator 仍直接写 UCI |
| 6 | Candidate Config | ❌ ~0% | 无 candidate、无 rollback；reload 仍是 `stop; start` |
| 7 | Runtime | ❌ ~0% | `init.d/homeproxy` 仍是 417 行，`runtime/` 不存在 |
| 8 | LuCI | 🟡 ~30% | TLS/Transport 已抽到 `homeproxy.js`；协议表前后端 6 份不同步；`parseShareLink` 是第二个后端 |
| 9 | Test / CI | 🟡 ~50% | 分层基本成型；但存在 vacuous 断言、无协议覆盖不变量、无 target-only 断言 |

**关键判断**：已经完成的是"结构好看"的那一半；**风险最高的那一半（PHASE 4/6/7）几乎为零**。而文档的"最终成功标准"恰恰是

```
Subscription Failure → Candidate Rejected → Old Config Preserved → Old Runtime Preserved
```

这条链目前完全不存在。

### 0.2 必须先处理的三件事

1. **P0-1 目标设备上 5 个新模块无法被 ucode 解析 ⇒ 生成器无法编译 ⇒ 服务根本无法启动**（已实测复现，见 §1.1）。
2. **P0-2 WireGuard 节点在 `Node` 化之后必然生成非法配置**（见 §1.2）。
3. **P0-3 前端 `parseShareLink` 与后端 `parse_uri` 双实现且已经漂移，导入链路完全绕过后端校验**（见 §1.3）。

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
**当前 HEAD 在目标设备上是不可用的。**

**修复**：给以下 7 处补 `;`（改成 `};`）：

| 文件 | 行（闭括号） | 函数 |
|---|---|---|
| `root/etc/homeproxy/scripts/config/loader.uc` | 111 / 132 | `load_tls` / `load_transport` |
| `root/etc/homeproxy/scripts/subscription/filter.uc` | 55 / 75 | `check` / `apply_policy` |
| `root/etc/homeproxy/scripts/subscription/decoder.uc` | 57 | `decode` |
| `root/etc/homeproxy/scripts/subscription/fetcher.uc` | 32 | `fetch` |
| `root/etc/homeproxy/scripts/subscription/repository.uc` | 92 | `apply` |

**防回归（重要）**：
- `tests/ucode/run.sh:69` 把 `*/config/*.uc` 从语法检查循环里排除了，且 import 循环（`:88-101`）也不含 `config/*.uc`。
  `config/loader.uc` 只被 generator 测试间接覆盖。**把 `config/*.uc` 加进 import 循环**。
- `tests/toolchain/build-ucode-linux.sh:61` 的 `clone ucode` **没有 pin 版本**（`git clone --depth 1`）。
  CI 用的 ucode 可能比目标设备宽松，于是 CI 绿、设备红——正好是文档里"不得伪造 PASS"要防的情况。
  **pin 到 ImmortalWrt 实际打包的 ucode 版本，并在 `tests/run.sh:47` 旁边加一条 ucode 版本断言。**

> 建议把这条单独作为一个 commit：`fix(ucode): terminate exported function declarations with ';'`，
> 因为它直接决定项目当前能否运行。

### 1.2 WireGuard 节点在 Node 化之后必然失败

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

**修复**（两条路，建议第 1 条）：
1. 在 `model.uc` 增加 `endpoint` 子对象 + `loader.uc` 增加对应读取，把 WireGuard 也纳入 Adapter
   （新增 `generate_endpoint` 的 Adapter 化，例如 `EndpointFactory.create(node)`），彻底符合 PHASE 3。
2. 过渡方案：`generate_endpoint` 改读 `node.raw.wireguard_*`，并把"wireguard 尚未建模"写进 TODO。
   注意 `Node.raw` 目前是死字段（全仓无人读），正好可以先用起来。

**防回归**：`tests/fixtures/generators/*.uci` **一个 WireGuard 节点都没有**，所以现有测试永远发现不了。
加一个 wireguard fixture + `sing-box check` 用例。

### 1.3 前端 `parseShareLink` 是第二个 backend，且已经漂移

**证据**：
- `node.js:22-409`（约 388 行）逐协议重写了 `parse_uri.uc:434-499`（约 500 行）的全部 12 个 scheme。
- 已实际漂移：
  - `node.js:41` `port: url.port || '80'` vs `parse_uri.uc:48` `port: url.port`（anytls 默认端口不一致）。
  - 前端 vmess 分支（`node.js` vmess block）**没有** `vmess_global_padding`，后端 `parse_uri.uc:397` 有 `'1'`。
- 校验强度不一致：后端 `parse_uri.uc:487-497` 用 `/sbin/validate_data` 校验 host/port；
  前端 `node.js:399-406` 只做 truthiness。
- 导入路径 `node.js:1152-1163` 直接 `uci.add/uci.set` + `uci.save()`，**后端 parser 从不参与**。

**影响**：同一份 URI，走订阅和走"导入分享链接"得到的节点不同；前端写进 UCI 的东西没有后端校验，
一个坏节点会触发 §1.5 的 `die()`。这正违反文档"前端 validation 不能取代后端 validation"和
"Frontend 不是第二个 Backend"。

**修复**：
1. 在 `luci.homeproxy` 暴露 `parse_uri`（入参 URI，出参归一化后的 node 对象，复用
   `singbox_generator` 已有的类型白名单风格）。
2. `node.js` 的 `parseShareLink` 改为调用该 RPC；删除 388 行 JS 副本。
3. 短期折中：保留前端副本，但加一个"协议 schema 一致性"测试，固化两边对同一 URI 的输出必须相同。
   （不建议——两个 parser 同步成本只会越来越高。）

### 1.4 订阅更新时"新增字段"永远写不进已有节点

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

**修复**：更新时取 `keys(cfg) ∪ keys(new)`；并且**顺便过滤 `.name/.type/.index/.anonymous` 伪键**
（当前代码会对 `.name` 调 `uci.delete`，虽然实测无害，但语义上是错的）。
然后把测试改成断言正确行为（`port` 应被写入）。

### 1.5 单个非法节点 `die()` 掉整份配置

**证据**：`config/adapter.uc:301-308`

```js
const problems = [...Node.validate(node), ...protocol_problems(node)];
if (length(problems))
        die(`node '${node.id}': ${join(', ', problems)}\n`);
```

`die()` 直接终止 `generate_client.uc`。

**影响**：任一节点缺 uuid / 端口越界 / TLS 无 SNI，整份 sing-box 配置就生成失败，服务**完全起不来**，
而不是"跳过这个坏节点、其余正常工作"。考虑到 §1.3 前端导入不做后端校验，这条很容易被触发。

**修复**：区分"致命"与"可跳过"。`main_node` / 路由引用的节点出错才致命；
仅出现在 urltest 候选列表里的坏节点应 `log()` + skip。至少在 `init.d` 层做到
"新配置不可用时保留旧配置"（见 §6 candidate/rollback）。

---

## 2. 架构改进（逐 PHASE）

### 2.1 PHASE 1 — Domain Model 收尾

现状：只有 `Node` 是真正的领域对象；`dm.dns.servers/rules`、`dm.routing.nodes/rules/rulesets`、
`dm.server.inbounds` 都是**原样 UCI section dict**，generator 里到处是 `cfg.enabled !== '1'`、
`cfg['.name']`、`cfg.groups` 这种 UCI 形状的判断（`generate_client.uc:520,551,797,1010,1096` 等），
`ConfigQuery.find_by_name()` 也专门服务于这种扁平 dict（`model.uc:180-185`）。

建议：
1. 为 `dns_server` / `dns_rule` / `routing_node` / `routing_rule` / `ruleset` 各建一个轻量领域对象
   （或在 Loader 中统一 `load_sections` 时归一化 `.enabled` 为布尔、保留 `.name` 为 `id`）。
   这一步做完，`generate_client.uc` 里的 `cfg.enabled !== '1'` 全部消失。
2. **删掉 `Node.raw`**（`model.uc:114`，全仓无人读，只在注释里被引用），或者按 §1.2 用它修 WireGuard。
   留一个"无人读的 opaque bag"只会让下一个人以为里面是权威数据。
3. 清理死代码：`ConfigQuery.node_ids`、`main_node_id`、`endpoints`（`model.uc:187-205`）全仓无调用点，
   而 `endpoints` 的注释说"A3/A4 填充"，A3/A4 早已落地。
4. `Config.create` 的注释（`model.uc:68-72`）说 dns/routing/endpoints/access_control/server
   "the loader does not read these yet"——A1.2 之后已经不成立，属于**误导性注释**，必须更新。

### 2.2 PHASE 2 — Parser 目录化 + 归一化 + 校验分离

现状：`parse_uri.uc`（500 行，顶层）已经按协议拆函数，质量不错。但：
- 没有 `parser/{uri,protocols,normalize,validator}.uc` 目录结构；
- 输出是**扁平 UCI 键**（`shadowsocks_encrypt_method`、`tls_sni`、`vless_flow`、`snell_userkey`…），
  不是 Domain `Node`；归一化职责被隐式推给了 `loader.uc` 的 `PROTOCOL_OPTIONS`；
- 校验只有末尾 12 行（`parse_uri.uc:487-497`），没有独立 validator，也没有 per-protocol 必填校验
  （那部分在 `adapter.uc:52-90`，属于 Adapter 层，可接受）。

建议：
1. 搬到 `scripts/parser/`：`uri.uc`（dispatch）、`protocols.uc`（`parse_*`）、`normalize.uc`、`validator.uc`。
2. 定义**唯一的协议字段映射表**，方向为 `canonical → uci_option`，从它同时派生：
   - parser 的归一化输出（canonical）
   - loader 的 `PROTOCOL_OPTIONS`（canonical → UCI）
   - adapter 的取值
   现在这张映射在三处重复：`parse_uri.uc`（输出扁平键）、`loader.uc:168-256`、`model.uc:43-57`。
3. 归一化后的 Node 与 §1.3 的 RPC 复用同一份 parser，前端不再有第二实现。

### 2.3 PHASE 3 — Adapter 收尾

现状：`adapter.uc` 用 `COMMON_FIELDS` + `CLAIM_FIELDS` + `OPTION_FIELDS` + `REQUIRED_CREDENTIALS`
四张表替代了 110 行三元表达式，这是本次重构最成功的部分，值得保留。

遗留：
1. **WireGuard endpoint 未 Adapter 化**（§1.2）。
2. `direct_overrides` 仍是模块级全局副作用（`generate_client.uc:202,292-296`，route builder 在
   `:912,924,1014` 读它）。文档建议的 `Node.raw.direct_overrides` / 数据化没有落地。
   建议改成 `generate_outbound()` 返回 `{outbound, override}`，或在 route 层直接查
   `node.protocol_options.override_address`（数据已经在 Node 里了，`loader.uc:254-257`）。
3. `CLAIM_FIELDS` 与 `OPTION_FIELDS.hysteria/hysteria2` 里 `auth`/`auth_str` 重复出现
   （`adapter.uc:150-154` 与 `:227-237`），`CLAIM_FIELDS` 的那两份是死代码（会被 OPTION_FIELDS 覆盖）。
4. `generate_server.uc` **完全没有走 Domain Model / Adapter**：它从 `dm.server.inbounds` 拿到的是
   扁平 UCI dict，然后逐字段 `cfg.snell_version` / `cfg.shadowsocks_encrypt_method`（`:61-158`）。
   server 端等于没重构。建议增加 `EndpointFactory`/`InboundFactory` 与 `Node` 对称的 server 模型。

### 2.4 PHASE 4 — Generator 拆分（当前 0%，但收益最直接）

`generate_client.uc` 1191 行，内部段落非常清晰，可以**按现有 `/* xxx start */` 注释机械拆分**，
风险低、review 容易：

| 目标文件 | 现有行区间 | 内容 |
|---|---|---|
| `generator/common.uc` | 394-411, 1180-1191 | `config.log`、`config.ntp`、`$schema`、写盘 + `sing-box check` |
| `generator/dns.uc` | 413-648 | DNS servers / rules / final（最大一块） |
| `generator/inbound.uc` | 650-708 | `config.inbounds` |
| `generator/outbound.uc` | 244-278, 710-850 | `generate_endpoint`、默认/main/urltest outbounds |
| `generator/route.uc` | 852-1132 | route rules + final |
| `generator/ruleset.uc` | 1094-1165 | rule_set + `http_clients` 归一化 |
| `generator/client.uc` | 394-1191 的编排 | 只做 orchestration |

配套（比拆文件更重要）：
1. **去掉 sed 注入式测试**。把 `generate_client.uc` 变成
   `generator/client.uc`（`export function generate(config, opts)`）+ 一个 10 行的 CLI 壳。
   这样 `Loader.load('__LOADER_DIR__')` 和 `/* HP_TEST_HOOK */` 都可以删掉，
   测试直接 `import { generate } from ...; generate(Loader.load(fixture_dir))`。
   现在的 `__LOADER_DIR__` / `HP_TEST_HOOK` / `__HP_TEST_DOMAIN_MODEL__` 机制已经部分腐朽
   （`test_demo_architecture.sh:158-159` 的两条 sed 是**空操作**，见 §3.1）。
2. **删掉重复的 `sing-box check`**：`generate_client.uc:1187` 与 `init.d:110` 检查同一份文件；
   `generate_server.uc:170` 与 `init.d:245` 同理。文档明确"不要重复实现已有的 sing-box check"。
   建议生成器只负责"原子写入 candidate + 序列化"，check 交给 runtime（或反之）。

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

### 2.6 PHASE 6 — Candidate Configuration + Rollback（最高优先级的新功能）

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

### 2.7 PHASE 7 — Runtime 抽离

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
- `wireguard` 在 `node.js:462-463` 可选，但没有任何 loader/adapter 行（见 §1.2）；
- hysteria2 的 `auth_payload` 在 `loader.uc:239` 有，UI 没有对应字段。

建议：先做**一份权威协议表**（JS 侧导出给 LuCI，ucode 侧由同一份数据生成或由一致性测试守护），
再拆目录；否则拆完还是 6 份。

### 2.9 PHASE 9 — Test / CI

现状分层（实测）：
- `python3 tests/i18n-coverage.py --warn-below 100` → **PASS**（724/724）
- `node tests/luci-form-snapshot.js` node/server → **PASS**（与 `tests/snapshots/*.json` 一致）
- `sh tests/ucode/run.sh` → 本机 **NOT RUN**（无 ucode；脚本没有 `command -v ucode` 守卫，
  会把每个用例打印成 "ucode: command not found" 的 FAIL，而不是 NOT RUN）
- 目标设备上 → **FAIL**（§1.1 的模块解析错误导致 generator / domain-model / subscription 全线失败）

必须补的：
1. **修掉 vacuous 断言**（§3.1）。
2. **协议覆盖不变量测试**：目前 `grep PROTOCOL_OPTIONS|OPTION_FIELDS` 在 `tests/` 下**零命中**。
   新增 `tests/ucode/test_protocol_inventory.uc`，断言
   `keys(loader.PROTOCOL_OPTIONS) == keys(adapter.OPTION_FIELDS) ∪ {direct, ...}`，
   且每个协议在 fixture 里都有节点。这条能一次性覆盖 ssh/wireguard/hysteria 的缺口。
3. **golden JSON 快照**：`tests/snapshots/generator/.gitkeep` 还是空的。
   每个协议一份 outbound 黄金 JSON，比现在的"自己跟自己比"（§3.1）有价值得多。
4. `client.json` 表单快照：`luci-form-snapshot.js:13,196-202` 只接受 `node|server`，
   而 `client.js`（1755 行，最大的表单）没有任何快照。
5. TLS/Transport 单测：目前没有测试直接调用 `load_tls/load_transport/buildTLSObject/buildTransportObject`，
   只被 fixture 间接覆盖。
6. `tests/ucode/run.sh` 加 `command -v ucode` 守卫，缺工具时明确 NOT RUN + 独立退出码。
7. 把 `run.sh:71-75,107-113` 里 SKIP 的 target-only 用例（firewall_pre、firewall template、
   `luci.homeproxy` RPC、`update_subscriptions`）纳入一个 on-target CI job；否则 CI 全绿但从未检查它们。

完全无测试的文件：`client.js`、`status.js`、`migrate_config.uc`、`update_resources.sh`、
`update_crond.sh`、`clean_log.sh`、`init.d/homeproxy`、`firewall_pre.uc`、`luci.homeproxy`、
`subscription/fetcher.uc`。（`generate_server.uc` 有 smoke test，但只断言 `sing-box check`。）

---

## 3. 测试诚信问题（文档 FINAL SELF REVIEW 明确要求）

### 3.1 `test_demo_architecture.sh` 的等价性断言是恒真的

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
`docs/architecture-review.md` 的 Bottom line 里那句话现在已经不成立。

同时 `demo/architecture/` 目录**根本不存在**（`find demo` → no such directory），但：
- 源码头注释仍在说"the copy in demo/architecture/ must stay in lockstep"
  （`model.uc:9-11`、`loader.uc:9-13`、`adapter.uc:9-10`）；
- `tests/README.md:105,113-119`、`tests/fixtures/architecture/README.md:14` 仍在引用它；
- `docs/architecture-review.md:40-42,143` 仍在描述它。

另外 `test_demo_architecture.sh:158-159` 的两条 sed 是**空操作**：
`const uci = cursor();` 在 `generate_client.uc` 里已不存在，`__HP_TEST_DOMAIN_MODEL__` 也只在
测试文件自身出现。

**建议**：二选一——(a) 恢复 `demo/architecture/` 作为独立参考实现并用它做对照；
(b) **删掉这个测试**，改用 §2.9 的 golden JSON 快照，并清掉全部 `demo/` 引用。
以当前仓库状态，(b) 更诚实、成本更低。

### 3.2 其它"把 bug 锁成契约"的断言

- `test_subscription_repository.uc:138-144` 断言"新增字段不写入"（见 §1.4）。
- `test_subscription_decoder.uc:44-53` 断言 `{servers:[...]}` / URI-array JSON 解码为 0 节点（"quirk"）。

修 bug 时这些测试会红——请在同一 commit 里改成断言正确行为，而不是保留 quirk。

### 3.3 脆弱锚点

`test_generators.sh:46-49,63` 和 `test_demo_architecture.sh:158-167` 依赖 sed 精确匹配源码行
（`export const HP_DIR = '/etc/homeproxy';`、`'__LOADER_DIR__'`、`/* HP_TEST_HOOK */`）。
§2.4 的"generator 变成可 import 的库"能一次性消除这类脆弱性。

---

## 4. 安全

| 项 | 现状 | 建议 |
|---|---|---|
| RPC ACL | `acl.d/luci-app-homeproxy.json:13` 仍是 `"luci.homeproxy": ["*"]`，且挂在 `read` 下，覆盖 5 个**写**方法（`acllist_write`、`certificate_write`、`log_clean`、`resources_update`、`singbox_generator`），并自动授权未来新增方法 | 拆成显式 read 方法列表 + write 方法列表 |
| 路径字段无后端校验 | `tls_cert_path`（`loader.uc:88`）、`tls_key_path`（`homeproxy.uc:392-393`）、ruleset `path`/`initial_path`（`client.js:1508,1558`，`datatype='file'`）只在浏览器里用 `validateCertificatePath`（`homeproxy.js:512-518`）检查，后端直接喂给以 root 运行的 sing-box | 在 Loader/Adapter 侧加白名单（允许 `/etc/homeproxy/...`），UI 校验只当 UX |
| 订阅响应大小 | `wGETVerbose`（`homeproxy.uc:107`）无 `--max-filesize`/无上限，只靠 `--timeout=10`；整个 body 经 `executeCommand` 落盘再读（上限 512KB 截断，但下载已完成），随后整份 `decodeBase64Str` + `split(\n)` | 加 `--max-filesize`，并在 decode 前做长度上限 |
| 订阅凭据泄漏 | `update_subscriptions.uc:97-140` 把完整 URL（可能含 token）写入 `/var/run/homeproxy/homeproxy.log` | 记录时脱敏（去掉 query/userinfo） |
| `innerHTML` | 无"订阅节点名/URL 进 innerHTML"的路径（已确认 label 都走 `o.value()`）。唯一活 sink 是 `client.js:109` / `server.js:137` 的 `renderStatus(res, features.version)`，把后端解析的 `sing-box version` 字符串直接拼进 HTML | 改用 `E()`/`textContent`；`status.js:246-258` 的 `rawhtml` 也建议复查 |
| 错误被静默吞掉 | `acllist_write` 返回 `{result:false,error}`（`luci.homeproxy:55-60`）但 `client.js:1680-1682,1712-1714` 完全忽略；`acllist_read` 的 error 同样被忽略 | 按 `homeproxy.js:494-498` 的模式上报 |
| 前端 RPC 无统一封装 | 11 处 `rpc.declare`，`L.resolveDefault(p,{})` 吞掉所有失败 | 抽 `shared/rpc.js` |
| 轮询泄漏 | `poll.add` 在 section render 内注册（`client.js:106-111`、`server.js:134-139`），`map.reset()` 会累积；`document.getElementById('service_status')` 未判空 | 移到 view 级注册一次 |
| 证书上传竞态 | 固定 `/tmp/homeproxy_certificate.tmp`（`homeproxy.js:491`）被 4 个上传按钮共享 | 用唯一临时名 |

---

## 5. 建议的 PR / commit 序列

按"先能让项目跑起来，再谈架构"排序：

```
P0（本周）
1. fix(ucode): terminate exported function declarations with ';'          # §1.1  5 文件 7 处
2. test(toolchain): pin ucode + import-check config/*.uc                  # §1.1
3. fix(generator): model WireGuard endpoint fields on Node                # §1.2
4. test(arch): protocol inventory invariant + wireguard fixture           # §2.9 / §1.2
5. fix(sub): update newly-added fields on existing subscription nodes      # §1.4
6. fix(generator): skip invalid candidate nodes instead of die()          # §1.5

P1（可靠性 — 文档 PHASE 6/7 的核心目标）
7. reliability: generate to candidate, keep rollback copy, health-check    # §2.6
8. reliability: back up + restore /etc/config/homeproxy on failed commit   # §2.6
9. refactor(sub): stop-before-fetch -> fetch-then-reload                   # §2.5
10. reliability: single sing-box check per generation                     # §2.4

P2（结构）
11. refactor(gen): split generate_client.uc into generator/*.uc            # §2.4
12. refactor(gen): generator becomes an importable library (drop sed hooks)# §2.4
13. refactor(parser): parser/ dir + single canonical field mapping         # §2.2
14. refactor(gen): server inbound through domain model + InboundFactory    # §2.3
15. refactor(runtime): extract runtime/*.uc, thin init.d                   # §2.7
16. refactor(luci): shared/rpc.js + components/ + protocol registry        # §2.8
17. security: split ACL wildcard; backend path allowlist                   # §4
18. test: golden protocol snapshots; client.json snapshot; de-quirk asserts# §2.9
19. docs: drop demo/ references; refresh architecture-review claims        # §3.1
```

---

## 6. 不建议做的事

1. **不要为了对齐目录树而拆文件**。文档自己也说"不要为了拆文件而拆文件"。
   `generate_client.uc` 该拆是因为它 1191 行且有清晰段落（§2.4）；
   而 `adapter.uc` 的数据表设计比"11 个 Adapter 类"更好，不要退回去。
2. **不要在 candidate/rollback 落地前继续做 generator 拆分**。先让失败路径安全，再动结构，
   否则每次拆分都在"服务可能起不来"的前提下做。
3. **不要保留两份 parser**（§1.3）。前端副本每加一个协议就多一份同步成本，而且已经漂移了。
4. **不要用"改 expected output"来让 §3.2 的 quirk 测试通过**——那是文档 ABSOLUTE RULES 第 10 条。
5. **不要在 CI 里把 SKIP 当成 PASS**（§2.9 第 7 条）。

---

## 附：本次实测记录

| 检查 | 结果 |
|---|---|
| `python3 tests/i18n-coverage.py --warn-below 100` | **PASS** 724/724，10 条 ignore |
| `node tests/luci-form-snapshot.js . node` / `server` | **PASS**（与 `tests/snapshots/*.json` 一致） |
| `sh tests/ucode/run.sh`（本机） | **NOT RUN** — 无 ucode，脚本未守卫，误报 FAIL |
| 目标设备 ucode module import：`config/loader.uc`、`subscription/{filter,decoder,fetcher,repository}.uc` | **FAIL** — `Expecting ';'` |
| 目标设备 ucode module import：`config/model.uc`、`config/adapter.uc`、`homeproxy.uc`、`parse_uri.uc` | **PASS** |
| 目标设备：`generate_client.uc` / `generate_server.uc` 能否运行 | **FAIL**（因 loader.uc 无法编译） |
| WireGuard 生成路径 | 静态确定的缺陷，**建议按 §1.2 加 fixture 后复测** |

目标设备环境：ImmortalWrt x86_64，`ucode-2026.01.16~85922056-r1`，
`libucode20230711-2026.01.16~85922056-r1`，`ucode-mod-uci/-fs/-ubus/-uloop/-digest` 同版本。
