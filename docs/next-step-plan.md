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
| **P0-6** | **生成器读错 UCI 路径 + 订阅更新器静默无效**（严重回归） | **P0** | 小 | 无 · 已完成✅ |
| **P0-1** | **两个 XSS**：label→弹窗标题、订阅 URL fragment→tab 标题 | **P0** | 小 | 无 · 已完成✅ |
| **P0-2** | `decodeURIComponent` 让节点页**整页渲染失败**（必现） | **P0** | 极小 | 无 · 已完成✅ |
| P0-3 | 真机配置善后：抢救 + 重建 | **P0** | 小 | 你提供节点信息 |
| P0-4 | ECH 上传修复（补后端含 ECH 专用校验） | **P0** | 小 | 无 · 已完成✅（方案 A） |
| P0-5 | README 把默认目标写成**生产路由器** | **P0** | 极小 | 无 · 已完成✅ |
| P1-1 | Architecture Guard（PR-07），含契约闭合性守卫 | P1 | 中 | 无 · 已完成✅ |
| P1-2 | 发布路径加测试门（tag 不再裸发布） | P1 | 小 | 无 · 已完成✅ |
| P1-3 | mock 副本同步守卫 | P1 | 小 | 无 · 已完成✅ |
| P1-4 | i18n 门补 source→pot | P1 | 小 | 无 · 已完成✅ |
| P1-5 | `luci.homeproxy` 行为测试（含 `certificate_write` 全分支） | P1 | 中 | 无 · 已完成✅ |
| P1-6 | ACL 收紧：删 6 条浏览器用不到的写路径 | P1 | 极小 | 无 · 已完成✅ |
| P1-7 | RPC 失败回退不再断言假状态（含 `type` 静默改写） | P1 | 中 | 无 · 已完成✅ |
| P1-8 | 真机 CI 作业（台账 §5 项 14） | P1 | 中 | 已建好；**需你加 `HP_SSH_KEY` secret** 才能真跑 |
| P1-9 | 版本对齐 / "只 stage 不安装" 策略落地 | P1 | 小 | 无 · 已完成✅ |
| P1-10 | crontab `sed -i` 不对称修复 | P1 | 极小 | 无 · 已完成✅ |
| P2-1 | 真空检查修复（含我本会话那条正则） | P2 | 小 | 无 · 已完成✅ |
| P2-2 | fw4 渲染层（改为在目标机上强制，而非 stub） | P2 | 中 | 无 · 已完成✅ |
| P2-3 | 低危安全项 + 后端复核遗留（#3-#6 已完成✅，余 #7-#12） | P2 | 小 | 无 |
| P2-4 | 测试确定性（并发两套套件互不干扰） | P2 | 小 | 无 · 已完成✅ |
| P2-5 | JSON 资产校验 + 出厂配置解析 | P2 | 小 | 无 · 已完成✅ |
| P2-3a | 后端复核 #8 订阅更新加锁 + 原子回滚 | P2 | 中 | 无 · 已完成✅ |
| P2-3b | 后端复核 #10 `tun_name` 未校验就进 nft | P2 | 小 | 无 · 已完成✅ |
| P2-3c | 后端复核 #11 `wget --header-file` 不存在（token 路径全废） | P2 | 小 | 无 · 已完成✅ |
| P2-3d | 后端复核 #12 一个畸形 `ss://` 中止整个更新 | P2 | 小 | 无 · 已完成✅ |
| P2-3e | 后端复核 #7 悬空引用改为具名诊断（**修复未经测试验证**） | P2 | 小 | 无 · 已完成（见说明） |
| P2-6 | PHASE 8 残留：状态三件套 | P2 | 中 | 无 · 已完成✅ |
| P2-7 | PHASE 8 残留：GridSection ×5（本就完成）/ 动态 load ×13（明确不做） | P2 | 中 | 无 · 已处理 |
| P2-8 | 代码卫生 §2.10.8 四项全部完成 | P2 | 小 | 无 · 已完成✅ |
| P3-1 | **浏览器人工回归** | P3 | 很小 | **只能你做** |
| P3-2 | 明确不做项 | — | — | 见 §16 |

---

## 1.5 P0-7 实机安装暴露的模块解析缺陷 —— 已完成✅

**这是"编译成包、装到真机"才暴露出来的**，本地套件跑了几个月都没看见。

### 现象
第一次把 workflow 编出的包装到测试机后，`init.d` 的生成器**完全跑不起来**：

```
Syntax error: Unable to resolve path for module 'homeproxy'
```

### 根因
ucode 解析**裸模块名**时，是相对**发起 import 的那个模块所在目录**去找的。
上游的脚本是**平铺**在 `/etc/homeproxy/scripts/` 下的，所以 `generate_client.uc`
和 `homeproxy.uc` 同目录，`import ... from 'homeproxy'` 天然解析得到。
而 PHASE 8 模块化把它们分进了 `config/`、`generator/`、`parser/`、`subscription/`，
于是 `config/model.uc` 里的裸 import 会去找 `config/homeproxy.uc` —— 找不到，
整个生成器编译失败。

后果：**真机上配好节点后服务永远起不来**（`reload_service` 生成失败即中止）。

### 为什么所有测试都没抓到
**每个测试 harness 都传了 `-L <scripts 目录>`** 才能定位到它的暂存树；
而生产环境的 `ucode -S <script>` 和 cron 的 shebang 调用**从不传**。
harness 提供了生产缺的东西 —— 与 P0-6（`UCICONFIG_DIR`）**完全同型**。

### 修复
21 处 `import ... from 'homeproxy'` 全部改成相对路径（`./` 或 `../`），
从根上不再依赖任何搜索路径，而不是逐个调用点补 `-L`。
三个 subscription 测试原本把模块平铺暂存、靠裸名解析，已改为镜像生产目录结构。

**新增守卫**（`tests/ucode/run.sh`）：用**不带 `-L`** 的方式跑
`generate_client.uc` 与 `update_subscriptions.uc`，断言模块解析。
反向验证：把任一 import 改回裸名 → 失败。

