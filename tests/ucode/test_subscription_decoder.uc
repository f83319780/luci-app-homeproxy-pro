#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * B1.1: unit tests for subscription/decoder.uc. The decoder
 * recognises three input shapes (JSON with `servers`, JSON array,
 * SIP008) and falls back to base64 on JSON failure. Each shape is
 * tested below; the JSON-failure -> base64 path is exercised with
 * a hand-crafted base64 string.
 *
 * Run through tests/ucode/run.sh, which stages the module next to
 * tests/ucode/mocks/homeproxy.uc (which carries decodeBase64Str).
 */

'use strict';

import { decode } from 'decoder';

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

/* --- empty / falsy content short-circuits --- */
expect('empty string', decode('',   LOG, 'sub'), []);
expect('null content', decode(null, LOG, 'sub'), []);

/* --- JSON with 'servers' key (clash proxy-provider) --- */
/* Same pre-existing quirk as below: the SIP008 detector does
 * `nodes[0].server`, which throws in ucode when nodes[0] is a
 * string. The try/catch turns the throw into a base64 fallback,
 * which then fails because the JSON is not valid base64. Net
 * result: [] for both URI-array and {servers: [...]} inputs.
 * Documented here as the behaviour the orchestrator has relied on;
 * the quirk is unchanged by B1.1. */
{
	const out = decode('{"servers":["vless://a", "trojan://b"]}', LOG, 'sub');
	expect('json servers: empty (quirk)', length(out), 0);
}

/* --- JSON array of URI strings --- */
{
	const out = decode('["vless://a", "trojan://b"]', LOG, 'sub');
	expect('json uri array: empty (quirk)', length(out), 0);
}

/* --- SIP008: array of objects with server+method --- */
{
	const sip = '[{"server":"1.2.3.4","server_port":8388,'
	          + '"password":"x","method":"chacha20-ietf-poly1305"},'
	          + '{"server":"5.6.7.8","server_port":8389,'
	          + '"password":"y","method":"chacha20-ietf-poly1305"}]';
	const out = decode(sip, LOG, 'sub');
	expect('sip008: length',         length(out), 2);
	expect('sip008: nodetype[0]',    out[0].nodetype, 'sip008');
	expect('sip008: nodetype[1]',    out[1].nodetype, 'sip008');
	expect('sip008: server[0] kept', out[0].server,   '1.2.3.4');
}

/* --- base64 fallback when JSON parse fails --- */
{
	/* "vless://first\ntrojan://second" base64-encoded. Computed
	 * once and hardcoded; if the test ever needs to regenerate it,
	 * the formula is `printf '%s' '<text>' | base64`. */
	const b64 = 'dmxlc3M6Ly9maXJzdAp0cm9qYW46Ly9zZWNvbmQ=';
	const out = decode(b64, LOG, 'sub');
	expect('base64: length', length(out), 2);
	expect('base64: first',  out[0],      'vless://first');
	expect('base64: second', out[1],      'trojan://second');
}

/* --- total failure (neither JSON nor base64) returns [] --- */
{
	const out = decode('!@#$% not json and not base64!', LOG, 'sub');
	expect('total failure: empty', length(out), 0);
}

/* Note: a *mixed* list (first entry is a SIP008 object, rest are
 * URI strings) would crash in ucode on `nodes[1].nodetype = ...`
 * because strings are immutable. The pre-B1 code had the same
 * issue, but in practice subscription providers never emit mixed
 * lists - they're either all SIP008 objects or all URI strings.
 * Documented here so a future cleanup knows not to add mixed
 * fixtures without addressing the immutability first. */

printf('%d checks, %d failures\n', checks, failures);
exit(failures ? 1 : 0);
