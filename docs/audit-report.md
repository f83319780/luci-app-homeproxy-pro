# 审计报告 — luci-app-homeproxy-pro

- **审计对象**：`github.com/szwjp/luci-app-homeproxy-pro`，审计时点 `b820aac`（本轮 53 个 commit 之后）
- **审计日期**：本轮会话末期
- **审计基线**：`3d0b195` → `b820aac`
- **工作树**：干净（`git status --porcelain` 为空），`main == origin/main`
- **方法与边界**：见 §1。**本文档是时点快照，不取代 `docs/architecture-improvement-plan.md` 的台账地位**；该台账仍是实现细节的权威，本文的结论在被处理后才回写台账。

---

## 0. 必须先说的一件事：测试机配置丢失

在把仓库同步到测试机（`192.168.1.102`）验证 P0 修复时，我执行了 `apk add luci-app-homeproxy`。
这个动作按 feed 的包定义覆盖了 `/etc/config/homeproxy`，把设备上原有配置替换成了 feed 默认值
（78 行 / 8 个 section / 0 个节点）。

**不可恢复的部分**：6 个节点，以及 `dns`、`server`、`subscription` 三个 section。
当时的备份目录 `/root/hp-pr05-backup` 已不存在；PVE 上 VM 200/201 既无快照也无 vzdump，
所以没有可回退的副本。

**已抢救的部分**：`infra`、`config`、`control`、`routing` 四个 section 来自一份早期的 `uci show` 转储。
抢救脚本在 `/Users/wjp/Downloads/homeproxy-config-salvage.sh`（47 条 UCI 命令，支持 dry-run），**尚未执行**。

**这是我的操作错误**，不是设备或上游的问题。根因有两条，都记在这里以便复用：
1. 在**有状态的生产配置**上执行了会改写配置的包管理命令，而当时没有先做一次
   `uci export homeproxy > 备份`——这台设备是测试机，但它承载的是真实的节点配置，不是一次性环境。
2. 我用"这是测试机"替代了"这一步是否可逆"的判断。测试机的**代码**可以随便换，
   但**配置**是数据，换代码的路径不应该经过配置。

**对后续的实际影响**：订阅自动更新、DNS 分流、服务端入站这三块**目前无法在真机上做端到端复现**，
因为它们的配置已经不在设备上了。这不阻塞仓库侧的开发与测试（本仓库的套件全部不依赖真机状态），
但会阻塞"改完之后在真机上确认行为"这一类验证。善后方案见计划报告 P0-2。

---

## 1. 审计范围与方法

**读过的**：全部 27 个 `.uc`（6225 行）、10 个 `.sh`（1128 行）、`htdocs/` 下 4305 行前端、
57 个测试文件、3 份纲领文档（3915 行）。逐文件通读，不是抽样。

**主动构造验证的**（不信任假设，用工具验证）：

| 检查项 | 手段 |
|---|---|
| 7 条架构边界是否仍成立 | 按 `agent_guide` 的边界定义逐条 grep + 反向搜索 |
| ACL 与后端能力是否一致 | 从 `.uc` 解析出方法表，与 ACL JSON 取差集（双向） |
| ACL 文件授权是否最小 | 从后端解析 `writefile()` 目标，与 ACL file 清单对比 |
| shell 注入边界 | 追 `shellQuote`/`shellquote` 的每一个调用点与白名单 |
| 生成器/解析器/适配器是否越界读 UCI | 在 `generator/`、`parser/`、`adapter/` 内搜 UCI 符号 |
| 重构是否留下悬空引用 | 搜本会话删掉/改名的每个符号；解析文档里反引号路径并逐个 `os.path.exists` |
| 前端死代码是否真被删除 | 全目录搜 `decodeBase64Str` 并区分前后端 |
| 本地套件是否真能失败 | 读每条新守卫的实现，确认有反向用例 |
| 台账是否有虚假声称 | 逐个核对被引用的文件是否存在、状态标记与实现是否相符 |

**独立对抗性复核**：另起三个 subagent 分别从"后端/ucode 正确性"、"前端与安全"、
"测试与 CI 有效性" 三个角度独立审计，与我并行、互不可见。**本轮结论以我自己的验证为准**；
它们的产出作为交叉印证，落在此处后并入本文。见 §7。

