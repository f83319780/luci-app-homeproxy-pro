# Contributing

Thanks for taking a look. luci-app-homeproxy-pro is a fork of immortalwrt/luci
applications/luci-app-homeproxy that targets sing-box 1.14+; the goal is a
modular, testable package that ships on ImmortalWrt/OpenWrt without rebuilding
the underlying proxy.

This file is for **how to land a change**. The architectural rules are
executable rather than prose: `tests/arch-guard.sh` pins them, and each guard
names the rule it enforces. The reasoning behind past decisions is in the
commit messages and the PRs that made them — the maintainer's working design
notes are deliberately not part of this tree.

## Workflow

1. **Fork & branch**. Base on `main`. Branch names like `fix/<area>-<short>` or
   `feat/<area>-<short>` are fine (`fix/firewall-port-validator`,
   `feat/subscription-multi-mirror`).

2. **Write the test first.** Most behaviour is pinned by either:
   - the **architecture guard** (`tests/arch-guard.sh` — 16 layers of cross-cutting
     invariants: UCI paths, capabilities, shell quoting, RPC whitelists, ...)
   - the **form snapshot** (`tests/luci-form-snapshot.js` — node/client/server
     forms are byte-diffed against `tests/snapshots/`)
   - the **ucode unit tests** (`tests/ucode/test_*.uc`)
   - the **frontend invariant tests** (`tests/frontend-*.js`)

   If your change does not have an obvious place among these, the question to
   answer before opening the PR is "what new test goes here, and which of
   these would have caught the bug?". If the answer is "none of them",
   your change is probably a regression in disguise — talk to the maintainer
   before writing code.

3. **Run the suite locally** before pushing:
   ```sh
   unset HP_TEST_HOST
   sh tests/run.sh
   ```
   The suite skips the device-side ucode layer when `HP_TEST_HOST` is unset; that
   is the right behaviour on a development host. On a CI machine the suite
   runs the same way; the on-target workflow (`workflow_dispatch`) is for
   manual verification only.

4. **Reverse-verify your guard.** If you added a new arch-guard, temporarily
   break the rule it pins and confirm the guard goes red. A guard that does
   not turn red under the regression it is meant to catch is not a guard.

5. **Commit message**: problem → fix → verification evidence. The repository
   convention is one paragraph per block. Example shape:
   ```
   fix(firewall): reject bad IPv4 in UCI before nft sees it

   Problem: a malformed UCI value used to land verbatim in an nft anonymous
   set; fw4 reload then failed and the router lost its firewall entirely.

   Fix: ipv4_to_nftarr() validates each entry, drops the bad ones, and
   writes the rest as the nft expression.

   Verification: tests/ucode/test_firewall_validators.sh covers the report's
   injection shapes; arch-guard 11 pins every call site; both reverse-
   verified by re-introducing the regression.
   ```

6. **Push & open a PR.** PR description should call out:
   - The architecture rule your change touches (or "no rule")
   - The new test that pins it
   - Any ADR you wrote (if your change closes a decision)

## What not to do

- Do not bump `PKG_VERSION` / `PKG_RELEASE` in a feature PR. The release
  pipeline does that on a tag.
- Do not add in-progress design notes to the published tree. The working
  documents live in a gitignored `docs/` directory and never reach a clone;
  what ships is the code, its guards and this file.
- Do not add a dependency that the consumer's firmware may not have. The
  package already pulls `+sing-box +firewall4 +kmod-nft-tproxy +kmod-tun +ucode-mod-digest`
  on the Makefile side; runtime imports (`system('sing-box ...')`, etc.) must
  assume these and nothing more.
- Do not weaken the arch-guard to make a change pass. If a guard is in the way,
  the guard is right and the change needs to be redesigned.

## Filing issues

Bug reports: include the sing-box version, the OpenWrt/ImmortalWrt version,
and the `logread` excerpt. **Subscription URLs are tokens; redact them before
pasting.** The maintainer will not ask for them.

Feature requests: open an issue first. The plan's priority order is documented;
a feature request that lands without going through the plan is unlikely to be
merged.

Vulnerabilities: see `SECURITY.md`. Do not open a public issue.

## Code style

- Ucode: 4-space indent, one `export` per symbol, and **every `export function`
  must end with `};`** — the ucode shipped by ImmortalWrt/OpenWrt 2026.01.16
  rejects the semicolon-free form and `tests/ucode/test_ucode_grammar.sh` pins
  that dialect. Indentation follows the file you are editing.
- JavaScript: 4-space indent, trailing commas, single-quote strings. The
  LuCI form framework expects you to mutate `form.Map` objects in place rather
  than constructing new ones; do not refactor that without the snapshot test
  agreeing.
- Shell: every `system()` argument that contains `${var}` must go through
  `shellQuote()` (see arch-guard 16). The reason is mechanical checkability,
  not aesthetics — leave constants quoted too, the rule is "all shell args".
- Commit: one concern per commit. Larger refactors go in their own PR, not
  folded into a feature.

## Maintainer

The repository owner is the only person who can merge. Expect a few review
rounds on anything architectural; expect a quick rubber-stamp on typo-fix
PRs.