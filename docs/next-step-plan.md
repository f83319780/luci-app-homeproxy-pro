# 下一步计划报告 — luci-app-homeproxy-pro

- **依据**：`docs/audit-report.md`（基线 `b820aac`，含三路独立复核）
- **纲领**：`homeproxy_architecture_refactor_agent_guide.md`（规格与 ABSOLUTE RULES）、
  `architecture-improvement-plan.md`（实现台账）、`重构实施间断性指导建议.md`（28 条 + 7 条 PR 路由）

---

## 0. 文档权威关系（先说清楚，避免出现第二本台账）

本文**不是**新纲领，是**本阶段的优先级排序**。

- `architecture-improvement-plan.md` **仍是实现细节的唯一权威**。本文每一项完成后，
  结果回写该台账（含 commit、删除线、进度比率），而不是堆在本文里。
- `agent_guide` 的 ABSOLUTE RULES 不可被本文覆盖；冲突时以纲领为准。
- 本文寿命到下**一次审计**为止。

**计划因审计而改变的地方**：审计前我认为剩余工作主要是 PHASE 8 收尾与守卫。
三路复核把两个**安全问题**放到了最前面，而它们**不是本轮重构引入的**——
所以下面的顺序与上一版不同：**安全问题先行，PHASE 8 收尾后置**。

---

## 1. 优先级总览

| 编号 | 事项 | 优先级 | 规模 | 阻塞于 |
|---|---|---|---|---|
| **P0-1** | **两个 XSS**：label→弹窗标题、订阅 URL fragment→tab 标题 | **P0** | 小 | 无 |
| **P0-2** | `decodeURIComponent` 让节点页**整页渲染失败**（必现） | **P0** | 极小 | 无 |
| P0-3 | 真机配置善后：抢救 + 重建 | **P0** | 小 | 你提供节点信息 |
| P0-4 | ECH 上传修复（补后端含 ECH 专用校验 或 删按钮） | **P0** | 小 | 需求决策 A/B |
| P0-5 | README 把默认目标写成**生产路由器** | **P0** | 极小 | 无 · 已完成✅ |
| P1-1 | Architecture Guard（PR-07），含契约闭合性守卫 | P1 | 中 | 无 |
| P1-2 | 发布路径加测试门（tag 不再裸发布） | P1 | 小 | 无 |
| P1-3 | mock 副本同步守卫 | P1 | 小 | 无 |
| P1-4 | i18n 门补 source→pot | P1 | 小 | 无 |
| P1-5 | `luci.homeproxy` 行为测试（含 `certificate_write` 全分支） | P1 | 中 | 与 P0-4 同批 |
| P1-6 | ACL 收紧：删 6 条浏览器用不到的写路径 | P1 | 极小 | 无 |
| P1-7 | RPC 失败回退不再断言假状态（含 `type` 静默改写） | P1 | 中 | 需先有可失败的测试 |
| P1-8 | 真机 CI 作业（台账 §5 项 14） | P1 | 中 | P0-3 之后更有意义 |
| P1-9 | 版本对齐 / "只 stage 不安装" 策略落地 | P1 | 小 | 无 |
| P1-10 | crontab `sed -i` 不对称修复 | P1 | 极小 | 无 |
| P2-1 | 真空检查修复（含我本会话那条正则） | P2 | 小 | 无 |
| P2-2 | fw4 渲染层进 CI | P2 | 中 | 无 |
| P2-3 | 低危安全项：`CAP_SYS_PTRACE`、`E()` sink、大小上限、`/tmp` TOCTOU | P2 | 小 | 无 |
| P2-4 | 测试确定性（固定 `/tmp`→`mktemp`、`rm -rf` 引号、ssh `BatchMode`） | P2 | 小 | 无 |
| P2-5 | JSON 资产校验 + 出厂配置解析 | P2 | 小 | 无 |
| P2-6 | PHASE 8 残留：状态三件套（**需先补守卫**） | P2 | 中 | P1-1 守卫 + P1-7 |
| P2-7 | PHASE 8 残留：GridSection ×5 / 动态 load ×13 | P2 | 中 | 无 |
| P2-8 | 代码卫生 §2.10.8 四项 | P2 | 小 | 无 |
| P3-1 | **浏览器人工回归** | P3 | 很小 | **只能你做** |
| P3-2 | 明确不做项 | — | — | 见 §16 |

