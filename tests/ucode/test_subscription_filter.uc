#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * B1.1: unit tests for subscription/filter.uc. Both check() and
 * apply_policy() are pure - no UCI access, no module state - so
 * the tests can hand them ordinary values and a no-op logger.
 *
 * Run through tests/ucode/run.sh, which stages the module next to
 * tests/ucode/mocks/homeproxy.uc so the `from 'homeproxy'` import
 * resolves to the test double.
 */

'use strict';

import { check, apply_policy } from 'filter';

const LOG = (..._args) => {};

let failures = 0;
let checks = 0;

function expect(name, actual, expected) {
	checks++;
	if (sprintf('%J', actual) !== sprintf('%J', expected)) {
		printf('FAIL %s: expected %J, got %J\n', name, expected, actual);
		failures++;
	}
}

/* --- check(): disabled mode passes everything through --- */
expect('disabled + match',    check('foo',     'disabled', ['foo'], LOG), false);
expect('disabled + miss',     check('foo-bar', 'disabled', ['baz'], LOG), false);
expect('disabled + no kw',    check('foo',     'disabled', [],       LOG), false);

/* --- check(): empty inputs short-circuit --- */
expect('empty name',          check(null, 'blacklist', ['x'], LOG), false);
expect('empty keywords',      check('foo', 'blacklist', [],    LOG), false);

/* --- check(): blacklist --- */
expect('blacklist hit',       check('foo-bar', 'blacklist', ['bar'],     LOG), true);
expect('blacklist miss',      check('foo-bar', 'blacklist', ['baz'],     LOG), false);
expect('blacklist multi-hit', check('foo-bar', 'blacklist', ['baz','bar'],LOG), true);
expect('blacklist invalid-rx skipped',
	check('foo', 'blacklist', ['[unterminated'], LOG), false);

/* --- check(): whitelist inverts the result --- */
expect('whitelist hit (kept)',   check('foo-bar', 'whitelist', ['bar'], LOG), false);
expect('whitelist miss (dropp)', check('foo-bar', 'whitelist', ['baz'], LOG), true);
/* whitelist with no keywords: the early-return guard (isEmpty(keywords))
 * fires before the whitelist inversion, so the node is kept. Documenting
 * this here so a future cleanup of the early-return does not silently
 * change the behaviour. */
expect('whitelist empty kw (kept)', check('foo-bar', 'whitelist', [], LOG), false);

/* --- apply_policy(): tls_insecure override --- */
{
	const cfg = apply_policy(
		{ tls: '1', type: 'vless' },
		{ allow_insecure: '1', packet_encoding: 'xudp' }
	);
	expect('tls=1 + allow_insecure=1 sets tls_insecure', cfg.tls_insecure, '1');
	expect('tls=1 + allow_insecure=1 also sets packet_encoding', cfg.packet_encoding, 'xudp');
}
{
	const cfg = apply_policy(
		{ tls: '1', type: 'vless' },
		{ allow_insecure: '0', packet_encoding: 'xudp' }
	);
	expect('tls=1 + allow_insecure=0 leaves tls_insecure absent',
		'tls_insecure' in cfg, false);
}

/* --- apply_policy(): packet_encoding only for vless/vmess --- */
{
	const cfg = apply_policy(
		{ tls: '0', type: 'trojan' },
		{ allow_insecure: '0', packet_encoding: 'xudp' }
	);
	expect('trojan + packet_encoding not set', 'packet_encoding' in cfg, false);
}
{
	const cfg = apply_policy(
		{ tls: '0', type: 'vmess' },
		{ allow_insecure: '0', packet_encoding: 'xudp' }
	);
	expect('vmess + packet_encoding set', cfg.packet_encoding, 'xudp');
}

/* --- apply_policy(): null / undefined guard --- */
expect('apply_policy(null) returns null', apply_policy(null, { allow_insecure: '0', packet_encoding: 'xudp' }), null);

printf('%d checks, %d failures\n', checks, failures);
exit(failures ? 1 : 0);
