/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * B1.2: thin wrapper around homeproxy's wGETVerbose that logs
 * the failure and returns a flat { content, error } shape. The
 * orchestrator used to inline the empty-content check + log
 * message right next to the call, which made the loop body hard
 * to read and conflated the fetch's success/failure decision with
 * the downstream decode step.
 *
 * On success: returns { content: <string>, error: null }.
 * On failure: returns { content: null, error: <string> }, having
 * already logged the failure with the URL. The caller can keep
 * the loop flat: 'if (result.content === null) continue;'.
 *
 * No caching, no retry, no backoff - the orchestrator decides
 * those if it ever needs them. The Fetcher is a single HTTP GET
 * + error log, nothing more.
 */

'use strict';

import { isEmpty } from 'homeproxy';

export function fetch(url, user_agent, log) {
	const result = wGETVerbose(url, user_agent);
	if (isEmpty(result.content)) {
		log(sprintf('Failed to fetch resources from %s: %s',
			url, result.error || 'empty response'));
		return { content: null, error: result.error || 'empty response' };
	}
	return { content: result.content, error: null };
}
