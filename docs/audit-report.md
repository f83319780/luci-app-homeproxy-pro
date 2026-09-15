# 审计报告 — luci-app-homeproxy-pro

- **审计对象**：`github.com/szwjp/luci-app-homeproxy-pro`
- **审计基线**：`b820aac`（本轮 53 个 commit 之后）
- **工作树**：干净，`main == origin/main`
- **方法与边界**：见 §1。**本文是时点快照，不取代 `docs/architecture-improvement-plan.md` 的台账地位**；
  该台账仍是实现细节的权威，本文的结论在被处理后才回写台账。

---

## 0. 必须先说的一件事：测试机配置丢失

在把仓库同步到测试机（`192.168.1.102`）验证 P0 修复时，我执行了 `apk add luci-app-homeproxy`。
这个动作按 feed 的包定义覆盖了 `/etc/config/homeproxy`，替换成 feed 默认值（78 行 / 8 section / 0 节点）。

**不可恢复**：6 个节点，以及 `dns`、`server`、`subscription` 三个 section。
备份目录 `/root/hp-pr05-backup` 已不存在；PVE 上 VM 200/201 既无快照也无 vzdump。

**已抢救**：`infra`、`config`、`control`、`routing`——其中 `control` 包含真实的
LAN 直连 IP/MAC 与 WAN 直连/代理 CIDR 清单。抢救脚本
`/Users/wjp/Downloads/homeproxy-config-salvage.sh`（已 dry-run 验证），**尚未执行**。

**这是我的操作错误。** 根因两条：
1. 在有状态的真实配置上执行了会改写配置的包管理命令，且没有先 `uci export` 备份。
   这台是测试机，但它承载的是**真实节点配置**，不是一次性环境。
2. 我用"这是测试机"替代了"这一步是否可逆"的判断。测试机的**代码**可以随便换，
   但**配置**是数据——换代码的路径不应该经过配置。

**后果**：订阅自动更新、DNS 分流、服务端入站三块目前**无法在真机做端到端复现**。
这不阻塞仓库侧开发（套件不依赖真机状态），但阻塞"改完在真机确认行为"这类验证。

---

## 1. 审计范围与方法

**读过的**：27 个 `.uc`（6225 行）、10 个 `.sh`（1128 行）、`htdocs/` 4305 行前端、
57 个测试文件、3 份纲领文档（3915 行）。逐文件通读，非抽样。

**构造验证的**：架构边界逐条 grep + 反向搜索；ACL 与后端方法表双向差集；
后端 `writefile()` 目标 vs ACL 文件清单；`shellQuote` 每个调用点；
生成器/解析器/适配器内 UCI 符号命中；本会话删改符号的悬空引用；
文档反引号路径逐个 `os.path.exists`；每条守卫能否失败（读实现找反向用例）。

**独立对抗性复核**：三个 subagent 从不同角度独立审计，与我并行、互不可见。
**三路全部返回并已并入本文**（§8），每一项我都自己复验过，不是转述。

**没有做的**（明确声明）：浏览器人工执行、真机端到端、并发/长稳、cgi-upload 的 open flags（仓库外）。

---

## 2. 结论摘要