---

## 2. P0-1 两个 XSS（最紧急）

### 现状
审计 §3、§4。两个独立入口，同一个终点（`dom.append` 的 `innerHTML`）：

1. **存储型**：远程订阅的节点 `label` → `loadModalTitle` → LuCI `titleFn` →
   `stripTags`（**解码 HTML 实体**）→ 弹窗标题。管理员点开该节点即触发。
2. **打开页面即触发**：订阅 URL 的 fragment → `decodeURIComponent` → `s.tab()` 标题。
   **不需要点击**。

对手是"你从他那里订阅的人"。载荷经 UCI 持久化（入口 1）或就在 URL 里（入口 2）。

### 计划
1. 在 `homeproxy.js` 里加**一个具名的导出转义函数**，例如
   `escapeForTitle(s)`：`&`→`&amp;`、`<`→`&lt;`、`>`→`&gt;`、`"`→`&quot;`、`'`→`&#39;`。
2. `loadModalTitle`（`homeproxy.js:793`）里对**原始 label** 先转义再拼进返回串。
   **一处修好覆盖 4 个调用点**（`node.js:681`、`client.js:89/1008/1240/1368`）。
3. 入口 2：**不要**把解码后的 fragment 当标题——改用 `url.hostname`；
   若确实要显示 fragment 文本，同样过 `escapeForTitle`。
4. **后端纵深防御**：`repository.uc` 写 UCI 时不原样存 label（或在写之前做同样的转义）。
   前端是唯一拦截点时，任何绕过前端的读取路径都会重新打开这个洞。
5. **顺带**：`node.js:554-559` 的 `try/catch`（即 P0-2）与这里同文件，一起改。

### 验收标准（关键：这是**可测的**）
`escapeForTitle` 是**纯函数**，所以能真正被单测覆盖：

- **往返不变量**：对 `decodeEntitiesOnce(escapeForTitle(x))` 断言结果中**不含裸 `<`/`>`**——
  这里的 `decodeEntitiesOnce` 就是**模拟 `stripTags` 的那一次解码**。
  这条不变量直接编码了"绕过 stripTags 的那个性质"，是本项的核心测试。
- 载荷用例：`&lt;img src=x onerror=alert(1)&gt;`、`<script>`、`"` `'` `&`、
  双重编码 `&amp;lt;`、以及普通中文 label（不得被改坏）。
- 反向验证：**去掉转义** → 测试必须红。

### 我必须明说的限制
**上面测的是转义函数的性质，不是"浏览器里真的不执行了"。**
测试 harness 从不创建 DOM（审计 §8.3），所以端到端只能**由你在浏览器里确认一次**（P3-1）。
我会把这条记为"未端到端验证"，不会声称已修好。

---

## 3. P0-2 `decodeURIComponent` 崩溃（必现）

`node.js:555` 对畸形 fragment 抛 `URIError`，位置在 `render()` 里、`m.render()` 之前，
**整页渲染不出来**。已实测 `#%`、`#100%`、`#%zz` 三种都抛，且都被校验器放行。
`new URL(suburl)` 对非 URL 的 UCI 值抛 `TypeError`，同路径。

**计划**：把 554-559 包 `try/catch`，失败退回 `url.hostname` 或原串。
**验收**：单测三种畸形 fragment + 非 URL 值，断言不抛且退回预期值；反向验证（去掉 try/catch → 红）。
**这不是安全问题，是必现的功能故障**，所以与 P0-1 同批做但独立验收。

---

## 4. P0-3 真机配置善后

设备 `/etc/config/homeproxy` 现为 feed 默认值（78 行 / 8 section / 0 节点）。

- **不可恢复**：6 个节点 + `dns` + `server` + `subscription`
- **可恢复**：`infra`、`config`、`control`（含 LAN IP/MAC、WAN CIDR 清单）、`routing`

**计划**：①`--dry-run` 给你确认 → ②只覆盖那 4 个 section → ③你补回其余 →
④**立刻 `uci export homeproxy` 存档**，并把"改配置前必须先导出"写进运行说明。

**验收**：section 数与预期一致；存档非空；`/etc/init.d/homeproxy start` 的失败信息
（若因无节点而失败）必须指向缺节点，而不是别的。