**没有做的**（明确声明，避免被当成已覆盖）：浏览器人工回归、真机端到端、压力/并发、
长期运行稳定性。理由见 §7。

---

## 2. 结论摘要

| # | 级别 | 问题 | 位置 | 影响 |
|---|---|---|---|---|
| 1 | **高** | "上传 ECH config" 按钮**必然失败** | `luci.homeproxy:146-157` ↔ `node.js:459` | 该功能 100% 不可用；已存在且未被任何测试覆盖 |
| 2 | 中 | 测试机跑的**不是**本仓库的版本 | 设备 `26.236.50544` vs `Makefile:27.911.1.14` | 真机验证的基线不明确；`/usr/bin/sing-box` 与 apk 记录不一致 |
| 3 | 低 | 同一文件两套 crontab 写法，一处会静默失败 | `migrate_config.uc:67` vs `service.sh:57` | 迁移路径在非 busybox sed 上删不掉旧条目且吞掉错误 |
| 4 | 低 | `sed -i` 仅剩两处，其中一处有明确替代范式 | `update_resources.sh:106` | 跨平台隐患，无当前故障 |
| 5 | 记录 | 台账 §5 第 20 项状态陈旧（PR-06 已完成） | `architecture-improvement-plan.md` | 审计中已修，`b820aac` |
| 6 | **正面** | 架构边界、ACL、注入边界、悬空引用**全部干净** | 见 §6 | 重构没有引入结构性债务 |

**总体判断**：重构本身是健康的——边界没有破，测试是真的，台账基本诚实。
唯一的高危问题不在重构范围内，是一个**上游继承下来、本轮安全改造反而把它固化了**的功能缺陷（§3）。
真正需要优先处理的是 §0 的数据损失善后，其次才是这个高 severity 缺陷。

---

## 3. 高危：ECH 上传按钮必然失败

### 3.1 现象与证据链

前端有四个证书上传按钮，共用一个 helper（`homeproxy.js:821`）：

```js
// homeproxy.js:832
const tmpPath = '/tmp/homeproxy_cert_' + filename + '.tmp';
return ui.uploadFile(tmpPath, ev.target)
    .then(... => this.rpcCall('certificate_write', [filename], ...))
```

第四个按钮传的 `filename` 是 `client_ech_conf`（`node.js:459`）：

```js
o.onclick = L.bind(hp.uploadCertificate, this, _('ECH config'), 'client_ech_conf');
```

后端 `certificate_write` 的 case 分支**只有三个**（`luci.homeproxy:146-157`）：

```ucode
switch (filename) {
case 'client_ca':
case 'server_publickey':
    return writeCertificate(filename, false);
case 'server_privatekey':
    return writeCertificate(filename, true);
default:
    return { result: false, error: 'illegal cerificate filename' };
}
```

`client_ech_conf` 落到 `default`。用户点击按钮 → 文件确实传进了
`/tmp/homeproxy_cert_client_ech_conf.tmp` → RPC 返回 false → 界面弹
"Failed to upload ECH config, error: illegal cerificate filename."

**这是 100% 必现的**，不是竞态也不是环境相关。

### 3.2 归属：上游继承，但本轮把它固化了

用 `git log -S` 追两个端点的来源：

- `node.js` 里的 `client_ech_conf`：**initial commit `1ff9d66`** 就有
- 后端 switch：**自 `1ff9d66` 起未改动过**
- ACL 里的 ECH 路径：**`d9a4dac` 才加入**（我本轮的 ACL 收紧改造）

所以缺陷本身是上游 `homeproxy1.14` 带来的。但本轮我做的 ACL 收紧**为
`/etc/homeproxy/certs/client_ech_conf.pem` 和 `/tmp/homeproxy_cert_client_ech_conf.tmp`
补上了写授权**，而我当时没有回头确认后端是否真的能写到这两个路径。
结果是我把一个"前端有个没人能用成功的按钮"变成了"ACL 明确授权了一条后端永远走不到的路由"，
并且在 `homeproxy.js` 里写下了一条**当时不成立的注释**：

> *The ACL write list in acl.d/luci-app-homeproxy.json enumerates all four paths.*