| # | 级别 | 问题 | 位置 |
|---|---|---|---|
| 1 | **严重** | **远程订阅 label → 存储型 XSS**（LuCI `stripTags` 解码实体） | `homeproxy.js:793` + `node.js:681` |
| 2 | **高** | **订阅 URL fragment → 打开页面即 XSS** | `node.js:557,679` |
| 3 | 中高 | `decodeURIComponent` 抛 `URIError` → **整个节点页渲染失败** | `node.js:555-557` |
| 4 | **高** | ECH 上传按钮必然失败 | `luci.homeproxy:146-157` ↔ `node.js:459` |
| 5 | **高** | 发布路径（打 tag）**不经过任何测试** | `build.yml:14-17` |
| 6 | **高** | 测试断言在**生产代码的副本**上 | `mocks/*.uc`、`validate-data.sh` |
| 7 | 中高 | i18n 门**看不见新字符串** | `i18n-coverage.py:106-117` |
| 8 | **高（安全）** | README 把默认目标写成**生产路由器** | `tests/README.md:18-19` |
| 9 | 中 | RPC 失败回退**断言假状态**，可能静默改写 UCI `type` | `homeproxy.js:742`、`homeproxy.js:349-373` |
| 10 | 中 | ACL **过度授权**：6 条浏览器用不到的写路径 | `acl.d/...json:25-34` |
| 11 | 中 | `luci.homeproxy` **无行为测试**，仅 `-c` 编译 | `tests/ucode/run.sh:63` |
| 12 | 中 | fw4 渲染层在 CI **从不运行** | `test_firewall_template.sh:58-63` |
| 13 | 中 | 构造性真空检查 ×3（**含我本会话写的一条**） | `frontend-rpc-inventory.js:72` 等 |
| 14 | 低 | `CAP_SYS_PTRACE` 给了 jail 内非 root 的 sing-box | `capabilities/homeproxy.json` |
| 15 | 低 | `certificate_write` 固定 `/tmp` 暂存 + TOCTOU | `luci.homeproxy:112-120` |
| 16 | 低 | `E(tag, <裸字符串>)` 通知（HTML sink 构造） | `homeproxy.js:734` 等 |
| 17 | 低 | `acllist_write.content` / `singbox_generator.params` / 证书上传无大小上限 | `luci.homeproxy:67-97,194-241` |
| 18 | 低 | crontab 两套写法，一处静默失败 | `migrate_config.uc:67` |
| 19 | 记录 | 台账 §5 第 20 项陈旧（已修） | `b820aac` |
| 20 | **正面** | 架构边界、注入边界、无任意路径、UCI 键注入防护**全部干净** | §7 |

### 总体判断

**代码结构是健康的，安全和验证层不是。**

11 项正面核验（§7）支持"架构没被破坏、重构是行为保持的"这个判断——
但**最严重的两个问题都是安全问题，都不是重构引入的，而是上游继承 + 缺守卫**：

- **#1/#2 是同一个病**：一个来自**不可信远程源**的值，流过一层**看起来像净化、
  实际会解码**的框架函数，最后到达 `innerHTML`。
  LuCI 的 `stripTags()` 文档字符串自己写着 *"HTML tags removed, and HTML entities decoded"*——
  **它解码实体**，所以 `&lt;img src=x onerror=...&gt;` 出来就是可执行的 `<img>`。
- **#4 是另一个病**：前端假设的取值域与后端实现的取值域不一致，
  而**恰恰是承载它的那个文件没有任何行为测试**（#11）。

**这两个病在测试层是同一个根因**：快照测试 model 的是**形状**（选项树），
不是**行为**（DOM sink、后端分支）。所以它同时看不见 XSS 和后端 filename 分支——
§8.3 有独立复核给出的证据。

**优先级**：§0 数据善后 → #1/#2/#3（安全，且 #3 是必现的页面崩溃）→ #5/#6（验证层）→ 其余。

---

## 3. 严重：远程订阅可控的存储型 XSS

### 3.1 完整链路（每一环都读过真实源码）

**① 数据来自不可信远程源**（`parser/protocols.uc`）：

```ucode
label: uri.remarks,                        // :32   vmess，来自远程 JSON 的 ps 字段
label: url.hash ? urldecode(url.hash) : null,   // :51,68,93,124,147,167,215,... 其余协议
```

**② 原样写进 UCI**（`subscription/repository.uc:132-134`）：

```ucode
const flat = flatten(node);
uci.set(uciconfig, nameHash, 'node');
for (let v in keys(flat))
    uci.set(uciconfig, nameHash, v, flat[v]);   // label 在这里，无净化
```

**③ 前端读出来**（`homeproxy.js:793`）：

```js
loadModalTitle(title, addtitle, uciconfig, ucisection) {
    let label = uci.get(uciconfig, ucisection, 'label');
    return label ? title + ' » ' + label : addtitle;   // 普通字符串
}
```

绑定在 `node.js:681`（`s.modaltitle = L.bind(hp.loadModalTitle, ...)`），
`client.js:89/1008/1240/1368` 的 `routing_node`/`dns_server`/`ruleset` 同样。

**④ 框架"净化"它**——这是关键的假象（`luci-base/form.js:344-359`）：

```js
titleFn(attr, ...args) {
    ...
    s = this.stripTags(String(s)).trim();   // :353
```

