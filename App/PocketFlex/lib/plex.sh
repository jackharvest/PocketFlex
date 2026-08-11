#!/bin/sh
# PocketFlex - Plex API layer.
# Every function prints to stdout and returns non-zero on failure.

PLEX_TV="https://plex.tv/api/v2"

PF_TOKEN_FILE="$PF_DATA/token"
PF_SERVER_FILE="$PF_DATA/server.json"

# Always succeeds: an empty token is a normal state, not an error, and a
# non-zero return here aborts callers running under `set -e`.
pf_token() { [ -s "$PF_TOKEN_FILE" ] && cat "$PF_TOKEN_FILE"; return 0; }
pf_token_save() { printf '%s' "$1" >"$PF_TOKEN_FILE"; }
pf_token_clear() { rm -f "$PF_TOKEN_FILE" "$PF_SERVER_FILE"; }

# ---------------------------------------------------------------------------
# Sign-in: 4-character PIN + plex.tv/link
# ---------------------------------------------------------------------------
# `strong=true` returns a 25-character code that cannot be typed at
# plex.tv/link. The short code is the whole point of this flow.
plex_pin_new() {
	pf_curl -X POST "$PLEX_TV/pins" -d "strong=false"
}

# plex_pin_check <pinId> -- prints authToken when the user has linked, else empty
plex_pin_check() {
	pf_curl -X GET "$PLEX_TV/pins/$1" | jq -r '.authToken // empty' 2>/dev/null
}

# plex_validate <token> -- 0 if the token still works
plex_validate() {
	_u=$(pf_curl -X GET "$PLEX_TV/user" -H "X-Plex-Token: $1" | jq -r '.username // .title // empty' 2>/dev/null)
	[ -n "$_u" ] && { printf '%s' "$_u"; return 0; }
	return 1
}

# ---------------------------------------------------------------------------
# Home users (profiles)
# ---------------------------------------------------------------------------
# Returns TSV: uuid <tab> title <tab> protected(1/0) <tab> admin(1/0)
plex_home_users() {
	pf_curl -X GET "$PLEX_TV/home/users" -H "X-Plex-Token: $1" |
		jq -r '.users[]? | [.uuid, .title, (if .protected then 1 else 0 end), (if .admin then 1 else 0 end)] | @tsv' 2>/dev/null
}

# plex_switch_user <token> <uuid> [pin] -- prints the switched-to token
# The v2 endpoint is the current one; v1 (XML) is kept as a fallback because
# older servers/accounts still answer there and the failure is otherwise silent.
plex_switch_user() {
	_tok="$1"; _uuid="$2"; _pin="$3"
	_url="$PLEX_TV/home/users/$_uuid/switch"
	[ -n "$_pin" ] && _url="$_url?pin=$_pin"

	_r=$(pf_curl -X POST "$_url" -H "X-Plex-Token: $_tok")
	_new=$(printf '%s' "$_r" | jq -r '.authToken // empty' 2>/dev/null)
	if [ -n "$_new" ]; then printf '%s' "$_new"; return 0; fi

	# Surface a wrong-PIN rejection rather than falling through to v1.
	if printf '%s' "$_r" | grep -qi 'pin.*incorrect\|incorrect.*pin\|401\|Unauthorized'; then
		log "switch_user rejected: $_r"
		return 2
	fi

	_url1="https://plex.tv/api/home/users/$_uuid/switch"
	[ -n "$_pin" ] && _url1="$_url1?pin=$_pin"
	_r1=$(pf_curl -X POST "$_url1" -H "X-Plex-Token: $_tok")
	_new=$(xml_attr authenticationToken "$_r1")
	[ -z "$_new" ] && _new=$(xml_attr authToken "$_r1")
	if [ -n "$_new" ]; then printf '%s' "$_new"; return 0; fi

	log "switch_user failed: $_r / $_r1"
	return 1
}

