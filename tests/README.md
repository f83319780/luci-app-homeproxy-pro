# luci-app-homeproxy tests

Automated checks for the pieces that `sing-box check` cannot validate: the
share-link parsers, the UCI→JSON generators and the LuCI form definitions.

## Running

```sh
tests/run.sh
```

* The **LuCI form snapshots** run locally and only need `node`. They re-render
  the node/server views through a mock LuCI runtime and diff the result against
  `tests/snapshots/*.json`.
* The **ucode tests** need `ucode`; the generator cases additionally run
  `sing-box check`, so they need sing-box ≥ 1.14 as well (available on an
  OpenWrt/ImmortalWrt target). When the host running `tests/run.sh` has neither,
  the checkout is copied over ssh to `$HP_TEST_HOST` (default
  `root@192.168.1.102`, the dedicated test machine) and the tests run there:

  ```sh
  HP_TEST_HOST=root@192.168.1.102 tests/run.sh
  HP_TEST_DIR=/tmp/hp-tests        tests/run.sh
  ```

  Point `$HP_TEST_HOST` at the **test machine, never the production router**:
  the fallback untars the whole checkout into `$HP_TEST_DIR` on the target, and
  `192.168.1.1` is the box the house actually routes through.

### The staging policy: never install

The ssh path **copies the checkout and runs it in place**. It never installs the
package and never runs `apk` or `opkg` on the target. That is a rule, not a
preference.

Installing on a live device runs the package manager, which rewrites
`/etc/config/homeproxy` from the feed package — and on 2026-09-15 that destroyed
the test machine's node configuration. There was no backup and no snapshot, and
six nodes plus the `dns`, `server` and `subscription` sections were
unrecoverable. Staging cannot do that: everything it writes lives under
`$HP_TEST_DIR` and nothing outlives the run.

Two consequences are printed rather than left to be discovered. `tests/run.sh`
reports both versions before staging:

```
== target and source versions (staging; the package is not installed) ==
  source  : 28.9.1.14-r1
  target  : luci-app-homeproxy-26.236.50544~cb5d434
  sing-box: 1.14.1
```

* the target may have a different build of the app installed, or none. **What is
  tested is the checkout, not what the device runs** — so "it passes on the
  device" never means "the installed package is good".
* `sing-box` on the target is whatever the target has. The local branch gates on
  ≥ 1.14; the staging branch records the version instead, because it cannot
  install one.

If a test genuinely needs the installed package, that is a different test and
needs a different safety story (a config backup, taken first, on the device).

`tests/run.sh` exits non-zero if anything fails. The ucode part can also be run
on its own on a target:

```sh
sh tests/ucode/run.sh "$PWD"
```

## Local macOS testbed

The ucode part normally needs an OpenWrt device because ucode has no Homebrew
formula and its `uci`/`ubus` modules link against the OpenWrt libraries. To
avoid depending on `$HP_TEST_HOST` (and on the LAN being reachable) for every
refactor step, the whole toolchain can be built from source into a private
prefix:

```sh
sh tests/toolchain/build-ucode-macos.sh
export PATH="$HOME/.local/ucode-testbed/bin:$PATH"
tests/run.sh
```

The script installs into `~/.local/ucode-testbed` and removes nothing outside
that directory plus the clone/build scratch tree (`/tmp/ucode-build` by
default), so dropping the prefix undoes it completely. It builds:

| Component | Why |
| --- | --- |
| `libubox`, `libuci`, `libubus` | ucode's `uci`/`ubus`/`uloop` plugins need them; not packaged for macOS |
| `libmd` | the `digest` module (`ucode-mod-digest` in the package Makefile); installed through Homebrew |
| `ucode` | the interpreter itself, plus `utpl`/`ucc`. Pinned to the revision ImmortalWrt/OpenWrt snapshots ship as `2026.01.16~85922056` — see "Why ucode is pinned" below |
| `liblucihttp` | `luci.http` is a thin wrapper over this C module and `homeproxy.uc` imports it |
| `luci` ucode sources | `http.uc`, `sys.uc`, … installed to `<prefix>/share/ucode/luci` like OpenWrt does |
| `sing-box` | the official 1.14.0 release binary; the fixtures are validated with `sing-box check` and the package targets 1.14 |

