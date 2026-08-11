#!/bin/sh
# Catch constructs the desktop accepts but the device rejects.
#
# The handheld runs busybox ash + busybox awk. macOS ships bash-as-sh and BWK
# awk, both far more permissive, so a script can test perfectly here and still
# blow up on boot there -- v0.1.2 shipped a "%-*s" that busybox awk refuses
# outright. Comments are stripped before matching so documenting a bad pattern
# doesn't trip the check on itself.
#
#   tools/lint-busybox.sh

fail=0
files="App/PocketFlex/launch.sh App/PocketFlex/lib/common.sh App/PocketFlex/lib/plex.sh App/PocketFlex/lib/cache.sh App/PocketFlex/lib/wifi.sh App/PocketFlex/lib/dlworker.sh App/PocketFlex/lib/ui.sh App/PocketFlex/lib/ui_util.sh"
tmp=/tmp/lint-bb.$$
mkdir -p "$tmp"

# Strip full-line and trailing comments so prose about a pattern isn't a hit.
for f in $files; do
	sed 's/[[:space:]]#[^"'\'']*$//; s/^[[:space:]]*#.*$//' "$f" >"$tmp/$(basename "$f")"
done

hit() {
	fail=1
	printf '  %-12s %s\n' "$1" "$2"
}

scan() {
	_label=$1
	_pat=$2
	for f in $files; do
		_b=$(basename "$f")
		grep -nE "$_pat" "$tmp/$_b" 2>/dev/null | while IFS= read -r l; do
			printf '%s|%s:%s\n' "$_label" "$f" "$l"
		done
	done
}

echo "busybox compatibility lint"
echo

{
	# busybox awk: "%*x formats are not supported"
	scan dyn-width '%[-+ 0#]*[0-9]*\*[a-z]'
	# gawk-only builtins
	scan gawk-only '\b(gensub|asort|asorti|patsplit|systime|strftime|mktime)[[:space:]]*\('
	# busybox ash has no [[ ]], no ++, no local/declare, no echo -e
	scan bashism '\[\['
	scan bashism '\b(declare|typeset)[[:space:]]'
	scan bashism '\becho[[:space:]]+-e\b'
	scan increment '\$\(\([^)]*\+\+'
} >"$tmp/hits" 2>/dev/null

if [ -s "$tmp/hits" ]; then
	while IFS='|' read -r label rest; do
		hit "$label" "$rest"
	done <"$tmp/hits"
	fail=1
else
	echo "  static checks: clean"
fi

echo
echo "syntax (sh -n):"
for f in $files; do
	if out=$(/bin/sh -n "$f" 2>&1); then
		:
	else
		fail=1
		printf '  %s: %s\n' "$f" "$out"
	fi
done
[ "$fail" = "0" ] && echo "  clean"

# Command-substitution bodies are not parsed by `sh -n`, which is how a
# case-in-$() bug reached the device once. Source the libs and run the pure
# helpers so any such error surfaces here instead.
echo
echo "load + smoke:"
smoke=$(
	PF_DIR="$PWD/App/PocketFlex" PF_SYS=/tmp/pfsys /bin/sh -c '
		. ./App/PocketFlex/lib/common.sh
		. ./App/PocketFlex/lib/plex.sh
		. ./App/PocketFlex/lib/cache.sh
		. ./App/PocketFlex/lib/ui_util.sh
		printf "%s" "$(fit "abcdefghij" 5)"
		glyph_row A 0 >/dev/null
		printf " %s" "$(urlencode "a b/c")"
		printf " %s" "$(pf_uri_plain "https://1-2-3-4.h.plex.direct:32400")"
		printf " %s" "$(pf_bar 50 4)"
		printf " %s" "$(pf_human_kb 2097152)"
		printf " %s" "$(pf_cache_name "The Show: Part 1" 1234)"
		COLUMNS=53; printf " %s" "$(big_col FLEX)"
	' 2>&1
)
case "$smoke" in
*"error"* | *"not found"* | *"unexpected"* | *"not supported"*)
	fail=1
	printf '  FAILED: %s\n' "$smoke" ;;
*)
	printf '  ok (%s)\n' "$smoke" ;;
esac

# Settings round-trip.
#
# pf_set's third argument means "the value is raw JSON", for numbers and
# booleans. Passing it for a string makes jq's --argjson a parse error, and jq's
# complaint goes to /dev/null -- so the write silently does not happen while the
# in-memory copy says it did. An abandoned text-size experiment shipped exactly
# that and its Settings row did nothing at all on the device, with no clue in
# the log. Every setting the UI writes is exercised here in both spellings.
echo
echo "settings round-trip:"
rt=$(
	PF_DIR="$PWD/App/PocketFlex" PF_SYS=/tmp/pfsys PF_TMP="$tmp" /bin/sh -c '
		. ./App/PocketFlex/lib/common.sh
		# After the source, not before: common.sh honours PF_DIR from the
		# environment but assigns PF_DATA and PF_SETTINGS outright. Setting
		# them in the environment does nothing, and the first version of this
		# check wrote its test values into the repo data dir instead.
		PF_DATA="$PF_TMP"
		PF_SETTINGS="$PF_TMP/settings.json"
		PF_S_LOADED=0
		pf_settings_init
		bad=""
		# key:value:raw -- the shapes the settings screen actually writes.
		set -- subtitles:off: aspect:stretch: skip_intro:off: \
			dl_resolution:480x320: server_name:Homeflix: \
			bitrate:3000:1 home_rowsize:8:1 flip:false:1 autoplay_next:true:1
		for spec; do
			k=${spec%%:*}; rest=${spec#*:}; v=${rest%%:*}; raw=${rest#*:}
			pf_set "$k" "$v" "$raw"
			# pf_settings_load only ever *adds* PFS_ variables, so it never
			# clears one the file does not have. Reading back without unsetting
			# first returns what pf_set put in memory and proves nothing about
			# the file -- the same blindness that hid the original bug.
			unset "PFS_$k"
			PF_S_LOADED=0
			got=$(pf_get "$k" "<unset>")
			[ "$got" = "$v" ] || bad="$bad $k(wrote=$v read=$got)"
		done
		if [ -n "$bad" ]; then printf "did not persist:%s" "$bad"
		else printf "9 keys persisted"; fi
	' 2>&1
)
case "$rt" in
*"did not persist"* | *"error"* | *"not found"*)
	fail=1
	printf '  FAILED: %s\n' "$rt" ;;
*)
	printf '  ok (%s)\n' "$rt" ;;
esac

rm -rf "$tmp"
echo
if [ "$fail" = "0" ]; then echo "PASS"; else echo "ISSUES FOUND"; fi
exit "$fail"