ACL 确实列了四条，但**后端只实现了三条**——注释把"前端假设"当成了"系统事实"。
这是本轮改造的方法论教训：**收紧权限时应该同时验证被授权方是否真的存在**，
我把 ACL 当成了独立的安全配置项，而它其实是前后端契约的一半。

### 3.3 为什么没有任何测试发现它

三个原因叠加，值得单独记：

1. **前端不变量测试测的是"表单暴露了什么"，不是"后端接受什么"**。
   `frontend-rpc-inventory.js`（21 项）核对 RPC 方法名在两个视图里一致，
   而 `certificate_write` 这一个方法名是对的——错的是它的**参数取值域**，
   测试从来没覆盖到这一层。
2. **后端 ucode 测试没有 `certificate_write` 的用例**。
   它是 10 个 RPC 方法里覆盖最少的一个，因为"写证书"看起来像纯 IO。
3. **ACL 检查只做"名单对不对"，不做"名单里的东西存不存在"**。

也就是说，缺陷正好落在三层测试的**缝隙**里：前端测方法名、后端测别的方法、ACL 测名单格式。
这不是"测试写得不够多"，而是**分层测试的接缝处天然无人负责**——这一点在计划报告里
被提升为一条结构性改进（P1-1 的守卫范围）。

### 3.4 系统性排查：这是个例，不是一类的一部分

为了确认它不是一个更大问题的一个样本，做了双向核对：

```
后端定义的方法数 : 10
ACL 授权 read    : acllist_read, connection_check, node_parse, resources_get_version, singbox_get_features
ACL 授权 write   : acllist_write, certificate_write, log_clean, resources_update, singbox_generator
DEFINED but NOT granted : none
GRANTED but NOT defined : none
```

**方法名层面 10/10 精确对称，没有野字符号，两个方向都没有缺口。** 再比文件授权：

```
后端实际 writefile 目标 : ${HP_DIR}/certs/${filename}.pem  |  ${RUN_DIR}/${type}.log
ACL write file 条目     : 10
```

逐条核对这 10 条的最终去向：2 个资源列表由 `resources_update` 拉起的脚本写入（可达）；
4 个 `/tmp/homeproxy_cert_*.tmp` 由前端 `ui.uploadFile` 写入（可达）；
4 个 `certs/*.pem` 中 3 个由 `writeCertificate()` 写入（可达），
**只有 `/etc/homeproxy/certs/client_ech_conf.pem` 后端不可达**。

注意 ECH 的 `/tmp` staging 路径是**可达的**——文件确实传上去了，
失败发生在消费它的那一步 RPC 上。这也解释了为什么现象是"上传成功提示换成失败弹窗"
而不是"文件根本传不上去"。

**结论：这是个例，ACL 除此之外没有过度授权。** 这很重要——它把修复范围限定在
"补一个 case"或"删一个按钮"，而不需要重新审计整个权限面。

### 3.5 修复方向（二选一，需求决定）

- **A. 补后端**：`case 'client_ech_conf': return writeCertificate('client_ech_conf', false);`
  —— 最小改动，1 行 + 1 个后端测试。前提是 sing-box 1.14 确实支持 ECH config 文件
  （生成器已在 `tls_ech_config_path` 里引用该路径，所以链路是通的）。
- **B. 删按钮**：如果决定不支持 ECH，则同时删按钮、`tls_ech`/`tls_ech_config_path`
  选项、ACL 两条、生成器引用。

**倾向 A**，因为生成器和 UCI 模型都已围绕 ECH 建好，删掉的面积远大于补一个 case。
但这是**需求问题不是技术问题**，所以列在计划里等你一句话，不自行决定。

---

## 4. 中危：测试机跑的不是本仓库的版本

两条独立的错位：

| 对象 | 设备上的实际值 | 来源 |
|---|---|---|
| `luci-app-homeproxy` | `26.236.50544`（feed 构建） | `apk` 安装的 feed 包 |
| 本仓库 | `PKG_VERSION=27.911.1.14` / `PKG_RELEASE=11` | `Makefile:25-26` |
| `/usr/bin/sing-box` | `1.14.1` | 由 passwall/openclash 带入 |
| apk 记录的 sing-box | `1.13.16-r1` | apk 数据库 |