### 实机验证（`28.9.1.14-r2`）
- `ucode -S /etc/homeproxy/scripts/generate_client.uc`（**无 `-L`**，与 init.d 一致）→ 产出配置 ✓
- 订阅按 cron 方式（shebang）导入 **4 个节点**（anytls / hysteria2 / shadowsocks / vless）✓
- 服务启动：`running: true`、监听 5330/5331/5333(tcp) + 5332/5333(udp) ✓
- **隧道建立**：设备到节点 `199.168.136.128:56976` 有 ESTABLISHED 连接 ✓
- `reload` 走完 生成 → stop → start → 健康门 → known-good，日志 `Reload completed.` 无告警 ✓

---

## 2. P0-6 生成器读错 UCI 路径 + 订阅更新器静默无效 —— 已完成✅

**最严重的一项**：后端对抗性复核提出，我在**真机实测确认**。

### 是什么
两条**重构遗留的静默回归**。都不在本轮引入，但都被本轮带到了现在：

**① 生成器读一个不存在的 UCI 文件。**
`Loader.load(HP_DIR + '/config')` → `cursor('/etc/homeproxy/config')`。
ucode 的 `cursor(dir)` 把 `dir` 当 **confdir**，所以 `uci.load('homeproxy')`
去找 `/etc/homeproxy/config/homeproxy`。包只提供 `/etc/config/homeproxy`（conffile），
没有任何东西创建那个目录。于是 `uci.load()` 返回 null、每个 `uci.get()` 返回 null，
Loader 交出**纯默认值**：没有 main-out、没有 route/dns final、没有用户的端口和节点，
而且**不报任何错**——服务照常起来，只是什么都不代理。

来源：`11af0bd`（本轮之前）把正确的 `Loader.load()` 换成 `__LOADER_DIR__` 占位符，
其注释声称"生产上会被解释为相对的 /etc/config 路径"——**这个说法是错的**；
`0c67d77`（本轮）又把它改写成 `HP_DIR + '/config'` 而没质疑。

**② 订阅更新器是静默空操作。**
`update_subscriptions.uc` 从 `access_control.subscription` 读
`subscription_urls` / `filter_keywords`，而 `load_access_control()` 把这两个
直接放在 `access_control` 上（`loader.uc:303-304`）。两者恒为 `[]`，
于是 `if (!isEmpty(subscription_urls)) call(main)` 永远为假：
脚本退出 0、不打任何日志，**LuCI 的"更新节点"按钮与 cron 条目什么都不做**。

### 真机证据（不是只读代码）
```
Loader.load(sentinel dir)        -> routing_mode="SENTINEL_MODE" main_node="SENTINEL_NODE"
Loader.load('/etc/homeproxy/config') -> routing_mode="bypass_mainland_china" main_node="nil"
Loader.load('/etc/config')           -> 真实配置的值
```
更新器行为（真机跑真实脚本 + 一个不可达的订阅 URL）：
- **修复后**：日志 1 行 `Failed to update subscriptions: no valid node found.` → **main() 确实跑了**
- **还原 bug**：日志 **0 行** → 静默空操作

另外确认了 `cursor('/etc/homeproxy/config')` 在真机上取不到值，
而 `cursor('/etc/config')` 取得到；`/etc/homeproxy/` 下只有 `resources/` 与 `scripts/`。

### 修复
- `homeproxy.uc` 新增 `export const UCICONFIG_DIR = '/etc/config';`（挨着 `HP_DIR`），
  两个生成器改用它；测试改为改写这个常量（保持"不 sed 源文件"的分层缝隙）。
- 更新器改读 `loaded.access_control.subscription_urls` / `.filter_keywords`，
  与项目自己的模型测试所断言的形状一致。

### 守卫（都能失败，已反向验证）
- `tests/arch-guard.sh`（新建）：confdir 必须是 `/etc/config`、不得由 `HP_DIR` 推导、
  `Loader.load()` 只允许 `UCICONFIG_DIR` 或裸默认两种形态；
  更新器读的每个 `sub.<field>` 必须是 Loader 嵌在 `subscription` 里的键，
  且 `subscription_urls`/`filter_keywords` 必须从 `access_control` 读。
  **三条反向验证全部变红**（两种 UCI 路径写法 + 错误层级读取）。
- `tests/ucode/test_subscription_updater_runs.sh`（新建）：端到端驱动更新器。
  **在此之前没有任何测试执行过 `main()`**——这正是静默空操作能存活的原因。

### 为什么全套测试都没抓到
两条同一个原因：**每个测试都自己铺输入**，所以测试无法发现生产读的是另一个地方。
`test_generators.sh` 把 fixture 恰好铺在代码会看的位置；
模型测试断言的是**正确**的形状，反而让消费方的错误读取显得没问题。

### 验收
`tests/run.sh` 全绿（含新守卫与新测试），真机 `ALL TESTS PASSED`。

---

## 3. P0-1 两个 XSS（最紧急） —— 已完成✅

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

### 实施记录：一次差点写错的修复
我的第一版把两条路径都用**普通 HTML 转义**处理。**这是错的**，而且会让事情更糟：
弹窗标题那条路径上，`stripTags` 会把 `&lt;` **解码回** `<`，于是
`&lt;img onerror=...&gt;` 重新变成可执行标记；更糟的是，**今天安全的原始 `<...>`
（会被 stripTags 当标签剥掉）反而变成 XSS**——修复把安全的情况改成了不安全的。

正确做法是**两个 sink 两个转义**：
- `escapeHtml()` 给"只解码一次"的 tab 标题；
- `escapeTitleText()` 给经过 `stripTags` 的弹窗标题：**删掉尖括号 + 转义 `&`**，
  使得那次解码之后**不再有字面 `<` 存活**。代价是名字里真实的尖括号会消失。

这个错误是**测试的原始标签用例抓到的**（`rev2` 反向验证变红 5 项）。
另一条教训也记在这里：我第一版的"调用点检查"里**又套了一次转义**，
于是把"调用点忘了转义"这个 bug 完全掩盖了（`rev1` 一开始没抓到）。
所以现在测试里保留**两个独立断言**：一个测净化函数，一个测调用点。

