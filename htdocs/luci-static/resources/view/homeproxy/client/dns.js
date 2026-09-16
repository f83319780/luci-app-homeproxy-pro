/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';

'require form';
'require uci';

'require homeproxy as hp';
'require view.homeproxy.client.common as common';

/* DNS settings tab plus the wrapping 'dns' NamedSection. Called after
 * routing.renderRoutingRules() so the NamedSection chain reads
 * config -> routing_node -> routing_rule -> dns from left to right. */
function renderDnsSettings(ctx) {
	const { s, data } = ctx;
	let o, ss, so;

	s.tab('dns', _('DNS Settings'));
	o = s.taboption('dns', form.SectionValue, '_dns', form.NamedSection, 'dns', 'homeproxy');
	o.depends('routing_mode', 'custom');

	ss = o.subsection;
	so = ss.option(form.ListValue, 'default_strategy', _('Default DNS strategy'),
		_('The DNS strategy for resolving the domain name in the address.'));
	for (let i in hp.dns_strategy)
		so.value(i, hp.dns_strategy[i]);

	so = ss.option(form.ListValue, 'default_server', _('Default DNS server'));
	so.load = function(section_id) {
		delete this.keylist;
		delete this.vallist;

		this.value('default-dns', _('Default DNS (issued by WAN)'));
		this.value('system-dns', _('System DNS'));
		uci.sections(data[0], 'dns_server', (res) => {
			if (res.enabled === '1')
				this.value(res['.name'], res.label);
		});

		return this.super('load', section_id);
	}
	so.default = 'default-dns';
	so.rmempty = false;

	so = ss.option(form.Flag, 'disable_cache', _('Disable DNS cache'));

	so = ss.option(form.Flag, 'disable_cache_expire', _('Disable cache expire'));
	so.depends('disable_cache', '0');

	so = ss.option(form.Value, 'client_subnet', _('EDNS Client subnet'),
		_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
		'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
	so.datatype = 'or(cidr, ipaddr)';

	so = ss.option(form.Flag, 'optimistic_cache', _('Optimistic DNS cache'),
		_('Return expired cache immediately and refresh in background (sing-box 1.14).'));
	so.depends('disable_cache', '0');
	so.depends('disable_cache_expire', '0');
	so.rmempty = false;

	so = ss.option(form.Value, 'optimistic_timeout', _('Optimistic cache timeout'),
		_('Max time an expired entry may be served. Examples: 3d, 1h.'));

	so = ss.option(form.Value, 'dns_timeout', _('DNS query timeout'),
		_('Default timeout per DNS query in seconds (sing-box default: 10).'));
	so.datatype = 'uinteger';

	so = ss.option(form.Flag, 'cache_file_store_dns', _('Store DNS cache'),
		_('Persist DNS cache across restarts (sing-box 1.14, replaces Store RDRC).'));
	so.depends('disable_cache', '0');
	so.rmempty = false;
	/* DNS settings end */
}

/* DNS rules sub-section. Split out from renderDnsSettings() so the
 * orchestrator can call it after nodes.renderDnsServers() and preserve
 * the original tab ordering (dns, dns_server, dns_rule). */
function renderDnsRules(ctx) {
	const { s, self, data } = ctx;

	/* DNS rules start */
	common.renderRuleSection(s, 'dns', self, data);
	/* DNS rules end */
}

/* DNS cache tab - the rightmost tab, surfaces the same options as the
 * routing-mode (non-custom) dns default, just on a separate page. */
function renderDnsCache(ctx) {
	const { s, data } = ctx;
	let o, ss, so;

	s.tab('dns_cache', _('DNS Cache (1.14)'));
	o = s.taboption('dns_cache', form.SectionValue, '_dns_cache', form.NamedSection, 'dns', 'homeproxy');
	o.depends({'routing_mode': 'custom', '!reverse': true});
	ss = o.subsection;

	so = ss.option(form.Flag, 'optimistic_cache', _('Optimistic DNS cache'),
		_('Return expired cache immediately and refresh in background (sing-box 1.14).'));
	so.rmempty = false;

	so = ss.option(form.Value, 'optimistic_timeout', _('Optimistic cache timeout'),
		_('Max time an expired entry may be served. Examples: 3d, 1h.'));

	so = ss.option(form.Value, 'dns_timeout', _('DNS query timeout'),
		_('Default timeout per DNS query in seconds (sing-box default: 10).'));
	so.datatype = 'uinteger';

	so = ss.option(form.Flag, 'cache_file_store_dns', _('Store DNS cache'),
		_('Persist DNS cache across restarts (replaces Store RDRC).'));
	so.rmempty = false;
}

return { renderDnsSettings, renderDnsRules, renderDnsCache };