---

## 5. P0-4 ECH 上传修复

审计 §6。**复核补充了一条我漏掉的**：即使补上 case，
`homeproxy.uc:597-598` 的 `isValidPEM(content,false)` 只认
`-----BEGIN CERTIFICATE-----`，而 ECH config 是 `-----BEGIN ECH CONFIGS-----`。

### 决策（需要你一句话）
- **A（推荐）补后端**：新增 `case 'client_ech_conf'`，走**ECH 专用校验**
  （不能复用 `isValidPEM`），并修掉错误路径不清理
  `/tmp/homeproxy_cert_client_ech_conf.tmp` 的问题。
- **B 删按钮**：同时删 `tls_ech`/`tls_ech_config_path`、ACL 两条、生成器引用。

**倾向 A**：生成器与 UCI 模型已围绕 ECH 建好，删的面积远大于补一条分支。

**验收**：四个文件名各一例成功 + 非法名仍被拒 + ECH 的 PEM 头校验生效 +
tmp 文件在成功与失败路径上都被清理。**在 P1-5 的行为测试里写**，并先确认它能抓到当前 bug。

---

## 6. P0-5 README 指向生产路由器 —— 已完成✅

`tests/README.md:18-19` 写默认 `root@192.168.1.1`——**那是家里的生产路由器**，
而 `run.sh:20` 的默认是 `.102`，`run.sh:12-14` 明确警告这个 fallback 会把整个 checkout
解包到目标机上、**绝不能落在生产路由**。照抄 README 的示例就会发生这件事。
**一行文档，风险最实际。** 验收：README 全文无 `192.168.1.1`（或明确标注为"勿用"）。

---

## 7. P1-1 Architecture Guard（PR-07）

审计 §8.3 的六个盲区就是它的需求清单。**不卡任何人，且是后面所有改动的前提。**

### 首批守卫
1. **ACL ↔ 后端方法表双向差集为空**（已用 Python 验证过，固化它）
2. **前端 `rpcCall` 的方法集合 ⊆ 后端定义集合**
3. **每个证书上传按钮的 filename 都有对应后端 case** ← 直接针对 ECH 缺陷
4. **每个 `rpcCall` 方法名都在测试里被引用过** ← 针对"无测试引用任何方法名"
5. 7 条架构边界固化为可执行断言
6. 无野字符号、无死代码符号
7. **ACL `file` 授权 ⊆ 前端实际用到的 `fs.*` 路径 + 明确豁免清单** ← 针对 P1-6

### 验收标准
- POSIX sh，不需要 ucode/node
- **每一条都反向验证过**（故意破坏 → 红 → 恢复）
- **先接上第 3 条，确认它能抓到当前这个 ECH bug**——抓不到就是守卫没写对

### 风险
中：守卫易耦合实现细节。**缓解**：从**数据/清单**派生断言（解析 switch 的 case 列表），
而不是匹配代码文本。

---

## 8. P1-2 发布路径加测试门

审计 §8.1。`build.yml:14-17` 在 tag/`workflow_dispatch` 触发，
**唯一检查**是 `--warn-below 100` 的 i18n，随后直接构建、上传、发布。
arch-test 只在 `push: [main]` 和 PR 上跑。分支保护不可用（`gh api` → 403）。
**漏洞**：给非 main 分支打 tag、或 dispatch 任意 ref，都会发布套件从未验证过的 commit。

**计划**：A（推荐）让 build 依赖一次通过的全量测试——可复用 workflow，
或在打包前加一步 `sh tests/ucode/run.sh .`；B 用 `workflow_run` 门控。

**验收**：故意让套件失败后触发 tag → **发布不进行**；dispatch 未测试 ref → 拒绝或先测。

**注意**：`--warn-below` 在那一步是**刻意的**（打包不该被翻译缺口阻塞）。
这次加的是**测试门**，不是把 i18n 改成 fail——**两者各自的原意都要保留**。

---

## 9. P1-3 mock 副本同步守卫

审计 §8.1/§8.2。`mocks/homeproxy_fetcher.uc` 的 `redactUrl`、
`mocks/homeproxy.uc` 的 `isEmpty`/`decodeBase64Str`/`parseURL` 都是生产代码的**手抄副本**。
我逐行比对过：**当前忠实**，所以现在没漏检——但无机制保证明天还忠实，
而 `test_subscription_fetcher.uc` 的**安全断言**就是对着副本断言的。