### 我必须明说的限制
**上面测的是转义函数的性质，不是"浏览器里真的不执行了"。**
测试 harness 从不创建 DOM（审计 §8.3），所以端到端只能**由你在浏览器里确认一次**（P3-1）。
我会把这条记为"未端到端验证"，不会声称已修好。

---

## 4. P0-2 `decodeURIComponent` 崩溃（必现） —— 已完成✅

`node.js:555` 对畸形 fragment 抛 `URIError`，位置在 `render()` 里、`m.render()` 之前，
**整页渲染不出来**。已实测 `#%`、`#100%`、`#%zz` 三种都抛，且都被校验器放行。
`new URL(suburl)` 对非 URL 的 UCI 值抛 `TypeError`，同路径。

**计划**：把 554-559 包 `try/catch`，失败退回 `url.hostname` 或原串。
**验收**：单测三种畸形 fragment + 非 URL 值，断言不抛且退回预期值；反向验证（去掉 try/catch → 红）。
**这不是安全问题，是必现的功能故障**，所以与 P0-1 同批做但独立验收。

---

## 5. P0-3 真机配置善后

设备 `/etc/config/homeproxy` 现为 feed 默认值（78 行 / 8 section / 0 节点）。

- **不可恢复**：6 个节点 + `dns` + `server` + `subscription`
- **可恢复**：`infra`、`config`、`control`（含 LAN IP/MAC、WAN CIDR 清单）、`routing`

**计划**：①`--dry-run` 给你确认 → ②只覆盖那 4 个 section → ③你补回其余 →
④**立刻 `uci export homeproxy` 存档**，并把"改配置前必须先导出"写进运行说明。

**验收**：section 数与预期一致；存档非空；`/etc/init.d/homeproxy start` 的失败信息
（若因无节点而失败）必须指向缺节点，而不是别的。

---

## 6. P0-4 ECH 上传修复 —— 已完成✅

审计 §6。**复核补充了一条我漏掉的**：即使补上 case，
`homeproxy.uc:597-598` 的 `isValidPEM(content,false)` 只认
`-----BEGIN CERTIFICATE-----`，而 ECH config 是 `-----BEGIN ECH CONFIGS-----`。

### 决策与实施
按计划推荐的 **A（补后端）** 实施（你没干预，且 B 只是删功能；如你更想要 B，
回退成本很低，告诉我即可）：
- `luci.homeproxy` 新增 `case 'client_ech_conf'`；
- **但只补 case 不够**：`isValidPEM` 只认 `CERTIFICATE` 与 `(RSA|EC) PRIVATE KEY`
  标记，而 ECH config 是 `-----BEGIN ECH CONFIGS-----`，所以补了 case 也会被
  以"does not look like a correct PEM file"拒掉。把共用的 body 规则抽成
  `validatePEM()`，新增 `isValidECHConfig()` 提供自己的标记。
- 四条路径都在 `writeCertificate()` 里清理 staging 文件，所以 ECH 的
  `/tmp/homeproxy_cert_client_ech_conf.tmp` 不再残留。

**验收**：四个文件名各一例成功 + 非法名仍被拒 + ECH 的 PEM 头校验生效 +
tmp 文件在成功与失败路径上都被清理。**在 P1-5 的行为测试里写**，并先确认它能抓到当前 bug。

---

## 7. P0-5 README 指向生产路由器 —— 已完成✅

`tests/README.md:18-19` 写默认 `root@192.168.1.1`——**那是家里的生产路由器**，
而 `run.sh:20` 的默认是 `.102`，`run.sh:12-14` 明确警告这个 fallback 会把整个 checkout
解包到目标机上、**绝不能落在生产路由**。照抄 README 的示例就会发生这件事。
**一行文档，风险最实际。** 验收：README 全文无 `192.168.1.1`（或明确标注为"勿用"）。

---

## 8. P1-1 Architecture Guard（PR-07） —— 已完成✅

审计 §8.3 的六个盲区就是它的需求清单。**不卡任何人，且是后面所有改动的前提。**

> **已全部完成**：`tests/arch-guard.sh` 共 **7 组守卫 / 33 项检查**，全部静态
> （不需要 ucode/node/python），已接入 `tests/run.sh`。7 条需求逐条对应：
> ① guard 4（ACL↔方法表双向）② guard 5（前端 rpcCall ⊆ 后端）③ guard 6（按钮↔case）
> ④ guard 5 后半（每个方法都被测试引用）⑤ guard 7（语义层不碰 UCI）
> ⑥ guard 4 的野字符号检查 ⑦ guard 3（ACL 文件授权 ⊆ 前端 fs.* 实际用法）。
> **7 组全部反向验证过**，见下节「反向验证清单」。
>
> 另外记录了**两条写错并真空通过的守卫**（用 `comm` 传 shell 变量、在错误的文件里
> 找 `object: 'service'`）——都已修正，现在都能在条件真被破坏时变红。

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

## 9. P1-2 发布路径加测试门 —— 已完成✅

审计 §8.1。`build.yml:14-17` 在 tag/`workflow_dispatch` 触发，
**唯一检查**是 `--warn-below 100` 的 i18n，随后直接构建、上传、发布。
arch-test 只在 `push: [main]` 和 PR 上跑。分支保护不可用（`gh api` → 403）。
**漏洞**：给非 main 分支打 tag、或 dispatch 任意 ref，都会发布套件从未验证过的 commit。

**计划**：A（推荐）让 build 依赖一次通过的全量测试——可复用 workflow，
或在打包前加一步 `sh tests/ucode/run.sh .`；B 用 `workflow_run` 门控。

**实施**：把 `arch-test.yml` 变成可复用 workflow（加 `workflow_call:`），
`build.yml` 新增 `test` job 调用它，`build` 用 `needs: [test]` 依赖。
**复用定义而不是抄步骤**——CI 复核指出 `arch-test.yml` 本来就手抄了 `run.sh` 的步骤，
再抄一份只会分叉。

**已验证（真跑了一次）**：`gh workflow run build.yml`（不带 version，只构建不发布）→
`test / arch-test` 先 **completed success**，`build` 才从 queued 开始 —— 门是真实生效的。

**注意**：`--warn-below` 在那一步是**刻意的**（打包不该被翻译缺口阻塞）。
这次加的是**测试门**，不是把 i18n 改成 fail——**两者各自的原意都要保留**，已保留。

