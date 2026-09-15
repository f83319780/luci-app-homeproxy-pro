#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Behaviour tests for the rpcd module (root/usr/share/rpcd/ucode/luci.homeproxy).
#
# Until now that file was only ever compiled for syntax. tests/ucode/run.sh
# rewrites its absolute imports and runs `ucode -c`, and nothing called a single
# one of its ten methods - which is why the "Upload ECH config" button could
# stay 100% broken: the frontend has called
# certificate_write('client_ech_conf') since the initial commit, the ACL
# granted the write, and the backend simply had no case for that name.
#
# This drives the methods directly with a fake request, the same way
# tests/frontend-validators.js drives the frontend's validate callbacks.
#
# Usage: sh tests/ucode/test_rpc_methods.sh <repo-root> [workdir]

set -u

ROOT="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"
WORK="${2:-/tmp/hp-rpc-methods}"

if ! command -v ucode > "/dev/null" 2>&1; then
	echo "NOT RUN: ucode is not on PATH."
	exit 2
fi

rm -rf "$WORK"
mkdir -p "$WORK/scripts"
cp -R "$ROOT/root/etc/homeproxy/scripts/." "$WORK/scripts/"

# stage_rewrite <src> <dst>: point a file's absolute /etc/homeproxy paths at the
# sandbox, and nothing else.  Both the imports and the runtime directories have
# to move, or the test would write real certificates into /etc/homeproxy/certs.
stage_rewrite() {
	sed -e "s#/etc/homeproxy/scripts/#$WORK/scripts/#g" \
	    -e "s#^const HP_DIR = '/etc/homeproxy';#const HP_DIR = '$WORK';#" \
	    -e "s#^export const HP_DIR = '/etc/homeproxy';#export const HP_DIR = '$WORK';#" \
	    -e "s#^const RUN_DIR = '/var/run/homeproxy';#const RUN_DIR = '$WORK/run';#" \
	    -e "s#^export const RUN_DIR = '/var/run/homeproxy';#export const RUN_DIR = '$WORK/run';#" \
	    -e "s#^export const UCICONFIG_DIR = '/etc/config';#export const UCICONFIG_DIR = '$WORK/cfg';#" \
	    "$1" > "$2"
}

stage_rewrite "$WORK/scripts/homeproxy.uc" "$WORK/scripts/homeproxy.uc.new"
mv -f "$WORK/scripts/homeproxy.uc.new" "$WORK/scripts/homeproxy.uc"
stage_rewrite "$ROOT/root/usr/share/rpcd/ucode/luci.homeproxy" "$WORK/rpc.uc"

mkdir -p "$WORK/certs" "$WORK/run" "$WORK/cfg" "$WORK/tmp"

cat > "$WORK/driver_body.uc" <<'DRIVER'
/* Appended to a copy of the module, so this runs in the module's own scope and
 * drives its `methods` table exactly as rpcd would hand it to a request. */
/* writefile/readfile/access come from the module's own `fs` import above;
 * only what is not already in scope is imported here. */
const WORK = '@@WORK@@';
const rpc = methods;

let checks = 0, failures = 0;
function check(what, ok, detail) {
	checks++;
	if (ok) return;
	failures++;
	printf('FAIL %s%s\n', what, detail != null ? ': ' + detail : '');
}

const CERT = '-----BEGIN CERTIFICATE-----\n' +
	'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' +
	'-----END CERTIFICATE-----\n';
const KEY = '-----BEGIN RSA PRIVATE KEY-----\n' +
	'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' +
	'-----END RSA PRIVATE KEY-----\n';
const ECH = '-----BEGIN ECH CONFIGS-----\n' +
	'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' +
	'-----END ECH CONFIGS-----\n';

/* The upload path is what the frontend's ui.uploadFile writes and what the
 * module reads; it is a literal /tmp path inside the module, so the driver
 * stages the real one and cleans up afterwards. */
function stage(filename, content) {
	writefile(sprintf('/tmp/homeproxy_cert_%s.tmp', filename), content);
}