```js
/* @returns {string}
 * The cleaned input string with HTML tags removed, and HTML entities decoded. */
stripTags(s) {
    if (typeof(s) == 'string' && !s.match(/[<>&]/))
        return s;
    const x = dom.elem(s) ? s : dom.parse(`<div>${s}</div>`);   // :309
    ...
    return (x.textContent ?? x.innerText ?? '').replace(/([ \t]*\n)+/g, '\n');
}
```

`dom.parse('<div>Node » &lt;img src=x onerror=alert(1)&gt;</div>')` 的 `textContent`
就是 **`Node » <img src=x onerror=alert(1)>`**——**实体被解码了**。
`stripTags` 去掉了标签，却把编码后的标签**还原成了真标签**。

**⑤ 落到 HTML sink**（`form.js:3875` → `ui.showModal(title, ...)`；堆叠路径走
`E('span', \` » ${title}\`)`）。终点在 `luci.js:1394-1396`：

```js
else if (children !== null && children !== undefined) {
    node.innerHTML = `${children}`;      // :1395  ← HTML sink
    return node.lastChild;
}
```

`dom.append(node, <普通字符串>)` 走的就是这一支：**字符串被当成 HTML 解析**。

**结论：`&lt;img src=x onerror=alert(1)&gt;` 形式的节点备注，在管理员点开该节点的
编辑/更多弹窗时执行**，运行在管理员已认证的 LuCI 会话里——对完整管理员而言等价于 root
（可调用所有写 RPC、改 UCI、改证书、应用配置）。

### 3.2 我复验了什么，没复验什么

**复验过**：三处前端源码（`homeproxy.js:793`、`node.js:681`、后端 label 写入路径）；
拉取了 `openwrt/luci` master 的 `form.js` 与 `luci.js`，确认 `stripTags` 的
**文档字符串明写 entities decoded**、`titleFn:353` 调用它、`form.js:3875-3876`
把结果交给 `title`、`ui.showModal(title, ...)`、以及 `dom.append` 的 `:1395` `innerHTML`。
也确认了**全仓库没有任何 label 净化函数**（`grep sanitiz|escapeHtml|encodeHTML` → 0 命中）。

**没复验**：没有浏览器，所以**没有实际触发过**。链路是读不可变框架源码推出来的，
不是观测到的。如果目标设备的 LuCI 版本 `stripTags`/`titleFn` 不同，需重查。
设备是 ImmortalWrt 25.12.1，其 LuCI 应属同源，但我没有在设备上比对过。

### 3.3 修复

在 label **进入标题之前**转义一次（必须对**原始** label 做，让 `stripTags` 解一次后留下文本）：

```js
label = label.replace(/&/g,'&amp;').replace(/</g,'&lt;')
             .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
```

注意这依赖 `stripTags` 会解码一次——**修的是"解码后仍安全"，不是"不要解码"**。
更彻底的做法是不让 label 走字符串标题通道（用 `E()` 节点），但那要改框架契约。
`loadModalTitle` 一处修好即可覆盖 4 个调用点。

**并且**：后端在写 UCI 时也不该原样存 label。纵深防御——**两侧都修**，
因为前端是唯一被验证的拦截点时，任何绕过前端的路径（别的脚本读 `label`）
都会重新打开这个洞。

---

## 4. 高：订阅 URL fragment → 打开页面即 XSS

`node.js:554-559`：

```js
for (let suburl of (uci.get(data[0], 'subscription', 'subscription_url') || [])) {
    const url = new URL(suburl);
    const urlhash = hp.calcStringMD5(suburl.replace(/#.*$/, ''));
    const title = url.hash ? decodeURIComponent(url.hash.slice(1)) : url.hostname;
    subinfo.push({ 'hash': urlhash, 'title': title });
}
```

`node.js:679` 把 `info.title` 放进 tab 标题：

```js
s.tab('sub_' + info.hash, _('Sub (%s)').format(info.title));
```

LuCI 的 tab 渲染把这个标题作为 `E('a', {href:'#',...}, title)` 的**裸字符串子节点**，
同样落到 `dom.append` 的 `innerHTML`（§3.1 ⑤）。

**已验证**（本地 node 实跑）：

