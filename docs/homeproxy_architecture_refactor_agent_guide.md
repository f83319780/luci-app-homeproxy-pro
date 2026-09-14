# 架构重构方案 + Agent 严格执行 Prompt

目标仓库：`szwjp/luci-app-homeproxy-pro`

## 一、重构目标

本次不是简单拆大文件，而是建立清晰分层：

```text
UCI
 ↓
Config Loader
 ↓
HomeProxy Domain Model
 ↓
Application / Service Layer
 ↓
Generator / Adapter Layer
 ↓
sing-box
```

同时建立：

```text
LuCI → RPC → Application Service

Subscription
 → Fetch → Decode → Parse → Filter → Validate
 → Candidate → Commit → Reload → Health → Rollback
```

核心原则：

1. UCI 不是 Domain Model。
2. Generator 不应该直接依赖 UCI。
3. Parser 只负责 URI → Normalized Node → Validation。
4. Runtime 与 Config Generation 分离。
5. Frontend 不是第二个 Backend。
6. 保持 OpenWrt/ImmortalWrt、sing-box >=1.14、UCI schema、firewall、协议行为兼容。

---

## 二、目标目录

最终可演进到：

```text
root/etc/homeproxy/
├── scripts/
│   ├── homeproxy.uc
│   ├── config/
│   │   ├── loader.uc
│   │   ├── model.uc
│   │   ├── validator.uc
│   │   └── repository.uc
│   ├── parser/
│   │   ├── uri.uc
│   │   ├── protocols.uc
│   │   ├── normalize.uc
│   │   └── validator.uc
│   ├── generator/
│   │   ├── client.uc
│   │   ├── server.uc
│   │   ├── common.uc
│   │   ├── dns.uc
│   │   ├── outbound.uc
│   │   ├── endpoint.uc
│   │   ├── route.uc
│   │   ├── ruleset.uc
│   │   └── tls.uc
│   ├── subscription/
│   │   ├── update.uc
│   │   ├── decoder.uc
│   │   ├── filter.uc
│   │   ├── normalizer.uc
│   │   └── repository.uc
│   ├── resource/
│   │   ├── update.sh
│   │   ├── validator.uc
│   │   └── repository.uc
│   └── runtime/
│       ├── service.uc
│       ├── health.uc
│       ├── rollback.uc
│       └── firewall.uc
└── resources/
```

这是最终目标，不要求第一 PR 一次创建全部文件。

---

## 三、Domain Model

核心对象：

```text
HomeProxyConfig
├── general
├── dns
├── nodes
├── outbounds
├── endpoints
├── routing
├── access_control
└── server
```

Node：

```text
Node
├── id
├── name
├── type
├── address
├── port
├── credentials
├── tls
├── transport
├── multiplex
└── protocol_options
```

注意：HomeProxy Node 不等于 sing-box outbound。

```text
HomeProxy Node
 → Protocol Adapter
 → SingBox Outbound
```

---

## 四、Protocol Adapter

将 `generate_outbound()` 中的协议分支逐步抽离：

```text
OutboundFactory
├── VLESSAdapter
├── VMessAdapter
├── TrojanAdapter
├── HysteriaAdapter
├── Hysteria2Adapter
├── TUICAdapter
├── SnellAdapter
├── ShadowsocksAdapter
├── SOCKSAdapter
├── HTTPAdapter
└── AnyTLSAdapter
```

公共能力统一复用：

```text
TLS Builder
Transport Builder
Multiplex Builder
```

---

## 五、URI Parser

目标：

```text
URI
 ↓
Protocol Parser
 ↓
Normalized Node
 ↓
Validator
```

Parser 不得直接：

- 修改 UCI
- commit
- restart service
- 操作 LuCI

保持现有合法 URI 的语义不变。

---

## 六、Subscription Pipeline

目标：

```text
SubscriptionService
├── Fetcher
├── Decoder
├── Parser
├── Filter
├── Validator
└── Repository
```

规则：

- Fetcher 不修改 UCI。
- Parser 不修改 UCI。
- Filter 不修改 UCI。
- 只有 Repository 负责持久化。

---

## 七、Candidate Configuration

目标：

```text
Current
 ↓
Candidate
 ↓
Validate
 ↓
sing-box check
 ↓
Commit
 ↓
Reload
 ↓
Health
 ↓
Success
```

失败：

```text
Rollback
```

不能采用：

```text
stop → modify → commit → 发现错误
```

必须认真理解 OpenWrt UCI cursor 生命周期，不得假设未 commit 的 candidate 会被另一个 ucode cursor 自动看到。

---

## 八、Runtime

最终：