function tmp_exists(filename) {
	return access(sprintf('/tmp/homeproxy_cert_%s.tmp', filename));
}

function call(filename) {
	return rpc.certificate_write.call({ args: { filename: filename } });
}

/* --- the four names the frontend actually sends ------------------------- */

const names = ['client_ca', 'server_publickey', 'server_privatekey', 'client_ech_conf'];
const bodies = [CERT, CERT, KEY, ECH];

for (let i = 0; i < length(names); i++) {
	const name = names[i];
	stage(name, bodies[i]);
	const ret = call(name);

	check(sprintf('%s: accepted', name), ret && ret.result === true,
		ret && (ret.error || sprintf('result=%J', ret.result)));

	if (ret && ret.result === true) {
		const stored = readfile(sprintf('%s/certs/%s.pem', WORK, name));
		check(sprintf('%s: stored with a trailing newline', name),
			stored != null && match(stored, /\n$/));
		check(sprintf('%s: staging file removed after success', name), !tmp_exists(name));
	}
}

/* --- the type checks still hold ----------------------------------------- */

stage('client_ca', KEY);
check('client_ca rejects a private key', call('client_ca').result === false);

stage('server_privatekey', CERT);
check('server_privatekey rejects a certificate', call('server_privatekey').result === false);

/* An ECH config is not a certificate: it has its own PEM markers, so the
 * certificate validator must not be reused for it. */
stage('client_ech_conf', CERT);
check('client_ech_conf rejects a certificate body', call('client_ech_conf').result === false);

stage('client_ech_conf', 'not a pem at all');
check('client_ech_conf rejects garbage', call('client_ech_conf').result === false);

/* --- unknown names and empty uploads ------------------------------------ */

stage('client_ca', CERT);
const bogus = call('not_a_certificate');
check('an unknown filename is refused', bogus.result === false);
check('an unknown filename says why', bogus.error === 'illegal cerificate filename',
	bogus.error);

writefile('/tmp/homeproxy_cert_client_ca.tmp', '');
check('an empty upload is refused', call('client_ca').error === 'empty certificate file');

system('rm -f /tmp/homeproxy_cert_client_ca.tmp');
check('a missing upload is refused', call('client_ca').result === false);

/* No method may throw on a request with no arguments at all. */
let threw = null;
try { rpc.certificate_write.call({}); } catch (e) { threw = sprintf('%s: %s', e.type, e.message); }
check('certificate_write tolerates an empty request', threw == null, threw);

const others = ['log_clean', 'connection_check', 'acllist_read', 'resources_get_version'];
for (let m in others) {
	let t = null;
	try { rpc[m].call({ args: {} }); } catch (e) { t = sprintf('%s: %s', e.type, e.message); }
	check(sprintf('%s tolerates an empty request', m), t == null, t);
}

printf('rpc methods: %d checks, %d failures\n', checks, failures);
exit(failures ? 1 : 0);
DRIVER

# The staging path in the module is the literal /tmp; keep the test's own files
# out of the way of anything else and clean them on exit.
cleanup() {
	rm -f /tmp/homeproxy_cert_client_ca.tmp /tmp/homeproxy_cert_server_publickey.tmp \
	      /tmp/homeproxy_cert_server_privatekey.tmp /tmp/homeproxy_cert_client_ech_conf.tmp
}
trap cleanup EXIT INT TERM

# The module ends with `return { 'luci.homeproxy': methods };`, which makes it a
# program rather than an importable module - that is how rpcd runs it.  Drop
# that one line and append the driver, so the module's top-level code builds
# `methods` and the driver drives it in the same scope.  Nothing else about the
# file changes.
sed '$d' "$WORK/rpc.uc" > "$WORK/run.uc"
sed "s#@@WORK@@#$WORK#" "$WORK/driver_body.uc" >> "$WORK/run.uc"

if ucode -L "$WORK/scripts" -L "$WORK" "$WORK/run.uc"; then
	echo "PASS: rpc method behaviour"
	rm -rf "$WORK"
	exit 0
else
	echo "FAIL: rpc method behaviour"
	rm -rf "$WORK"
	exit 1
fi
