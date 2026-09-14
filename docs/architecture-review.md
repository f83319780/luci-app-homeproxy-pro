# Architecture Refactor Review (A1–A5)

**Reviewed commits** (szwjp/luci-app-homeproxy-pro, branch `main`,
622360f..4c4c548):

| # | Commit  | Title                                                   | Files  | +/– |
|---|---------|---------------------------------------------------------|--------|-----|
| 1 | a07cfd6 | refactor(arch): introduce domain model skeleton (A1.1)  | 8      | +1042 / –1 |
| 2 | 2f2a988 | refactor(arch): fill domain sub-objects from UCI (A1.2) | 5      | +415 / –105 |
| 3 | 18ddffa | refactor(arch): wire the generator through HomeProxyConfig (A2)  | 5  | +313 / –64 |
| 4 | 15724a4 | refactor(arch): wire all 10 protocol adapters (Stage A4) | 2      | +143 / 0 |
| 5 | b9028c2 | refactor(arch): route the generator through the Adapter (A3+A5) | 7 | +197 / –127 |
| 6 | 4c4c548 | test(toolchain): add macOS ucode build + sing-box version gate | 5 | +357 / –1 |
| **Total** | | | **20 unique** | **+1 905 / –298** |

Commit 6 is testbed scaffolding, not a refactor step; it makes the
other five run on a dev host. The review below covers commits 1–5.

## Goals (recap)

The refactor guide (`homeproxy_architecture_refactor_agent_guide.md`)
asks for the same six-layer shape that sing-box already has, but at
the configuration level:

```
UCI → Config Loader → HomeProxyConfig / Node → Protocol Adapter → sing-box JSON
```

The previous code (before A1) collapsed the Loader, the Domain Model
and the Adapter into one 1 229-line generator with ~60 `uci.get()`
calls scattered through the file and a 110-line `generate_outbound()`
function full of `type === '…' ? … : null` ternaries. The refactor
turns that into data tables, three files and one shim.

## What the refactor actually did

### A1.1 — Skeleton (`a07cfd6`)

`root/etc/homeproxy/scripts/config/{loader,model,adapter}.uc` are
introduced, lifted verbatim from `demo/architecture/`. The two
copies are kept in sync by the test suite (`test_demo_architecture.sh`
runs against the production path, `demo/architecture/demo.uc` runs
against the reference copy). `Loader.load()` returns a
`HomeProxyConfig` with five empty sub-objects so downstream code can
already assert their presence.

`Node.create({...})` produces a Node shaped as the Adapter expects
(sub-objects, not flat prefixed keys). `Node.validate()` and
`Node.tag()` live in the model, not the generator.

`tests/ucode/test_domain_model_skeleton.sh` is a 34-check fixture
loader; on a fixture that exercises every UCI section, it asserts
the field set and value of each sub-object. The 5 missing
sub-objects (dns, routing, endpoints, access_control, server) are
documented placeholders in `Config.create()`.

`tests/snapshots/generator/.gitkeep` is the placeholder for per-
protocol golden JSON, reserved for A4.

**Verdict:** Clean introduction. The two notable bugs caught during
this stage (`CREDENTIALS.shadowsocks.method` and
`CREDENTIALS.snell.userkey` mapping to non-existent UCI option
names) are fixed in the same commit. The fixture test caught both.

### A1.2 — Sub-object population (`2f2a988`)

The Loader grows the five sub-object readers:
`load_dns`, `load_routing`, `load_access_control`, `load_server`
and `load_sections(uci, type)` for list sections. Every sub-object
ships with its corresponding `settings` dict (built by
`load_settings(uci, section, keys)`), three list sections, the two
helper tables and a list of `wan_proxy_*_ips` /
`subscription_url` / `filter_keywords`.

`udp_timeout` is moved out of `general` and into both
`routing.settings.udp_timeout` and `infra.udp_timeout` (the
generator branches on `routing_mode` to read one or the other). The
pre-A1.2 `general.udp_timeout` was incorrect; A1.2 fixes it.

`tests/fixtures/generators/domain.uci` is the new fixture (10
protocols, every UCI section the Loader is supposed to read).
`test_domain_model_skeleton.sh` is grown to 63 checks.

