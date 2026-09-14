#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Local stand-in for OpenWrt's /sbin/validate_data.
#
# homeproxy.uc validates hostnames, addresses and ports by shelling out to
# validate_data, which only exists on an OpenWrt target; without it the
# generators cannot run on a development host at all. This wrapper reproduces
# the contract the caller relies on -- exit 0 means valid, non-zero means
# invalid -- and delegates the checks themselves to the test double that the
# parser unit tests already use, so the validation logic stays in one place
# instead of growing a third copy.
#
# Not shipped in the package: it only exists for the local testbed, see
# tests/README.md. Exported as HP_VALIDATE_DATA by tests/ucode/run.sh.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

datatype="${1:-}"
data="${2:-}"

[ -n "$datatype" ] && [ -n "$data" ] || exit 1

exec ucode -L "$HERE" -e "
	import { validation } from '$REPO/tests/ucode/mocks/homeproxy.uc';
	exit(validation('$datatype', '$data') === true ? 0 : 1);
"