**计划**：加一条**可失败的**同步断言（抽取两侧函数体、归一化、比对）。
`validate-data.sh:27-30` 的 `validation()` 是另一种——**故意**与生产不同（逼近而非等价），
**不**要求逐字节一致，而应**钉成受审的固定 fixture** 并在注释里写明它简化了什么。

**验收**：改生产 `redactUrl` 语义而不动 mock → 必须红；反向验证通过。

---

## 10. P1-4 i18n 门补 source→pot

`i18n-coverage.py:106-117` 只做 `.pot`→`.po`；**没有东西重新生成 `.pot` 与源码比对**。
加一条全新未翻译的 `_()`，门禁仍 724/724 退出 0。
`.github/rescan-translation.sh` **已存在但未被任何 workflow 引用**。

**计划**：CI 跑 rescan，断言 `po/templates/homeproxy.pot` 无变化。
**验收**：加新文案 → CI 红；文案 + 同步 `.pot`/`.po` → 绿。顺手修正 `README:143` 的措辞。

---

## 11. P1-5 `luci.homeproxy` 行为测试

审计 §8.3 的结构性根因：`tests/ucode/run.sh:63` 把它单独 `-c` 编译、**从不执行**。

> **存放 `certificate_write` 的那个文件，没有任何行为测试。**

**计划**：建一个能真正调用其 `call()` 的测试（沿用已有的路径重写/暂存手法）。
首批：`certificate_write` 四个合法名 + 非法名 + ECH 的 PEM 头校验；
`log_clean` 合法/非法 type；`connection_check` 非法 site；其余方法的返回形状。

**验收**：**在修 ECH 之前先写**，确认它能抓到当前 bug（红），再修（绿）。

---

## 12. P1-6 ACL 收紧

审计 §8.2（**推翻了我第一轮的结论**）。ACL 的 `file` 写授权管的是**浏览器会话**，
而后端 ucode 以 root 运行、写文件**不经过**这个 ACL。
前端只用 `fs.exec_direct(update_subscriptions.uc)` 与 `fs.read_direct(<log>)`，
**`grep fs.write` 零命中**。所以这 6 条是纯多余：
`resources/{direct,proxy}_list.txt` + `certs/{server_publickey,server_privatekey,client_ca,client_ech_conf}.pem`。
它们让仅有本应用 ACL 的**受限用户**能直接覆写 `server_privatekey.pem`，
**绕过 `certificate_write` 的校验**。

**计划**：删这 6 条，保留 4 条 `/tmp/homeproxy_cert_*.tmp`（`ui.uploadFile` 真正要写的）。
**验收**：四个上传按钮仍工作；用受限用户尝试 `fs.write` 到 `certs/` 应被拒。
**由 P1-1 的第 7 条守卫防复发。**

---

## 13. P1-7 RPC 失败回退不再断言假状态

审计 §7。`rpcCall` 的回退设计是对的，但调用方把"未知"当成"否"：

- 状态栏：`list` 失败 → 显示红色 **NOT RUNNING**，与"确实停止"无法区分
- `getBuiltinFeatures()` 回退 `{}` → `type` 候选项缩水 → 不在候选里的值
  **显示成第一个协议**，紧接着 Save & Apply 会把它**改写成 `direct`**（静默改协议）

**计划**：区分"未知"与"否"（哨兵值 + 渲染"未知/刷新失败"）；
`type` 列表在 cfgvalue 不在 features 过滤集内时，**把当前 cfgvalue 补回候选项**。

**验收（本条尤其要注意顺序）**：这块**没有任何现存测试覆盖**
（`luci-form-snapshot.js:233` 恒传完整 features、`:175` `rpc` 恒成功 → 回退分支从不执行）。
所以**先补一个能让回退分支跑起来的测试**，确认它在当前代码上**红**，再改。
**没有可失败的测试就不动这段代码**——这是本项目已确立的纪律。

---

## 14. P1-8 ~ P1-10

### P1-8 真机 CI 作业
`workflow_dispatch` 或带 label 触发，SSH 到 `.102`，走 `tests/runtime/` 的 stage + drive 模式。
**前提**：P1-9 的策略先落地，且**绝不在真机上执行 `apk` 写操作**（见审计 §0）。
密钥走 GitHub Secrets。验收：能手动跑通并在日志里看到真实结果；失败不破坏设备配置。