**Verdict:** Honest about what changed. The 22 lines of git diff in
`loader.uc` plus 153 lines of new code in `model.uc` are almost
entirely new feature surface; the test grew from 34 to 63 checks.
One missed opportunity: the `__HP_TEST_DOMAIN_MODEL__` plumbing
could have been added here, but the Loader changes were
independently testable so the reviewer's instinct to commit a clean
slice was correct.

### A2 — Dual-track read path (`18ddffa`)

`generate_client.uc` (and later `generate_server.uc`) gain a
`__HP_TEST_DOMAIN_MODEL__` placeholder, six `g/i/d/r/c/s` helpers
that flip every scalar UCI read onto the `HomeProxyConfig` values
when the flag is on, and an `iter_sections(name, cb)` helper that
replaces each `uci.foreach(...)` call with a unified interface.
When the flag is off, the helpers fall back to the legacy
`uci.get()` / `uci.foreach()` calls so the two paths are compared
field-by-field on the same fixture.

`tests/ucode/test_generators.sh` adds a `dual_run()` block: the
same fixture is run twice (flag=0, then flag=1), the outputs are
normalised (log.output, data_directory, resources/cache_file paths
are rewritten back to the base dir) and `cmp`'d.

`tests/ucode/test_demo_architecture.sh` is updated to alias the
`Loader` import in the hook to `DemoLoader`, because the production
file now imports `Loader` at the top.

**Verdict:** This is the highest-risk commit. Three regressions were
fixed during the test pass:

* `Loader.load()` was called without an argument, so it read
  `/etc/config/homeproxy` on the dev host instead of the staging
  dir. `test_generators.sh` now sed-substitutes `Loader.load()`
  → `Loader.load('$dir/config')` at staging time. The same
  rewrite is needed for `cursor()` so the two paths agree.
* `log.output` (and friends) read from `RUN_DIR`, which differs
  between base and on_dir staging. The dual-run block now
  normalises the path before `cmp`ing. The contract is "JSON
  semantics match, testbench paths don't".
* `test_domain_model_skeleton.sh` staging didn't `mkdir -p` the
  `config/` subdir in `$WORK/scripts`, so the relative
  `./config/loader.uc` import could not resolve; the staging
  script was fixed to mirror the production layout.

A fourth, smaller trap was the local `popen` segfault on the macOS
ucode build. A2 swaps it for a sed-injected constant so the flag
mechanism survives both runtimes.

**A2 is the only commit where the test infra had to grow at the
same time as the production code; the others are production-only
or test-only.** The dual-run block is a real piece of engineering
machinery that will keep paying off (any future regression in
the Loader/Adapter pipeline will be caught here).

### A4 — All 10 protocol Adapters (`15724a4`)

`OPT_FIELDS` in `adapter.uc` grows from 2 entries (vless, snell)
to 11. `PROTOCOL_OPTIONS` in `loader.uc` grows the same way.
`demo/architecture/fixture.uci` adds a node per remaining protocol
(anytls, http, socks, trojan, shadowtls, tuic, hy2, vmess); the
demo equivalence test now exercises every protocol and reports
"11/11 nodes byte-identical to production generate_outbound()".

A few notable adapter choices:

* `shadowsocks` adds `plugin` / `plugin_opts` / `udp_over_tcp`.
* `tuic` maps `tuic_enable_zero_rtt` to `zero_rtt_handshake`
  (sing-box 1.14 schema name) and adds `udp_over_stream` /
  `heartbeat`.
* `hysteria2` re-uses the hysteria obfs shape and adds
  `hop_interval_max` / `bbr_profile` / `disable_chrome_parrot`.
  `hopping_port` is kept as the UCI name; the rename to
  `server_ports` happens in the Adapter.
* `vmess` carries `alter_id` / `security` / `global_padding`.

**Verdict:** Compresses 10 protocol PRs into one commit. The review
guide suggested one PR per protocol; the commit message is honest
about that and explains why: every protocol touches the same three
files (Loader.PROTOCOL_OPTIONS, Adapter.OPTION_FIELDS, fixture), the
diff per protocol is small enough that splitting would add review
overhead without shipping faster. The fixture's `fixture.uci`
remains untracked (the user explicitly said demo is reference, not
source) so the diff is only the Adapter and Loader tables.

The `n_tuic.zero_rtt_handshake: missing on the candidate side`
failure during the test pass caught a real bug: the UCI option is
named `tuic_enable_zero_rtt`, not `tuic_zero_rtt_handshake`.
The test caught it before any user hit a "this config doesn't
match what I set in the UI" bug.