# ---------------------------------------------------------------------------
# Servers
# ---------------------------------------------------------------------------
# Returns TSV: clientId <tab> name <tab> uri <tab> local(1/0) <tab> relay(1/0) <tab> accessToken
# Ordered local-first: on a handheld the LAN path is both faster and the only
# one that reliably avoids TLS/cert trouble.
plex_resources() {
	pf_curl -X GET "$PLEX_TV/resources?includeHttps=1&includeRelay=1" \
		-H "X-Plex-Token: $1" |
		jq -r '
      [ .[]? | select(.provides != null and (.provides | contains("server"))) ] as $srv
      | $srv[]
      | . as $s
      | .connections[]?
      | [ $s.clientIdentifier,
          $s.name,
          .uri,
          (if .local then 1 else 0 end),
          (if .relay then 1 else 0 end),
          ($s.accessToken // "") ]
      | @tsv
    ' 2>/dev/null | sort -t"$(printf '\t')" -k4,4r -k5,5n
}

# plex_probe <uri> <token> -- 0 if a Plex server answers there quickly
# Short timeout: unreachable candidates (remote URIs on a LAN-only network)
# otherwise stall the whole picker.
plex_probe() {
	_id=$(curl -K "$PF_CURLRC" --connect-timeout 4 --max-time 6 \
		-H "X-Plex-Token: $2" "$1/identity" 2>/dev/null)
	printf '%s' "$_id" | grep -q 'machineIdentifier'
}

# Our own IPv4 address, used to rank connections without probing them.
# busybox `ip` on device; route/ifconfig covers the desktop test harness.
pf_lan_ip() {
	_a=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
	[ -z "$_a" ] && _a=$(ipconfig getifaddr en0 2>/dev/null)
	[ -z "$_a" ] && _a=$(ifconfig 2>/dev/null | sed -n 's/.*inet \(192\.168\.[0-9.]*\).*/\1/p' | head -1)
	printf '%s' "$_a"
}

# Plex hands out hostnames like 192-168-3-68.<hash>.plex.direct, which resolve
# to that LAN address. Recovering the literal IP lets us (a) rank same-subnet
# servers first and (b) fall back to plain http if DNS is unavailable.
pf_uri_ip() {
	printf '%s' "$1" | sed -n 's#^https\{0,1\}://\([0-9]\{1,3\}\)-\([0-9]\{1,3\}\)-\([0-9]\{1,3\}\)-\([0-9]\{1,3\}\)\..*#\1.\2.\3.\4#p'
}

# http://IP:PORT for a plex.direct URI. Unencrypted, but it needs no DNS and no
# certificate validation -- the reliable last resort on a flaky handheld.
pf_uri_plain() {
	_ip=$(pf_uri_ip "$1")
	[ -z "$_ip" ] && return 1
	_port=$(printf '%s' "$1" | sed -n 's#.*:\([0-9]*\)$#\1#p')
	[ -z "$_port" ] && _port=32400
	printf 'http://%s:%s' "$_ip" "$_port"
}

# Rank 0 = same /24 as us, 1 = other local, 2 = remote, 3 = relay.
pf_conn_rank() {
	_uri="$1"; _local="$2"; _relay="$3"
	[ "$_relay" = "1" ] && { printf '3'; return; }
	if [ "$_local" = "1" ]; then
		_mine=$(pf_lan_ip); _theirs=$(pf_uri_ip "$_uri")
		if [ -n "$_mine" ] && [ -n "$_theirs" ] &&
			[ "${_mine%.*}" = "${_theirs%.*}" ]; then printf '0'; return; fi
		printf '1'; return
	fi
	printf '2'
}

# Find the best working connection for a given server id.
# Prints "uri<TAB>token<TAB>name<TAB>clientId" on success.
#
# Ordering matters a lot here: each dead candidate costs a multi-second
# timeout, and the resource list routinely includes LAN addresses belonging to
# other people's networks (shared servers) that can never work from here.
plex_pick_connection() {
	_want="$1"; _tok="$2"
	_cand="$PF_RUN/cands.$$"
	: >"$_cand"

	plex_resources "$_tok" | while IFS="$TABC" read -r cid name uri local relay atok; do
		[ -n "$_want" ] && [ "$cid" != "$_want" ] && continue
		[ "$relay" = "1" ] && [ "$(pf_get allow_relay false)" != "true" ] && continue
		printf '%s\t%s\t%s\t%s\t%s\n' \
			"$(pf_conn_rank "$uri" "$local" "$relay")" "$uri" "$atok" "$name" "$cid" >>"$_cand"
	done

	sort -n "$_cand" | while IFS="$TABC" read -r rank uri atok name cid; do
		_t="$atok"; [ -z "$_t" ] && _t="$_tok"
		if plex_probe "$uri" "$_t"; then
			printf '%s\t%s\t%s\t%s\n' "$uri" "$_t" "$name" "$cid"
			break
		fi
		# Secure path failed; try the same host over plain http before moving
		# on. This is the local-only fallback for devices whose DNS cannot
		# resolve *.plex.direct.
		_plain=$(pf_uri_plain "$uri") || continue
		if plex_probe "$_plain" "$_t"; then
			log "plex.direct unreachable for $uri; using plain $_plain"
			printf '%s\t%s\t%s\t%s\n' "$_plain" "$_t" "$name" "$cid"
			break
		fi
	done | head -1

	rm -f "$_cand"
}

# ---------------------------------------------------------------------------
# Library browsing
# ---------------------------------------------------------------------------
# srv_get <uri> <token> <path> -- GET against a media server
srv_get() {
	pf_curl -X GET "$1$3" -H "X-Plex-Token: $2"
}

# Returns TSV: key <tab> title <tab> type
plex_sections() {
	srv_get "$1" "$2" "/library/sections" |
		jq -r '.MediaContainer.Directory[]? | [.key, .title, .type] | @tsv' 2>/dev/null
}

# PF_ROW -- every list function returns this same 12-field TSV so the UI has one
# row format to render:
#
#   1 ratingKey  2 type  3 title  4 year  5 viewOffset  6 duration
#   7 titleSort  8 index  9 parentIndex
#  10 viewCount 11 leafCount 12 viewedLeafCount
#  13 librarySectionTitle 14 grandparentTitle 15 parentTitle
#
# Fields 10-12 are what let a list say whether you have seen something. With
# no artwork and no episode thumbnails there is otherwise nothing at all to
# distinguish an episode you watched last night from one you have never opened,
# which on a 25-episode season is the difference between a usable list and a
# guessing game.
#
# Fields 13-15 are where the item lives -- library, show, season. They exist so
# a download can be filed under the same three names you walked through to find
# it, without the code having to reconstruct that from the navigation stack:
# the same episode reached from Continue Watching or from a letter search then
# lands in the same folder as one reached by browsing. Every reader indexes
# fields positionally, so appending here is safe; inserting would not be.
PF_ROW_JQ='[
  .ratingKey, .type, .title,
  (.year // ""), (.viewOffset // 0), (.duration // 0),
  (.titleSort // .title // ""),
  (.index // ""), (.parentIndex // ""),
  (.viewCount // 0), (.leafCount // 0), (.viewedLeafCount // 0),
  (.librarySectionTitle // ""), (.grandparentTitle // ""), (.parentTitle // "")
] | @tsv'

# plex_section_items <uri> <token> <sectionKey> [sort]
#
# titleSort is carried through because the list is ordered by it, not by the
# displayed title: Plex files "The 10th Kingdom" under 1, not T. The A-Z gutter
# and letter jump have to agree with that or they point at the wrong rows.
plex_section_items() {
	_sort="${4:-titleSort:asc}"
	srv_get "$1" "$2" "/library/sections/$3/all?sort=$_sort" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ" 2>/dev/null
}

# plex_children <uri> <token> <ratingKey>  (seasons of a show, episodes of a season)
plex_children() {
	srv_get "$1" "$2" "/library/metadata/$3/children" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ" 2>/dev/null
}

# Every episode of a show in one call, for "download the whole series".
plex_show_episodes() {
	srv_get "$1" "$2" "/library/metadata/$3/allLeaves" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ" 2>/dev/null
}

# plex_item <uri> <token> <ratingKey> -- full metadata JSON for one item
#
# includeMarkers=1 is asked for unconditionally. Plex omits chapter markers
# unless requested, and the intro marker is what "skip intros" needs -- getting
# it here means the item screen pays no extra request for it, since it is
# already reading this response for everything else it draws.
plex_item() {
	srv_get "$1" "$2" "/library/metadata/$3?includeMarkers=1"
}

# plex_next_episode <uri> <token> <ratingKey>
#
# The PF_ROW of whatever comes after this episode: the next one in the season,
# or the first of the next season. Nothing for a film, or at the end of a show.
#
# Deliberately not `allLeaves`: that is one request but it is 291 rows on Dragon
# Ball Z, and this runs at the end of every single episode.
plex_next_episode() {
	_m=$(plex_item "$1" "$2" "$3" |
		jq -r '.MediaContainer.Metadata[0]
           | [ (.type // ""), ((.index // 0) | tostring),
               (.parentRatingKey // ""), (.grandparentRatingKey // ""),
               ((.parentIndex // 0) | tostring) ] | @tsv' 2>/dev/null)
	[ -z "$_m" ] && return 1
	[ "$(printf '%s' "$_m" | cut -f1)" = "episode" ] || return 1
	_ix=$(printf '%s' "$_m" | cut -f2)
	_par=$(printf '%s' "$_m" | cut -f3)
	_shw=$(printf '%s' "$_m" | cut -f4)
	_pix=$(printf '%s' "$_m" | cut -f5)

	_n=""
	[ -n "$_par" ] && _n=$(plex_children "$1" "$2" "$_par" |
		awk -F"$TABC" -v i="$_ix" '
			$2=="episode" && $8+0 > i+0 { if (b=="" || $8+0 < bi) { b=$0; bi=$8+0 } }
			END {print b}')

	# End of the season: take the first episode of the next one.
	if [ -z "$_n" ] && [ -n "$_shw" ]; then
		_ns=$(plex_children "$1" "$2" "$_shw" |
			awk -F"$TABC" -v p="$_pix" '
				$2=="season" && $8+0 > p+0 { if (b=="" || $8+0 < bi) { b=$1; bi=$8+0 } }
				END {print b}')
		[ -n "$_ns" ] && _n=$(plex_children "$1" "$2" "$_ns" |
			awk -F"$TABC" '
				$2=="episode" { if (b=="" || $8+0 < bi) { b=$0; bi=$8+0 } }
				END {print b}')
	fi
	[ -z "$_n" ] && return 1
	printf '%s' "$_n"
	unset _m _ix _par _shw _pix _ns
}

# plex_intro_end <uri> <token> <ratingKey> -- ms the intro ends at, or nothing.
#
# Only a marker that starts inside the first five minutes counts. A recap or a
# credits marker further in is not something to silently seek past, and Plex's
# marker set is not limited to intros.
plex_intro_end() {
	plex_item "$1" "$2" "$3" |
		jq -r '[ .MediaContainer.Metadata[0].Marker[]?
             | select(.type == "intro")
             | select(((.startTimeOffset // 0) | tonumber) < 300000)
             | ((.endTimeOffset // 0) | tonumber) ]
           | map(select(. > 0)) | first // empty' 2>/dev/null
}

# Recently added in one library. The rows every other Plex client opens with.
plex_recent() {
	srv_get "$1" "$2" "/library/sections/$3/recentlyAdded?X-Plex-Container-Start=0&X-Plex-Container-Size=${4:-5}" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ_FLAT" 2>/dev/null
}

# Continue Watching for one library rather than the whole server.
plex_section_ondeck() {
	srv_get "$1" "$2" "/library/sections/$3/onDeck?X-Plex-Container-Start=0&X-Plex-Container-Size=${4:-5}" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ_FLAT" 2>/dev/null
}

# Recently *released*, which is not the same list as recently added: added is
# when the file appeared on the server, released is when the thing came out.
plex_section_newest() {
	srv_get "$1" "$2" "/library/sections/$3/newest?X-Plex-Container-Start=0&X-Plex-Container-Size=${4:-5}" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ_FLAT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Hubs -- the rows an official Plex client's home screen is made of
# ---------------------------------------------------------------------------
# `/hubs` and `/hubs/sections/<id>` are what those clients actually draw. The
# *server* decides what the rows are and what they are called -- Continue
# Watching, Recently Added, Recently Released, Recently Played, "Because you
# watched..." -- and returns every one of them, titled, in a single request.
#
# That is the whole reason to use it rather than assembling rows by hand: the
# hand-built version is one request per row per library, on a device where a
# request is expensive and the home screen is redrawn constantly. It also means
# the rows track whatever the server offers instead of a list hard-coded here.
#
# Emits a flat stream the interface turns straight into menu rows:
#
#   HDR <tab> <row title>
#   <PF_ROW> ...
#
# Anything that is not a film, show, season or episode is dropped -- a music or
# photo library's hubs come back here too, and there is nothing this player can
# do with a track. A hub left with no items after that filtering emits no
# header either, so an empty row never appears.
#
# plex_hubs <uri> <token> <path> [count] [hiddenSectionList]
plex_hubs() {
	_hp="$3"
	case "$_hp" in
	*\?*) _hp="$_hp&count=${4:-5}" ;;
	*) _hp="$_hp?count=${4:-5}" ;;
	esac
	srv_get "$1" "$2" "$_hp" |
		jq -r --argjson n "${4:-5}" --arg hid "${5:-}" '
      .MediaContainer.Hub[]?
      | ( [ (.Metadata // [])[]
            | select(.type=="movie" or .type=="show"
                     or .type=="season" or .type=="episode") ][0:$n] ) as $items
      | select(($items | length) > 0)
      # The section id has to be bound *before* the pipe into index(): inside
      # `$hid | index(f)`, f is evaluated against $hid -- a string -- and
      # `.librarySectionID` on a string is an error that takes the whole
      # response with it. A hub with no section at all (Continue Watching spans
      # every library) has an empty id and is never hidden.
      | ((.librarySectionID // "") | tostring) as $sid
      | select($hid == "" or $sid == ""
               or (($hid | index("," + $sid + ",")) == null))
      | ( "HDR\t" + (.title // .hubIdentifier // "More") ),
        ( $items[] | '"$PF_ROW_JQ_FLAT"' )
    ' 2>/dev/null
	unset _hp
}

# Same shape, but episodes and seasons carry the show name -- outside a season
# list the episode title alone ("Stone World") identifies nothing.
#
# Seasons need this just as badly, and for a while did not have it. A season's
# own title is "Season 1", so a Recently Added row on a TV library -- where what
# the server hands back *is* a list of seasons, because that is what got added --
# came out as five identical lines reading "S01  Season 1" with no clue which
# show any of them belonged to. The show name is in .parentTitle; it just was
# never read.
#
# When the season title is the generic "Season <n>", the number is dropped from
# the label rather than repeated: the list already prints an "S01" prefix in
# front of it (see items_to_menu), so keeping both gives "S01  Fire Force -
# Season 1". A season with a real name of its own -- "Specials", or a named arc
# -- keeps it, because there the title is carrying information the prefix isn't.
#
# The generic case is spotted by comparing against the index rather than by
# matching a pattern, so this needs no regex support from jq.
PF_ROW_JQ_FLAT='[
  .ratingKey, .type,
  (if .type=="episode" then ((.grandparentTitle // "") + " - " + (.title // ""))
   elif .type=="season" then
     ( (.parentTitle // "") as $p | (.title // "") as $t
       | if $p == "" then $t
         elif $t == ("Season " + ((.index // 0) | tostring)) then $p
         else $p + " - " + $t end )
   else (.title // "") end),
  (.year // ""), (.viewOffset // 0), (.duration // 0),
  (.titleSort // .title // ""),
  (.index // ""), (.parentIndex // ""),
  (.viewCount // 0), (.leafCount // 0), (.viewedLeafCount // 0),
  (.librarySectionTitle // ""), (.grandparentTitle // ""), (.parentTitle // "")
] | @tsv'

# Continue Watching / On Deck, the one row every Plex client is expected to have.
plex_ondeck() {
	_lim=""
	[ -n "$3" ] && _lim="?X-Plex-Container-Start=0&X-Plex-Container-Size=$3"
	srv_get "$1" "$2" "/library/onDeck$_lim" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ_FLAT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Browse by letter
# ---------------------------------------------------------------------------
# This used to be `/search?query=A`, which is not a letter browse at all: Plex's
# search matches a substring anywhere in a title and ranks by relevance, so "S"
# returned Steins;Gate and Samurai Champloo mixed in with every episode whose
# name happens to contain an s. Episodes especially, which nobody is looking for
# when they pick a letter off a menu.
#
# Plex keeps a proper first-letter index per library, the one its own clients
# draw as an A-Z rail. Each entry carries the character, how many titles are
# under it, and the key to fetch them -- so the counts on our menu are the
# server's counts and the results are the server's own idea of what starts with
# that letter, which is titleSort-based and therefore files "The Angel Next
# Door" under A exactly as the library list does.
#
# Returns TSV: character <tab> count <tab> key
plex_first_characters() {
	srv_get "$1" "$2" "/library/sections/$3/firstCharacter" |
		jq -r '.MediaContainer.Directory[]?
           | [(.title // .key // ""), (.size // 0), (.key // "")]
           | @tsv' 2>/dev/null
}

# plex_section_letter <uri> <token> <sectionKey> <keyFromFirstCharacter>
#
# The key is followed as given rather than assumed: some server versions hand
# back a whole path ("/library/sections/2/firstCharacter/A"), others just the
# character. Both are answered here, and a caller that gets nothing back falls
# through to filtering the section itself -- see letter_items() in ui.sh.
plex_section_letter() {
	case "$4" in
	/*) _p="$4" ;;
	*) _p="/library/sections/$3/firstCharacter/$(urlencode "$4")" ;;
	esac
	case "$_p" in
	*\?*) _p="$_p&sort=titleSort:asc" ;;
	*) _p="$_p?sort=titleSort:asc" ;;
	esac
	srv_get "$1" "$2" "$_p" |
		jq -r ".MediaContainer.Metadata[]? | $PF_ROW_JQ" 2>/dev/null
	unset _p
}

# ---------------------------------------------------------------------------
# Subtitles
# ---------------------------------------------------------------------------
# The server burns subtitles into the video it sends; the device's ffplay is an
# ffmpeg 2.8 build with no libass, so it cannot render a subtitle track itself.
# Since everything is transcoded, that costs nothing -- but it does mean the
# choice has to be made before the stream starts, not during it.
#
# streamType 3 is subtitles. Returns TSV: id <tab> label <tab> selected(1/0)
plex_subtitle_streams() {
	plex_item "$1" "$2" "$3" |
		jq -r '.MediaContainer.Metadata[0].Media[0].Part[0].Stream[]?
           | select(.streamType == 3)
           | [ (.id | tostring),
               ((.extendedDisplayTitle // .displayTitle // .language // "Track")
                 | if (. | length) > 34 then .[0:32] + ".." else . end),
               (if .selected then 1 else 0 end) ]
           | @tsv' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Audio tracks
# ---------------------------------------------------------------------------
# streamType 2. The other half of the job the subtitle switch only did half of:
# on an anime library the choice between a dub and the original with subtitles
# is the same size of decision as subtitles on or off, and it was not reachable
# from the device at all.
#
# It costs nothing extra to honour, because everything is transcoded: the server
# is already building a stream and simply builds it from a different track.
# Returns TSV: id <tab> label <tab> selected(1/0)
plex_audio_streams() {
	plex_item "$1" "$2" "$3" |
		jq -r '.MediaContainer.Metadata[0].Media[0].Part[0].Stream[]?
           | select(.streamType == 2)
           | [ (.id | tostring),
               ((.extendedDisplayTitle // .displayTitle // .language // "Track")
                 | if (. | length) > 34 then .[0:32] + ".." else . end),
               (if .selected then 1 else 0 end) ]
           | @tsv' 2>/dev/null
}

# plex_set_audio <uri> <token> <partId> <streamId>
# Server-side, like the subtitle choice, so it sticks for this item everywhere.
plex_set_audio() {
	pf_curl -X PUT "$1/library/parts/$3?audioStreamID=$4&allParts=1" \
		-H "X-Plex-Token: $2" >/dev/null 2>&1
}

# The part id is what a subtitle or audio selection is applied to, not the item.
plex_part_id() {
	plex_item "$1" "$2" "$3" |
		jq -r '.MediaContainer.Metadata[0].Media[0].Part[0].id // empty' 2>/dev/null
}

# plex_set_subtitle <uri> <token> <partId> <streamId>   (0 = none)
# This is a server-side preference, so the choice sticks for this item on every
# client -- which is the behaviour people expect from Plex.
plex_set_subtitle() {
	pf_curl -X PUT "$1/library/parts/$3?subtitleStreamID=$4&allParts=1" \
		-H "X-Plex-Token: $2" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Playback URLs
# ---------------------------------------------------------------------------
pf_new_session() {
	_s=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-24)
	[ -z "$_s" ] && _s="pf$(date +%s)$$"
	printf '%s' "$_s"
}

# The player cannot speak TLS.
#
# OnionOS's ffplay links libavformat.so.56 (ffmpeg 2.8 era) built with no
# openssl/gnutls/mbedtls backend -- the library literally contains the string
# "https protocol not found, recompile with openssl or gnutls enabled." Handing
# it an https:// URL makes it exit within a second with no visible error, which
# is exactly the "Loading... then straight back to the menu" symptom.
#
# So: the API keeps using verified https via curl, while *media* URLs are built
# against the plain-http endpoint on the same host.
plex_media_base() {
	case "$1" in
	http://*) printf '%s' "$1"; return 0 ;;
	esac
	pf_uri_plain "$1"
}

# Direct play is gone, and there is deliberately no plex_direct_url any more.
# It never worked on this device: the log shows ffplay exiting after one or two
# seconds and dropping back to the launcher on a 1080p remux and on an 848x480
# 500 kbps file alike, so it was not simply a matter of the SoC being too slow
# for big files. Keeping it as an option meant the default setting was one that
# could not play anything.
#
# Everything after the endpoint name, shared by playback and download so the
# two can never drift apart in a way that makes a downloaded file behave
# differently from the same title streamed.
#
# <res> <bitrate> <session> <offsetSeconds> <subs on|off> <token>
plex_stream_params() {
	printf '&mediaIndex=0&partIndex=0'
	printf '&offset=%s&fastSeek=1' "$4"
	printf '&directPlay=0&directStream=0'
	printf '&videoQuality=60&videoResolution=%s&maxVideoBitrate=%s' "$1" "$2"
	# subtitles=burn renders them into the video frames. That is the only
	# option that works here: the player cannot draw a subtitle track, so a
	# soft track would arrive and be silently discarded.
	if [ "$5" = "on" ]; then
		printf '&subtitles=burn&subtitleSize=100'
	else
		printf '&subtitles=none'
	fi
	printf '&audioBoost=100'
	printf '&session=%s&X-Plex-Session-Identifier=%s' "$3" "$3"
	# Identity goes in the query string, not headers. ffplay's `-headers`
	# handling varies between builds and the on-device binary is an old one;
	# query parameters are understood by every version and by the server
	# identically. X-Plex-Platform in particular is mandatory (see common.sh).
	printf '&X-Plex-Client-Identifier=%s' "$(client_id)"
	printf '&X-Plex-Product=%s&X-Plex-Platform=%s' "$PF_PRODUCT" "$PF_PLATFORM"
	printf '&X-Plex-Token=%s' "$6"
}

# plex_transcode_url <uri> <token> <ratingKey> <session> <offsetSeconds>
# HLS is used rather than a raw MPEG-TS stream: ffmpeg's hls demuxer recovers
# from a stalled segment, where a broken TS pipe just ends playback.
plex_transcode_url() {
	printf '%s/video/:/transcode/universal/start.m3u8' "$1"
	printf '?path=%s' "$(urlencode "/library/metadata/$3")"
	printf '&protocol=hls'
	plex_stream_params "$(pf_res_get resolution 640x480)" "$(pf_get bitrate 2000)" \
		"$4" "${5:-0}" "$(pf_get subtitles on)" "$2"
}

# plex_download_url <uri> <token> <ratingKey> <session>
#
# The same transcoder, asked for one continuous file instead of a playlist.
# `protocol=http` makes Plex emit a single Matroska stream that curl can write
# straight to the card -- no playlist polling, no segment stitching, and the
# result is an ordinary local file the player opens with no network at all.
#
# Quality is deliberately its own setting and defaults lower than streaming:
# the panel is 3.5", storage is an SD card, and the whole point of a download
# is to fit a lot of them.
plex_download_url() {
	printf '%s/video/:/transcode/universal/start.mkv' "$1"
	printf '?path=%s' "$(urlencode "/library/metadata/$3")"
	printf '&protocol=http&copyts=0'
	plex_stream_params "$(pf_res_get dl_resolution 480x320)" "$(pf_get dl_bitrate 720)" \
		"$4" 0 "$(pf_get subtitles on)" "$2"
}

# Confirm the server will actually serve this stream before we hand the screen
# over to ffplay. Plex answers a bare 400 (no body, no reason) when its
# transcoder is briefly wedged -- observed repeatedly against 1.43.2 under
# rapid session churn -- and recovers within a few seconds. Without this the
# user just gets a black screen and a silent bounce back to the menu.
# Prints the HTTP status; returns 0 only on 200.
plex_preflight() {
	_try=1
	while [ "$_try" -le 3 ]; do
		_code=$(curl -K "$PF_CURLRC" -o /dev/null -w '%{http_code}' \
			--max-time 30 "$1" 2>/dev/null)
		[ "$_code" = "200" ] && { printf '200'; return 0; }
		log "preflight attempt $_try got HTTP $_code"
		_try=$((_try + 1))
		[ "$_try" -le 3 ] && sleep 3
	done
	printf '%s' "$_code"
	return 1
}

# Tell the server to tear the transcode session down. Skipping this leaves
# ffmpeg processes running on the server until it times them out.
plex_transcode_stop() {
	pf_curl -X GET "$1/video/:/transcode/universal/stop?session=$3" \
		-H "X-Plex-Token: $2" >/dev/null 2>&1
}

# plex_timeline <uri> <token> <ratingKey> <state> <timeMs> <durationMs>
# Reports progress so resume works here and everywhere else on the account.
plex_timeline() {
	pf_curl -X GET "$1/:/timeline?ratingKey=$3&key=$(urlencode "/library/metadata/$3")&state=$4&time=$5&duration=$6&X-Plex-Token=$2" \
		>/dev/null 2>&1
}
