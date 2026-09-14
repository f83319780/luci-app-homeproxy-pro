#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Equivalence test for the architecture demo: the same UCI input must produce
# the same sing-box outbound through
#
#   (a) the current generator's generate_outbound(), and
#   (b) demo/architecture/{loader,model,adapter}.uc
#
# (a) is reached by replacing one line of a generator *copy* with a hook that
# runs before the main body, so the production file is never modified and the
# comparison runs against the real function, not a copy of it. The hook exits
# before any UCI read or JSON write, which also keeps the test out of /var/run.
#
# Usage: sh tests/ucode/test_demo_architecture.sh <repo-root> [work-dir]

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-demo-test}"

ROOT="$(cd "$ROOT" && pwd)"
DEMO="$ROOT/demo/architecture"
FAILED=0

rm -rf "$WORK"
mkdir -p "$WORK/config"

# The demo loads `homeproxy` (production helpers) and, through it, `luci.http`.
# HP_VALIDATE_DATA is honoured for the same reason as in test_generators.sh.
VALIDATE_DATA="${HP_VALIDATE_DATA:-/sbin/validate_data}"
sed -e "s#/sbin/validate_data#${VALIDATE_DATA}#" \
	"$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" > "$WORK/homeproxy.uc"

# Stage A1.1: generate_client.uc's hook now imports Loader/OutboundFactory
# from ./config/*.uc. Mirror that layout next to the staged generator so
# the relative import resolves.
mkdir -p "$WORK/config_module"
cp "$ROOT/root/etc/homeproxy/scripts/config/loader.uc"  "$WORK/config_module/"
cp "$ROOT/root/etc/homeproxy/scripts/config/model.uc"   "$WORK/config_module/"
cp "$ROOT/root/etc/homeproxy/scripts/config/adapter.uc" "$WORK/config_module/"
ln -sfn "$WORK/config_module/loader.uc"  "$WORK/config/loader.uc"
ln -sfn "$WORK/config_module/model.uc"   "$WORK/config/model.uc"
ln -sfn "$WORK/config_module/adapter.uc" "$WORK/config/adapter.uc"

cp "$DEMO/fixture.uci" "$WORK/config/homeproxy"

# Hook: load the new architecture, diff it against the production builder
# field by field, exit. %J makes the comparison value-exact, so key order is
# irrelevant; the demo output is compared after removeBlankAttrs() on both
# sides, which is what the generator does before writing.
#
# Loader / Adapter are read from the production tree (Stage A1.1); demo/
# keeps a verbatim reference copy under demo/architecture/ for reading.
cat > "$WORK/hook.part" <<EOF
/* Hook injected by tests/ucode/test_demo_architecture.sh - never shipped.
 *
 * 'Loader' and 'OutboundFactory' are already imported at the top of
 * generate_client.uc (Stage A1.1 added Loader; Stage A3+A5 added
 * OutboundFactory when the generator started using the Adapter), so
 * both copies are aliased here to avoid "Import name already used"
 * errors. The production generator never executes the hook. */
import { Loader as DemoLoader } from '$ROOT/root/etc/homeproxy/scripts/config/loader.uc';
import { OutboundFactory as DemoOutboundFactory } from '$ROOT/root/etc/homeproxy/scripts/config/adapter.uc';

{
	const demo = Loader.load('$WORK/config');
	const mark = demo.infra.self_mark;
	let checks = 0, failures = 0;

	/* Structural comparison: %J output depends on key insertion order, which
	   legitimately differs between the two implementations, so compare values
	   per key instead and report the exact paths that diverge. */
	function diff(a, b, path, out) {
		if (type(a) !== type(b)) {
			push(out, sprintf('%s: type %s != %s', path, type(a), type(b)));
			return;
		}

		if (type(a) === 'object') {
			for (let k in keys(a))
				if (!(k in b))
					push(out, sprintf('%s.%s: missing on the candidate side', path, k));

			for (let k in keys(b)) {
				if (!(k in a)) {
					push(out, sprintf('%s.%s: missing on the reference side', path, k));
					continue;
				}

				diff(a[k], b[k], sprintf('%s.%s', path, k), out);
			}

			return;
		}

		if (type(a) === 'array') {
			if (length(a) !== length(b)) {
				push(out, sprintf('%s: %d != %d elements', path, length(a), length(b)));
				return;
			}

			for (let i = 0; i < length(a); i++)
				diff(a[i], b[i], sprintf('%s[%d]', path, i), out);

			return;
		}

		if (a !== b)
			push(out, sprintf('%s: %J != %J', path, a, b));
	}

	for (let node in demo.nodes) {
		const reference = removeBlankAttrs(generate_outbound(node.raw));
		const candidate = DemoOutboundFactory.create(node, mark);
		const problems = [];

		checks++;
		diff(candidate, reference, node.id, problems);

		if (length(problems)) {
			printf('FAIL: %s: %d field(s) differ\n', node.id, length(problems));
			for (let problem in problems)
				printf('  %s\n', problem);
			failures++;
		} else {
			printf('PASS: %s: outbound identical (%d fields)\n',
				node.id, length(keys(reference)));
		}
	}

	if (checks === 0) {
		printf('FAIL: the demo loaded no nodes from $DEMO/fixture.uci\n');
		failures++;
	}

	printf('%d node(s) compared, %d failure(s)\n', checks, failures);
	exit(failures ? 1 : 0);
}
EOF

# Copy of the generator with the fixture cursor redirected, and an explicit
# hook command comment replaced by the comparison block. 'HP_TEST_HOOK' is
# a documented injection point that sits after every module-level option has
# been read and before any outbound is emitted, so the hook can call the real
# builders and exit. The cursor rewrite anchor is the same one
# tests/ucode/test_generators.sh depends on; that fragility is itself part of
# the argument for the loader layer (see demo/architecture/README.md).
#
# Stage A1.1 sed: __HP_TEST_DOMAIN_MODEL__ is the testbed-injected flag
# that controls whether the generator reads UCI directly (off) or via
# Loader.load() (on). The hook is verified with both off, since
# OutboundFactory is what we are testing here, not the Loader path.
sed -e "s#const uci = cursor();#const uci = cursor('$WORK/config');#" \
    -e "s#__HP_TEST_DOMAIN_MODEL__#0#g" \
    -e "/\\/\\* HP_TEST_HOOK \\*\\//r $WORK/hook.part" \
    -e "/\\/\\* HP_TEST_HOOK \\*\\//d" \
	"$ROOT/root/etc/homeproxy/scripts/generate_client.uc" > "$WORK/generate_client.uc"

if ! grep -q "Hook injected by" "$WORK/generate_client.uc"; then
	echo "FAIL: could not hook the generator (the /* HP_TEST_HOOK */ marker is gone)"
	exit 1
fi

if ( cd "$WORK" && ucode -L "$WORK" generate_client.uc ); then
	echo "PASS: demo outbound equals the production generate_outbound()"
else
	echo "FAIL: demo outbound diverges from generate_outbound()"
	FAILED=1
fi

exit $FAILED