```text
/etc/init.d/homeproxy
 ↓
Runtime Service
 ├── Config Manager
 ├── Firewall Manager
 ├── DNS Manager
 ├── Health Manager
 └── Rollback Manager
```

init.d 逐步变薄，但不得破坏 procd、respawn、start/stop/reload。

---

## 九、LuCI

目标：

```text
view/homeproxy/
├── client.js
├── node.js
├── protocol/
├── components/
└── shared/
```

提取：

- protocol registry
- shared validation
- RPC wrapper
- TLS component
- transport component

不要为了拆文件而拆文件。

前端 validation 不能取代后端 validation。

---

## 十、测试

最终测试分层：

```text
Unit
├── parser
├── validator
├── TLS
├── Transport
└── protocol adapters

Generator
├── client
├── server
└── sing-box check

Frontend
├── form snapshots
└── protocol schema

Integration
├── UCI
├── generator
├── sing-box
├── runtime
└── firewall
```

必须保持现有测试，并增加针对重构回归的测试。

---

# Agent 严格执行 Prompt

将下面内容直接交给 Coding Agent：

---

## EXECUTION MODE

你现在负责对 `szwjp/luci-app-homeproxy` 进行架构级重构。

目标不是简单拆文件，而是建立：

```text
UCI
→ Domain Model
→ Service
→ Generator
→ sing-box
```

以及：

```text
LuCI
→ RPC
→ Application Service
```

架构。

### ABSOLUTE RULES

1. 先阅读完整仓库，再修改。
2. 不允许一次性重写整个项目。
3. 每个阶段必须保持现有功能。
4. 每个阶段必须测试。
5. 不改变 UCI schema。
6. 不改变 sing-box JSON 语义。
7. 不改变 firewall 行为。
8. 不改变 URI parser 行为。
9. 不删除测试。
10. 不通过修改 expected output 来掩盖 regression。
11. 不做无关格式化。
12. 不引入不必要的新依赖。
13. 任务描述与代码不一致时，以实际代码为准。
14. 不允许为了架构漂亮而破坏已有功能。
15. 未测试的功能不得声称完成。

---

## PHASE 0 — BASELINE

先执行：

```sh
git status
git branch --show-current
git log --oneline -20
```

阅读：

```text
README.md
Makefile
tests/README.md
```

阅读核心文件：

```text
root/etc/homeproxy/scripts/homeproxy.uc
root/etc/homeproxy/scripts/generate_client.uc
root/etc/homeproxy/scripts/generate_server.uc
root/etc/homeproxy/scripts/parse_uri.uc
root/etc/homeproxy/scripts/update_subscriptions.uc
root/etc/homeproxy/scripts/update_resources.sh
root/etc/init.d/homeproxy
root/usr/share/rpcd/ucode/luci.homeproxy
root/usr/share/rpcd/acl.d/luci-app-homeproxy.json
root/etc/homeproxy/scripts/firewall_pre.uc
root/etc/homeproxy/scripts/firewall_post.ut
htdocs/luci-static/resources/view/homeproxy/client.js
htdocs/luci-static/resources/view/homeproxy/node.js
```

搜索：

```sh
grep -R "uci\.get" .
grep -R "uci\.set" .
grep -R "uci\.commit" .
grep -R "sing-box check" .
grep -R "parseShareLink" .
grep -R "generate_outbound" .
grep -R "luci.homeproxy" .
grep -R "innerHTML" .
```

确认 baseline 后才能开始重构。

---

## PHASE 1 — DOMAIN MODEL

建立：

```text
UCI
 ↓
Config Loader
 ↓
HomeProxyConfig
```

要求：

- generator 不再直接读取大量 UCI。
- UCI parsing 与业务模型分离。
- Domain Model 不依赖 LuCI。
- Domain Model 不依赖 sing-box JSON schema。

本阶段禁止改变 generator 语义。

运行现有 generator regression tests。

---

## PHASE 2 — PARSER

将 `parse_uri.uc` 演进为：

```text
URI
 ↓
Protocol Parser
 ↓
Normalized Node
 ↓
Validator
```

保持实际仓库支持的所有协议。

禁止删除协议。

禁止改变合法 URI 的解析结果。

通过所有现有 parser tests。

---

## PHASE 3 — PROTOCOL ADAPTER

将 `generate_outbound()` 的 protocol-specific logic 提取成 adapter。

目标：

```text
Node
 ↓
Protocol Adapter
 ↓
SingBox Outbound
```

公共 TLS / Transport / Multiplex 必须复用。

每提取一个协议：

1. parser test
2. generator regression
3. 对比重构前后 JSON

---

## PHASE 4 — GENERATOR

逐步拆分 `generate_client.uc`：