```
new URL("https://e.com/#<img src=x onerror=alert(1)>")
  → hash "#%3Cimg%20src=x%20onerror=alert(1)%3E"
  → decodeURIComponent(...) → "<img src=x onerror=alert(1)>"
```

而校验器（`node.js:708-721`）只要求 `new URL()` 成功且有 hostname，**放行**这个 URL。
fragment 从不发给服务器，所以任何重定向都不会把它洗掉。

**触发条件比 #1 更糟**：**只需打开"节点设置"页面，不需要点击任何东西**。
一个分发订阅的对手（或任何一个你能从它那里订阅的人）即可投毒。

**修复**：不要把解码后的 fragment 当标题——只用 `url.hostname`，
或在 `s.tab()` 之前剥掉 `<>&"'`。

---

## 5. 中高：`decodeURIComponent` 让整个节点页渲染失败

`node.js:555` 的 `decodeURIComponent(url.hash.slice(1))` 对畸形转义**抛异常**，
而它在 `render()` 里、`m.render()` 之前，所以**整页渲染不出来**。

**已验证**（本地 node 实跑）：

```
https://h/p#%      → URIError: URI malformed
https://h/p#100%   → URIError: URI malformed
https://h/p#%zz    → URIError: URI malformed
```

这三种都被校验器接受（都有 hostname）。另外 `new URL(suburl)` 若 UCI 里存了非 URL
（任何其它脚本 `uci set` 过）会抛 `TypeError`，同样路径。

**这是必现的**，而且**不需要恶意**——一个有 `%` 的订阅 URL 就够。
修复：把 555-558 包 `try/catch`，失败时退回 `url.hostname` 或原串。

---

## 6. ECH 上传按钮必然失败

前端四个证书上传按钮共用一个 helper（`homeproxy.js:821`），第四个传
`client_ech_conf`（`node.js:459`）；后端 `certificate_write` 的 switch
**只有三个 case**（`luci.homeproxy:146-157`），落 `default` 返回
`illegal cerificate filename`。**100% 必现。**

**归属**：前端按钮与后端 switch **都来自 initial commit `1ff9d66`**（上游继承）；
**ACL 里的 ECH 路径是我本轮 `d9a4dac` 加的**。我当时没回头确认后端能不能写到那两个路径，
结果把"一个没人用成功的按钮"变成"ACL 明确授权了一条后端永远走不到的路由"，
并在 `homeproxy.js:832` 留下一条**当时不成立的注释**（说 ACL 列了四条就等于四条都实现）。
**教训：ACL 是前后端契约的一半，不是独立的安全配置项。**

**独立复核补充了一条我漏掉的**：即使补上 case，`homeproxy.uc:597-598` 的
`isValidPEM(content,false)` 要求 `-----BEGIN CERTIFICATE-----`，
而 ECH config 是 `-----BEGIN ECH CONFIGS-----`——**必须单独校验**，
否则补了 case 也只是把"文件名非法"换成"PEM 非法"。错误路径还会在 `rm -f` 之前返回，
`/tmp/homeproxy_cert_client_ech_conf.tmp` **永不被清理**。

**系统性排查**：ACL 的 ubus 方法表与后端**双向差集为空**（10/10，无野字符号）——
这是个例，不是一类的一部分。

**修复**：A 补后端（含 ECH 专用校验 + 清理 tmp）或 B 删按钮与 ACL 两条。倾向 A。

---

## 7. 中：RPC 失败回退断言假状态，可能静默改写 UCI

`rpcCall` 失败时返回 `options.fallback`（默认 `{}`，`homeproxy.js:718-740`）。这个设计本身是对的
（统一失败处理 + 每个方法只提示一次），但**调用方把"未知"当成了"否"**：

- **状态栏**（`client.js:27-36`、`server.js:42-51`）：`list` 失败 → `{}` →
  `try/catch` 吞掉 TypeError → `isRunning=false` → 显示红色 **NOT RUNNING**，
  与"确实停止"**无法区分**。（用户仍会收到 `rpcCall` 的失败通知，所以不是完全静默。）
