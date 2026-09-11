#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2025 ImmortalWrt.org
 *
 * Regression tests for homeproxy.uc helpers, focused on executeCommand():
 * return shape, stderr/exit-code capture, binary detection and (most
 * importantly) that the temporary descriptors are closed on every run.
 */

'use strict';

import { lsdir } from 'fs';
import { executeCommand, shellQuote } from 'homeproxy';

let failures = 0,
    checks = 0;

function expect(name, actual, want) {
	checks++;
	if (sprintf('%J', actual) !== sprintf('%J', want)) {
		printf('FAIL %s: expected %J, got %J\n', name, want, actual);
		failures++;
	}
}

function fd_count() {
	let n = 0;
	for (let _entry in lsdir('/proc/self/fd'))
		n++;
	return n;
}

/* successful command */
const ok = executeCommand('echo', 'hello');
expect('ok.exitcode', ok.exitcode, 0);
expect('ok.stdout', ok.stdout, 'hello\n');
expect('ok.stderr', ok.stderr, '');
expect('ok.binary', ok.binary, false);
expect('ok.command', ok.command, 'echo hello');

/* failing command keeps stderr and the exit code */
const bad = executeCommand('sh', '-c', shellQuote('echo oops >&2; exit 3'));
expect('bad.exitcode', bad.exitcode, 3);
expect('bad.stderr', bad.stderr, 'oops\n');
expect('bad.stdout', bad.stdout, '');

/* nondescript exit code */
expect('false.exitcode', executeCommand('false').exitcode, 1);

/* binary output is detected and withheld */
const bin = executeCommand('sh', '-c', shellQuote('printf "\\001\\002\\003"'));
expect('bin.binary', bin.binary, true);
expect('bin.stdout', bin.stdout, null);

/* descriptors must not leak across calls */
const before = fd_count();
for (let i = 0; i < 200; i++)
	executeCommand('true');
const after = fd_count();

checks++;
if (after > before) {
	printf('FAIL descriptor leak: %d -> %d after 200 calls\n', before, after);
	failures++;
}

printf('%d checks, %d failures\n', checks, failures);
exit(failures === 0 ? 0 : 1);