### P1-9 版本 / stage 策略
设备 `26.236.50544` vs 仓库 `27.911.1.14`；`/usr/bin/sing-box` 是 1.14.1 而 apk 记录 1.13.16-r1。
**倾向 B**：把"真机验证一律 stage 到 `/tmp`，从不安装"**显式写进文档**，
并做成 P1-8 作业的前置断言（版本不一致时明确提示而非静默通过）。
理由：A 需维护 feed；B 正是当前已用且有效的做法，显式化即可消除"基线不明"，
同时彻底关掉 `apk` 改写配置这条路径。

### P1-10 crontab `sed -i` 不对称
`migrate_config.uc:67` 改用 `hp_crontab_drop` 同样的临时文件写法，**不再吞错误**。
顺手核对 `update_resources.sh:106`（优先级更低）。
验收：非 busybox sed 环境下迁移能真正删掉条目，失败时有日志。

---

## 15. P2 剩余项

### P2-1 真空检查修复（**含我本会话写的那条**）
1. `frontend-rpc-inventory.js:72` 正则放宽为 `L\.resolveDefault\s*\(`，
   **并同时删掉** `client.js:665`、`server.js:147` 那两处冗余的
   `L.resolveDefault(getServiceStatus())`（无害空操作，但会让严格正则误报）。
   顺序：先删冗余 → 再放宽 → 确认仍绿。
2. `test_protocol_inventory.sh:169-176` 加 `check('parser produced types', length(parser_types) > 0)`。
3. `test_parser_flatten.uc:58-61` 的 `if (!flat) return;` 改为**报错**。

**注意教训**（审计 §8.1）：我当初的反向验证用的是正则硬编码的那个写法，
**是循环论证**。反向验证必须用**真实的回归形态**（`hp.rpcCall(...)`）。

### P2-2 fw4 渲染层进 CI
`test_firewall_template.sh:58-63` 打印 NOT RUN，`:91-105` 九条 nft 断言从未执行。
方案：toolchain 里加最小 `fw4` stub（或 golden 渲染产物 fixture）。
验收：CI 不再出现 NOT RUN，且改坏模板能被抓到。

### P2-3 低危安全项（各自独立、都很小）
- `capabilities/homeproxy.json` **去掉 `CAP_SYS_PTRACE`**（五组），
  回归验证 TUN/tproxy 仍可用。**上游继承，但要在这里修掉。**
- `E(tag, <裸字符串>)` 一律改为 `E(tag, {}, [ ... ])`
  （`homeproxy.js:734,837,839,842`、`client.js:1570,1616`、`node.js:776`、`status.js:196`）
- 大小上限：`acllist_write.content` ~1MB、`singbox_generator.params` ~255B、
  证书上传 ~64KB（显式 `lstat` 尺寸检查）。`node_parse` 已有 4096 的范例。
- `certificate_write` 暂存改到 root-only 0700 目录（如 `/etc/homeproxy/tmp/`），或用单 fd 读，
  消除 TOCTOU 与 /tmp 中的私钥暴露。

### P2-4 测试确定性
固定 `/tmp` → `mktemp -d`（`test_runtime_extraction.sh:51` 等；
`test_config_transaction.sh`/`test_ucode_grammar.sh` 已是对范例）；
`tests/run.sh:86-87` 的 `$REMOTE_DIR` 在远端 `rm -rf` 里加引号 + `ssh -o BatchMode=yes -o ConnectTimeout=10`。
验收：两个测试进程并行不再互相踩（当前实测两次并行均退出 1）。

### P2-5 JSON 资产与出厂配置校验
`menu.d/*.json`、`acl.d/*.json`、`capabilities/homeproxy.json`、`uci-defaults/*`
**从未被校验**——写坏的 ACL 会静默拒绝 RPC；`root/etc/config/homeproxy` 从未被解析。
验收：故意制造语法错误的 ACL → 测试必须红。

### P2-6 状态三件套（**必须先有守卫**）
`service_status`/`renderStatus` 在三个快照里**命中 0 次**。
**没有守卫就不动它。** 顺序：P1-1 守卫 + P1-7 的回退测试 → 确认能失败 → 再重构。

