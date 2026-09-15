/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * PR-03 (Subscription Transaction Boundary): every UCI write the
 * subscription pipeline performs now lives in this module. Three
 * entry points cover what used to be six uci.set+commit sites in
 * update_subscriptions.uc plus the existing node add/update/remove
 * walk:
 *
 *   apply_nodes                 - the add / update / remove walk
 *                                 for the nodes the subscription
 *                                 fetch returned this run.
 *   apply_main_node_refs        - main_node / main_udp_node cleanup:
 *                                 remove stale urltest members, switch
 *                                 main_node if its target is gone,
 *                                 reset both to 'nil' when the
 *                                 subscription has no nodes.
 *   scrub_stale_urltest_refs    - one-shot pass over every UCI
 *                                 routing_node that purges dead
 *                                 urltest_nodes entries left behind by
 *                                 nodes that have since been removed.
 *
 * apply_nodes takes canonical Node objects (post- parser/normalize)
 * and flattens them via parser/flatten before talking to UCI. The
 * orchestrator (update_subscriptions.uc) never writes UCI directly
 * anymore; it only orchestrates fetch + parse + filter + apply +
 * reload.
 */

'use strict';

import { md5 } from 'digest';

import { isEmpty } from '../homeproxy.uc';

/* Relative, like config/loader.uc's '../parser/mapping.uc': ucode's
 * resolver only searches top-level module names in the -L tree, so a
 * bare 'parser/flatten.uc' does not resolve. */
import { flatten } from '../parser/flatten.uc';

/* --- apply_nodes -------------------------------------------------------- */

/* Add / update / remove the subscription-owned nodes against UCI.
 *
 *   node_cache   - { [groupHash]: { [nameHash]: canonical_node } }
 *                  A lookup table keyed by subscription URL group
 *                  and then by the per-node name hash. The fetch
 *                  loop populates this for de-duplication.
 *   node_result  - [[canonical_node, ...]] (one inner list per URL)
 *                  The de-duplicated, policy-applied nodes in the
 *                  order they should appear in UCI.
 *
 * Behaviour parity with the pre-PR-03 code:
 *   - user-created nodes (no grouphash) are never touched
 *   - nodes whose subscription has no cache entry (network
 *     failure for that URL) are left in place; we don't delete
 *     a node just because today's fetch didn't return it
 *   - a node in UCI but not in the cache is deleted
 *   - a node in both has every field of the new config written
 *     (including options the stored section did not have yet),
 *     and the options the new config no longer carries are removed
 *   - new nodes are added under name = md5(groupHash + label), the
 *     same hash the cache uses, so a subsequent re-fetch recognises
 *     them as existing
 *
 * Returns the { added, removed } counts. The single uci.commit()
 * is the boundary of "this run wrote something". */
function apply_nodes(uci, uciconfig, ucinode, node_cache, node_result, log) {
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
			return null;
		}

		/* Canonical Node -> flat UCI keys. flatten() drops
		 * nulls so a freshly-saved canonical Node does not
		 * litter /etc/config with `tls_sni ''` entries for
		 * fields the parser never set; the Loader treats null
		 * and absent the same, so this is observably
		 * equivalent. */
		const flat = flatten(incoming);

		/* Write every option the new config carries, including
		 * ones the stored section did not have yet. Walking only
		 * the OLD section's keys used to miss new options
		 * (plugin, tls_sni, packet_encoding) the subscription
		 * started sending after the node was first imported. */
		for (let v in keys(flat))
			uci.set(uciconfig, cfg['.name'], v, flat[v]);

		/* Then drop the options the new config no longer
		 * carries. `.name` / `.type` / `.index` are section
		 * metadata, not options; deleting them is meaningless
		 * at best. */
		for (let v in keys(cfg)) {
			if (substr(v, 0, 1) === '.')
				continue;
			if (!(v in flat))
				uci.delete(uciconfig, cfg['.name'], v);
		}

		incoming.isExisting = true;
	});

	for (let nodes in node_result)
		map(nodes, (node) => {
			if (node.isExisting)
				return null;

			/* normalize() exposes the source label as `name`; `label`
			 * is only set when the orchestrator carries it over. Relying
			 * on `label` alone hashed every node of a subscription to the
			 * same section name, because undefined stringifies
			 * identically - four nodes collapsed into one section mixing
			 * several protocols' options. Accept either. */
			const label = node.label || node.name;
			const nameHash = md5(node.grouphash + label);
			const flat = flatten(node);

			uci.set(uciconfig, nameHash, 'node');
			for (let v in keys(flat))
				uci.set(uciconfig, nameHash, v, flat[v]);

			added++;
			log(sprintf('Adding node: %s.', label));
		});

	uci.commit(uciconfig);

	return { added, removed };
}

/* --- apply_main_node_refs ---------------------------------------------- */

