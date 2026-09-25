#!/bin/bash

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
RESOURCES_DIR="$BASE_DIR/../root/etc/homeproxy/resources"

TEMP_DIR="$(mktemp -d -p $BASE_DIR)"

check_list_update() {
	local listtype="$1"
	local listrepo="$2"
	local listref="$3"
	local listname="$4"

	local list_info="$(gh api "repos/$listrepo/commits?sha=$listref&path=$listname&per_page=1")"
	local list_sha="$(echo -e "$list_info" | jq -r ".[].sha")"
	local list_date="$(echo -e "$list_info" | jq -r ".[].commit.committer.date" | cut -d 'T' -f1)"
	if [ -z "$list_sha" ]; then
		echo -e "[${listtype^^}] Failed to get the latest version, please retry later."
		return 1
	fi
	local list_ver="${list_date:+$list_date }$list_sha"

	local local_list_ver="$(cat "$RESOURCES_DIR/$listtype.ver" 2>"/dev/null" || echo "NOT_FOUND")"
	local local_list_sha="${local_list_ver##* }"
	local local_list_disp="${local_list_ver%% *}"
	if [ "$local_list_sha" = "$list_sha" ]; then
		echo -e "[${listtype^^}] Current version: $local_list_disp."
		echo -e "[${listtype^^}] You're already at the latest version."
		return 3
	else
		echo -e "[${listtype^^}] Local version: $local_list_disp, latest version: ${list_ver%% *}."
	fi

	if ! curl -fsSL "https://raw.githubusercontent.com/$listrepo/$list_sha/$listname" -o "$TEMP_DIR/$listname" || [ ! -s "$TEMP_DIR/$listname" ]; then
		rm -f "$TEMP_DIR/$listname"
		echo -e "[${listtype^^}] Update failed."
		return 1
	fi

	mv -f "$TEMP_DIR/$listname" "$RESOURCES_DIR/$listtype.${listname##*.}"
	echo -e "$list_ver" > "$RESOURCES_DIR/$listtype.ver"
	echo -e "[${listtype^^}] Successfully updated."

	return 0
}

check_list_update "china_ip4" "1715173329/IPCIDR-CHINA" "master" "ipv4.txt"
check_list_update "china_ip6" "1715173329/IPCIDR-CHINA" "master" "ipv6.txt"
check_list_update "gfw_list" "Loyalsoldier/v2ray-rules-dat" "release" "gfw.txt"

# The upstream direct-list is not a dnsmasq domain list: `full:` marks an exact
# match and `regexp:` lines are regular expressions, which the consumer
# (runtime/dns.sh renders `server=/<domain>/...`) cannot express.  Strip the
# prefix and drop the regex lines, through a temporary file: `sed -i -e` is a
# GNU form that BSD sed - i.e. macOS, where this maintenance script normally
# runs - rejects with "sed: -e: No such file or directory".  The upload had
# already replaced the file by then, so the failure shipped a raw direct-list
# in a package whose every other script converter was written portably for
# exactly that reason.
if check_list_update "china_list" "Loyalsoldier/v2ray-rules-dat" "release" "direct-list.txt"; then
	if ! sed -e "s/full://g" -e "/:/d" "$RESOURCES_DIR/china_list.txt" > "$RESOURCES_DIR/china_list.txt.hp-new" \
	   || ! mv -f "$RESOURCES_DIR/china_list.txt.hp-new" "$RESOURCES_DIR/china_list.txt"; then
		rm -f "$RESOURCES_DIR/china_list.txt.hp-new"
		echo -e "[CHINA_LIST] Conversion failed; the file may still be in the upstream format."
		exit 1
	fi
fi

rm -rf "$TEMP_DIR"