- **`getBuiltinFeatures()` 回退 `{}`**（`homeproxy.js:742-744`）：`type` 这个 `ListValue`
  的候选项由 features 过滤（`homeproxy.js:349-373`）而缩水。
  `ui.Select.render()` 对不在候选里的值**不产出 `<option>`**，而
  `AbstractValue.parse()` 在 `formvalue != cfgvalue` 时会写回——
  于是 sing-box/RPC 失败时，一个 `type=tuic` 的节点**显示成第一个协议**，
  紧接着的 Save & Apply 会把 `type` **改写成 `direct`**。**静默改协议。**

**严重性判断**：这条是独立复核给的，我复读了 `rpcCall` 与两个调用点，
**机制成立**；但"显示成第一个协议"依赖 `ui.Select` 的具体实现，我未在浏览器验证。
按"可能导致静默数据改写"对待，排在 #1-#5 之后。

**修复**：区分"未知"与"否"（返回哨兵值，渲染"未知/刷新失败"而不是 NOT RUNNING）；
`type` 列表在 cfgvalue 不在 features 过滤集内时，**把当前 cfgvalue 补回候选项**。

---

## 8. 交叉印证：三路独立复核结果

三路 review 全部返回。**下表每一项我都自己复验过**，不是转述。

### 8.1 已并入的发现

| 发现 | 我的复验 |
|---|---|
| XSS 链（#1/#2） | 拉 `openwrt/luci` master 的 `form.js`/`luci.js`，确认 `stripTags` 文档字符串写 entities decoded、`titleFn:353`、`:3875` → `showModal`、`dom.append:1395` `innerHTML`；确认全仓库无 label 净化 |
| `decodeURIComponent` 抛错（#3） | 本地 node 实跑三种畸形 fragment → 全部 `URIError` |
| ECH 死代码（#4） | 见 §6；并确认 `isValidPEM` 只认 CERTIFICATE PEM（复核补充） |
| 发布路径无测试门（#5） | 读 `build.yml:14-17`（tag + dispatch）、`:44-48`（`--warn-below`）；`gh api .../branches/main/protection` → **403** |
| 测试断言在副本上（#6） | 归一化比对：`isEmpty`/`decodeBase64Str`/`parseURL` **IDENTICAL**、`redactUrl` 语义一致但重排；**无任何同步检查** |
| i18n 只做 pot→po（#7） | 读 `i18n-coverage.py:106-117`；`.github/rescan-translation.sh` **未被任何 workflow 引用**（grep 0 命中） |
| README 指向生产路由（#8） | `tests/README.md:18-19` 写 `root@192.168.1.1`；`run.sh:20` 默认 `.102`；`run.sh:12-14` 警告过绝不能用生产路由 |
| ACL 过度授权（#10） | **推翻了我自己先前的结论**，见 §8.2 |
| `luci.homeproxy` 无行为测试（#11） | `tests/ucode/run.sh:63` 把它单独 `-c` 编译，从不执行 |
| fw4 渲染层 NOT RUN（#12） | CI 日志确认打印 `NOT RUN: the 'fw4' ucode module is not available` |
| 真空检查（#13） | 读正则确认只匹配 `call*` 前缀；`L.resolveDefault(hp.rpcCall(...))` 不被抓到 |
| `CAP_SYS_PTRACE`（#14） | 读 `capabilities/homeproxy.json` 五组 + `service.sh:153` 的 jail 内非 root 客户端 |

### 8.2 我先前的一个结论是错的：ACL 确有过度授权

我在第一轮审计里写过"ACL 除此之外没有过度授权"，依据是"后端能不能写到这些路径"。
**这个判据是错的**：ACL 的 `file` 授权管的是**浏览器会话**通过 `fs.*` 能做什么，
而后端 ucode 以 root 运行、写文件**不经过**这个 ACL（它靠 ubus 方法名授权）。

按正确判据重查：前端**只用** `fs.exec_direct(update_subscriptions.uc)`（`node.js:773`）
与 `fs.read_direct(<log>)`（`status.js:157`）——**`grep fs.write` 零命中**。
所以这 6 条写授权是纯粹的多余：
`/etc/homeproxy/resources/{direct,proxy}_list.txt` 与
`/etc/homeproxy/certs/{server_publickey,server_privatekey,client_ca,client_ech_conf}.pem`。
它们让一个**仅有本应用 ACL 的受限用户**能直接覆写
`server_privatekey.pem`，**绕过 `certificate_write` 的 PEM/二进制校验**（`luci.homeproxy:121-130`），
也能清空两份域名列表。其中 `client_ech_conf.pem` 更是**连后端都没有写入者**（§6）。

