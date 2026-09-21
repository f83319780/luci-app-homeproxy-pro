#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

NAME="homeproxy"

RESOURCES_DIR="/etc/$NAME/resources"
mkdir -p "$RESOURCES_DIR"

RUN_DIR="/var/run/$NAME"
LOG_PATH="$RUN_DIR/$NAME.log"
mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") $*" >> "$LOG_PATH"
}

to_upper() {
	echo -e "$1" | tr "[a-z]" "[A-Z]"
}

# Review M7: each entry is tried in order, success stops the loop.  Order
# matters: fastly.jsdelivr.net is the CDN edge closest to the original
# report and used to be the only mirror; gcore and cdn are sibling edges;
# raw.githubusercontent.com is the upstream fallback (the file lives in
# the same GitHub repo we just queried for the SHA, so it is reachable
# whenever the version query was reachable).  Putting the CDN edges first
# keeps the common case fast; the GitHub fallback catches the case where
# the CDN is blocked but GitHub is reachable - which is the shape of the
# `api.github.com` rate-limit problem the report calls out.
MIRRORS="fastly.jsdelivr.net gcore.jsdelivr.net cdn.jsdelivr.net raw.githubusercontent.com"

# Pick the first mirror that responds to a HEAD with HTTP 200 in 10s.
# Called with: <path-suffix>.  Echoes the chosen base URL on stdout, or
# fails the script if every mirror timed out.
pick_mirror() {
	local path_suffix="$1"
	for base in $MIRRORS; do
		if [ "$base" = "raw.githubusercontent.com" ]; then
			# GitHub raw serves paths from the repo root, not the
			# /gh/<repo>@<sha>/<file> shape jsdelivr uses. The caller
			# passes the suffix already split out, so we re-stitch it.
			local probe_url="https://$base/$listrepo/$list_sha/$listname"
		else
			local probe_url="https://$base/gh/$listrepo@$list_sha/$listname"
		fi
		if wget --timeout=10 --spider -q "$probe_url" 2>"/dev/null"; then
			printf '%s\n' "$base"
			return 0
		fi
	done
	return 1
}

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"
	local lock="$RUN_DIR/update_resources-$listtype.lock"
	local github_token="$(uci -q get homeproxy.config.github_token)"
	local wget="wget --timeout=10 -q"

	exec 200>"$lock"
	if ! flock -n 200 &> "/dev/null"; then
		log "[$(to_upper "$listtype")] A task is already running."
		return 2
	fi

	# The token travels in argv, which the previous form avoided by writing it
	# to a 0600 file and passing --header-file - an option neither busybox nor
	# GNU wget has, so it failed with "unrecognized option" and the version
	# query never worked at all with a token configured. There is no
	# file-based header option in either wget, so argv is the only way; on a
	# single-user router that is the right trade for a feature that otherwise
	# does not function. `wget` is invoked with the header only when a token
	# is set, and nothing logs the command line.
	local github_header=""
	[ -n "$github_token" ] && github_header="Authorization: Bearer $github_token"

	local list_info="$($wget ${github_header:+--header "$github_header"} -O- "https://api.github.com/repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1")"
	local wget_exit=$?

	if [ $wget_exit -ne 0 ]; then
		log "[$(to_upper "$listtype")] Failed to fetch version info (wget exit $wget_exit)."
		return 1
	fi
	local list_sha="$(echo -e "$list_info" | jsonfilter -qe "@[0].sha")"
	local list_date="$(echo -e "$list_info" | jsonfilter -qe "@[0].commit.committer.date" | cut -d 'T' -f1)"
	if [ -z "$list_sha" ]; then
		log "[$(to_upper "$listtype")] Failed to get the latest version, please retry later."
		return 1
	fi
	local list_ver="${list_date:+$list_date }$list_sha"

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT_FOUND")"
	local local_list_sha="${local_list_ver##* }"
	local local_list_disp="${local_list_ver%% *}"
	if [ "$local_list_sha" = "$list_sha" ]; then
		[ "$local_list_ver" = "$local_list_sha" ] && [ -n "$list_date" ] && \
			echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
		log "[$(to_upper "$listtype")] Current version: ${list_ver%% *}."
		log "[$(to_upper "$listtype")] You're already at the latest version."
		return 3
	else
		log "[$(to_upper "$listtype")] Local version: $local_list_disp, latest version: ${list_ver%% *}."
	fi

	# Pick a mirror, then download. pick_mirror walks the list and uses
	# the first reachable one; raw.githubusercontent.com is a separate
	# path shape so the helper handles it.
	local mirror="$(pick_mirror)"
	if [ -z "$mirror" ]; then
		log "[$(to_upper "$listtype")] All mirrors unreachable (tried: $MIRRORS)."
		return 1
	fi
	local mirror_url
	if [ "$mirror" = "raw.githubusercontent.com" ]; then
		mirror_url="https://raw.githubusercontent.com/$listrepo/$list_sha/$listname"
	else
		mirror_url="https://$mirror/gh/$listrepo@$list_sha/$listname"
	fi
	log "[$(to_upper "$listtype")] Downloading from $mirror."

	if ! $wget -O "$RUN_DIR/$listname" "$mirror_url" || [ ! -s "$RUN_DIR/$listname" ]; then
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Download failed ($mirror)."
		return 1
	fi

	if mv -f "$RUN_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"; then
		echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
		# Review M7: persist the time *this router* last succeeded.
		# $list_date is the upstream commit date and can be months old
		# even on a successful run, so it is not a stand-in.  Stored in
		# the same directory as the .ver file so resources_get_version
		# can read it.
		date -u +"%Y-%m-%dT%H:%M:%SZ" > "$RESOURCES_DIR/$listtype.updated_at"
		log "[$(to_upper "$listtype")] Successfully updated via $mirror."
	else
		rm -f "$RUN_DIR/$listname"
		log "[$(to_upper "$listtype")] Failed to install update (mv failed)."
		return 1
	fi

	return 0
}

case "$1" in
"china_ip4")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv4.txt"
	;;
"china_ip6")
	check_list_update "$1" "1715173329/IPCIDR-CHINA" "master" "ipv6.txt"
	;;
"gfw_list")
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"
	;;
"china_list")
	# Not `sed -i`: the bare -i form is a busybox/GNU extension, and the same
	# script is exercised off-device where a non-busybox sed fails it with
	# "invalid command code".  Edit through a temp file, the way the crontab
	# helper in runtime/service.sh does.
	check_list_update "$1" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt" && \
		sed -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt" > "$RESOURCES_DIR/china_list.txt.hp-new" && \
		mv -f "$RESOURCES_DIR/china_list.txt.hp-new" "$RESOURCES_DIR/china_list.txt" || \
		rm -f "$RESOURCES_DIR/china_list.txt.hp-new"
	;;
*)
	echo -e "Usage: $0 <china_ip4 / china_ip6 / gfw_list / china_list>"
	exit 1
	;;
esac
