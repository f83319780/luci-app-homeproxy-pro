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
| `ucode` | the interpreter itself, plus `utpl`/`ucc` |
| `liblucihttp` | `luci.http` is a thin wrapper over this C module and `homeproxy.uc` imports it |
| `luci` ucode sources | `http.uc`, `sys.uc`, … installed to `<prefix>/share/ucode/luci` like OpenWrt does |
| `sing-box` | the official 1.14.0 release binary; the fixtures are validated with `sing-box check` and the package targets 1.14 |

The script ends with a module import check (`lucihttp`, `luci.http`,
`luci.sys`, `uci`, `ubus`, `digest`, …) and a `urldecode_params()` behaviour
assertion, and exits non-zero if any of them fail.

`tests/run.sh` refuses to run the fixtures against an older `sing-box`
(`FAIL: sing-box >= 1.14 required`), so keep the prefix first in `PATH`.

### What the local testbed cannot cover

Four checks need a real target and are reported as `SKIP` instead of failing:

| Skipped | Reason |
| --- | --- |
| `scripts/update_subscriptions.uc` | imports `init_action` from `luci.sys` and stops/starts the service |
| `scripts/firewall_pre.uc`, `rpcd/ucode/luci.homeproxy` | import through the absolute path `/etc/homeproxy/scripts/homeproxy.uc` |
| `tests/ucode/test_firewall_template.sh` | renders a template that imports the same absolute path |

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
| `tests/ucode/test_demo_architecture.sh` | Equivalence check for the architecture demo in `demo/architecture/`: the same UCI fixture through the production `generate_outbound()` and through the new Loader/Node/adapter layers, compared per field. |

`tests/ucode/mocks/homeproxy.uc` is a test double for the real module: only
`validation()` is stubbed (the real one runs `/sbin/validate_data`, which does
not exist outside OpenWrt), everything else is a copy of the production code.

## Architecture demo

`demo/architecture/` holds a runnable reference implementation of the layering
proposed in `homeproxy_architecture_refactor_agent_guide.md` (Config Loader ->
Domain Model -> Protocol Adapter), verified against the production builder by
`tests/ucode/test_demo_architecture.sh`. It is a vertical slice, not the
refactor; see `demo/architecture/README.md` for exactly what it does and does
not claim, including the production-side `/* HP_TEST_HOOK */` marker the
equivalence test relies on.

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
