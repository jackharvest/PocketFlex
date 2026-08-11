#!/bin/sh
# Desktop harness: exercises the exact same lib/*.sh the handheld runs, but
# against a local data dir. Lets us validate the Plex plumbing without an
# eject/insert cycle on the SD card.
#
#   tools/pftest.sh login          - PIN sign-in
#   tools/pftest.sh whoami         - validate stored token
#   tools/pftest.sh users          - list home users/profiles
#   tools/pftest.sh servers        - list servers + connections
#   tools/pftest.sh probe          - find the best working connection
#   tools/pftest.sh sections       - list libraries
#   tools/pftest.sh items <key>    - list items in a library
#   tools/pftest.sh kids <key>     - list children (seasons/episodes)
#   tools/pftest.sh ondeck         - continue watching
#   tools/pftest.sh url <key>      - print the transcode URL
#   tools/pftest.sh play <key>     - transcode URL -> ffplay (desktop preview)

here=$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)

PF_DIR="$here/App/PocketFlex"
PF_SYS="$here/.testsys"
mkdir -p "$PF_SYS/bin" "$PF_SYS/lib"
export PF_DIR PF_SYS

. "$PF_DIR/lib/common.sh"
. "$PF_DIR/lib/plex.sh"

TOK=$(pf_token)

need_token() {
	[ -n "$TOK" ] || { echo "No token. Run: tools/pftest.sh login"; exit 1; }
}

resolve_server() {
	need_token
	SRV_URI=$(pf_get server_uri "")
	SRV_TOK=$(pf_get server_token "")
	if [ -z "$SRV_URI" ]; then
		echo "No server selected; probing..." >&2
		line=$(plex_pick_connection "$(pf_get server_id '')" "$TOK" | head -1)
		[ -n "$line" ] || { echo "No reachable server found." >&2; exit 1; }
		SRV_URI=$(printf '%s' "$line" | cut -f1)
		SRV_TOK=$(printf '%s' "$line" | cut -f2)
		pf_set server_uri "$SRV_URI"
		pf_set server_token "$SRV_TOK"
	fi
	[ -n "$SRV_TOK" ] || SRV_TOK="$TOK"
	echo "server: $SRV_URI" >&2
}

case "$1" in
login)
	r=$(plex_pin_new)
	id=$(printf '%s' "$r" | jq -r .id)
	code=$(printf '%s' "$r" | jq -r .code)
	[ "$code" = "null" ] && { echo "PIN request failed: $r"; exit 1; }
	echo
	echo "  Go to https://plex.tv/link and enter:   $code"
	echo
	printf 'Waiting'
	n=0
	while [ $n -lt 150 ]; do
		printf '.'
		sleep 3
		t=$(plex_pin_check "$id")
		if [ -n "$t" ]; then
			echo
			pf_token_save "$t"
			echo "Linked as: $(plex_validate "$t")"
			exit 0
		fi
		n=$((n + 1))
	done
	echo; echo "Timed out."; exit 1
	;;
whoami)  need_token; plex_validate "$TOK" && echo ;;
users)   need_token; plex_home_users "$TOK" ;;
servers) need_token; plex_resources "$TOK" ;;
probe)   need_token; plex_pick_connection "$(pf_get server_id '')" "$TOK" ;;
sections) resolve_server; plex_sections "$SRV_URI" "$SRV_TOK" ;;
items)   resolve_server; plex_section_items "$SRV_URI" "$SRV_TOK" "$2" ;;
kids)    resolve_server; plex_children "$SRV_URI" "$SRV_TOK" "$2" ;;
ondeck)  resolve_server; plex_ondeck "$SRV_URI" "$SRV_TOK" ;;
search)  resolve_server; plex_search "$SRV_URI" "$SRV_TOK" "$2" ;;
url)
	resolve_server
	plex_transcode_url "$SRV_URI" "$SRV_TOK" "$2" "$(pf_new_session)" 0
	echo
	;;
direct)  resolve_server; plex_direct_url "$SRV_URI" "$SRV_TOK" "$2"; echo ;;
play)
	resolve_server
	s=$(pf_new_session)
	u=$(plex_transcode_url "$SRV_URI" "$SRV_TOK" "$2" "$s" 0)
	echo "session $s"
	ffplay -autoexit -x 640 -y 480 "$u" || true
	plex_transcode_stop "$SRV_URI" "$SRV_TOK" "$s"
	;;
reset)   pf_token_clear; rm -f "$PF_SETTINGS"; echo "cleared" ;;
*)       sed -n '2,20p' "$0" ;;
esac