**修正后的结论**：ACL 的 **ubus 方法表是精确的**（双向差集空、无野字符号、读写划分正确），
**file 表有 6 条过度授权**。修法：删掉这 6 条，保留 4 条 `/tmp/homeproxy_cert_*.tmp`
（那些是 `ui.uploadFile` 真正要写的）。

### 8.3 为什么测试层看不见 #1-#3：独立复核给出的机制

这一节是全报告最值得留存的部分——它解释了"为什么 57 个测试文件、全绿，
却放过了两个 XSS"：

| 盲区 | 证据 |
|---|---|
| **快照 mock 从不创建 DOM** | `luci-form-snapshot.js:29-31` 把 `E()` stub 成 `{tag, attrs, children}`，`:149` `form.Map.render()` 返回纯 JSON 树 → **`innerHTML`/`dom.append` 路径永不执行** |
| **它的 UCI mock 是空的** | `:152-160` 返回 `undefined`/空操作 → `uci.get(...,'subscription','subscription_url')` 恒空 → **`subinfo` 循环（`node.js:554-559,678-685`）从不运行**，tab 标题 sink 与 label 驱动的弹窗标题根本没被触达 |
| **函数被丢弃** | `:62-64` `if (typeof value == 'function') continue` → `validate`/`load`/`write`/`cfgvalue`/`render`/`onclick` 全部不被记录 |
| **`status` 不是快照目标** | `:219` 只有 node\|client\|server，无 `snapshots/status.json` → status.js 零快照覆盖 |
| **features 永远完整、RPC 永远成功** | `:233` 恒传完整 features；`:175` `rpc = () => Promise.resolve({})` → **`rpcCall` 的失败/回退分支在任何测试里都不执行**（§7 那条因此无从被发现） |
| **没有任何测试引用 RPC 方法名** | `grep <任一方法名> tests/` 零命中 → `certificate_write` 的 filename 分支、全部参数校验行为**未测试** |
| **没有测试读 ACL 文件** | 于是 ACL 漂移（§8.2、§6 的死授权）**结构性不可见** |

**这就是 #4 与 #1/#2 的共同根因**：测试 model 的是**形状**，不是**行为**。
`agent_guide` 的架构守卫（PR-07）至今未建，正是这个缺口的位置。

### 8.4 三路复核一致确认的"干净"项（与我的第一轮结论吻合）

- ACL **ubus** 方法表与 10 个方法精确匹配，无野字符号、无缺失、无幽灵、读写划分正确。
- **无命令注入**：每个 `system()/popen()` 参数要么是常量、要么 `shellquote()` 且值白名单
  （`acllist` 的 type 走 `index()`、证书文件名走 switch、`resources` 走 `index()`、
  `connection` 走 switch、`log` 走 `in`）。
- **无任意路径**：每个路径段都来自白名单。
- `node_parse` 有类型检查与 4096 长度上限；`parse_uri`/`protocols.uc` 用固定键构造，
  所以 `node.js:609-627` 的 `Object.keys(config).forEach(k => uci.set(...))`
  **无法注入 UCI 键名**。
- `acllist_write` 的字符过滤（`luci.homeproxy:88`）挡住空白与 shell 元字符，
  内容按行切分后喂给 dnsmasq/sing-box，**行内无法突破**。
- 行标题、`data-title`（`setAttribute`）、`ui.Select` 候选项（数组子节点）都是文本节点；
  没有订阅可控值进入 `href`/`src`；`status.js` 的 `rawhtml` 是惰性的
  （版本串走 `E('strong', {}, [..])` 数组 → 文本节点）。
- `rpcCall` 是唯一的 `rpc.declare` 点，每个调用点都走它，warn-once 集合是真的。
- `log_clean`/`singbox_generator` 用 ucode 的 `in` 判数组**值成员**（不是 JS 的键判断），
  我专门确认过——这个白名单是有效的。

---

## 9. 低危与记录项