/* Replace the 4 inline uci.set/commit sites (plus the 2-line
 * 'reset to nil' block) in update_subscriptions.uc. Logic parity:
 *
 *   - if main_node is set and at least one subscription node exists:
 *     * when main_node === 'urltest', scrub main_urltest_nodes down
 *       to nodes that still exist, then switch main_node to the first
 *       surviving one if the urltest set is empty
 *     * otherwise, switch main_node to first_server if its target is
 *       gone
 *     * same shape for main_udp_node, only when main_udp_node is set
 *       AND not 'same'
 *   - if main_node is set but no subscription nodes exist, reset
 *     both main_node and main_udp_node to 'nil'
 *
 * `ctx` carries the inputs the orchestrator used to read from UCI:
 *   { main_node, main_udp_node, has_nodes }
 *
 * Returns { main_node: <new>, main_udp_node: <new>, log: [..] } so
 * the orchestrator can log "Main node is gone, switching to ..." /
 * "No available node, disable tproxy." exactly as before. */
function apply_main_node_refs(uci, uciconfig, ucimain, ucinode, ctx, log) {
	/* Object destructuring is not part of the dialect the ucode on the
	 * target accepts (ImmortalWrt ucode 2026.01.16 rejects
	 * `const { a } = x` with "Expecting variable name"), so pull the
	 * fields out by name. tests/ucode/test_ucode_grammar.sh guards this. */
	const main_node = ctx.main_node,
	      main_udp_node = ctx.main_udp_node;
	const result = { main_node, main_udp_node, log: [] };

	if (isEmpty(main_node))
		return result;

	const first_server = uci.get_first(uciconfig, ucinode);
	if (!first_server) {
		/* No nodes left at all: reset both to 'nil'. */
		uci.set(uciconfig, ucimain, 'main_node', 'nil');
		uci.set(uciconfig, ucimain, 'main_udp_node', 'nil');
		uci.commit(uciconfig);
		result.main_node = 'nil';
		result.main_udp_node = 'nil';
		push(result.log, 'No available node, disable tproxy.');
		return result;
	}

	if (main_node === 'urltest') {
		const old_main_urltest_nodes = uci.get(uciconfig, ucimain, 'main_urltest_nodes') || [];
		const main_urltest_nodes = filter(old_main_urltest_nodes, (v) => {
			if (!uci.get(uciconfig, v)) {
				log(sprintf('Node %s is gone, removing from urltest list.', v));
				return false;
			}
			return true;
		});
		if (length(main_urltest_nodes) !== length(old_main_urltest_nodes)) {
			uci.set(uciconfig, ucimain, 'main_urltest_nodes', main_urltest_nodes);
			uci.commit(uciconfig);
		}

		if (!length(main_urltest_nodes)) {
			uci.set(uciconfig, ucimain, 'main_node', first_server);
			uci.commit(uciconfig);
			result.main_node = first_server;
			push(result.log, 'Main node is gone, switching to the first node.');
		}
	} else if (!uci.get(uciconfig, main_node)) {
		uci.set(uciconfig, ucimain, 'main_node', first_server);
		uci.commit(uciconfig);
		result.main_node = first_server;
		push(result.log, 'Main node is gone, switching to the first node.');
	}

	if (!isEmpty(main_udp_node) && main_udp_node !== 'same') {
		if (main_udp_node === 'urltest') {
			const old_main_udp_urltest_nodes = uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes') || [];
			const main_udp_urltest_nodes = filter(old_main_udp_urltest_nodes, (v) => {
				if (!uci.get(uciconfig, v)) {
					log(sprintf('Node %s is gone, removing from urltest list.', v));
					return false;
				}
				return true;
			});
			if (length(main_udp_urltest_nodes) !== length(old_main_udp_urltest_nodes)) {
				uci.set(uciconfig, ucimain, 'main_udp_urltest_nodes', main_udp_urltest_nodes);
				uci.commit(uciconfig);
			}

			if (!length(main_udp_urltest_nodes)) {
				uci.set(uciconfig, ucimain, 'main_udp_node', first_server);
				uci.commit(uciconfig);
				result.main_udp_node = first_server;
				push(result.log, 'Main UDP node is gone, switching to the first node.');
			}
		} else if (!uci.get(uciconfig, main_udp_node)) {
			uci.set(uciconfig, ucimain, 'main_udp_node', first_server);
			uci.commit(uciconfig);
			result.main_udp_node = first_server;
			push(result.log, 'Main UDP node is gone, switching to the first node.');
		}
	}

	return result;
}

/* --- scrub_stale_urltest_refs ----------------------------------------- */

/* Walk every routing_node and prune the urltest_nodes list to drop
 * entries that no longer point at a live node. One uci.commit()
 * at the end, only if something actually changed (a single commit
 * per affected section, not per node). The pre-PR-03 code committed
 * inside the foreach loop, once per scrubbed routing_node. */
function scrub_stale_urltest_refs(uci, uciconfig, log) {
	let commits = 0;

	uci.foreach(uciconfig, 'routing_node', (cfg) => {
		if (cfg.node !== 'urltest' || isEmpty(cfg.urltest_nodes))
			return null;

		const cleaned_nodes = filter(cfg.urltest_nodes, (v) => uci.get(uciconfig, v));
		if (length(cleaned_nodes) === length(cfg.urltest_nodes))
			return null;

		uci.set(uciconfig, cfg['.name'], 'urltest_nodes', cleaned_nodes);
		uci.commit(uciconfig);
		commits++;
		log(sprintf('Routing node %s: removed gone nodes from urltest list.', cfg['.name']));
	});

	return { commits };
}

export const Repository = {
	apply_nodes,
	apply_main_node_refs,
	scrub_stale_urltest_refs
};