---

## 10. P1-3 mock 副本同步守卫 —— 已完成✅

审计 §8.1/§8.2。`mocks/homeproxy_fetcher.uc` 的 `redactUrl`、
`mocks/homeproxy.uc` 的 `isEmpty`/`decodeBase64Str`/`parseURL` 都是生产代码的**手抄副本**。
我逐行比对过：**当前忠实**，所以现在没漏检——但无机制保证明天还忠实，
而 `test_subscription_fetcher.uc` 的**安全断言**就是对着副本断言的。

**实施**：没有用"抽取函数体比对文本"——副本**允许被重排**
（`redactUrl` 的副本就已经调整了语句顺序），所以文本比对会误报。
改成**行为等价测试**：`tests/ucode/test_mock_sync.sh` 用绝对路径同时 import
生产模块与两个 mock，在共享语料上比对返回值（46 项检查）。
`validation()` **刻意排除**（它就是替身），并由 `validate-data.sh` 顶部的
"PINNED FIXTURE, NOT AN EQUIVALENT" 注释列出它不覆盖哪些类型。
`validate-data.sh:27-30` 的 `validation()` 是另一种——**故意**与生产不同（逼近而非等价），
**不**要求逐字节一致，而应**钉成受审的固定 fixture** 并在注释里写明它简化了什么。

**反向验证**：把生产 `redactUrl` 的 query 脱敏删掉 → 5 项红；
把 `decodeBase64Str` 的 padding 修复删掉 → 1 项红。

**顺带发现并修掉一个真实隐患**：`validate-data.sh` 把两个参数**插值进 ucode 源码**，
所以含单引号的 hostname 会闭合字符串字面量 → ucode 语法错误 → 合法名字被判为 invalid。
改成走环境变量。真机验证：`a'b` → valid，注入尝试既不执行也不崩溃。

---

## 11. P1-4 i18n 门补 source→pot —— 已完成✅

`i18n-coverage.py:106-117` 只做 `.pot`→`.po`；**没有东西重新生成 `.pot` 与源码比对**。
加一条全新未翻译的 `_()`，门禁仍 724/724 退出 0。
`.github/rescan-translation.sh` **已存在但未被任何 workflow 引用**。

**实施**：CI 跑 `.github/rescan-translation.sh` 并断言 `po/` 无 diff。
**验收通过**：①当前树再跑一次 rescan → 无 diff（不会误报）；
②新增一条未翻译 `_()` → `po/` 变化 → 步骤失败，且 coverage 降到 99.9%。

**过程中发现两件必须先修的事**：

1. **`rescan-translation.sh` 会毁掉模板。** 它只判断 `[ -d "$LUCI_DIR" ]`，
   而本机的 `/Users/wjp/Downloads/luci`（luci 软件包 feed）**没有 `build/` 目录** →
   perl 失败 → 而 stdout 直接重定向进模板 → **`homeproxy.pot` 被清空**，
   而 coverage 门会高兴地报 `0/0 = 100%`。（我实际触发了一次，已 `git checkout` 还原。）
   现在：两个脚本都存在才用本地 checkout、扫到临时文件、空结果拒绝安装、
   从仓库根目录扫描（不再取决于调用者 cwd）、清理临时文件。

2. **协议名在 PHASE 8 重构中失去了可翻译性。** 表格里是 `label: 'Shadowsocks'`，
   而 `renderProtocolOptions` 用 `_(p.label)`（变量，扫描器看不见）→ 这些词条
   从模板里消失。13 个里 12 个的中文与原文相同（等于没翻译），但
   `Snell (1.14)` → `Snell（1.14）`（全角括号）**是真的翻译**，而且趋势是全部会慢慢失去翻译。
   现在改为在表格里 `_()` 包裹、使用点不再二次翻译；清单测试的 label 断言改为接受
   被翻译的 String 对象；**三个表单快照逐字节未变**。

**顺带说明**：`Traffic shaping mode`、`unsafe-raw`、`unshaped`、`v6 only.` 也离开了模板，
但这是**正确的**——它们由 `8cdf713` 从源码里删掉（sing-box 1.14 不接受那些拥塞控制值），不是丢失。
两条新文案已翻译。

---

## 12. P1-5 `luci.homeproxy` 行为测试 —— 已完成✅

审计 §8.3 的结构性根因：`tests/ucode/run.sh:63` 把它单独 `-c` 编译、**从不执行**。

> **存放 `certificate_write` 的那个文件，没有任何行为测试。**

**计划**：建一个能真正调用其 `call()` 的测试（沿用已有的路径重写/暂存手法）。
首批：`certificate_write` 四个合法名 + 非法名 + ECH 的 PEM 头校验；
`log_clean` 合法/非法 type；`connection_check` 非法 site；其余方法的返回形状。

**验收**：**在修 ECH 之前先写**，确认它能抓到当前 bug（红），再修（绿）。

---

## 13. P1-6 ACL 收紧 —— 已完成✅

审计 §8.2（**推翻了我第一轮的结论**）。ACL 的 `file` 写授权管的是**浏览器会话**，
而后端 ucode 以 root 运行、写文件**不经过**这个 ACL。
前端只用 `fs.exec_direct(update_subscriptions.uc)` 与 `fs.read_direct(<log>)`，
**`grep fs.write` 零命中**。所以这 6 条是纯多余：
`resources/{direct,proxy}_list.txt` + `certs/{server_publickey,server_privatekey,client_ca,client_ech_conf}.pem`。
它们让仅有本应用 ACL 的**受限用户**能直接覆写 `server_privatekey.pem`，
**绕过 `certificate_write` 的校验**。

**实施**：删掉这 6 条，保留 4 条 `/tmp/homeproxy_cert_*.tmp`。
（注：第一次我把理由写成 JSON 注释，那会让 ACL 解析失败——已改回纯 JSON，
理由记在提交信息、本文件与审计报告里。）

