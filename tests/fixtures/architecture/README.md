# Architecture equivalence fixture

`fixture.uci` is the input to `tests/ucode/test_demo_architecture.sh`, which
proves that the production `generate_outbound()` (which now routes through
`OutboundFactory.create()`) produces the same sing-box outbound as the demo
Adapter path, field by field, for every protocol.

The fixture deliberately covers all 11 protocols the package supports
(vless, snell, shadowsocks, anytls, http, socks, trojan, shadowtls, tuic,
hysteria2, vmess) so a single failure surfaces as a per-protocol diff.
Keep it that way: a regression in any single adapter should be visible here
without needing a per-protocol test.

A copy of this file lives at `demo/architecture/fixture.uci` for readers
who prefer the demo as a top-level entry point. The test reads only the
tracked copy under `tests/fixtures/` so the demo can stay untracked
reference material without breaking CI.