**含义**：设备上安装的 LuCI 应用比仓库旧，`/usr/bin/sing-box` 的实际版本
与包管理器的记录也不一致。所以：

1. **所有真机验证都是通过 `/tmp` 暂存仓库文件来做的**，不是通过安装本仓库的包。
   这一点在测试脚本里是成立的（`tests/runtime/` 就是 stage + drive 的模式），
   但它意味着**"在真机上装一次本仓库的包"这条路径从未被验证过**。
2. `apk upgrade` 或重装会把应用拉回旧版，把 `/tmp` 暂存的改动覆盖掉——
   这正是 §0 数据丢失那次操作的同一条路径。**在没有先导出配置之前，不应再在
   `192.168.1.102` 上执行任何 `apk` 写操作。**
3. sing-box 版本二元性会影响"`sing-box check` 通过"这一证据的解释：
   本地 golden 校验用的二进制与设备上的可能不同版本（见 §7）。

**这不是代码缺陷**，是环境事实，必须记录，因为它决定了后续验证结论的适用范围。
修复方向（计划 P1-3）是让设备版本与仓库版本对齐，或明确采用"永远 stage 不安装"的策略并写进文档。

---

## 5. 低危与记录项

### 5.1 crontab 两套写法（低）

`service.sh:57` 的 `hp_crontab_drop` 明确解释了为什么不用 `sed -i`：

> *Not `sed -i`: the bare `-i` form is a busybox/GNU extension, and on a host with
> BSD sed it fails ("invalid command code"), which silently left the stale entry behind.*

但**同一个文件** `/etc/crontabs/root` 在迁移路径里仍然是裸 `sed -i`，
而且把失败也吞掉了（`migrate_config.uc:67`）：

```ucode
system('sed -i "/update_crond.sh/d" "/etc/crontabs/root" 2>/dev/null');
```

**后果**：在 BSD sed 环境上迁移会静默留下旧的 cron 条目，且没有任何日志。
在 OpenWrt（busybox sed）上正常工作，所以没有现网症状。
**价值在于它证明了一件事**：同一条经验在本轮只被应用到了被测试覆盖的那条路径上
（`hp_crontab_drop` 有 `tests/runtime/` 驱动），没被应用到时序迁移路径上。
**修复**：把 `sed -i` 换成同样的临时文件写法。属于"顺手就能修对"的类型。

### 5.2 `update_resources.sh:106`（低）

```sh
sed -i -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt"
```

同一类，但它操作的是自己刚下载进自己目录的文件，失败会表现为列表格式不对而非"静默留脏数据"，
优先级低于 5.1。无当前故障。

### 5.3 台账第 20 项陈旧（已修）

`architecture-improvement-plan.md` §5 第 20 项（PR-06）标着 ⬜，但其列出的三项内容都已落地。
审计中已修正为 ✅ 并**写明了与计划的偏离**：计划说新建 `shared/rpc.js` 和 `components/` 目录，
实际都没建——`homeproxy.js` 本来就是两个视图共同 import 的共享模块，再开一个模块和一个目录
只会增加 import 改动而没有收益。**偏离被记录下来，而不是静默略过**（`b820aac`）。
同一轮核对中，第 14 项（真机 CI 作业）确实仍未做，保持 ⬜ 不变。

### 5.4 未发现的问题（明确列出）

以下几类是我**专门查过、结果干净**的，写在这里以免下次重复劳动：

- **悬空引用**：本会话删掉/改名的符号（`decodeBase64Str` 前端副本、`hp_dnsmasq_resolve_dir` 等）
  全部无残留。`decodeBase64Str` 仍有引用，但**全部在后端**（`homeproxy.uc:371` 导出，
  `protocols.uc`、`decoder.uc` 使用）——前端副本确实删掉了，后端副本是活的。
- **文档引用不存在的文件**：机械扫描发现 14 处，**逐条核对后全部合理**——
  要么是 glob（`tests/snapshots/*.json`）、要么是 `path:line` 形式、
  要么是台账**明确记述的已删除文件**（`architecture-review.md` 在第 132、1730、1737 行
  三处都写明"文件已删除"）、要么是 PR-07 待建文件的**提案**（`tests/arch-guard.sh`，
  第 1483 行写的是"新增"）。**台账对自己删除过什么是诚实的。**