**由守卫防复发**：`tests/arch-guard.sh` 的 guard 3 从视图里的**按钮名**推导出
需要的 staging 路径，断言每个按钮都有授权、write-file 列表里**没有任何 `/etc/` 路径**、
且前端**没有 `fs.write` 调用**（这样将来真要用 `fs.write` 就必须同时改 ACL，
而不是继承一条陈旧授权）。两个方向都反向验证过：加回两条 `/etc/` → 红；
删掉某个按钮的 staging → 红。

---

## 14. P1-7 RPC 失败回退不再断言假状态 —— 已完成✅

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

## 15. P1-8 ~ P1-10

### P1-8 真机 CI 作业 —— 已完成✅（代码侧；真跑需你加 secret）
**已完成（代码侧）**：新增 `.github/workflows/on-target.yml`，仅 `workflow_dispatch`：
- 先有一道**拒绝生产路由**的硬失败闸（`192.168.1.1` 与 `192.168.1.1:22` 都拒，`.102`/`.10` 放行）——
  因为 staging 会把整份 checkout 解包到目标机上，而这套件绝不该落在路由器上；
- 密钥从 `secrets.HP_SSH_KEY` 读，`BatchMode` 下主机密钥用 `ssh-keyscan` 预热；
- 只调用 `tests/run.sh`（本 runner 没有 ucode/sing-box，自然走 ssh 分支）；
- **不含任何 `apk`/`opkg` 写操作**，并由 **guard 10** 保证以后也不会有人加进去
  （反向验证：往测试里塞一行 `apk add` → guard 指名文件与行号；注释行排除，
  否则 guard 会命中它自己那段解释）。

**未做端到端验证，而且在这里做不到**：作业需要一个仓库 secret `HP_SSH_KEY`，只有你能加。
它由三部分组成，三部分都各自验证过（YAML 可解析、路由闸真的拒绝、
`HP_TEST_HOST=… tests/run.sh` 就是本会话一直在对真机跑的那条命令）。
在 secret 存在之前，这个作业会在 "Set up the SSH key" 步停下并明确说明原因。

### P1-9 版本 / stage 策略 —— 已完成✅
设备 `26.236.50544~cb5d434` vs 仓库 `28.9.1.14-r1`；`/usr/bin/sing-box` 是 1.14.1。

**采用方案 B 并落地**：
- `tests/README.md` 新增「The staging policy: never install」一节，写明**规则与理由**
  （在真机上装包会跑包管理器，2026-09-15 就是这样把 `/etc/config/homeproxy` 覆写成 feed 默认值，
  6 个节点加 `dns`/`server`/`subscription` 不可恢复；staging 写的东西不出 `$HP_TEST_DIR`）；
- `tests/run.sh` 在 staging 前**打印两侧版本**，把两个代价显式化：
  **测的是 checkout，不是设备上装的东西**；设备上的 `sing-box` 是设备自带的那个。
  实测输出：`source 28.9.1.14-r1` / `target luci-app-homeproxy-26.236.50544~cb5d434` / `sing-box 1.14.1`。

**踩的坑**：第一版用双引号穿两层 ssh，目标机 shell 报 "unterminated quoted string"——
内层 `$(...)` 必须由远端求值，所以远端命令用单引号；`apk info -v` 打的是描述不是版本，
得用 `apk list -I`。

### P1-10 crontab `sed -i` 不对称 —— 已完成✅
**已完成**：改用临时文件 + `mv -f`（与 `hp_crontab_drop` 一致），
**只有两步都成功才设置标记**，否则 `warn` 并留待下次重试。

带出两个连带修正：
- mock 必须补 `shellQuote`（迁移测试 import 的是 mock，而我的改动用到了它）——
  这正是 mock 该有的"逐字副本"职责，`test_mock_sync.sh` 也随之从 46 项涨到 57 项。
- 迁移测试现在把 crontab 路径也重定向进沙箱（带硬守卫，与 cursor 重定向同款），
  并断言：旧行被删、无关行保留、标记被设置。

**验证（真机）**：PATH 里放一个拒绝 `-i` 的 `sed`（模拟 BSD sed）——
旧写法**留下旧行且错误被丢弃**，新写法删掉且保留无关行。
再把 crontab 目录设为只读让 `mv` 失败：**标记不被设置**，且不留临时文件。

---

## 16. P2 剩余项

### P2-1 真空检查修复 —— 已完成✅（**含我本会话写的那条**）
1. `frontend-rpc-inventory.js:72` 正则放宽为 `L\.resolveDefault\s*\(`，
   **并同时删掉** `client.js:665`、`server.js:147` 那两处冗余的
   `L.resolveDefault(getServiceStatus())`（无害空操作，但会让严格正则误报）。
   顺序：先删冗余 → 再放宽 → 确认仍绿。
2. `test_protocol_inventory.sh:169-176` 加 `check('parser produced types', length(parser_types) > 0)`。
3. `test_parser_flatten.uc:58-61` 的 `if (!flat) return;` 改为**报错**。

**已完成，三条都反向验证过**：
1. 正则放宽为 `L\.resolveDefault\s*\(`，并**自测**两种写法都能匹配（防止守卫本身失效）；
   同时删掉两处冗余包装（`getServiceStatus()` 从不 reject，而 `resolveDefault` 会把它
   有意义的 `null` 变回 `undefined`）。
   **反向验证用的是真实形态 `L.resolveDefault(hp.rpcCall(...))`**，并**断言旧正则匹配不到它**——
   这正是当初循环论证的那一步。
2. 加 `check('the parser produced at least one type to cross-check', length(parser_types) > 0)`；
   反向：把 parser-types.json 置空 → 92 checks / 1 failure。
3. `if (!flat) return;` 改为记失败；反向：放一个解析不了的样本 →
   "FAIL socks5: parse_uri() rejected a sample this test is meant to cover"，
   164 checks / 1 failure（原来是 173 checks / 0，安静地少检了几个）。

### P2-2 fw4 渲染层 —— 已完成✅（采用了与复核建议不同的方案）

**原方案（stub fw4）没有采用。** 复核建议加最小 `fw4` stub 让第二层在 CI 也能跑。但：
- `utpl` **不是**障碍——它由 ucode 包提供，而 toolchain 本来就构建 ucode；
  真正缺的只是 firewall4 的 `/usr/share/ucode/fw4.uc`；
