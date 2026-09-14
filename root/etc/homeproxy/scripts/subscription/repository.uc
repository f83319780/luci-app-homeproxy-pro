/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * B1.2: UCI persistence for subscription nodes. The orchestrator
 * used to inline the add / update / remove walk against the UCI
 * cursor, which is the part of update_subscriptions.uc that is
 * hardest to test off-target - the cursor writes go straight to
 * /etc/config/homeproxy. Pulling it into a module that takes the
 * cursor as an argument lets the test suite stage a sandboxed
 * config dir and exercise the full add/update/remove cycle.
 *
 * The Repository consumes the two structures the orchestrator
 * builds during the fetch phase:
 *
 *   node_cache   - { [groupHash]: { [nameHash]: config } }
 *                  A lookup table keyed by subscription URL group
 *                  and then by the per-node name hash. The fetch
 *                  loop populates this for de-duplication.
 *   node_result  - [[config, ...]] (one inner list per URL)
 *                  The de-duplicated, policy-applied configs in
 *                  the order they should appear in UCI.
 *
 * Behaviour parity with the pre-B1.2 inline code:
 *   - user-created nodes (no grouphash) are never touched
 *   - nodes whose subscription has no cache entry (network
 *     failure for that URL) are left in place; we don't delete
 *     a node just because today's fetch didn't return it
 *   - a node in UCI but not in the cache is deleted
 *   - a node in both has every field of the new config written
 *     (including options the stored section did not have), and the
 *     options the new config no longer carries are removed
 *   - nodes not yet in UCI are added under name = md5(groupHash
 *     + label), which is the same hash the cache uses, so a
 *     subsequent re-fetch recognises them as existing
 *
 * Returns the { added, removed } counts so the orchestrator can
 * log them; the on-disk state change is the side effect.
 */

'use strict';

import { md5 } from 'digest';

export function apply(uci, uciconfig, ucinode, node_cache, node_result, log) {
	let added = 0, removed = 0;

	uci.foreach(uciconfig, ucinode, (cfg) => {
		/* User-created nodes do not have a grouphash. The
		 * repository must never touch them, even if the
		 * subscription fetch returns nothing for today. */
		if (!cfg.grouphash)
			return null;

		/* No cache entry for this subscription group means
		 * the fetch failed for that URL. Leave the existing
		 * nodes in place so the user does not lose them on
		 * a transient network blip. */
		if (!node_cache[cfg.grouphash] || length(node_cache[cfg.grouphash]) === 0)
			return null;

		const incoming = node_cache[cfg.grouphash][cfg['.name']];

		if (!incoming) {
			uci.delete(uciconfig, cfg['.name']);
			removed++;
			log(sprintf('Removing node: %s.', cfg.label || cfg['name']));
		} else {
			/* Write every option the new config carries, including ones
			 * the stored section does not have yet.  The previous version
			 * walked only the OLD section's keys, so an option that a
			 * subscription started sending after the node was first
			 * imported (plugin, tls_sni, packet_encoding, ...) was never
			 * written to existing nodes - the user had to delete and
			 * re-import the whole subscription to pick it up. */
			for (let v in keys(incoming))
				uci.set(uciconfig, cfg['.name'], v, incoming[v]);

			/* Then drop the options the new config no longer carries.
			 * `.name` / `.type` / `.index` are section metadata, not
			 * options; deleting them is meaningless at best. */
			for (let v in keys(cfg)) {
				if (substr(v, 0, 1) === '.')
					continue;
				if (!(v in incoming))
					uci.delete(uciconfig, cfg['.name'], v);
			}

			incoming.isExisting = true;
		}
	});

	for (let nodes in node_result)
		map(nodes, (node) => {
			if (node.isExisting)
				return null;

			const nameHash = md5(node.grouphash + node.label);
			uci.set(uciconfig, nameHash, 'node');
			map(keys(node), (v) => uci.set(uciconfig, nameHash, v, node[v]));

			added++;
			log(sprintf('Adding node: %s.', node.label));
		});

	uci.commit(uciconfig);

	return { added, removed };
};