### 9.1 `CAP_SYS_PTRACE`（低，上游继承）
`capabilities/homeproxy.json` 五组都给，`service.sh:153` 应用于**以 `sing-box` 用户
运行在 ujail 内、面向互联网**的客户端实例。sing-box 正常不需要 ptrace
（TUN/tproxy 靠 `CAP_NET_ADMIN`/`BIND_SERVICE`/`RAW`）。一个被攻破的 sing-box
（它解析不可信网络输入与不可信订阅配置）因而能窥探/注入它能看到的其它进程。
与上游 ImmortalWrt/luci **完全一致**，是继承不是本轮引入。

### 9.2 `certificate_write` 的固定暂存路径与 TOCTOU（低）
`luci.homeproxy:112-120`：浏览器把文件传到 world-writable 的
`/tmp/homeproxy_cert_<name>.tmp`，后端 `lstat`（拒符号链接/非普通文件）后 `readfile()`
**按路径读**——检查与读取不原子，且上传的**私钥**在该 RPC 窗口内可被读取。
预置符号链接能否得手取决于 cgi-upload 的 open flags，**在仓库外，未验证**，故记低。
修法：改到 root-only 0700 目录（如 `/etc/homeproxy/tmp/`），或用单 fd 读。

### 9.3 `E(tag, <裸字符串>)`（低，潜伏）
`homeproxy.js:734,837,839,842`、`client.js:1570,1616`、`node.js:776`、`status.js:196`。
`E()` → `dom.create` → `dom.append`，**裸字符串即 `innerHTML`**（§3.1 ⑤）。
今天这些值（rpc 状态文本、`acllist_read` 的 `'illegal type'`、`certificate_write` 的静态串）
**都不含攻击者数据**，所以是潜伏而非现网。但同一模式若接上
`node_parse` 的 `'parse failed: ' + e.message` 就会变活。修法：一律用 `E('p', {}, [ ... ])`。

### 9.4 无大小上限（低）
`acllist_write.content`、`singbox_generator.params`、证书上传文件都无上限：
写 ACL 会话可 post 任意大的域名列表、传任意长 argv、或上传多 GB 文件让 root 整个 `readfile()`。
`node_parse` 已正确限制 4096，这三处没有。修法：`content` ~1 MB、`params` ~255 B、证书 ~64 KB，
用显式 `lstat` 尺寸检查。

### 9.5 crontab 两套写法（低）
`service.sh:57` 的 `hp_crontab_drop` 明确解释了为什么不用 `sed -i`
（BSD sed 下失败且静默留下旧条目），但**同一个文件** `/etc/crontabs/root` 在
`migrate_config.uc:67` 仍是裸 `sed -i` **且吞掉错误**。OpenWrt（busybox sed）正常，
所以无现网症状。**价值在于它证明**：这条经验只被应用到了**有测试覆盖**的那条路径上。

### 9.6 台账第 20 项陈旧（已修）
PR-06 标着 ⬜ 但三项内容均已落地。已改为 ✅ 并**写明与计划的偏离**
（计划说建 `shared/rpc.js` 与 `components/`，实际都没建，理由是 `homeproxy.js` 本来就是共享模块）。
同一轮核对：第 14 项（真机 CI）确实未做，保持 ⬜。（`b820aac`）

### 9.7 未发现的问题（专门查过、结果干净）
- **悬空引用**：本会话删改的符号无残留。`decodeBase64Str` 仍有引用但**全在后端**
  （`homeproxy.uc:371` 导出，`protocols.uc`/`decoder.uc` 使用）——前端副本确实删了。
- **文档引用不存在文件**：机械扫描 14 处，逐条核对**全部合理**——glob、
  `path:line`、台账**明确自述的已删除文件**（`architecture-review.md` 三处写明已删除）、
  或 PR-07 待建文件的**提案**（`tests/arch-guard.sh` 写的是"新增"）。
  **台账对自己删除过什么是诚实的。**
- README 小错：`:152` 写 `socks(4/4a/5/5h)`，实际只断言了 `socks`/`socks4`/`socks5`；
  `:143` 的"破坏翻译覆盖的 PR 会失败"只对**已扫描过的**字符串成立（#7）。

---

## 10. 已核验为健康的项