- 用 stub 渲染，断言的就是**真 fw4 从未产出过的规则集**——这正是该测试头部原本
  写明的顾虑。（我确实写了一个 stub，然后**删掉了**，不留死代码。）

**实际做法（把静默跳过变成强制）**：新增 `HP_REQUIRE_FW4=1`，把"跳过"变成"失败"；
`tests/run.sh` 的 **ssh 分支**设置它——因为**目标机一定有 firewall4**。
于是"唯一能跑这一层的环境"必须跑；某天某台目标机解析不到 fw4，会**失败**而不是
安静地 NOT RUN。理由写进了脚本头部与 `tests/README.md`。

**验证**：目标机上 `HP_REQUIRE_FW4=1` → 渲染层真的执行并 PASS。
**反向验证**（PATH 里放一个必然失败的 `ucode`）：不带 flag → 仍然 NOT RUN 且 exit 0；
带 flag → **exit 1**。

### P2-3 低危安全项与后端复核遗留

> **进度（用真实订阅地址验证过）**：后端复核的 12 项里已修完 **#1 #2 #3 #4 #5 #6**
> （#1/#2 见 P0-6，#3 见下），剩余 **#7 #8 #9 #10 #11 #12**。
>
> 真机端到端（全程沙箱，未触碰设备配置）：
> 抓取 804 字节 → 解码 4 个节点 → 解析 → 仓库写入 **4 个独立 section** →
> 生成器输出 → **目标机自带的 sing-box 1.14.1 `check` 通过**。
> 第二次运行同一订阅：**0 added / 0 removed**（不再反复删建）。
>
> **#3 `wget --max-filesize` 已完成**：busybox wget 没有这个选项，
> 它在**发出请求之前**就以 "unrecognized option" 退出 2 ——
> 我在 `d9a4dac` 那次"加抓取体积上限"的安全加固里引入的，
> 结果是**每一次订阅抓取都失败**。现改用 `head -c`（busybox 支持）在管道上截断；
> 管道需要 `{ ...; }` 分组，否则 `executeCommand` 追加的 `>out 2>err`
> 只作用于管道最后一个命令，wget 的 stderr 会逃到调用者终端（这个坑是测试抓出来的）。
> 真机验证：真实抓取 1333 字节无错误；把上限降到 200 字节时正确报
> "response exceeds the 200 byte limit"。
> 守卫：`test_homeproxy_utils.uc` 现在断言"失败不是用法错误"——
> 这正是一条能抓住此类问题的测试（抓取器自身的测试 mock 掉了 `wGETVerbose`）。
>
> **#4 已完成**：`generator/outbound.uc` 用了 `get_resolver()` 却没有 import，
> ucode 报 "access to undeclared variable" 直接终止生成——但只在自定义
> `routing_node` 设了 `domain_resolver` 时触发（UI 提供该选项，且**没有任何 fixture 覆盖**）。
> 已补 import，并让 `custom.uci` 设置该选项。
>
> **#5 已完成，且比复核描述的更严重**：复核说是"churn + 日志错"，
> 实际是**多节点塌缩成一个损坏的 section**——`repository.uc` 用
> `md5(grouphash + node.label)` 当 section 名，而 `normalize()` 只给 `name`，
> `label` 恒为 null → 同一订阅的**所有节点算出同一个 section 名** →
> 4 个节点写进 1 个 section，出现 `type 'anytls'` 却带着 shadowsocks 密码套件和
> vless flow 的混合体。已修（编排器带上 label + 仓库改为 `label || name`），
> 并把测试里那个**不忠实**的 `canonical_node` 助手（它自己补了 `label`，
> 这正是 bug 被掩盖的原因）改成与 `normalize()` 一致。
>
> **#6 已完成**：vmess 丢 `packet_encoding`；golden 快照把缺失锁住了，
> 重新生成后恰好只多出 `"packet_encoding": "packetaddr"`——**这个 diff 就是证据**。

### 本轮追加完成的后端复核项（#7 #8 #10 #11 #12）

- **#8 已完成**：订阅更新器的回滚改为**写临时文件 + `mv`**（原来 `writefile` 先截断，
  中途崩溃就把 `/etc/config/homeproxy` 留成半截）；并加了 **`mkdir` 锁**，
  cron 与 LuCI 按钮不会再交错提交。锁超过 10 分钟视为被遗弃并打破（被杀掉的进程
  没法自己清理），否则一次崩溃会永久堵死所有更新。ucode 没有 `finally`，两条路径都显式释放。
  **踩到三个只有跑起来才会发现的问题**：`getTime()` 是格式化函数不是时钟，
  `getTime() - st.mtime` 得到 NaN 所以过期检查从不触发（应该用 `time()`）；
  `acquire_lock()` 一开始被插在 `log()` 定义之前，而 ucode **不提升函数声明**，
  运行时报"access to undeclared variable"；测试里 `TUN_NAME` 没重置，污染了后面的场景。
- **#10 已完成**：`tun_name` 是 UCI 值，直接插进 fw4 以 root 加载的 nft 文件；
  `;` 与 `}` 不需要换行，所以可以凭空加一条 chain。同一个文件**已经**校验了 server 的
  port 与 network，唯独漏了它。现在按接口名规则（≤15 字符、`[A-Za-z0-9_.-]`）校验，
  不合法就 warn 且不产出规则。**反向验证很直观**：去掉校验，payload 原样出现在生成的规则里。
- **#11 已完成**：`--header-file` 两个 wget 都没有 → 配了 GitHub token 就问不到版本。
  改用 `--header`（真机验证：`--header-file` 退出 2，`--header` 正常发出请求）。
  代价是 token 进 argv（wget 没有文件式 header 选项），已在源码里写明这个取舍。
- **#12 已完成**：`ss://` 的 userinfo 里 base64 非法时 `decodeBase64Str` 返回 null，
  `split(null)` 是 null，取 `[0]` 抛 ReferenceError；`parse_uri` 不捕获，
  而 `update_subscriptions.uc` 会捕获——于是一个坏链接中止整次更新。
  **先复现**（"left-hand side expression is null" @ `ss_userinfo[0]`），再加保护并补两个用例。
