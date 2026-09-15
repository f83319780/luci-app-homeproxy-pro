/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * homeproxy module shim for subscription/fetcher unit tests.
 *
 * The real homeproxy.uc wraps wGETVerbose around `executeCommand(
 * /usr/bin/wget ...)`, which means a unit test that imports it
 * would shell out to the network. Tests stage this file as
 * `homeproxy` in their -L directory so the fetcher picks up the
 * shim's wGETVerbose instead.
 *
 * The shim reads HP_TEST_WGET_CONTENT / HP_TEST_WGET_ERROR globals
 * (set by the test before each fetch call) and returns them. The
 * two other names the fetcher imports (isEmpty, redactUrl) are
 * short enough to copy verbatim from homeproxy.uc so the shim is
 * fully self-contained - the real homeproxy.uc also imports
 * validate_data / popen / a long list of luci.* modules that the
 * testbed does not have on PATH, and pulling the full file would
 * pull those imports along.
 *
 * The `global` prefix is the only cross-module shared state ucode
 * exposes without a dependency-injection hook, and the test is the
 * only writer.
 */

export function wGETVerbose(url, _ua) {
	const content = global.HP_TEST_WGET_CONTENT;
	const error = global.HP_TEST_WGET_ERROR;
	return { content: content, error: error };
}

export function isEmpty(res) {
	return !res || res === 'nil' || (type(res) in ['array', 'object'] && length(res) === 0);
};

/* Verbatim copy of homeproxyuc:redactUrl - keeps the security
 * behaviour covered in test_subscription_fetcher.uc. */
export function redactUrl(url) {
	if (!url || type(url) !== 'string')
		return '';
	const at = index(url, '@');
	const scheme = match(url, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//);
	let u = url;
	if (scheme && at !== -1 && at > length(scheme[0]))
		u = substr(u, 0, length(scheme[0])) + '***' + substr(u, at);
	const q = index(u, '?');
	if (q !== -1)
		u = substr(u, 0, q) + '?***';
	return u;
}