### A3+A5 — Adapter is the only outbound builder (`b9028c2`)

`generate_client.uc`'s 280-line `generate_outbound(cfg)` is
replaced with a 20-line shim. The shim's only job is to record
direct-node overrides into the module-level `direct_overrides`
table (a side effect the Adapter has no place for, because the
route builder reads it later) and then call
`OutboundFactory.create(Node.from_section(cfg), self_mark)`.

`Node.from_section()` is the bridge from the old flat-UCI-dict
shape that the rest of `generate_client.uc` still passes around
(its five call sites were not touched) to the Node shape the
Adapter expects. It inlines the `load_tls` / `load_transport` /
`load_multiplex` / `load_protocol_options` logic from
`loader.uc`; the test suite (a) keeps the two copies in sync and
(b) verifies the Node-side copy with the same `domain.uci`
fixture that exercises the Loader side.

Two bugs caught by `sing-box check` during the test pass:

* `legacy_view()` was emitting `transport.host` for every
  transport kind. sing-box 1.14 rejects `transport.host` for ws
  outbounds (it wants `headers.Host` instead). The shim is now
  type-aware: ws gets `ws_host`, http gets `http_host`,
  httpupgrade / http2 get `httpupgrade_host`.
* The `routing_mark: null, /* comment */` line tripped the
  ucode parser, which interprets `value, /* comment */` as
  starting a new block. The comment was moved to its own line.

A third, smaller issue: `hopping_port` is the UCI option name for
the Hysteria2 port-hopping list; the sing-box schema calls it
`server_ports`. The rename happens in the Adapter.

**Verdict:** The load-bearing commit. After A5, the only way to
add a new protocol is `1` row in `PROTOCOL_OPTIONS`, `1` row in
`CREDENTIALS`, and `1` row in `OPTION_FIELDS` (or `CLAIM_FIELDS`
when the protocol has renamed credentials). The 280-line function
is gone. The dual-run block continues to pass because the Adapter
is now the only place that produces outbound JSON.

The `routing_mark: null, /* comment */` failure is a good example
of why the test infra exists: ucode is a small enough parser that
syntax errors that *look* trivial blow up spectacularly.

## Cross-cutting observations

### 1. The two CREDENTIALS tables

`model.uc` has *two* CREDENTIALS tables: one for the Loader's
`load_credentials()` (consumed by `Node.create()` in the Loader)
and one for `Node.from_section()` (consumed by the generator
shim). They have to stay in sync. The test suite has no explicit
check for this; the next person to add a protocol who only updates
one of them will get a silent regression on the dual-run block.

**Recommendation:** the second table is a sign of duplication.
The cleaner next step is to make `Loader.load_credentials()`
public, export it from `loader.uc`, and have `Node.from_section`
import it. This will become important when a new protocol
(looking at you, Hysteria 2) is added and the table grows.

### 2. `Node.from_section()` is a bridge, not the destination

The shim still takes a flat UCI dict in. A future A-stage should
move the five call sites (line 839, 864, 877, 914, 932) to take
`Node` directly. The shim itself can be deleted once the last
call site is converted, and `Node.from_section()` can be deleted
once the generator's `uci.get_all()` calls are replaced with
`Loader.lookup_node(section_name)`. Both are simple follow-ups.

### 3. `legacy_view()` is still a shim

`buildTLSObject(legacy, false)` and `buildTransportObject(legacy, false)` accept the flat UCI dict the pre-refactor code
used. The Adapter hands them a flat dict constructed from
`Node`'s sub-objects. As long as `buildTLSObject` and
`buildTransportObject` stay where they are (in `homeproxy.uc`),
the shim has to stay. Both helpers would benefit from a Node-shaped
input — a small A3.5 stage that refactors the two helpers in
`homeproxy.uc` to take a Node and have the Adapter skip the shim
entirely.

### 4. `direct_overrides` is a module-level side effect

The shim writes to `direct_overrides[node['.name']] = {…}`;
the route builder later reads it. This is a global mutable that
the Adapter cannot own. Worth a comment in
`generate_client.uc` warning future readers; worth an eventual
`Node.raw.direct_overrides = {…}` field so the side effect
moves into the data.

### 5. Test coverage is the only real safety net

