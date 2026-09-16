# Security

luci-app-homeproxy-pro is a network-facing proxy package. The package ships a
ucode-based admin interface, an ubus RPC surface, and a UCI configuration that
any process on the router (or any host on the LAN with shell) can write to.

This page is the **private** reporting channel for things that public issues
should not carry. Subscription URLs are tokens; do not paste them into a
public thread. Same for any concrete payload that demonstrates an injection.

## Reporting a vulnerability

Open a **GitHub Security Advisory** through the repository's Security tab
("Report a vulnerability"). This sends the report to the maintainer privately.

If you cannot use the GitHub Security tab, email the maintainer at
`security@szwjp.dev` (or whatever the maintainer's current contact is — the
address below is the one set up for this purpose). **PGP key on request**.

Either way, do **not** open a public issue for the initial report. A public
thread draws attention to a not-yet-patched bug.

## What to include

- The exact version (`PKG_VERSION` / `PKG_RELEASE`)
- The firmware (`/etc/openwrt_release` or equivalent)
- Steps to reproduce, with any URLs / tokens redacted
- The expected vs actual behaviour
- A suggested fix (optional but appreciated)

## Response time

Initial triage: **within 7 days**. We may reply faster; we will not reply
slower without a status update.

Disclosure timeline: the maintainer will work with you on a coordinated
disclosure. A patch is usually available within 30 days of confirmed
reproducibility; the advisory is published when a tagged release ships.

## What is in scope

- The RPC methods defined in `root/usr/share/rpcd/ucode/luci.homeproxy`
- The CBI views under `htdocs/luci-static/resources/view/homeproxy/`
- The shell scripts under `root/etc/homeproxy/scripts/`
- The ubus ACL in `root/usr/share/rpcd/acl.d/`
- The capabilities set in `root/etc/capabilities/`
- The nftables template `root/etc/homeproxy/scripts/firewall_post.ut`

If you are not sure whether something is in scope, report it anyway; the
maintainer will tell you.

## What is NOT a vulnerability

- The user has shell on the router and can read or write UCI directly.
  This is by design; the package trusts UCI to be local-writable and
  enforces validation on every write (the H1 / H2 / H3 fix series; the guards
  that pin them are in `tests/arch-guard.sh`).
- The package drops capabilities to the minimum needed for tproxy/TUN;
  the absence of a capability that you think a process needs is a feature,
  not a bug (the capability set is pinned by `tests/arch-guard.sh`).
- The firmware does not include sing-box. Without sing-box the package does
  not function; that is documented in the README, not a security issue.

## Recent fixes worth knowing about

If you found something already patched, the audit trail is the commit
history. The most relevant recent fixes:

- **H1** (2026-09-16): UCI-derived values are validated in
  `firewall_utils.c` before reaching `firewall_post.ut`. Without this, a
  malformed value would have failed the whole `fw4 reload`.
- **H2** (2026-09-16): `CAP_SYS_PTRACE` and `CAP_NET_RAW` are no longer
  granted to the homeproxy process.
- **H3** (2026-09-16): subscription URLs are redacted inside `wGETVerbose()`
  so a leaked `error` field cannot leak the token.
- **M1** (2026-09-16): `tests/run.sh` no longer defaults to sshing into a
  hardcoded LAN address.

Each of these has a guard in `tests/arch-guard.sh` that reverse-verifies the
fix.

## Disclosure policy

Once a fix ships, the maintainer publishes:
1. A GitHub Security Advisory with the credit, the affected versions, and
   the patch summary.
2. A commit on `main` referencing the advisory.
3. A note in the next release's `PKG_RELEASE` bump.

Public credit is given by default. If you prefer to remain anonymous, say so
in the initial report and the advisory will reflect that.