```text
dns
outbound
endpoint
route
ruleset
common
tls
transport
```

主 generator 只负责 orchestration。

禁止同时修改无关业务逻辑。

---

## PHASE 5 — SUBSCRIPTION PIPELINE

拆分：

```text
fetch
decode
parse
filter
validate
repository
```

最终 `update_subscriptions.uc` 只负责 orchestration。

Fetcher / Parser / Filter 不得直接 commit UCI。

---

## PHASE 6 — CANDIDATE CONFIG

引入：

```text
Current
 ↓
Candidate
 ↓
Validate
 ↓
sing-box check
 ↓
Commit
 ↓
Reload
 ↓
Health
 ↓
Success
```

失败必须 rollback。

必须以真实 OpenWrt UCI 行为为依据设计 transaction。

---

## PHASE 7 — RUNTIME

逐步抽离：

- config lifecycle
- firewall lifecycle
- health
- rollback

保持 procd。

不要重复实现已有的 sing-box check。

---

## PHASE 8 — LUCi

拆分：

```text
client.js
node.js
```

提取：

- protocol registry
- shared validation
- RPC wrapper
- TLS
- Transport

检查 `innerHTML` 相关 XSS 风险。

后端 validation 永远保留。

---

## PHASE 9 — TEST / CI

完善：

```text
parser tests
generator regression
subscription tests
ACL tests
LuCI snapshots
firewall tests
integration tests
```

尽可能运行：

```sh
git diff --check
sh -n <changed-shell-file>
node --check <changed-js-file>
tests/run.sh
sing-box check
```

如果环境缺少 OpenWrt / ucode / sing-box / LuCI runtime：

不得伪造 PASS。

必须明确：

```text
PASS
FAIL
NOT RUN
```

---

## REFACTORING INVARIANTS

以下绝不能破坏：

```text
UCI schema
protocol URI semantics
sing-box >=1.14 behavior
firewall behavior
LuCI behavior
subscription semantics
security validation
```

---

## COMMIT STRATEGY

建议：

```text
refactor: introduce homeproxy config model
refactor: normalize protocol parser output
refactor: extract protocol outbound adapters
refactor: split client generator modules
refactor: separate subscription pipeline
reliability: introduce candidate configuration
reliability: add transactional reload and rollback
refactor: extract runtime service manager
refactor: modularize LuCI protocol definitions
test: expand architecture regression coverage
```

实际 commit 数量根据代码范围调整。

每个 commit 必须：

- 单一目的
- 可独立 review
- 不包含无关格式化

---

## FINAL SELF REVIEW

完成后重新执行：

```sh
git diff
git diff --check
```

逐项检查：

### Architecture

- 是否仍存在 UCI → Generator 强耦合？
- 是否存在 Parser → UCI？
- 是否存在 Generator → Runtime？
- 是否存在 Frontend → backend implementation details？
- 是否存在重复 protocol schema？
- 是否存在重复 TLS / Transport logic？

### Reliability

- subscription update 失败是否可能留下 partial config？
- candidate 是否经过 sing-box check？
- reload failure 是否有 rollback？
- rollback failure 是否被记录？

### Security

- 外部 URL 是否经过 backend validation？
- RPC ACL 是否仍然 wildcard？
- 外部输入是否可能进入 innerHTML？
- subscription response 是否存在无限资源消耗？
- 日志是否泄漏 subscription credentials？

### Compatibility

- UCI schema 是否保持？
- sing-box >=1.14 是否保持？
- parser behavior 是否保持？
- firewall behavior 是否保持？

### Testing

每项必须标记：

```text
PASS
FAIL
NOT RUN
```

---

## FINAL OUTPUT

最终必须输出：

```markdown
# Implementation Summary

# Architecture Changes

# Changed Files

# Dependency Graph

# Before / After Architecture

# Security Impact

# Reliability Impact

# Compatibility

# Tests

# Remaining Risks

# Commits

# PR Description
```

PR Description 必须包含：

```text
Title
Summary
Changes
Architecture
Security
Reliability
Testing
Compatibility
Known Limitations
```

不得声称没有实际验证过的内容已经完成。

---

## 最终成功标准

真正成功不是“文件拆得更多”，而是：

```text
UCI
 ↓
Domain Model
 ↓
Service
 ↓
Generator Adapter
 ↓
sing-box
```

每层边界清晰。

同时：

```text
Subscription Failure
        ↓
Candidate Rejected
        ↓
Old Config Preserved
        ↓
Old Runtime Preserved
```

以后新增协议、升级 sing-box、修改 routing、增加 subscription provider 时，可以局部修改，而不是继续向几个超大文件堆逻辑。
