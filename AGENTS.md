# Project rules for AI agents

This file is consumed by OpenCode / Codex / Cursor / Aider / Devin / Gemini
CLI / and any other AI coding tool that reads `AGENTS.md`. The rules below
override any default behaviour.

## The hard rule: no local test environment for this project

**Do not build or use a local test environment for this repository.** No
`~/.local/ucode-testbed/`, no `~/.local/ucode-strict/`, no Docker-as-Linux,
no WSL, no `tests/toolchain/build-ucode-linux.sh` invocation on a dev box.
Local simulators look like a green run but drift from the real target in
ways that have already shipped bugs in this project:

- r23 baseline `67d2c3a` cleared 131/131 arch-guard + 7/7 frontend tests
  on macOS, then exposed three bugs in production that no local check
  caught:
  1. `L.bind(hp.renderSectionAdd, this, ss, factory)` landed the factory
     in the `extra_class` slot and crashed with `InvalidCharacterError`
     the moment the section "Add" button rendered.
  2. `stubValidator` had `apply` and `assert` but no `factory`, so
     `validation.types['ip6addr']`'s `this.factory.parseIPv6` threw
     `TypeError: undefined is not an object` the first time any node
     address was labelled.
  3. `readfile()` returned `null` (not threw) on a missing file; the
     chained `split()` / `slice()` / `join()` propagated that null into
     the status RPC's `log_tail`, which the UI rendered as the literal
     text `null`.

The "stable test gate" is **the target environment itself** (`192.168.1.1`,
ImmortalWrt 25.12.2, sing-box 1.14.2, x86_64) plus end-to-end verification
through the browser:

| Step | Where |
| --- | --- |
| Source-of-truth verification | **CI** (`.github/workflows/build.yml` calling `.github/workflows/arch-test.yml`); the gate is `arch-test` green |
| UI / RPC end-to-end | **Live router** at `192.168.1.1`; `apk add --allow-untrusted --no-network` then load each tab in a real browser |
| Network uptime | sing-box 1.14.2 (pid 9360 in this session's captures) must keep listening on 5330/5331/5332/5333 throughout |

## What is still fine to run locally (smoke only)

These are pure-shell or pure-Node and do not pretend to be OpenWrt:

- `sh tests/arch-guard.sh "$(pwd)"` — file/conffile/structure assertions.
  Fast (under a second). Useful for catching obvious mistakes before push.
- `sh tests/run.sh` — runs the i18n coverage, the LuCI form snapshots, the
  frontend Node-only suites, and the runtime-equivalence shell checks. It
  reports `PARTIAL: the ucode layer did not run` and exits non-zero on a
  host without ucode — that is **not a pass**, it is an honest skip.
- `node tests/frontend-*.js` — pure JS, no ucode / no LuCI runtime.

These local suites are **structural smoke**, not behaviour verification. A
green run here is necessary but not sufficient: the bar for "ready to
tag" is CI green AND a browser smoke through each tab on the real router.

## What must never happen on this project

- Building `tests/toolchain/build-ucode-linux.sh` on a developer machine
  (Linux host, macOS host, Docker, WSL — all four). The toolchain script
  exists for CI; CI is the only legitimate caller.
- Tagging a release from a green local run alone. The tag step is
  `git tag v<PKG_VERSION>-r<PKG_RELEASE> && git push origin <tag>`, which
  triggers `build.yml`. The build then calls `arch-test.yml`; only that
  combined pass is authoritative.
- "Installing" on the live router without a config backup taken first.
  `apk` keeps a modified conffile and drops `<file>.apk-new` next to it;
  check `md5sum` on `/etc/config/homeproxy` before and after and only
  delete the `.apk-new` files once the config matches.

## Sing-box stays up

The user's main router at `192.168.1.1` is the lab for this repo's end-to-end
checks. **Network uptime is non-negotiable**: do not stop / restart
`/etc/init.d/homeproxy`, do not touch `/etc/config/homeproxy`, do not
replace `/etc/homeproxy/scripts/*`, do not restart sing-box. Replace only:

- `/www/luci-static/resources/homeproxy.js` and the view files under
  `/www/luci-static/resources/view/homeproxy/`
- `/usr/share/luci/menu.d/luci-app-homeproxy.json`
- `/usr/share/rpcd/acl.d/luci-app-homeproxy.json`
- `/usr/share/rpcd/ucode/luci.homeproxy`

…and then `killall -HUP rpcd` so the new module is picked up. The
post-install script already does this; verify by reading the apk's
`scripts:` block in `apk adbdump` before deploying.

If a deeper change requires touching the scripts / init / config, that
needs the user's explicit go-ahead per session and a config backup from
`/tmp/hp-r*-preflight-*/`.

## Session handoff

When handing the project to another agent or resuming after compaction:

- The user's GitHub handle is `szwjp`; the local clone is
  `/Users/wjp/Downloads/luci-app-homeproxy-pro`.
- Live router: `ssh root@192.168.1.1`. Do not guess the address from
  memory; confirm with `ssh -o ConnectTimeout=5` first.
- Backup convention: `/tmp/hp-r<NN>-preflight-<YYYYMMDD-HHMMSS>/` holds
  the UCI dump, the running `sing-box-c.json`, the procd state, the
  scripts and `init.d`; preserve the most recent one until the new
  release has been smoke-tested for at least 24 h.