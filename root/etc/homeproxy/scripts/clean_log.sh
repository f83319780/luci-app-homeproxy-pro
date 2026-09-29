#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

NAME="homeproxy"

log_max_size="50" #KB
main_log_file="/var/run/$NAME/$NAME.log"
singc_log_file="/var/run/$NAME/sing-box-c.log"
sings_log_file="/var/run/$NAME/sing-box-s.log"
# The preserved previous run of each sing-box log (see
# hp_rotate_instance_log in runtime/service.sh).  It is replaced on every
# start, so it is bounded by one run, but a failing run at `trace` level
# can still produce more than log_max_size before the next start - so it
# gets the same trim as the live files instead of being the one log that
# is never cleaned.
singc_prev_log_file="/var/run/$NAME/sing-box-c.log.prev"
sings_prev_log_file="/var/run/$NAME/sing-box-s.log.prev"

while true; do
	sleep 180
	for i in "$main_log_file" "$singc_log_file" "$sings_log_file" \
		"$singc_prev_log_file" "$sings_prev_log_file"; do
		[ -s "$i" ] || continue
		[ "$(( $(wc -c < "$i") / 1024 >= log_max_size))" -eq "0" ] || : > "$i"
	done
done