| 项 | 证据 |
|---|---|
| ACL **ubus** 方法面 | 双向差集为空，10/10，无野字符号（三路独立确认） |
| **无命令注入** | 每个 `system/popen` 参数常量或 `shellquote` + 白名单 |
| **无任意路径** | 所有路径段来自白名单 |
| **UCI 键注入** | `node_parse` 限长 4096 + 解析器固定键 |
| 生成器/解析器/适配器不读 UCI | 三个目录内 UCI 符号命中 0 |
| 7 条架构边界 | 逐条 grep 全部成立 |
| 前端死代码 | `decodeBase64Str` 前端零调用已删，后端保留在用 |
| 本地套件 | `./tests/run.sh` 全绿（130 项协议清单、82 项入站适配器、82 项领域模型、golden 经真实 `sing-box check`） |
| 快照稳定性 | 三个表单快照在 PHASE 8 全部重构中**逐字节未变** |
| 代码卫生 | 全仓库 `TODO`/`FIXME` 命中 0 |
| 台账诚实度 | 状态标记与实现逐项核对；已删文件三处自述；陈旧项已修并记录偏离 |

**关于 `init.d` 行数的准确记述**：`517` →（纯抽取）`253` →（P0 健康门 + 回滚）`359`。
当前 359 行 = 186 代码 + 107 注释 + 空行；抽出到 `runtime/*.sh` 共 937 行（6 模块）。
健康门回到 orchestrator 是**刻意的**（procd 生命周期钩子必须定义在那里）。

---

## 11. 审计未覆盖的部分（能力的诚实边界）

必须明说，否则上面所有"通过"都会被过度解读：

1. **所有 XSS 结论都没有在浏览器里实际触发过。** 链路是读 `openwrt/luci` master 的
   不可变源码推出来的。如果目标设备的 LuCI `titleFn`/`stripTags` 不同，需重查。
   设备是 ImmortalWrt 25.12.1（应同源），但我没在设备上比对过 LuCI 版本。
2. **浏览器人工回归：从未做过，agent 做不到。** 这也是 `(f)` 里
   `null` vs 省略 `description` 那处唯一未被验证的原因。
3. **真机端到端：受 §0 配置丢失与版本错位双重限制。**
   订阅更新、DNS 分流、服务端入站三块无法在真机复现。
4. **`sing-box check` 的版本归属**：本地校验用的二进制是否与设备上
   `/usr/bin/sing-box`（1.14.1，而 apk 记录 1.13.16-r1）同版本未确认——所以
   "golden 通过"证明的是**该二进制接受**，不是**设备二进制接受**。
5. **ucode 语义**：复核者无 ucode 二进制，`in` 判数组值成员等结论来自官方文档 + 本仓库测试。
6. **cgi-upload 的 open flags**：仓库外，未查（影响 §9.2 的严重性评级）。
7. **并发与长期运行**：健康门、回滚、cron 同步都在单次调用语义下验证。
   （§8.3 提到的"两个测试进程互相踩"是**测试**的并发问题，不是**服务**的。）

---

## 12. 统计

| 维度 | 数值 |
|---|---|
| 后端 ucode | 27 文件 / 6225 行 |
| 后端 shell | 10 文件 / 1128 行（`runtime/` 937 行 / 6 模块） |
| `init.d` orchestrator | 359 行（自 517 行下降） |
| 前端 JS | 4305 行 |
| 测试文件 | 57 |
| 纲领文档 | 3915 行 |
| 本轮 commit | 53 |
| 本轮改动 | 84 文件 / +20525 / −4105 |
| 严重 / 高 / 中高 / 中 / 低 / 记录 | 1 / 3 / 2 / 6 / 6 / 1 |
| 正面核验项 | 11（§10）+ 复核一致确认 9 条（§8.4） |
| 独立复核 | 3 路全部返回并并入（§8） |
| 本地套件 | 全绿 |
| 真机套件（手工） | 上轮 `rc=0`，0 FAIL，0 NOT RUN（真机有 `fw4`，渲染层真的执行了） |
| CI 套件 | **存在 NOT RUN 层**：fw4 渲染、golden 的 `sing-box` schema 半场 |

**注意读这张表的方式**：每一格"通过"只对它所描述的那件事成立。
本地"全绿"、真机"0 NOT RUN"、CI"有跳过"是**三套不同的运行**——
把三者混为一谈，正是 §8.3 想指出的问题本身。

**下一步**：见 `docs/next-step-plan.md`。
