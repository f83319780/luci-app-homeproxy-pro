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
  `root@192.168.1.1`) and the tests run there:

  ```sh
  HP_TEST_HOST=root@192.168.1.1 tests/run.sh
  HP_TEST_DIR=/tmp/hp-tests      tests/run.sh
  ```

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
| `tests/i18n-coverage.py` | Reports how many `po/templates/homeproxy.pot` strings have a non-fuzzy, non-empty `po/zh_Hans/homeproxy.po` translation. Technical tokens that stay as-is are listed in `tests/i18n-ignore.txt`; anything else missing produces a warning annotation (`--warn-below 100` by default) and a job-summary entry. Run by `.github/workflows/i18n.yml` on push/PR and before a release. |
| `tests/luci-form-snapshot.js` | Dumps every option (name, kind, title, description, depends, values, datatype/default/…) of the node and server views. Diffs against `tests/snapshots/{node,server}.json`, so a refactor that changes a field or its visibility fails. |
| `tests/ucode/test_homeproxy_utils.uc` | `executeCommand()` return shape, stderr/exit-code capture, binary detection, and a descriptor-leak check (200 calls). |
| `tests/ucode/test_homeproxy_utils_inject.uc` | The failure path of `executeCommand()`: the script stages a copy of `homeproxy.uc` whose `system()` call is replaced by `die()`, then checks that the exception still propagates and that neither descriptor leaks. |
| `tests/ucode/test_fw4_names.sh` | Keeps the fw4 chain/set inventory in `scripts/fw4_names.sh` (used by `init.d/homeproxy` to clean up on stop) in sync with the objects declared in `scripts/firewall_post.ut`. |
| `tests/ucode/test_parse_uri.uc` | Per-scheme assertions on the `parse_uri()` result: anytls, http/https, hysteria, hysteria2/hy2, snell, socks(4/4a/5/5h), shadowsocks (SIP002 base64 + plain + plugin, Shadowrocket), trojan (ws/grpc), tuic, vless (reality/ws/http/httpupgrade), vmess (ws/h2/httpupgrade/grpc) and SIP008 objects, plus the rejection paths (unsupported kcp/quic, no QUIC support, invalid port, unknown scheme). |
| `tests/ucode/test_generators.sh` | Runs `generate_client.uc`/`generate_server.uc` against the UCI fixtures in `tests/fixtures/generators/` inside a scratch directory (the `uci` cursor and `HP_DIR`/`RUN_DIR` are redirected) and validates each result with `sing-box check`. |
| `tests/toolchain/build-ucode-macos.sh` | Builds the local ucode toolchain described above; not part of `tests/run.sh`. |
| `tests/toolchain/validate-data.sh` | Off-target stand-in for `/sbin/validate_data`, used through `HP_VALIDATE_DATA`; not part of `tests/run.sh`. |
| `tests/ucode/test_ucode_grammar.sh` | Pins the ucode dialect: the toolchain must reject `export function ... }` without `;` and object/array destructuring, and must accept the constructs the package uses (`?.`/`??`, object spread, computed keys, template literals). |
| `tests/ucode/test_generators.sh` (wireguard case) | Asserts the WireGuard fixture keeps its private key, peer public key and local address list, so the endpoint builder cannot silently regress to reading flat UCI option names. |
| `tests/ucode/test_demo_architecture.sh` | **Self-comparison, not an equivalence check.** `generate_outbound()` now delegates to the same `OutboundFactory` the test imports, so both sides are one code path and its assertions cannot fail. Kept only until golden per-protocol snapshots replace it (see `docs/architecture-improvement-plan.md` §3.1); the `demo/architecture/` tree it names no longer exists. |

`tests/ucode/mocks/homeproxy.uc` is a test double for the real module: only
`validation()` is stubbed (the real one runs `/sbin/validate_data`, which does
not exist outside OpenWrt), everything else is a copy of the production code.

## Architecture demo (stale)

`demo/architecture/` no longer exists in the tree, and
`tests/ucode/test_demo_architecture.sh` now compares the production
`OutboundFactory` against itself, so it proves nothing. The layering it was
meant to guard (Config Loader -> Domain Model -> Protocol Adapter) is the
production code now, and the regression value has moved to
`tests/fixtures/generators/` plus the per-protocol snapshots proposed in
`docs/architecture-improvement-plan.md`. The test and the `/* HP_TEST_HOOK */`
marker it relies on are kept only until that replacement lands.

## Adding cases

* New share link → add an `expect_fields(...)` case to `test_parse_uri.uc`.
* New protocol option that reaches the generator → extend the fixtures in
  `tests/fixtures/generators/`, keeping values schema-valid so `sing-box check`
  still passes.
* Intentional LuCI form change → regenerate the snapshots:

  ```sh
  node tests/luci-form-snapshot.js . node   > tests/snapshots/node.json
  node tests/luci-form-snapshot.js . server > tests/snapshots/server.json
  ```
