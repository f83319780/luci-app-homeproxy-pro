/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * B1.1: pure subscription decoder. The fetcher returns raw bytes
 * and the orchestrator used to inline the JSON / base64 / SIP008
 * handling. Pulling it out gives the orchestrator a single
 * `decode(content, log, url)` call and lets us unit-test each input
 * shape without involving the network or UCI.
 *
 * Three input shapes are recognised, in order:
 *   1. JSON with a top-level 'servers' array (clash proxy-provider)
 *   2. JSON array directly (the same data, just unwrapped)
 *   3. Shadowsocks SIP008 JSON: top-level array of objects with
 *      server+method. Each entry is tagged nodetype='sip008' so the
 *      orchestrator can dispatch them differently downstream.
 *
 * On JSON failure, decode the content as base64 and split on '\n'
 * to get one share-link URI per line (sing-box subscription format).
 *
 * On total failure (no JSON, no base64), return an empty list and
 * let the caller log the empty result.
 *
 * `url` is optional and only used to enrich the parse-failed log
 * line; the decoder itself never makes a network call.
 */

'use strict';

import { isEmpty, decodeBase64Str } from 'homeproxy';

export function decode(content, log, url) {
	if (isEmpty(content))
		return [];

	let nodes;
	try {
		const parsed = json(content);
		nodes = parsed.servers || parsed;

		/* Shadowsocks SIP008: each entry is a JSON object with
		 * server + method, not a URI string. The pre-B1 code only
		 * inspected the first entry and then marked the whole
		 * array; we keep that quirk so a SIP008 list and a
		 * mixed list with one SIP008 entry in front both still
		 * work. */
		if (nodes[0] && nodes[0].server && nodes[0].method) {
			for (let i = 0; i < length(nodes); i++)
				nodes[i].nodetype = 'sip008';
		}
	} catch (e) {
		const tag = url ? sprintf('for %s, ', url) : '';
		log(sprintf('JSON parse failed %strying base64: %s', tag, e.message));
		const decoded = decodeBase64Str(content);
		nodes = decoded ? split(trim(decoded), '\n') : [];
	}

	return nodes;
}