---

## 6. 已核验为健康的项（含证据）

这些不是"看起来没问题"，是逐条构造过验证的：

| 项 | 证据 |
|---|---|
| **ACL 方法面** | 后端 10 个方法与 ACL 授权**双向差集为空**，无野字符号 |
| **ACL 文件面** | 唯一过度授权是 ECH 那一对（§3.4），其余全部可达 |
| **7 条架构边界** | 按 `agent_guide` 定义逐条 grep，全部成立 |
| **生成器/解析器/适配器不读 UCI** | 三个目录内 UCI 符号命中数为 0 |
| **shell 注入边界** | `shellQuote`/`shellquote` 的每个调用点都在白名单之后 |
| **前端死代码** | `decodeBase64Str` 前端零调用，已删；后端保留且在用 |
| **本地套件** | `./tests/run.sh` 全绿，结尾 `ALL TESTS PASSED`（含 130 项协议清单、82 项入站适配器、82 项领域模型、golden 快照经真实 `sing-box check` 校验） |
| **快照稳定性** | 三个表单快照（node/client/server）在整个 PHASE 8 重构中**逐字节未变**，证明重构是行为保持的 |
| **代码卫生** | 全仓库 `TODO`/`FIXME` 命中 0 |
| **台账诚实度** | 状态标记与实现逐项核对；已删除文件三处自述；本次发现的陈旧项已修并记录偏离 |
| **工作树/远端** | 工作树干净，`main == origin/main` |

**关于 `init.d` 行数的准确记述**（避免引用一个中间态数字）：
`517` →（纯抽取）`253` →（P0 健康门 + 回滚）`359`。
当前 359 行 = 186 行代码 + 107 行注释 + 空行；抽出到
`runtime/*.sh` 的共 937 行（6 个模块）。健康门回到 orchestrator 是**刻意的**，
因为 procd 生命周期钩子必须定义在那里，不是抽取不彻底。

---

## 7. 审计未覆盖的部分（能力的诚实边界）

必须明说，否则上面所有"通过"都会被过度解读：

1. **浏览器人工回归：从未做过，agent 做不到。**
   这是 ≥1 处未验证改动的唯一原因——`(f)` 里那处 `null` vs 省略 `description`
   的差异（快照能看见 DOM 结构，看不见渲染后的观感）。**唯一需要人做的事。**
2. **真机端到端：受 §0 配置丢失与 §4 版本错位双重限制。**
   订阅更新、DNS 分流、服务端入站三块目前无法在真机复现。
3. **`sing-box check` 的版本归属**：本地校验用的二进制版本与设备上
   `/usr/bin/sing-box`（1.14.1）是否同一版本未确认，所以"golden 通过"
   证明的是**该二进制接受**这些配置，不是**设备二进制接受**。
4. **并发与长期运行**：健康门、回滚、cron 同步都在单次调用语义下验证，
   没有做并发 reload、长时间运行、watchdog 反复重启的场景。
5. **三个独立对抗性复核**（后端/前端安全/测试 CI）与本审计并行进行，
   **本文前述结论全部来自我自己的验证**。它们的产出在到达后并入本文，
   预期作用是**证伪或补强**上述结论，而不是替换它们。

---

## 8. 统计

| 维度 | 数值 |
|---|---|
| 后端 ucode | 27 文件 / 6225 行 |
| 后端 shell | 10 文件 / 1128 行（其中 `runtime/` 937 行 / 6 模块） |
| `init.d` orchestrator | 359 行（自 517 行下降） |
| 前端 JS | 4305 行 |
| 测试文件 | 57 |
| 纲领文档 | 3915 行 |
| 本轮 commit | 53 |
| 本轮改动 | 84 文件 / +20525 / −4105 |
| 高危 / 中危 / 低危 / 记录 | 1 / 1 / 2 / 1 |
| 正面核验项 | 11（§6） |
| 本地套件 | 全绿 |
| 真机套件 | 上轮 `rc=0`，0 FAIL，0 NOT RUN |

**下一步**：见 `docs/next-step-plan.md`。