### P2-7 GridSection ×5 / 动态 load ×13
纯样板去重，收益中等。**排在前面的做完之后。**

### P2-8 代码卫生（§2.10.8 四项）
`runtime/config.sh`/`health.sh` 缺 `local`；`pgrep` 耦合 procd 命令文本；
dnsmasq 卸载不对称；custom 模式 `chown` 告警。逐项小改，各跑受影响测试。

---

## 16. P3 明确不做的事（含理由）

1. **浏览器人工回归**：agent 做不到，只能你做。这是**唯一**未覆盖的验证面，
   涉及 P0-1/P0-2 的端到端确认与 `(f)` 里 `null` vs 省略 `description` 那一处。
2. **并发 reload / 长稳 / watchdog 压测**：需要一套真机长稳环境，**当前收益不抵成本**；
   若真机出现"偶发回滚"，这是首选排查方向。
3. **TLS 证书块、额外设置块合并**：两侧 `depends` 本就不同，强合反增分支。理由在台账 `(f)`。
4. **为 `components/` 建新目录**：`b820aac` 已记录偏离理由。
5. **不动 `docs/architecture-review.md` 的历史记述**：文件已删，台账三处自述清楚。
6. **要求 mock 的 `validation()` 与 `/sbin/validate_data` 等价**：做不到也不必要，
   它是**替身**，要求是"钉住并被审"（§9）。
7. **把 LuCI 的 `stripTags` 换掉**：那会改框架契约。我们在自己的边界上修（§2）。

---

## 17. 建议推进顺序

```
P0-5 README 生产路由（一行）
  ▼
P0-2 decodeURIComponent 崩溃（必现，极小）
  ▼
P0-1 两个 XSS（转义函数 + 后端纵深防御 + 往返不变量测试）
  ▼
P0-4 ECH（P1-5 先写行为测试 → 确认抓到 bug → 再修）
  ▼
P1-6 ACL 收紧（极小）→ P1-1 Architecture Guard（第 3 条抓 ECH，第 7 条防 ACL 复发）
  ▼
P1-2 发布测试门 → P1-3 mock 同步 → P1-4 i18n 源扫描 → P2-2 fw4 stub
  ▼
P1-7 回退假状态（先补可失败的测试）→ P2-1 真空检查 → P2-5 JSON 校验
  ▼
P1-10 crontab → P2-3 低危安全 → P2-4 确定性
  ▼
P1-9 stage 策略 → P1-8 真机 CI 作业
  ▼
P2-6 状态三件套 → P2-7 样板去重 → P2-8 代码卫生
```

**为什么安全项最前**：P0-1/P0-2 是**用户可被真实伤害**的问题
（一个恶意订阅即可在管理员会话里执行代码；一个含 `%` 的 URL 即可让页面打不开），
而它们**都不卡任何人**。其余 P0 卡在你的决策/信息上。
**先把能自己做完且影响最实际的事做掉。**

**里程碑**
- **M1（安全与验证层）**：P0-1/P0-2/P0-4/P0-5 修完 + 守卫能抓到 ECH 这类缺陷 +
  发布门/副本同步/i18n 源扫描就位。这一版之后，"测试全绿"的含金量才与字面一致。
- **M2（真机可复现）**：stage 策略 + 真机 CI 作业，且不可能再改写设备配置。
- **M3（PHASE 8 收尾）**：状态三件套 + 样板去重，PHASE 表到 100% 或明确记录剩余不做项。

---

## 18. 需要你决定的三件事

1. **ECH：A 补后端（推荐，含 ECH 专用 PEM 校验）还是 B 删按钮？**
2. **设备上那 6 个节点 + `dns`/`server`/`subscription` 的信息你还留有吗？**
   - 留有 → 我先恢复 4 个 section（dry-run 先行），你再补其余
   - 没有 → 那三块只能重建，审计 §11.3 的"真机端到端"限制会持续存在
3. **XSS 的端到端确认**：我修完会给出浏览器里可以**手动粘贴**的最小验证步骤
   （一条订阅 URL / 一个 label 载荷），需要你确认一次"不再执行"。
   这是 agent 能力的硬边界，我不会替你声称已验证。

其余部分按上面顺序自行推进，不再逐项确认。