The script ends with a module import check (`lucihttp`, `luci.http`,
`luci.sys`, `uci`, `ubus`, `digest`, …), a check that `utpl` exists and that the
ucode grammar is still the strict one the package targets, and a
`urldecode_params()` behaviour assertion. It exits non-zero if any of them fail.

`tests/run.sh` refuses to run the fixtures against an older `sing-box`
(`FAIL: sing-box >= 1.14 required`), so keep the prefix first in `PATH`.

### Why ucode is pinned

`UCODE_REV` in both toolchain scripts is the revision the ImmortalWrt/OpenWrt
snapshot ships (`2026.01.16~85922056`). That ucode is stricter than current
upstream HEAD: it requires a terminating `;` after `export function ... }` and
rejects object and array destructuring, both of which upstream relaxed
afterwards (`openwrt/openwrt@main` pins `b885dd0f`, whose own test suite uses
the semicolon-free form). Building ucode from the default branch therefore
compiles code that no router accepts, which is how five refactor modules
shipped unparseable while CI stayed green.

`tests/ucode/test_ucode_grammar.sh` pins the *dialect* rather than trusting the
revision: it asserts the toolchain still rejects the two constructs and still
accepts the ones the package uses. It runs at the end of the toolchain build
and as the first step of `tests/ucode/run.sh`, so a permissive toolchain fails
loudly instead of turning into a green run. Set
`HP_ALLOW_PERMISSIVE_UCODE=1` to demote that to a warning while deliberately
probing a newer ucode.

**If the canary reports `exported_function_without_semicolon compiles, but the
target ucode rejects it`, the problem is usually the local build, not the pin.**
A testbed built before `UCODE_REV` was introduced tracks upstream HEAD and is
too permissive; rebuild it with `tests/toolchain/build-ucode-macos.sh` (or
`-linux.sh`) and the canary passes. This is worth doing rather than reaching
for `HP_ALLOW_PERMISSIVE_UCODE=1`: on a permissive toolchain the canary's
"rejected" probes pass for the wrong reason, and a real
missing-`;`/destructuring regression would go unnoticed — which is precisely
how the generator subtree shipped unloadable.

### What the local testbed cannot cover

Nothing is skipped any more. The suite used to report four checks as `SKIP` on
a development host, and those skips are exactly what let a non-compiling
`update_subscriptions.uc` (and, once that was fixed, a destructuring statement)
reach a device:

| Was skipped | Now |
| --- | --- |
| `scripts/update_subscriptions.uc` | compiled like every other source; `luci.sys` comes from the toolchain |
| `scripts/firewall_pre.uc` | compiled; its `homeproxy` import resolves through `-L` |
| `rpcd/ucode/luci.homeproxy` | compiled from a copy whose absolute `/etc/homeproxy/...` imports are rewritten to the checkout |
| `tests/ucode/test_firewall_template.sh` | runs; `utpl` is a symlink to `ucode` and ships with the toolchain |

A missing `utpl`, or any other gap in the toolchain, now FAILS instead of
silently reducing coverage.

The one remaining `NOT RUN` is honest rather than a skip: the render half of
`tests/ucode/test_firewall_template.sh` needs the device-only `fw4` ucode
module. Its source-level half always runs, and it checks the actual
precondition of the bug that test exists for (nothing but the shebang may
precede the `{%-` tag, otherwise the trimmed newline glues the first generated
statement onto a comment). Stubbing `fw4` would let the render run everywhere,
but the assertions would then be about a ruleset the real `fw4` never
produced — see that script's header for the reasoning.

It is not left as a bare skip, though: `HP_REQUIRE_FW4=1` turns the skip into a
failure, and `tests/run.sh` sets it in the ssh branch. A target always has
firewall4, so the one environment able to run the render must run it — and a
target that somehow cannot now fails instead of quietly reporting `NOT RUN`.

Two further host differences are bridged so the remaining checks still run:

* **`/sbin/validate_data`** — `homeproxy.uc` shells out to this OpenWrt helper
  for hostname/address/port validation. `tests/toolchain/validate-data.sh`
  reproduces the caller's contract (exit 0 = valid) using the same validation
  code as the parser unit tests; `tests/ucode/run.sh` exports it as
  `HP_VALIDATE_DATA` when `/sbin/validate_data` is absent, and
  `tests/ucode/test_generators.sh` substitutes it while staging the generator.