- **#7 完成但未经测试验证**：给两处 null 解引用加了具名 `die()`。
  我试了两个 fixture（`main_node` 指向不存在的 section、`routing_node.node` 指向不存在的节点），
  **都到不了那两行**——生成器退出 0 并跳过。我把两次尝试都**删掉了**，
  而不是留下一个永远通过的测试。守卫严格优于 null 解引用，但它是**未经验证**的，提交信息里也这么写了。

### P2-3 低危安全项（其余）
- `capabilities/homeproxy.json` **去掉 `CAP_SYS_PTRACE`**（五组），
  回归验证 TUN/tproxy 仍可用。**上游继承，但要在这里修掉。**
- `E(tag, <裸字符串>)` 一律改为 `E(tag, {}, [ ... ])`
  （`homeproxy.js:734,837,839,842`、`client.js:1570,1616`、`node.js:776`、`status.js:196`）
- 大小上限：`acllist_write.content` ~1MB、`singbox_generator.params` ~255B、
  证书上传 ~64KB（显式 `lstat` 尺寸检查）。`node_parse` 已有 4096 的范例。
- `certificate_write` 暂存改到 root-only 0700 目录（如 `/etc/homeproxy/tmp/`），或用单 fd 读，
  消除 TOCTOU 与 /tmp 中的私钥暴露。

### P2-4 测试确定性 —— 已完成✅
**已完成，并且跑了验收**：同时启动两套 `tests/run.sh`，**两边都 exit 0、都 ALL TESTS PASSED**。
修复前每次至少一边失败，而且失败点会变——一共暴露了**五处共享路径**：

1. 子套件默认用固定工作目录（`/tmp/hp-ucode-tests`、`/tmp/hp-runtime-trace`）→ 互相删暂存。
   现在 `run.sh` 建一个 `mktemp -d` 工作根往下传，并在退出时清理。
2. ssh 暂存目录固定 `/tmp/hp-tests` → 一边把另一边的 checkout 删掉（"could not stage the tests"）。
   现在由工作根派生，`HP_TEST_DIR` 仍可覆盖，远端目录也在同一个 trap 里清理。
3. **远端调用没传工作目录** → 即使暂存目录独立，设备上的 `/tmp/hp-ucode-tests` 仍是共享的。
4. `test_runtime_extraction.sh` 现在默认 `mktemp -d` 并用 trap 清理（它有两个调用方，其中一个不传参数）。
   —— 我第一次把清理语句插进了某个提前退出分支的中间；trap 覆盖所有路径。
5. `test_firewall_template.sh` 每次运行泄漏一个 `mktemp -d`——测试机上已累积 **50 个**。

顺带：`ucode/run.sh` 的语法错误输出写死 `/tmp` 名字，两次运行会互相覆盖。
`$REMOTE_DIR` 在远端 `rm -rf` 里加了引号，ssh 加了 `BatchMode`/`ConnectTimeout`（否则主机密钥或密码提示会永久挂住）。

**剩下一个无法消除的共享资源**：`/tmp/etc/dnsmasq.conf.hp_test`。
它的**路径本身是语义的一部分**（dnsmasq 的 section 名由文件名派生），不能挪进工作目录
——我试过，trace 立刻变了，测试正确地失败了。现在并发运行通过**原子 `mkdir` 锁 + 有限等待**排队；
不用 `flock` 是因为 macOS 没有，而这套件也要能在开发机上跑。

### P2-5 JSON 资产与出厂配置校验 —— 已完成✅
**已完成**：
- `tests/json-assets.js`（68 项）：root/ 下所有 `.json` 可解析；menu.d 的 `view` action
  指向真实存在的视图文件；ACL 的名字与 menu.d 的 `depends.acl` 一致、有 read/write、
  方法名是字符串、**无野字符号、无重复**；capabilities 五组内容一致；
  `etc/config/homeproxy` 是合法 UCI 语法。
- `tests/ucode/test_factory_config.sh`（13 项）：把**出厂配置喂给真实的 Loader**。
  **第一版是真空的**——只断言 Loader 产出了 `routing` 对象，而它总会产出
  （缺 section 时用默认值），所以**把 section 改名也能通过**。改为从每个 section
  读一个**具体值**之后，同一个改名会让 3 项失败。

**反向验证（每类守卫一条）**：ACL JSON 语法错、menu action 指向不存在的视图、
`depends.acl` 不存在、capabilities 各组不一致、ACL 出现野字符号、UCI 语句畸形、
UCI 值未加引号、出厂配置 section 被改名 —— 全部变红。

### P2-6 状态三件套 —— 已完成✅
**已完成**：把「状态轮询是否已注册」这个模块级状态从两个视图里抽到
`hp.statusPoller()`（接收 `poll`/`read`/`paint`，返回注册函数）。

为什么这才是关键：这个布尔是**跨文件重复的状态**，而且是有承重的——
每次 `render()` 只要越过它就会再加一个轮询 handler，而 LuCI 会全部保留，
于是每次 UCI 写入都会多排一次状态查询。抽成"接收协作者、返回注册函数"之后，
**"只注册一次"这个性质才能被断言**（快照永远到不了这段代码，这正是当初把它列为
"先补守卫再动"的原因）。

测试调注册函数三次，断言只加了一个 handler，并断言调用它会真的 `read()`——
所以"注册了个空函数"也会被抓到。视图只留下真正属于它们的部分（元素 id 与 `renderStatus`）。

**验证**：新增 5 项（共 38 项）；三个表单快照逐字节一致；
反向验证——把注册函数改成无视自己的标志 → 3 项红（`3 added`）。

### P2-7 PHASE 8 残留：GridSection / 动态 load —— 已处理（一半本就完成，一半明确不做）

**逐项核查后，这一项不需要再做新工作。**

**GridSection ×5 —— 早已完成。** 共享的 `hp.renderSectionAdd` 在 `homeproxy.js` 里，
5 处调用点（`client.js` ×4、`server.js` ×1）都用 `L.bind(hp.renderSectionAdd, …)`；
这是 PHASE 8 早先那一批做的。