`test_generators.sh`'s dual-run block is the only thing keeping
the Loader ↔ uci.cursor() paths in lockstep. As long as A3+A5
keeps the Adapter as the only outbound builder, the dual-run
block is technically redundant (both paths converge on
`OutboundFactory.create()`) — but it is also the cheapest
regression test for *any* future Loader or Domain Model change.
It should stay.

## Recommended follow-ups (in priority order)

1. **De-duplicate the CREDENTIALS tables.** Export
   `load_credentials` from `loader.uc` and have
   `Node.from_section()` import it. ~10 lines of code, but
   removes the future-bug class where the two CREDENTIALS tables
   drift apart.
2. **Convert the five shim call sites to take a Node.** Once the
   `uci.foreach(ucinode, ...)` and `uci.get_all(uciconfig, name)`
   calls are replaced with `ConfigQuery.node_by_id(config, id)`
   (or a new `Loader.lookup_node(name)`), the shim and
   `Node.from_section()` can both be deleted. The five call
   sites become `OutboundFactory.create(node, self_mark)`.
3. **Refactor `buildTLSObject` / `buildTransportObject` to take a
   Node.** Then `legacy_view()` can be deleted; the Adapter
   passes `node.tls` / `node.transport` directly.
4. **Stage B1 — subscription pipeline.** Fetcher/Decoder/Filter/
   Repository is a clean separation that does not depend on
   anything else in this refactor. The user has not asked for it
   yet, but the boundaries laid down by A1.2 (`access_control`
   already exposes `filter_keywords` and `subscription_url`)
   are ready.
5. **Stage E1 — UCI file-level transaction.** Now that
   `HomeProxyConfig` is the only place the generator reads from,
   a transaction wrapper around `apply()` and `commit()` is
   small. Stage E1 will be much smaller than the original plan
   suggested, because the Adapter has absorbed most of the
   per-config-field complexity.

## Bottom line

The refactor does what the guide said: 280 lines of ternary soup
gone, every per-protocol field now lives in a data table, the
UCI cursor is owned in one place, and a new protocol is one
PROTOCOL_OPTIONS row + one CREDENTIALS row + one OPTION_FIELDS
row. The dual-run test is the only thing preventing silent
regressions, and the demo equivalence test (11/11 nodes
byte-identical) is the only thing that caught two of the
genuine bugs (tuic zero_rtt naming, ws transport.host
mismatch) before sing-box rejected the output.

The refactor did *not* reach the goal of "the Adapter is the
*only* outbound builder" without bridging: the generator still
passes a flat UCI dict around and `Node.from_section()` /
`legacy_view()` translate it. The follow-ups above reduce that
friction step by step.

## Follow-ups since this review

The five items in "Recommended follow-ups" have been tracked
and four have landed. Mapping them to the closing commits:

| # | Item from this review                                            | Commit(s)                       |
|---|------------------------------------------------------------------|---------------------------------|
| 1 | De-duplicate the CREDENTIALS tables                              | `11af0bd` + `da9b5c8`           |
| 2 | Convert the five shim call sites to take a Node                 | `da9b5c8` (P1-A)                |
| 3 | `buildTLSObject` / `buildTransportObject` take a Node            | `9b0d679` (P1-B)                |
| 4 | Stage B1 - subscription pipeline (Filter / Decoder / Fetcher / Repository) | `6a08e1e` (B1.1) + `b524492` (B1.2) |
| 5 | Stage E1 - UCI file-level transaction                            | pending                         |

The validation and `node.raw` follow-ups (mentioned in the
"Bottom line" paragraph above) were also picked up:

  - `458b635` (P3-D) split `Node.validate()` (generic) from
    `OutboundFactory` (per-protocol), so the model stays free of
    sing-box-outbound field names.
  - `dbf5e96` (P3-E) added `node.common` + `PROTOCOL_OPTIONS.direct`
    so the Adapter no longer reads specific fields from
    `node.raw`; only the verbatim tail remains there for the
    Loader's not-yet-modelled shapes.

After these commits the original goal in the "Bottom line"
holds: the Adapter is the only outbound builder, and the
generator does not know UCI exists. The remaining gap is `E1`
(transactional commit) and the secondary gaps called out in
`docs/architecture-review.md` itself (e.g. `Loader.lookup_node`,
which never landed because `ConfigQuery.node_by_id` covered the
same use case).