* **`routing_mark`** — a Linux-only `SO_MARK` socket option in sing-box (1.14
  has no portable `set_mark` route action), so redirect/tproxy configs cannot
  pass `sing-box check` on macOS. On Darwin the generator *copy* staged by the
  test is rewritten to emit `routing_mark: null`, which `removeBlankAttrs()`
  drops; the emitted JSON is then identical on every platform and the
  production generator is untouched.

## What is covered

| Path | Checks |
| --- | --- |
| `tests/i18n-coverage.py` | Reports how many `po/templates/homeproxy.pot` strings have a non-fuzzy, non-empty `po/zh_Hans/homeproxy.po` translation. Technical tokens that stay as-is are listed in `tests/i18n-ignore.txt`; anything else missing fails the run (`--fail-below 100`) and adds a job-summary entry. The release workflow (`build.yml`) deliberately warns instead of failing, so a translation gap cannot block packaging - the PR gates already catch it. |
| `tests/luci-form-snapshot.js` | Dumps every option (name, kind, title, description, depends, values, datatype/default/…) of the node, client and server views. Diffs against `tests/snapshots/{node,client,server}.json`, so a refactor that changes a field or its visibility fails. |
| `tests/ucode/test_homeproxy_utils.uc` | `executeCommand()` return shape, stderr/exit-code capture, binary detection, and a descriptor-leak check (200 calls). |
| `tests/ucode/test_homeproxy_utils_inject.uc` | The failure path of `executeCommand()`: the script stages a copy of `homeproxy.uc` whose `system()` call is replaced by `die()`, then checks that the exception still propagates and that neither descriptor leaks. |
| `tests/ucode/test_tls_transport.uc` | Direct calls into `buildTLSObject()` / `buildTransportObject()`: client-vs-server-only fields (no `insecure` on a server inbound, no `utls` on a server, `public_key` only on the client and `private_key` only on the server for reality), the ECH client/server split, and the `validateHomeProxyPath()` gate on `cert_path` / `key_path`. This is the boundary the generator fixtures only exercised end-to-end, so it is where the "server emitted insecure=true" and "reality key on the wrong side" classes of bug get named. |
| `tests/ucode/test_subscription_fetcher.uc` | `subscription/fetcher.uc` against a shimmed `wGETVerbose`: empty content logs a **redacted** URL and returns `{content:null,error}`; non-empty content returns the body and logs nothing. The redaction assertion is what stops the subscription token from reappearing in `homeproxy.log`. |
| `tests/ucode/test_migrate_config.sh` | Runs `migrate_config.uc` (36 checks) against a sandboxed UCI file that needs every migration step it can see at once — the 1.14 DNS renames, the legacy `dns_server.address` split, `rcode://` → predefined rule, `rule_set_ipcidr_match_source` rename, `block-out`/`block-dns` → `action='reject'`, `auto_firewall` redistribution, and the `block-dns` default-server replacement. The staged copy's cursor is redirected at the sandbox; the runner aborts if that rewrite stops matching rather than letting the migration touch the live `/etc/config`. |
| `tests/ucode/test_firewall_pre.sh` | Behaviour tests for `firewall_pre.uc` (8 scenarios, one process each because the script has no exports): the tun accept pair, the per-server accept rules, the explicit-network narrowing, and — most importantly — that an invalid port or network skips the server with a WARN instead of interpolating garbage into an nft statement, which would make nft reject the entire ruleset. |
| `tests/ucode/test_fw4_names.sh` | Keeps the fw4 chain/set inventory in `scripts/fw4_names.sh` (used by `init.d/homeproxy` to clean up on stop) in sync with the objects declared in `scripts/firewall_post.ut`. |
| `tests/ucode/test_parse_uri.uc` | Per-scheme assertions on the `parse_uri()` result: anytls, http/https, hysteria, hysteria2/hy2, snell, socks(4/4a/5/5h), shadowsocks (SIP002 base64 + plain + plugin, Shadowrocket), trojan (ws/grpc), tuic, vless (reality/ws/http/httpupgrade), vmess (ws/h2/httpupgrade/grpc) and SIP008 objects, plus the rejection paths (unsupported kcp/quic, no QUIC support, invalid port, unknown scheme). |
| `tests/ucode/test_parser_normalize.uc` | Asserts that `parser/normalize.uc` correctly maps the parser's flat UCI-key output to the canonical Node shape (`tls`, `transport`, `multiplex`, `common`, `credentials`, `protocol_options`); pins the contract between the parser, the Loader's `PROTOCOL_OPTIONS` (now derived from `parser/mapping.uc`) and the Adapter. |
| `tests/ucode/test_parser_flatten.uc` | Round-trip invariant for the canonical-Node pipeline: `flatten(normalize(parse_uri(uri)))` must equal the parser's flat UCI dict field-for-field for every supported scheme. This is what stops the parser, the Loader's `PROTOCOL_OPTIONS` (now derived from `parser/mapping.uc`) and the Repository's flatten from drifting apart. |
| `tests/ucode/test_subscription_repository.uc` | Integration test for `subscription/repository.uc`: stages a sandboxed UCI file with a user node, a kept subscription node, and a dropped subscription node, then runs `Repository.apply_nodes` and asserts (a) the user node is untouched, (b) the kept node has the new fields and no stale fields, (c) the dropped node is gone, (d) a brand-new node is added under `md5(group+label)`. PR-03 added the `apply_main_node_refs` paths (urltest prune + missing-target switch + reset-to-nil) and the `scrub_stale_urltest_refs` pass to the same test. |
| `tests/ucode/test_generators.sh` | Runs `generate_client.uc`/`generate_server.uc` against the UCI fixtures in `tests/fixtures/generators/` inside a scratch directory (the `uci` cursor and `HP_DIR`/`RUN_DIR` are redirected) and validates each result with `sing-box check`. |
| `tests/toolchain/build-ucode-macos.sh` | Builds the local ucode toolchain described above; not part of `tests/run.sh`. |
| `tests/toolchain/validate-data.sh` | Off-target stand-in for `/sbin/validate_data`, used through `HP_VALIDATE_DATA`; not part of `tests/run.sh`. |
| `tests/ucode/test_ucode_grammar.sh` | Pins the ucode dialect: the toolchain must reject `export function ... }` without `;` and object/array destructuring, and must accept the constructs the package uses (`?.`/`??`, object spread, computed keys, template literals). |
| `tests/ucode/test_generators.sh` (wireguard case) | Asserts the WireGuard fixture keeps its private key, peer public key and local address list, so the endpoint builder cannot silently regress to reading flat UCI option names. |
| `tests/ucode/test_golden_outbounds.sh` | Builds one outbound per protocol from `tests/fixtures/generators/outbounds.uci` and diffs the result against `tests/snapshots/generator/outbounds.json`, so a field change for any protocol is a reviewable diff. Regenerate with `HP_UPDATE_SNAPSHOTS=1`. |
| `tests/ucode/test_golden_inbounds.sh` | PR-04: the server-side counterpart. Builds one inbound per protocol from `tests/fixtures/generators/server.uci` and diffs the result against `tests/snapshots/generator/inbounds.json`. The ACME `data_directory` is normalised to `<HP_DIR>/certs` so the snapshot is portable across hosts. Before this existed the server path had no snapshot at all, which is how the fixture's unused `listen_port` option survived. Regenerate with `HP_UPDATE_SNAPSHOTS=1`. |
| `tests/ucode/test_inbound_adapter.uc` | PR-04: `InboundFactory`'s protocol-shape decisions — snell / shadowsocks must get no `users[]` block (a snell users entry is read as an extra user key and makes sing-box reject the section), vless / vmess keep `flow` / `alterId` per-user, the snell listener set omits `udp_fragment` / `udp_timeout` / `network`, the server-only TLS tail (key material, ECH key, REALITY private key + handshake, ACME) reaches `buildTLSObject()`, hysteria v1 emits `obfs` as a string while hysteria2 emits the object, and the per-protocol credential requirements are enforced. |
| `tests/ucode/test_protocol_inventory.sh` | Cross-checks the protocol surface: every type named by `parse_uri.uc`, `CREDENTIALS`, `PROTOCOL_OPTIONS`, `REQUIRED_CREDENTIALS`, `OPTION_FIELDS` and the golden snapshot must agree. This is the check that catches "added a protocol to one table and forgot another". |
| `tests/frontend-protocol-inventory.js` | The frontend's single ordered protocol table (`homeproxy.js`'s `protocols`) against the backend tables that decide what the generators can build: every offered type must be modelled (`PROTOCOL_TO_UCI` on the client side, `INBOUND_CREDENTIALS` on the server side), every outbound-capable protocol (`OPTION_FIELDS`, `REQUIRED_CREDENTIALS`) must be selectable in the node form, both rendered orders are pinned, and protocols the backend models but no form offers must be listed as deliberate decisions. This is the check that would have caught `snell`: it had a form block, a credentials row and a golden outbound, but was missing from the node form's value list so it could not be selected. Node-only, no ucode needed. |
| `tests/frontend-rpc-inventory.js` | The frontend RPC boundary: exactly one `rpc.declare` site (inside `homeproxy.js`'s `rpcCall`), no view wrapping a call in `L.resolveDefault`, `rpcCall` itself catching and falling back and reporting, and no view left with an unused `require rpc`. Source-level on purpose - the behaviour it protects needs a browser, but "nobody reintroduces a second declaration site" does not. Comments are stripped before matching, because a naive grep matches the doc comment that quotes the old idiom. |
| `tests/frontend-validators.js` | Drives the shared form validators with a fake form context. The snapshots cannot cover these: a `validate` callback is a function, and the dump skips function-valued properties. Sharing the password validator between the node and server forms added the 2022-blake3 key-length check to the node form, which the server form had and the node form did not - a client could save a key that makes the generated configuration fail to decode. Reverse-proved: deleting that branch fails six checks. |
| `tests/lib/luci-module.js` | The off-target LuCI module loader (`'require x as y';` rewritten into a dependency lookup), shared by the snapshot renderer and the frontend invariant tests. Its default `_()` returns a LuCI String object with `.format`, because the form code calls both halves. |
| `tests/runtime/test_config_transaction.sh` | The `runtime/` helpers `init.d/homeproxy` leans on: the known-good copy, the fallback when generation produced nothing, the rollback, and the health probe. Pure shell, runs anywhere. |
| `tests/runtime/test_runtime_extraction.sh` | Drives `init.d/homeproxy` through a stubbed environment (fake `ip` / `nft` / `fw4` / `ucode` / `sing-box` / `uci` / `netstat`, fake procd and jsonfilter state, fixture UCI) across four scenarios and diffs the resulting command + file trace against a baseline. Two baselines exist and are captured with the SAME harness, so the diff between them is exactly the intentional change: `tests/fixtures/runtime/trace.pre-pr05.txt` (the 517-line init script before PHASE 7 moved the plumbing out — the record that the extraction was behaviour-preserving) and `tests/fixtures/runtime/trace.golden.txt` (after the health-gate fix). Scenario D is the P0 regression: a candidate whose `mixed_port` is already taken must be rejected by the health gate, the previous known-good must survive, and the reload must roll back onto it. Pure shell, no ucode needed. Regenerate with `HP_UPDATE_GOLDEN=1` (optionally `HP_GOLDEN=` / `HP_INITD=` to target another baseline or revision). |

### What the LuCI form snapshots cover

A snapshot records, for every option the form builds: kind, name, title,
description, dependency set, the `ListValue` value list, and the non-function
properties that were set on it.  Options are nested, so a `SectionValue`
option's nested form is included.

That last part was missing until it was fixed: `Option.toJSON()` skipped the
`subsection` key, which is where `SectionValue` keeps the nested form, so the
node form's entire body and client.js's rule sections were invisible.  The
measured effect of the fix:

| Target | Options dumped | Snapshot size |
|---|---|---|
| `node.json` | 13 → **117** | 3.5 KB → 34.6 KB |
| `client.json` | 29 → **206** | 8.6 KB → 56.3 KB |
| `server.json` | 95 → 95 | 25.9 KB → 27.8 KB |

Before that fix, a change to the protocol picker - exactly the kind of change
PHASE 8 makes - was visible in `server.json` only.  That is why
`tests/frontend-protocol-inventory.js` also exists: it asserts the *meaning* of
the protocol table against the backend, which a structural snapshot cannot.

What the snapshots still cannot tell you: whether the form is *usable*. They
prove a change to the option tree is deliberate and reviewable; they say nothing
about whether the resulting page works in a browser.

`tests/ucode/mocks/homeproxy.uc` is a test double for the real module: only
`validation()` is stubbed (the real one runs `/sbin/validate_data`, which does
not exist outside OpenWrt), everything else is a copy of the production code.

Three further mocks exist because a test needs a narrower seam than the full
module:

* `tests/ucode/mocks/homeproxy_fetcher.uc` — replaces `wGETVerbose` with a
  stub that reads the canned response from a global, so the fetcher test never
  shells out to `wget`.
* `tests/ucode/mocks/homeproxy_firewall.uc` — `isEmpty` / `validation` plus a
  `RUN_DIR` read from a global, so `firewall_pre.uc` writes its nft fragments
  into a scratch dir.
* `tests/ucode/test_migrate_config.sh` rewrites the staged copy of
  `migrate_config.uc` so its cursor points at the sandbox. Whenever a test
  rewrites a staged copy, it must abort when the rewrite anchor stops
  matching — otherwise the sed no-ops and the script under test operates on
  the live `/etc/config`. Both `test_migrate_config.sh` and
  `test_firewall_pre.sh` do this.

### Files that still have no direct test

Deliberately, because a meaningful test would need more than the off-target
harness provides:

| Path | Why |
| --- | --- |
| `scripts/update_resources.sh` | Its body is a GitHub API round-trip plus a jsdelivr download; only the `*)` usage branch is reachable offline. Covered by the shell syntax check. |
| `scripts/update_crond.sh` | A fixed list of invocations against hard-coded `/etc/homeproxy/scripts` paths. Covered by the shell syntax check. |
| `scripts/clean_log.sh` | `while true; do sleep 180; …` — testing the rotation needs the loop made injectable first. Covered by the shell syntax check. |
| `htdocs/.../view/homeproxy/status.js` | A LuCI view; its behaviour is only observable in a browser. |
| `init.d/homeproxy` | procd semantics need a real procd, and `service_started` only behaves correctly when procd really starts the instances — the offline harness models that, but it is a model. PR-05 shrank the file from 517 to 253 lines by moving the dnsmasq / fw4 / tproxy-TUN / service-plumbing into `scripts/runtime/{service,dns,firewall,net}.sh`; the trace test proves the move kept the command-and-file behaviour identical, and the shell syntax check covers every file. The health gate itself was verified on the ImmortalWrt test machine (see the plan's 2.14.8). |

## Architecture regression coverage

The old `test_demo_architecture.sh` compared the production `OutboundFactory`
against itself (via `generate_outbound()`, which delegates to it) and could
therefore never fail; it is gone, along with the `/* HP_TEST_HOOK */` marker it
relied on. Two tests replaced it:

* `tests/ucode/test_golden_outbounds.sh` pins the actual emitted JSON per
  protocol in `tests/snapshots/generator/outbounds.json`; PR-04 added the
  matching `tests/ucode/test_golden_inbounds.sh` for the server inbounds
  (`tests/snapshots/generator/inbounds.json`).
* `tests/ucode/test_protocol_inventory.sh` asserts that the parser, the model,
  the loader option table, the adapter tables and the golden snapshot all name
  the same set of protocols.

`root/etc/init.d/homeproxy` is exercised for what can be checked off-target:
`tests/ucode/run.sh` syntax-checks it and the `runtime/` helpers,
`tests/runtime/test_config_transaction.sh` covers the transaction semantics, and
`tests/runtime/test_runtime_extraction.sh` pins the orchestration order
(generate before teardown, known-good before firewall, cron before
`config_load`, early return before `mkdir`) against the pre-PR-05 trace.

procd itself is still only exercised on a target. PR-05 was verified on the
ImmortalWrt test machine (`root@192.168.1.102`): `start` brought up both
`sing-box-c` and `log-cleaner` instances (proving that a procd instance
registered from a *sourced module* works), `reload` passed the health gate and
refreshed known-good, and `stop` removed the instances, the TUN device, the ip
rules, the dnsmasq snippets and the live configuration while keeping the
known-good copy. That run is a manual step, not a CI job — see the plan's
PHASE 9 row for the on-target CI gap.

## Adding cases

* New share link → add an `expect_fields(...)` case to `test_parse_uri.uc`.
* New protocol option that reaches the generator → extend the fixtures in
  `tests/fixtures/generators/`, keeping values schema-valid so `sing-box check`
  still passes.
* Intentional LuCI form change → regenerate the snapshots:

  ```sh
  node tests/luci-form-snapshot.js . node   > tests/snapshots/node.json
  node tests/luci-form-snapshot.js . client > tests/snapshots/client.json
  node tests/luci-form-snapshot.js . server > tests/snapshots/server.json
  ```