**`node.js` 那一处不是重复，不能合。** 我本打算一起换掉，先读了一遍，发现它除了同样的
UCI 名校验，**还多挂了一个「Import share links」按钮和 `handleLinkImport` handler**。
换成共享版本会**把这个按钮删掉**——那是行为回归，不是去重。
计划当初把它与"TLS 证书块两侧 depends 本就不同"并列，判断是对的。

**动态 load ×13 —— 明确不做。** 这 13 处 `so.load = function(section_id) { … }`
形态确实相似（清 keylist/vallist → 若干静态 `this.value()` → `uci.sections(type)` 里按
`enabled === '1'` 收 `value(name, label)` → `super('load')`），但：

- **没有任何测试调用 `.load(`**（全仓库 grep 为 0），快照 harness 停在选项树、到不了这些回调；
- 也就是说动它们等于**在零覆盖下改 13 处加载逻辑**，而各处的过滤条件并不统一
  （有的带 `res['.name'] !== section_id`，有的按 type/grouphash 过滤，静态项数量各异）；
- 真要做得先补守卫：驱动 `load()`、给 `uci.sections` 喂假 section、断言 `vallist`。
  那是另一件独立工作，不该夹在"去重"里做。

按本项目既定纪律——**没有守卫就不动零覆盖的代码；宁可留着不做，也不做无法验证的改动**——
这一半记在此处，不做。

### P2-8 代码卫生（§2.10.8 四项） —— 已完成✅
四项全部完成：

1. **`local` 缺失**：写了个脚本逐函数比对「声明 vs 赋值」，比计划更准确——
   `config.sh` 三个事务函数确实缺（已修）；**`dns.sh` 的 `hp_dnsmasq_write_snippets`
   也缺**（`server=` 泄漏成全局，而已在修）；`health.sh` **其实没缺**
   （`HP_HEALTH_LISTENER_WARNED` 是故意导出的一次性提示，`DNSMASQ_DIR` 是故意全局的计算产物）。
2. **pgrep 与 procd 命令文本耦合**：加了 **guard 9** 把两者绑在一起——
   任一侧改成别的写法就红。反向验证两个方向都做过。计划里说的正是"加一条断言把两者绑在一起测"。
3. **dnsmasq 卸载不对称**：`remove_snippets` 原来无条件 `rm -rf` + 重启 dnsmasq，
   即使 `start` 从未写入（`main_node == nil` 的正常情况）。现在两者都不存在时直接返回，
   不做无意义的删除与重启（重启会白白清空所有客户端的 DNS 缓存）。
4. **custom 模式 chown 告警**：`cache.db` 只在 `bypass_mainland_china` 下创建，
   而旧代码无条件把它列进 chown，于是 custom 模式**每次启动**都报
   "failed to change the ownership of the runtime files"。改为逐路径 chown、不存在就跳过、
   存在的失败才具名报告。

**测试**：runtime trace 新增第 5 个场景（custom 模式）——此前**没有任何场景覆盖 custom**，
这正是那条告警能活过整轮重构的原因。golden 从 830 行长到 965 行，
diff 只含三处：逐路径 chown、少一次 dnsmasq 重启、新场景。两个修复都反向验证过。

**两次"锚点选错"的教训**（同一个文件上第二次）：新增场景时我用 `rm -f "$DNSMASQ_CONF"`
作锚点，而它**先出现在某个失败分支里**，于是场景被插进 `if` 分支内部、从不执行——
这就是 838 行的 golden 只带 4 个场景的原因。而场景 E 的断言读 `TRACE.norm`，
我第一版把它放在了该文件**生成之前**，所以它一直**真空通过**。都已修正。

---

## 17. P3 明确不做的事（含理由）

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
8. **`node.js` 的 `renderSectionAdd` 并入共享实现**：它不是重复——除同样的 UCI 名校验，
   它还多挂「Import share links」按钮与 handler。合并等于删功能（见 P2-7）。
9. **13 处动态 `load` 回调去重**：没有测试调用 `.load(`，快照停在选项树，
   零覆盖下改 13 处加载逻辑不可验证。要做先补守卫（见 P2-7）。

---

## 18. 建议推进顺序

```
P0-6 生成器 UCI 路径 + 订阅更新器（两条静默回归）   ✅ 已完成
  ▼
P0-5 README 生产路由（一行）                          ✅ 已完成
  ▼
P0-2 decodeURIComponent 崩溃（必现，极小）            ✅ 已完成
  ▼
P0-1 两个 XSS（两个 sink 两个转义 + 双解码不变量测试）  ✅ 已完成
  ▼
P0-4 ECH + P1-5 行为测试（先写测试 → 确认抓到 bug → 再修）  ✅ 已完成
  ▼
P1-6 ACL 收紧 ✅ → P1-1 Architecture Guard（7 组 / 33 项，全部反向验证）  ✅ 已完成
  ▼
P1-2 发布测试门 ✅ → P1-3 mock 同步 ✅ → P1-4 i18n 源扫描 ✅ → P2-2 fw4 渲染层 ✅
  ▼
P1-7 回退假状态（先补可失败的测试）  ✅ 已完成
  ▼
P2-1 真空检查 ✅ → P2-5 JSON 校验 ✅
  ▼
P1-10 crontab ✅ → P2-3 后端复核 #7-#12 大部分 ✅ → P2-4 确定性 ✅
  ▼
P1-9 stage 策略 ✅ → P1-8 真机 CI 作业 ✅（待 secret）→ P2-6 状态三件套 ✅
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

## 19. 需要你决定的三件事

1. **ECH：A 补后端（推荐，含 ECH 专用 PEM 校验）还是 B 删按钮？**
2. **设备上那 6 个节点 + `dns`/`server`/`subscription` 的信息你还留有吗？**
   - 留有 → 我先恢复 4 个 section（dry-run 先行），你再补其余
   - 没有 → 那三块只能重建，审计 §11.3 的"真机端到端"限制会持续存在
3. **XSS 的端到端确认**：我修完会给出浏览器里可以**手动粘贴**的最小验证步骤
   （一条订阅 URL / 一个 label 载荷），需要你确认一次"不再执行"。
   这是 agent 能力的硬边界，我不会替你声称已验证。

其余部分按上面顺序自行推进，不再逐项确认。
