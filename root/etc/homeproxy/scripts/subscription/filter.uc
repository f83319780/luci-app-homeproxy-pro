/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * B1.1: pure subscription filter. The orchestrator
 * (update_subscriptions.uc) used to inline both the keyword
 * whitelist/blacklist check and the post-parse policy application
 * (tls_insecure override, packet_encoding for vless/vmess). Moving
 * them here keeps the orchestrator focused on the fetch/cache/
 * repository flow and lets the pure logic be unit-tested without
 * UCI access.
 *
 * Neither function touches module state: mode / keywords / opts
 * come in as arguments, and a logger is passed in for the
 * invalid-regex warning. That makes the module callable from a
 * plain test stub and means the orchestrator can keep its own
 * file-writer log() around the call.
 */

'use strict';

import { isEmpty } from '../homeproxy.uc';

/* Decide whether a node named `name` should be dropped. `mode` is
 * one of:
 *   'disabled'  - filter is off, return false (keep)
 *   'blacklist' - drop if any keyword regex matches
 *   'whitelist' - drop unless any keyword regex matches
 *
 * `keywords` is a list of strings; each is compiled as a regexp.
 * One bad regex is logged and skipped, not treated as fatal - this
 * matches the pre-B1 behaviour, where a stray `[` would not block
 * the whole subscription.
 *
 * Returns true when the node should be skipped. */
export function check(name, mode, keywords, log) {
	if (isEmpty(name) || mode === 'disabled' || isEmpty(keywords))
		return false;

	let matched = false;
	for (let i in keywords) {
		let patten;
		try {
			patten = regexp(i);
		} catch (e) {
			log(sprintf('Skipping invalid filter keyword regex: %s.', i));
			continue;
		}
		if (patten && match(name, patten))
			matched = true;
	}
	if (mode === 'whitelist')
		matched = !matched;

	return matched;
};

/* Apply the two policy tweaks the orchestrator used to do inline:
 *   - tls_insecure is set on a config that has tls='1' when the
 *     user opted in via subscription.allow_insecure='1'
 *   - packet_encoding is set on vless/vmess configs to the
 *     subscription's default
 *
 * Mutates and returns the config; the return value is the same
 * object as the input, so callers can chain. */
export function apply_policy(config, opts) {
	if (!config)
		return config;

	if (config.tls === '1' && opts.allow_insecure === '1')
		config.tls_insecure = '1';

	if (config.type in ['vless', 'vmess'])
		config.packet_encoding = opts.packet_encoding;

	return config;
};
