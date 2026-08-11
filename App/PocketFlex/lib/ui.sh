#!/bin/sh
# PocketFlex - main interface. Runs inside OnionOS's `st` SDL terminal.
#
# Playback cannot happen while this is running: ffplay and st both want the
# SDL framebuffer. So when the user picks something we write a request file,
# exit, and let launch.sh run ffplay and start us again. The navigation stack
# is persisted for exactly that reason -- it is what makes "watch an episode,
# land back on the episode list" work across that round trip.

PF_DIR="${PF_DIR:-/mnt/SDCARD/App/PocketFlex}"
. "$PF_DIR/lib/common.sh"
. "$PF_DIR/lib/plex.sh"
. "$PF_DIR/lib/cache.sh"
. "$PF_DIR/lib/ui_util.sh"
. "$PF_DIR/lib/wifi.sh"

PF_STACK="$PF_RUN/stack"
PF_REQ="$PF_RUN/play.req"
PF_QUIT="$PF_RUN/quit"
PF_NOTE="$PF_RUN/note"

NLC='
'

TOKEN=""
SRV_URI=""
SRV_TOK=""
# Set when the server could not be reached and we fell back to the downloads.
PF_OFFLINE=0

# --- menu building ----------------------------------------------------------
# Command substitution strips trailing newlines, so concatenating $(...) blocks
# silently glues the last row of one block onto the first row of the next.
# Everything goes through these helpers to keep the line breaks explicit.
#
# Row shape is pf_menu's: payload, label, sortLetter, right, flags.
mb_reset() { MB=""; }
mb_row() { MB="$MB$1$TABC$2$TABC$3$TABC$4$TABC$5$NLC"; }
mb_add() { mb_row "$1" "$2" "" "$3" "$4"; }
mb_sep() { mb_row "--" "-" "" "" "s"; }
mb_block() { [ -n "$1" ] && MB="$MB$1$NLC"; }
mb_back() { mb_add BACK ".. Back"; }

# --- detail panel -----------------------------------------------------------
# pf_menu draws this under the list when there is room. Writing it to a file
# rather than a variable keeps the redraw path free of re-splitting.
note_reset() { : >"$PF_NOTE"; }
note_add() { printf '%s\n' "$1" >>"$PF_NOTE"; }
note_use() { [ -s "$PF_NOTE" ] && PF_MENU_NOTE="$PF_NOTE"; return 0; }

# --- navigation stack -------------------------------------------------------
# type <tab> key <tab> title <tab> cursor
#
# The cursor is the fourth field, written by nav_mark just before a screen hands
# off to the next one, and read back by the main loop when that screen is drawn
# again. It is what makes coming back land on the row you left rather than at
# the top: out of an episode into its season, out of a season into a 600-title
# library, and -- because the stack is a file and this interface exits for
# playback -- out of a film you have just watched.
nav_push() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$PF_STACK"; }

# Record the cursor on the frame currently on top.
nav_mark() {
	[ -s "$PF_STACK" ] || return 0
	_t="$PF_RUN/stack.tmp"
	awk -F"$TABC" -v OFS="$TABC" -v c="${1:-0}" '
		{ line[NR] = $0 }
		END {
		  for (i = 1; i <= NR; i++) {
		    if (i < NR) { print line[i]; continue }
		    $0 = line[i]; $4 = c; print
		  }
		}' "$PF_STACK" >"$_t" && mv "$_t" "$PF_STACK"
	unset _t
}
nav_pop() {
	[ -s "$PF_STACK" ] || return 1
	_t="$PF_RUN/stack.tmp"
	sed '$d' "$PF_STACK" >"$_t" && mv "$_t" "$PF_STACK"
}
nav_top() { [ -s "$PF_STACK" ] && tail -1 "$PF_STACK"; return 0; }
nav_reset() { : >"$PF_STACK"; nav_push home "" "PocketFlex"; }

# The title of the innermost frame of a given type, or nothing. Used to name
# the library a download came from: an episode's own metadata carries the show
# and the season but not always the library, and that is the one part of the
# path the stack always knows.
nav_title_of() {
	[ -s "$PF_STACK" ] || return 0
	awk -F"$TABC" -v t="$1" '$1==t {v=$3} END {print v}' "$PF_STACK"
}

# --- formatting -------------------------------------------------------------
ms_to_hms() {
	_s=$(( ${1:-0} / 1000 ))
	_h=$((_s / 3600)); _m=$(((_s % 3600) / 60)); _sec=$((_s % 60))
	if [ "$_h" -gt 0 ]; then printf '%d:%02d:%02d' "$_h" "$_m" "$_sec"
	else printf '%d:%02d' "$_m" "$_sec"; fi
}

draw() { printf "$@" >/dev/tty; }

# Quality is named by what it is rather than by its pixel box: nobody choosing
# between two options on a 3.5" screen is thinking in transcoder arguments.
# Both are panel-sized or smaller -- there is no longer a setting that asks the
# server for more pixels than this panel can show.
res_label() {
	case "$1" in
	480x320) printf '320p - lighter on Wi-Fi' ;;
	*) printf '480p - full panel' ;;
	esac
}

# ---------------------------------------------------------------------------
# Sign-in
# ---------------------------------------------------------------------------
do_signin() {
	pf_msg "Requesting a sign-in code..." nowait
	_r=$(plex_pin_new)
	_id=$(printf '%s' "$_r" | jq -r '.id // empty' 2>/dev/null)
	_code=$(printf '%s' "$_r" | jq -r '.code // empty' 2>/dev/null)
	if [ -z "$_id" ] || [ -z "$_code" ]; then
		pf_msg "Could not reach plex.tv.${NLC}${NLC}Check Wi-Fi is connected,${NLC}then try again."
		return 1
	fi

	term_size
	raw_on
	draw '\033[?25l'
	_n=0
	while [ "$_n" -lt 200 ]; do
		{
			printf '\033[H\033[2J'
			bar "Sign in to Plex" "plex.tv/link" 1
			printf '\033[3;3HOn a phone or computer, open'
            printf '\033[4;3H%splex.tv/link%s and enter:' "$C_ACC" "$C_OFF"
			# Rendered as block text: this is the one thing that has to be
			# read off the panel and typed somewhere else.
			big_text "$_code" 6
			printf '\033[12;3H%sWaiting' "$C_HINT"
			_d=0
			while [ "$_d" -lt $((_n % 4)) ]; do printf '.'; _d=$((_d + 1)); done
			printf '   %s' "$C_OFF"
			bar "Code expires in 15 minutes" "MENU cancel" "$LINES"
		} >/dev/tty

		sleep 3
		_t=$(plex_pin_check "$_id")
		if [ -n "$_t" ]; then
			raw_off
			draw '\033[?25h'
			pf_token_save "$_t"
			TOKEN="$_t"
			pf_msg "Signed in as${NLC}$(plex_validate "$_t")"
			return 0
		fi
		_n=$((_n + 1))
	done
	raw_off
	draw '\033[?25h'
	pf_msg "That code expired.${NLC}Try signing in again."
	return 1
}

# ---------------------------------------------------------------------------
# Profiles (Plex Home users)
# ---------------------------------------------------------------------------
screen_profiles() {
	pf_status "Loading profiles..."
	_users=$(plex_home_users "$TOKEN")
	if [ -z "$_users" ]; then
		pf_msg "No additional profiles on${NLC}this account."
		return 0
	fi

	mb_reset
	mb_back
	mb_block "$(printf '%s\n' "$_users" |
		awk -F"$TABC" '{lk = ($3=="1") ? "  (PIN)" : ""; printf "%s|%s\t%s%s\n", $1, $3, $2, lk}')"

	_sel=$(printf '%s' "$MB" | pf_menu "Who's watching?" "A select | R1 back | MENU quit")
	case "$_sel" in
	BACK | "") return 0 ;;
	esac

	_uuid=${_sel%%|*}
	_prot=${_sel##*|}

	_pin=""
	if [ "$_prot" = "1" ]; then
		_pin=$(pf_pinpad "Enter profile PIN" 4)
	fi

	pf_status "Switching profile..."
	_new=$(plex_switch_user "$TOKEN" "$_uuid" "$_pin")
	_rc=$?
	case "$_rc" in
	0)
		pf_token_save "$_new"
		TOKEN="$_new"
		# The cached per-server access token belongs to the previous user, and so
		# does the media endpoint that was probed with it.
		pf_set server_uri ""
		pf_set server_token ""
		pf_set media_uri ""
		SRV_URI=""; SRV_TOK=""
		# Another profile can see a different set of libraries.
		home_cache_clear
		nav_reset

		# Re-connect here, before returning to a screen that assumes a server.
		#
		# Throwing the cached connection away is right -- it belongs to the user
		# we just stopped being -- but nothing was putting a new one in its
		# place. ensure_server runs once at start-up and from Settings, not on
		# the way out of this screen, so SRV_URI stayed empty; the next thing to
		# ask the server anything got an empty answer, and screen_home reads an
		# empty answer as the connection having dropped. Hence "Lost the
		# connection to Homeflix" immediately after a profile switch on a
		# network that never went anywhere -- and hence "Try again" fixing it,
		# since that path does call ensure_server.
		pf_status "Reconnecting..."
		if ensure_server; then
			PF_OFFLINE=0
			pf_msg "Switched profile."
		else
			pf_msg "Switched to that profile, but${NLC}the server could not be reached${NLC}as that user."
		fi
		;;
	2) pf_msg "That PIN was not accepted." ;;
	*) pf_msg "Could not switch profile.${NLC}The server may be unreachable." ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Servers
# ---------------------------------------------------------------------------
ensure_server() {
	SRV_URI=$(pf_get server_uri "")
	SRV_TOK=$(pf_get server_token "")
	if [ -n "$SRV_URI" ] && [ -n "$SRV_TOK" ]; then
		# Installs that predate the media endpoint won't have one stored.
		[ -z "$(pf_get media_uri '')" ] && set_media_uri
		return 0
	fi

	pf_status "Looking for your Plex server..."
	_line=$(plex_pick_connection "$(pf_get server_id '')" "$TOKEN" | head -1)
	if [ -z "$_line" ]; then
		screen_servers && return 0
		return 1
	fi
	SRV_URI=$(printf '%s' "$_line" | cut -f1)
	SRV_TOK=$(printf '%s' "$_line" | cut -f2)
	pf_set server_uri "$SRV_URI"
	pf_set server_token "$SRV_TOK"
	pf_set server_name "$(printf '%s' "$_line" | cut -f3)"
	pf_set server_id "$(printf '%s' "$_line" | cut -f4)"
	set_media_uri
	return 0
}

# The player has no TLS support, so media has to come over plain http even
# when the API is on https. Resolve and verify that endpoint once, here,
# rather than discovering it's missing at the moment someone presses Play.
set_media_uri() {
	_m=$(plex_media_base "$SRV_URI")
	if [ -n "$_m" ] && plex_probe "$_m" "$SRV_TOK"; then
		pf_set media_uri "$_m"
		log "media endpoint $_m"
	else
		pf_set media_uri ""
		log "no usable plain-http media endpoint for $SRV_URI"
	fi
}

screen_servers() {
	pf_status "Finding servers..."
	_res=$(plex_resources "$TOKEN")
	if [ -z "$_res" ]; then
		pf_msg "No servers found on this${NLC}account. Check Wi-Fi."
		return 1
	fi

	# One row per server, not per connection: choosing the connection is our
	# job, not the user's.
	mb_reset
	mb_back
	mb_block "$(printf '%s\n' "$_res" | awk -F"$TABC" '!seen[$1]++ {print $1"\t"$2}')"

	_sel=$(printf '%s' "$MB" | pf_menu "Choose a server" "A select | R1 back | MENU quit")
	case "$_sel" in
	BACK | "") return 1 ;;
	esac

	pf_status "Connecting..."
	_line=$(plex_pick_connection "$_sel" "$TOKEN" | head -1)
	if [ -z "$_line" ]; then
		pf_msg "Could not reach that server${NLC}from this network."
		return 1
	fi
	SRV_URI=$(printf '%s' "$_line" | cut -f1)
	SRV_TOK=$(printf '%s' "$_line" | cut -f2)
	_name=$(printf '%s\n' "$_res" | awk -F"$TABC" -v c="$_sel" '$1==c {print $2; exit}')
	pf_set server_id "$_sel"
	pf_set server_name "$_name"
	pf_set server_uri "$SRV_URI"
	pf_set server_token "$SRV_TOK"
	set_media_uri
	# The letter index and the home rows belong to whichever server built them.
	home_cache_clear
	nav_reset
	return 0
}

# ---------------------------------------------------------------------------
# Browsing
# ---------------------------------------------------------------------------
# Turn a PF_ROW list into pf_menu rows:
#   payload <TAB> label <TAB> sortLetter <TAB> rightText <TAB> flags
#
# The payload encodes type+key so the caller knows which screen to push next.
#
# Episode and season numbers lead the label. In a client with no artwork the
# S01E04 code is the primary way to tell episodes apart and to know where you
# are in a season, so it belongs at the start of the line where it can be
# scanned, not buried after the title.
#
# The right column carries the one fact that actually helps you choose: how far
# through it you are. For a show or season that is "9/24" episodes seen; for an
# episode or film it is a resume percentage, "seen", or the year.
#
# Cache state is joined in from the index inside awk. Doing it per row in the
# shell would be one process per item, which on a 638-title library is a wait
# long enough to look broken.
items_to_menu() {
	awk -F"$TABC" -v cache="$PF_CACHE_IDX" '
    # A hub title arriving in the same stream as the items under it. Passing it
    # through here rather than converting it separately is what lets one pass
    # turn a whole home screen -- four titled rows and their contents -- into
    # menu rows in the order the server sent them.
    $1 == "HDR" { printf "HDR\t%s\t\t\th\n", toupper($2); next }
    BEGIN {
      if (cache != "") {
        while ((getline line < cache) > 0) {
          n = split(line, a, "\t");
          if (n >= 2) dl[a[1]] = a[2];
        }
        close(cache);
      }
    }
    {
      key=$1; type=$2; title=$3; year=$4; off=$5+0; dur=$6+0;
      sortk=$7; idx=$8; pidx=$9; vc=$10+0; leaf=$11+0; vleaf=$12+0;

      prefix="";
      if (type=="episode" && idx != "") {
        if (pidx != "") prefix=sprintf("S%02dE%02d  ", pidx, idx);
        else            prefix=sprintf("E%02d  ", idx);
      } else if (type=="season" && idx != "") {
        prefix=sprintf("S%02d  ", idx);
      }

      label=prefix title;

      right=""; flags="";
      if (type=="show" || type=="season") {
        if (leaf>0 && vleaf>=leaf)   { right="seen"; flags=flags "w" }
        else if (vleaf>0)            right=sprintf("%d/%d", vleaf, leaf);
        else if (year!="" && type=="show") right=year;
      } else {
        if (dur>0 && off>60000)      right=sprintf("%d%%", off*100/dur);
        else if (vc>0)               { right="seen"; flags=flags "w" }
        else if (year!="" && type=="movie") right=year;
      }

      s = dl[key];
      if (s == "done") flags = flags "d";
      else if (s == "queued" || s == "downloading") flags = flags "q";

      if (sortk=="") sortk=title;
      ch=toupper(substr(sortk,1,1));
      if (ch !~ /[A-Z]/) ch="#";

      printf "%s:%s\t%s\t%s\t%s\t%s\n", type, key, label, ch, right, flags;
    }'
}

# Offer only the initials that actually occur in this list, with a count, so
# nobody scrolls to Q to find it empty.
pick_letter() {
	_opts=$(printf '%s\n' "$1" | awk -F"$TABC" '
		$3 != "" { n[$3]++ }
		END { for (c in n) printf "%s\t%s   (%d)\n", c, c, n[c] }' | sort)
	mb_reset
	mb_back
	mb_block "$_opts"
	PF_MENU_INDEX=0
	_r=$(printf '%s' "$MB" | pf_menu "Jump to letter" "A select | R1 back")
	case "$_r" in
	BACK | "") printf '' ;;
	*) printf '%s' "$_r" ;;
	esac
}

# screen_list <title> <PF_ROW data> [contextKey]
#
# contextKey, when given, is the show or season being listed, which is what
# makes "download everything below this point" possible in one press -- the
# feature that turns this from a streaming client into something you can take
# on a plane.
screen_list() {
	_ttl="$1"
	_data="$2"
	_ctx="$3"
	if [ -z "$_data" ]; then
		pf_msg "Nothing here."
		nav_pop
		return 0
	fi

	_rows=$(printf '%s\n' "$_data" | items_to_menu)
	_n=$(printf '%s\n' "$_rows" | wc -l | tr -d ' ')
	# Rows above the content, which every jump target has to be offset by.
	_lead=1

	while :; do
		mb_reset
		mb_back
		_lead=1
		if [ -n "$_ctx" ] && [ "$PF_OFFLINE" != "1" ]; then
			mb_add DLALL "Download all not yet saved"
			_lead=2
		fi
		# Walking to a letter one row at a time is miserable on a d-pad once a
		# library runs to hundreds of titles.
		if [ "$_n" -gt 40 ]; then
			mb_add JUMP "-- Jump to letter --"
			_lead=$((_lead + 1))
		fi
		mb_block "$_rows"
		_sel=$(printf '%s' "$MB" | pf_menu "$_ttl" "A select | R1 back | L/R jump letter")
		_at=$(pf_menu_at)

		case "$_sel" in
		JUMP)
			_letter=$(pick_letter "$_rows")
			[ -z "$_letter" ] && { PF_MENU_INDEX=1; continue; }
			_hit=$(printf '%s\n' "$_rows" | awk -F"$TABC" -v L="$_letter" -v lead="$_lead" '
				$3 == L { print NR + lead - 1; exit }')
			if [ -n "$_hit" ]; then PF_MENU_INDEX=$_hit
			else PF_MENU_INDEX=1; fi
			continue ;;
		DLALL)
			queue_many "$_ttl" "$_ctx"
			# Re-read cache state so the new "." markers appear immediately,
			# and come back to the row that started it.
			_rows=$(printf '%s\n' "$_data" | items_to_menu)
			PF_MENU_INDEX=$_at
			continue ;;
		esac
		break
	done

	# Remember where we were before pushing whatever was chosen, so backing out
	# of it lands here again.
	nav_mark "$_at"

	# Carry the chosen row's own title forward so the header reads as a
	# breadcrumb (show -> season) instead of repeating the library name.
	_selkey=${_sel#*:}
	_subttl=$(printf '%s\n' "$_data" |
		awk -F"$TABC" -v k="$_selkey" '$1==k {print $3; exit}')
	[ -z "$_subttl" ] && _subttl="$_ttl"

	case "$_sel" in
	show:*) nav_push show "$_selkey" "$_subttl" ;;
	season:*) nav_push season "$_selkey" "$_ttl - $_subttl" ;;
	movie:* | episode:*) nav_push item "$_selkey" "$_subttl" ;;
	*) nav_pop ;;
	esac
}

# ---------------------------------------------------------------------------
# Bulk queueing
# ---------------------------------------------------------------------------
# "Cache a whole show" is the reason to own this feature at all, so it is one
# button and it is confirmed with a real count and a real size before anything
# starts -- filling a card by accident is not a recoverable mistake on a device
# with no file manager.
queue_many() {
	_qttl="$1"; _qkey="$2"
	pf_status "Working out what is missing..."

	# allLeaves gets every episode of a show in one request; for a season the
	# children are already the episodes.
	_eps=$(plex_show_episodes "$SRV_URI" "$SRV_TOK" "$_qkey")
	[ -z "$_eps" ] && _eps=$(plex_children "$SRV_URI" "$SRV_TOK" "$_qkey")
	if [ -z "$_eps" ]; then
		pf_msg "Nothing here can be downloaded."
		return 0
	fi

	# Only leaf items are downloadable: a season row has no file behind it.
	#
	# What comes out is not a PF_ROW: it is the five things queueing actually
	# needs, joined by US (0x1f) -- key, title, runtime, sort title, show, and
	# the path this will be filed under in Downloads.
	#
	# The separator is the point. `read` collapses runs of IFS *whitespace*, and
	# tab is whitespace, so a row with an empty field in the middle (every film
	# has no season, most episodes have no library name) silently shifts every
	# field after it by one. A twelve-field PF_ROW survived that only because
	# everything this loop read happened to sit before the first empty column.
	# US is not whitespace, so an empty field stays an empty field.
	#
	# The path is worked out here, inside the awk pass that is already reading
	# every episode, rather than per item in the shell: "download the whole
	# series" is 291 episodes on Dragon Ball Z, and a path built with command
	# substitution would be several processes each. The season comes from the
	# episode itself rather than from the screen this was started on, which is
	# what makes a whole-show download land in one folder per season instead of
	# 291 items in a single heap.
	_navlib=$(nav_title_of library)
	_todo="$PF_RUN/queue.$$"
	printf '%s\n' "$_eps" |
		awk -F"$TABC" -v cache="$PF_CACHE_IDX" -v sep="$PSEP" \
			-v navlib="$_navlib" -v navshow="$(nav_title_of show)" '
		function join(a, b,   r) {
		  if (b == "") return a;
		  if (a == "") return b;
		  return a sep b;
		}
		BEGIN {
		  if (cache != "") {
		    while ((getline line < cache) > 0) { split(line, a, "\t"); dl[a[1]] = 1 }
		    close(cache);
		  }
		}
		($2 == "episode" || $2 == "movie") && !($1 in dl) {
		  lib  = ($13 != "") ? $13 : navlib;
		  show = ($14 != "") ? $14 : navshow;
		  seas = $15;
		  if (seas == "" && $9 != "") seas = sprintf("Season %d", $9);
		  path = join("", lib);
		  code = "";
		  if ($2 == "episode" && $8 != "")
		    code = ($9 != "") ? sprintf("S%02dE%02d", $9, $8) : sprintf("E%02d", $8);
		  if ($2 == "episode") { path = join(path, show); path = join(path, seas) }
		  printf "%s%s%s%s%s%s%s%s%s%s%s%s%s\n",
		    $1, sep, $3, sep, $6, sep, $7, sep, show, sep, path, sep, code;
		}' >"$_todo"

	_cnt=$(wc -l <"$_todo" | tr -d ' ')
	if [ "$_cnt" -eq 0 ]; then
		rm -f "$_todo"
		# Distinguish the two ways of getting here. If the list held no leaf
		# items at all, allLeaves gave us nothing and we are looking at season
		# rows, which have no file behind them -- telling the user everything
		# is already saved would simply be untrue.
		_leaves=$(printf '%s\n' "$_eps" |
			awk -F"$TABC" '$2=="episode" || $2=="movie" {n++} END {print n + 0}')
		if [ "$_leaves" -eq 0 ]; then
			pf_msg "Nothing here can be downloaded${NLC}directly. Open a season and${NLC}download from there."
		else
			pf_msg "Everything here is already saved${NLC}or already queued."
		fi
		return 0
	fi

	_free=$(pf_cache_free_kb)

	# Subtitles are decided here, not afterwards. A download is burned in at
	# the moment it is fetched and cannot be changed later without fetching the
	# whole thing again, so the switch belongs on the screen that starts it --
	# and this is a season or a whole series, which is a long way to get it
	# wrong.
	while :; do
		_bit=$(pf_get dl_bitrate 720)
		_estkb=$(awk -F"$PSEP" -v b="$_bit" '{n += (b + 128) * int($3 / 1000) / 8} END {printf "%d", n}' "$_todo")

		mb_reset
		mb_add GO "Download $_cnt now"
		if [ "$(pf_get subtitles on)" = "on" ]; then
			mb_add SUBS "Subtitles: ON  - burned into these files"
		else
			mb_add SUBS "Subtitles: OFF"
		fi
		mb_add NO "Cancel"
		note_reset
		note_add "$_cnt items, about $(pf_human_kb "$_estkb")"
		note_add "Free space on card: $(pf_human_kb "$_free")"
		note_add ""
		note_add "Quality: $(res_label "$(pf_res_get dl_resolution 480x320)") at $_bit kbps"
		note_add "Downloads run while PocketFlex is open."
		if [ "$_estkb" -gt "$_free" ]; then
			note_add ""
			note_add "!! This will not fit on the card."
		fi
		note_use
		PF_MENU_INDEX=0
		_go=$(printf '%s' "$MB" | pf_menu "Download: $_qttl" "A select | R1 back")

		case "$_go" in
		SUBS)
			if [ "$(pf_get subtitles on)" = "on" ]; then pf_set subtitles off
			else pf_set subtitles on; fi
			continue ;;
		GO)
			if ! pf_cache_room "$_estkb"; then
				pf_msg "That would fill the card.${NLC}${NLC}$(pf_human_kb "$_free") free, about${NLC}$(pf_human_kb "$_estkb") needed.${NLC}${NLC}Download a season at a time, or${NLC}delete something under Downloads."
				break
			fi
			_added=0
			while IFS="$PSEP" read -r k ti du so sh pa cd; do
				if pf_cache_add "$k" "$ti" "$du" "$sh" "$so" "$pa" "$cd"; then
					_added=$((_added + 1))
				fi
			done <"$_todo"
			pf_msg "Queued $_added items.${NLC}${NLC}They download in the background${NLC}while PocketFlex is open. Check${NLC}progress under Downloads."
			;;
		esac
		break
	done
	rm -f "$_todo"
}

# The item screen is where all the dead space used to be: four options and
# twenty blank rows. Everything known about the item now goes in the panel
# underneath, so "Details" is no longer a place you have to go -- the synopsis,
# the runtime, the stream and whether it is saved offline are simply there.
screen_item() {
	_key="$1"
	pf_status "Loading..."

	# One jq, not eleven.
	#
	# Every field on this screen used to be its own `printf | jq`, which is
	# eleven dynamically linked binaries loaded off an SD card to draw one
	# screen -- the same self-inflicted cost the settings screen had before it
	# read its values once. This is the screen you pass through on the way to
	# every single thing you watch, so it is the worst place to pay it.
	#
	# Fields come back joined by US (0x1f), not tabs. Tab is IFS *whitespace*,
	# so `read` collapses runs of it and drops empties: one missing year in the
	# middle would silently shift every field after it by one. US is not
	# whitespace, so an empty field stays an empty field.
	#
	# And the values land via a file rather than a pipe, because a pipeline runs
	# `read` in a subshell whose variables die with it.
	_j=$(plex_item "$SRV_URI" "$SRV_TOK" "$_key")
	_mf="$PF_RUN/item.$$"
	printf '%s' "$_j" | jq -r '.MediaContainer.Metadata[0] | [
		(if .type=="episode" then ((.grandparentTitle // "") + " - " + (.title // "")) else (.title // "") end),
		((.viewOffset // 0) | tostring),
		((.duration // 0) | tostring),
		((.viewCount // 0) | tostring),
		((.year // "") | tostring),
		(.contentRating // ""),
		(.titleSort // .title // ""),
		((.Media[0].videoResolution // "?") + " " + (.Media[0].videoCodec // "?")),
		(.librarySectionTitle // ""),
		(.grandparentTitle // ""),
		(.parentTitle // ""),
		(if .type == "episode" and .index != null then
		   (if .parentIndex != null
		    then "S" + (.parentIndex | tostring | if length < 2 then "0" + . else . end)
		         + "E" + (.index | tostring | if length < 2 then "0" + . else . end)
		    else "E" + (.index | tostring | if length < 2 then "0" + . else . end) end)
		 else "" end),
		([ .Marker[]? | select(.type == "intro")
		   | select(((.startTimeOffset // 0) | tonumber) < 300000)
		   | ((.endTimeOffset // 0) | tonumber) ]
		 | map(select(. > 0)) | first // 0 | tostring),
		# The season and the show this episode sits in, so the screen can offer
		# to go to either. Both are already in this response, so the two rows
		# they add cost no extra request. Empty for a film, which is exactly
		# what keeps the rows off the screen of a film.
		((.parentRatingKey // "") | tostring),
		((.grandparentRatingKey // "") | tostring),
		((.summary // "") | split("\n") | join(" ") | split("\r") | join(" "))
	] | join("\u001f")' >"$_mf" 2>/dev/null
	IFS="$PSEP" read -r _title _off _dur _vw _year _rate _sortk _info \
		_lib _show _season _code _intro _pkey _gkey _summary <"$_mf"
	rm -f "$_mf"

	[ -z "$_off" ] && _off=0
	[ -z "$_dur" ] && _dur=0

	# Where this item lives, for the download to be filed under. Taken from the
	# item itself rather than from the navigation stack, so the same episode
	# reached from Continue Watching, from a letter browse or by walking the
	# library all end up in one folder instead of three. The library name is the
	# one thing an episode does not always carry, so the stack answers for it.
	[ -z "$_lib" ] && _lib=$(nav_title_of library)
	_path=$(path_join "" "$_lib")
	_path=$(path_join "$_path" "$_show")
	_path=$(path_join "$_path" "$_season")

	_cstate=$(pf_cache_state "$_key")
	_local=$(pf_cache_file "$_key" 2>/dev/null)

	mb_reset
	if [ "$_off" -gt 60000 ]; then
		mb_add RESUME "Resume from $(ms_to_hms "$_off")"
	fi
	mb_add PLAY "Play from start"

	# Subtitles sit on the item screen, one row under the thing they affect,
	# because that is where you remember you wanted them. Everything is
	# transcoded now, so this row is always live -- it used to disappear
	# entirely whenever the streaming mode was direct, which was the default.
	if [ "$(pf_get subtitles on)" = "on" ]; then
		mb_add SUBS "Subtitles: ON  - burned in"
	else
		mb_add SUBS "Subtitles: OFF"
	fi
	# The other half of the same decision. On an anime library, dub versus
	# original-with-subtitles is the choice people actually make, and until now
	# it could not be made from the device at all. It costs nothing to honour --
	# everything is transcoded, so the server simply builds the stream from a
	# different track.
	[ "$PF_OFFLINE" != "1" ] && mb_add AUDIO "Audio track"

	if [ "$PF_OFFLINE" != "1" ]; then
		case "$_cstate" in
		done) mb_add DELDL "Saved offline - delete" "" "d" ;;
		queued | downloading) mb_add CANCELDL "Downloading - cancel" "" "q" ;;
		failed) mb_add REDL "Download failed - try again" ;;
		*) mb_add ADDDL "Download for offline" ;;
		esac
	fi

	if [ "${_vw:-0}" -gt 0 ]; then
		mb_add UNWATCH "Mark as unwatched"
	else
		mb_add WATCHED "Mark as watched"
	fi

	# Getting out of an episode and into the rest of the show.
	#
	# An episode reached from the home screen has no season or show behind it on
	# the navigation stack -- you came from a row of recommendations, so backing
	# out returns to the home screen, not to the season. Landing on episode 11
	# because it was newly released and wanting episode 12, or the season list,
	# meant walking back to the library and down through the show by hand.
	#
	# These push the same frames browsing would have pushed, so everything below
	# them behaves identically however you arrived. Both need the server, and
	# neither exists for a film.
	if [ "$PF_OFFLINE" != "1" ]; then
		[ -n "$_pkey" ] && mb_add GOSEASON "Go to season"
		[ -n "$_gkey" ] && mb_add GOSHOW "Go to show"
	fi
	mb_back

	# --- detail panel ---
	note_reset
	note_add "-------------------------------------------------"
	_meta=""
	[ -n "$_year" ] && _meta="$_year"
	[ "$_dur" -gt 0 ] && _meta="$_meta  $((_dur / 60000)) min"
	[ -n "$_info" ] && _meta="$_meta  $_info"
	[ -n "$_rate" ] && _meta="$_meta  $_rate"
	note_add "$_meta"
	if [ "$_off" -gt 60000 ] && [ "$_dur" -gt 0 ]; then
		note_add "$(pf_bar $((_off * 100 / _dur)) 20)  $(ms_to_hms "$_off") of $(ms_to_hms "$_dur")"
	elif [ "${_vw:-0}" -gt 0 ]; then
		note_add "Watched"
	fi
	case "$_cstate" in
	done) note_add "Saved on this device - plays without Wi-Fi" ;;
	downloading) note_add "Downloading now" ;;
	queued) note_add "Waiting to download" ;;
	esac
	if [ -n "$_summary" ]; then
		note_add ""
		term_size
		printf '%s\n' "$_summary" | fold -s -w $((COLUMNS - 4)) | head -8 >>"$PF_NOTE"
	fi
	note_use

	_hdr="$_title"
	[ "$_dur" -gt 0 ] && _hdr="$_title  [$(ms_to_hms "$_dur")]"

	PF_MENU_INDEX=0
	_sel=$(printf '%s' "$MB" | pf_menu "$_hdr" "A select | R1 back")

	case "$_sel" in
	RESUME) confirm_play "$_title" "$_off" "$_local" && request_play "$_key" "$_title" "$_off" "$_dur" "$_local" ;;
	PLAY)
		# Starting "from the start" means past the intro when the server has
		# marked one and the setting is on. There is no way to draw a Skip
		# Intro button over ffplay -- it owns the panel for the whole time it
		# runs -- so the only place this decision can be made is before the
		# stream begins, and the card below says plainly that it was made.
		_start=0
		[ "${_intro:-0}" -gt 0 ] && [ "$(pf_get skip_intro on)" = "on" ] &&
			_start=$_intro
		confirm_play "$_title" "$_start" "$_local" "$_start" &&
			request_play "$_key" "$_title" "$_start" "$_dur" "$_local" ;;
	SUBS) screen_subtitles "$_key" ;;
	AUDIO) screen_audio "$_key" ;;
	# The item frame is replaced rather than stacked on: backing out of the
	# season you just jumped to should go where the season came from, not to
	# the episode screen that sent you there and would send you here again.
	GOSEASON)
		nav_pop
		nav_push season "$_pkey" "$_show - $_season"
		return 0 ;;
	GOSHOW)
		nav_pop
		nav_push show "$_gkey" "$_show"
		return 0 ;;
	ADDDL | REDL)
		# A card with no room left is not a recoverable state on a device with
		# no file manager, so the floor is checked before anything is queued.
		if ! pf_cache_room $(( ($(pf_get dl_bitrate 720) + 128) * (_dur / 1000) / 8 )); then
			pf_msg "Not enough room on the card.${NLC}${NLC}$(pf_human_kb "$(pf_cache_free_kb)") free.${NLC}Delete something under Downloads${NLC}first."
			return 0
		fi
		[ "$_cstate" = "failed" ] && pf_cache_remove "$_key"
		if pf_cache_add "$_key" "$_title" "$_dur" "$_show" "$_sortk" "$_path" "$_code"; then
			# Say which way the subtitle switch was set, because this is the
			# last moment it can matter: it is burned into the file as it
			# downloads and changing it afterwards does nothing to the copy on
			# the card.
			pf_msg "Queued for download,${NLC}with subtitles $(pf_get subtitles on).${NLC}${NLC}It downloads in the background${NLC}while PocketFlex is open."
		else
			pf_msg "Already queued."
		fi
		;;
	CANCELDL)
		pf_cache_remove "$_key"
		pf_msg "Download cancelled."
		;;
	DELDL)
		pf_cache_remove "$_key"
		pf_msg "Deleted from this device.${NLC}It can still be streamed."
		;;
	WATCHED)
		srv_get "$SRV_URI" "$SRV_TOK" "/:/scrobble?key=$_key&identifier=com.plexapp.plugins.library" >/dev/null
		pf_msg "Marked as watched."
		;;
	UNWATCH)
		srv_get "$SRV_URI" "$SRV_TOK" "/:/unscrobble?key=$_key&identifier=com.plexapp.plugins.library" >/dev/null
		pf_msg "Marked as unwatched."
		;;
	*) nav_pop ;;
	esac
}

# ---------------------------------------------------------------------------
# Subtitles
# ---------------------------------------------------------------------------
# The server burns them into the picture: the device's ffplay is an ffmpeg 2.8
# build with no libass and cannot draw a subtitle track itself. That used to
# make this a transcode-only feature that vanished whenever the streaming mode
# was direct -- which was the default. Everything is transcoded now, so the
# switch is simply always there.
#
# Picking a specific track writes the choice back to the server, which is what
# Plex clients do -- so the same track is then selected everywhere.
screen_subtitles() {
	pf_status "Reading subtitle tracks..."
	_streams=$(plex_subtitle_streams "$SRV_URI" "$SRV_TOK" "$1")

	mb_reset
	if [ "$(pf_get subtitles on)" = "on" ]; then
		mb_add SOFF "Turn subtitles off"
	else
		mb_add SON "Turn subtitles on"
	fi
	if [ -n "$_streams" ]; then
		mb_sep
		mb_block "$(printf '%s\n' "$_streams" |
			awk -F"$TABC" '{ mark = ($3=="1") ? "  (selected)" : "";
			                 printf "S:%s\t%s%s\n", $1, $2, mark }')"
	fi
	mb_back

	note_reset
	note_add "-------------------------------------------------"
	if [ -n "$_streams" ]; then
		note_add "Subtitles are burned into the picture by"
		note_add "the server. Choosing a track here selects"
		note_add "it on your Plex account too."
	else
		note_add "This item has no subtitle tracks."
	fi
	note_use

	PF_MENU_INDEX=0
	_s=$(printf '%s' "$MB" | pf_menu "Subtitles" "A select | R1 back")
	case "$_s" in
	SOFF) pf_set subtitles off ;;
	SON) pf_set subtitles on ;;
	S:*)
		_sid=${_s#S:}
		pf_status "Selecting track..."
		_part=$(plex_part_id "$SRV_URI" "$SRV_TOK" "$1")
		if [ -n "$_part" ]; then
			plex_set_subtitle "$SRV_URI" "$SRV_TOK" "$_part" "$_sid"
			pf_set subtitles on
			pf_msg "Subtitle track selected."
		else
			pf_msg "Could not change the track."
		fi
		;;
	esac
}

# ---------------------------------------------------------------------------
# Audio tracks
# ---------------------------------------------------------------------------
# Same shape as the subtitle screen and the same server-side write, because it
# is the same kind of decision: a dub or the original. It is transcode-only in
# the sense that everything here is transcoded, so the server builds the stream
# from whichever track is selected and the device never sees the difference.
#
# A downloaded copy had its audio decided when it was fetched, exactly like its
# subtitles, so this says so rather than pretending to change it.
screen_audio() {
	pf_status "Reading audio tracks..."
	_streams=$(plex_audio_streams "$SRV_URI" "$SRV_TOK" "$1")

	mb_reset
	if [ -n "$_streams" ]; then
		mb_block "$(printf '%s\n' "$_streams" |
			awk -F"$TABC" '{ mark = ($3=="1") ? "  (selected)" : "";
			                 printf "A:%s\t%s%s\n", $1, $2, mark }')"
	fi
	mb_back

	note_reset
	note_add "-------------------------------------------------"
	if [ -n "$_streams" ]; then
		note_add "The server builds the stream from the"
		note_add "track chosen here, and the choice is"
		note_add "saved to your Plex account."
		note_add ""
		note_add "A copy already downloaded keeps the"
		note_add "audio it was fetched with."
	else
		note_add "This item has only one audio track."
	fi
	note_use

	PF_MENU_INDEX=0
	_s=$(printf '%s' "$MB" | pf_menu "Audio track" "A select | R1 back")
	case "$_s" in
	A:*)
		_aid=${_s#A:}
		pf_status "Selecting track..."
		_part=$(plex_part_id "$SRV_URI" "$SRV_TOK" "$1")
		if [ -n "$_part" ]; then
			plex_set_audio "$SRV_URI" "$SRV_TOK" "$_part" "$_aid"
			pf_msg "Audio track selected."
		else
			pf_msg "Could not change the track."
		fi
		;;
	esac
}

# Hand off to launch.sh, which owns the framebuffer once we exit.
# $5, when set, is a downloaded copy on the card; launch.sh prefers it over the
# network and never touches the server to play it.
request_play() {
	{
		printf 'PF_KEY=%s\n' "$1"
		printf "PF_TITLE='%s'\n" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
		printf 'PF_OFFSET_MS=%s\n' "${3:-0}"
		printf 'PF_DURATION_MS=%s\n' "${4:-0}"
		printf "PF_LOCAL='%s'\n" "$(printf '%s' "$5" | sed "s/'/'\\\\''/g")"
		printf "PF_URI='%s'\n" "$SRV_URI"
		printf "PF_STOK='%s'\n" "$SRV_TOK"
		printf 'PF_OFFLINE=%s\n' "$PF_OFFLINE"
	} >"$PF_REQ"
	exit 0
}

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------
# Everything on the card: what is saved, what is still coming down, how much
# room is left, and how to get rid of any of it. This is the screen that has to
# work with the Wi-Fi off, so it never calls the server.
#
# It is browsed the way the library it came from is browsed -- Anime > Dragon
# Ball Z > Season 3 > S03E05 -- because a flat list is fine for six episodes and
# unusable for sixty, and sixty is what a 128 GB card fills up with. Nothing
# here asks Plex anything: the folder names were recorded in the index when each
# item was queued.
#
# dl_rows <path> <nowKey> <partKB> [mode]  -- index rows on stdin, menu rows out
#
# mode "level" (the default) lists one level of the tree: the folders directly
# under <path>, then the items sitting in it. mode "active" ignores <path> and
# lists everything not yet finished, which is what the top of the root screen
# shows -- otherwise the one thing you opened this screen to look at could be
# three folders down.
#
# Folders carry their own totals, so "12/24" on a season means twelve of its
# episodes are on the card and the rest are still coming, and a size means the
# whole folder is here. It is the same right-hand column the library lists use,
# which is deliberate: one column, one meaning, everywhere.
dl_rows() {
	awk -F"$TABC" -v cur="$1" -v now="$2" -v pkb="$3" -v mode="${4:-level}" \
		-v sep="$PSEP" '
	function human(k) {
	  if (k >= 1048576) return sprintf("%d.%d GB", k/1048576, (k%1048576)*10/1048576);
	  if (k >= 1024)    return sprintf("%d MB", k/1024);
	  return sprintf("%d KB", k);
	}
	# An item row, in the shape pf_menu wants, with a sort key in front.
	function item(key, st, ti, sz, est,   flags, right, ord) {
	  flags=""; right="";
	  if (st == "done")            { flags="d"; right=human(sz) }
	  else if (key == now)         { flags="q"; right=(est>0) ? sprintf("%d%%", pkb*100/est) : human(pkb) }
	  else if (st == "downloading"){ flags="q"; right="held" }
	  else if (st == "queued")     { flags="q"; right="queued" }
	  else                         { flags="";  right="failed" }
	  # Two different orders, because the two lists answer different questions.
	  # The flat in-progress list is sorted by state, so whatever is downloading
	  # right now is at the top with its percentage. Inside a folder the order
	  # that matters is the episode order, which the code in front of the title
	  # already gives -- putting the two episodes still coming down above the
	  # ones already saved would shuffle a season out of sequence.
	  ord = (key == now) ? 0 : (st == "queued" ? 1 : (st == "done" ? 2 : 3));
	  return sprintf("1%s%s\tI:%s\t%s\t\t%s\t%s",
	                 (mode == "active") ? ord "" : "", ti, key, ti, right, flags);
	}
	{
	  key=$1; st=$2; ti=$3; sz=$5+0; est=$10+0; path=$11; code=$12; show=$8;

	  # Only what is filed away somewhere: an unfinished item with no folder is
	  # already sitting on the root screen and does not need listing twice.
	  # Its title keeps the show name, because up here there is no folder above
	  # it to say which show it belongs to.
	  if (mode == "active") {
	    if (st != "done" && path != "") print item(key, st, ti, sz, est);
	    next;
	  }

	  # Inside a folder the show name is the folder, so repeating it in every
	  # row costs a third of the width and says nothing. What replaces it is the
	  # episode code -- which also sorts, so a season reads down in episode
	  # order instead of alphabetically by episode title.
	  if (cur != "") {
	    if (show != "" && index(ti, show " - ") == 1)
	      ti = substr(ti, length(show) + 4);
	    if (code != "") ti = code "  " ti;
	  }

	  # Rows written before v0.3.0 have no path at all and land at the top
	  # level, which is where they already were.
	  if (cur == "")                                          rest = path;
	  else if (path == cur)                                   rest = "";
	  else if (substr(path, 1, length(cur) + 1) == cur sep)   rest = substr(path, length(cur) + 2);
	  else next;

	  if (rest != "") {
	    i = index(rest, sep);
	    seg = (i > 0) ? substr(rest, 1, i - 1) : rest;
	    n[seg]++;
	    if (st == "done") { ndone[seg]++; bytes[seg] += sz } else pend[seg]++;
	    next;
	  }
	  print item(key, st, ti, sz, est);
	}
	END {
	  # Folders sort ahead of loose items: the tree first, then whatever is
	  # sitting at this level on its own.
	  for (s in n) {
	    if (pend[s] > 0)    { f = "q"; r = sprintf("%d/%d", ndone[s] + 0, n[s]) }
	    else                { f = "d"; r = human(bytes[s] + 0) }
	    printf "0%s\tF:%s\t%s/\t\t%s\t%s\n", s, s, s, r, f;
	  }
	}'
}

# screen_downloads [path] [callersCursor] -- one level of the download tree.
#
# The cursor is handed down and handed back. Descending into a folder opens it
# at the top, and coming back out puts the cursor on the folder you just left
# rather than at the top of a list you have to walk down again -- which on a
# card with forty seasons on it is the difference between a tree and a chore.
#
# It travels as a *positional parameter* because sh has no local variables: this
# function calls itself, and a plain variable holding the caller's cursor would
# be overwritten by the callee the moment it drew its own menu. Positional
# parameters belong to the invocation, so they survive the recursion.
screen_downloads() {
	_cur="$1"
	while :; do
		pf_cache_init
		_rows=$(pf_cache_rows)
		_now=""
		[ -s "$PF_RUN/dl.now" ] && _now=$(cat "$PF_RUN/dl.now")
		_partkb=0
		[ -n "$_now" ] && _partkb=$(pf_cache_partial_kb "$_now")

		mb_reset
		mb_back
		if [ -z "$_rows" ]; then
			note_reset
			note_add "-------------------------------------------------"
			note_add "Nothing saved yet."
			note_add ""
			note_add "Open any film or episode and choose"
			note_add "\"Download for offline\", or use"
			note_add "\"Download all not yet saved\" on a show"
			note_add "to take a whole series with you."
			note_add ""
			note_add "Saved titles play with the Wi-Fi off."
			note_use
			PF_MENU_INDEX=0
			printf '%s' "$MB" | pf_menu "Downloads" "A select | R1 back" >/dev/null
			return 0
		fi

		# On the top level, anything still coming down is listed flat above the
		# folders as well as inside them. Progress is the reason this screen gets
		# opened while a download is running, and having to remember which season
		# it was under to watch it tick would be a poor answer to that.
		if [ -z "$_cur" ]; then
			_act=$(printf '%s\n' "$_rows" | dl_rows "" "$_now" "$_partkb" active |
				sort -f | cut -f2-)
			if [ -n "$_act" ]; then
				mb_block "$_act"
				mb_sep
			fi
		fi

		_lvl=$(printf '%s\n' "$_rows" | dl_rows "$_cur" "$_now" "$_partkb" |
			sort -f | cut -f2-)
		# A folder emptied by the delete that just happened has nothing left to
		# draw, and a screen with only a Back row on it is a dead end.
		if [ -z "$_lvl" ] && [ -n "$_cur" ]; then
			PF_MENU_INDEX="${2:-0}"
			return 0
		fi
		mb_block "$_lvl"

		mb_sep
		if [ -n "$_cur" ]; then
			mb_add DELHERE "Delete everything in here"
		else
			mb_add PURGE "Delete everything watched"
			mb_add WIPE "Delete all downloads"
		fi

		_free=$(pf_cache_free_kb)
		note_reset
		note_add "-------------------------------------------------"
		if [ -n "$_cur" ]; then
			# Folder totals, counted over everything below this point rather
			# than only what is directly in it -- a show says what the whole
			# show costs, not what its loose episodes cost.
			note_add "$(printf '%s\n' "$_rows" | awk -F"$TABC" -v cur="$_cur" -v sep="$PSEP" '
				$11 == cur || substr($11, 1, length(cur) + 1) == cur sep {
				  n++; if ($2 == "done") { d++; kb += $5 }
				}
				END {
				  if (kb >= 1048576) s = sprintf("%d.%d GB", kb/1048576, (kb%1048576)*10/1048576);
				  else if (kb >= 1024) s = sprintf("%d MB", kb/1024);
				  else s = sprintf("%d KB", kb + 0);
				  printf "%d of %d saved here, %s", d + 0, n + 0, s;
				}')"
		else
			note_add "$(pf_cache_count done) saved, $(pf_human_kb "$(pf_cache_size_kb)") used"
		fi
		note_add "$(pf_human_kb "$_free") free on the card"
		_nq=$(pf_cache_count queued)
		if [ "$_nq" -gt 0 ] || [ -n "$_now" ]; then
			note_add "$_nq waiting - these download while"
			note_add "PocketFlex is open."
		fi
		note_use

		_ttl="Downloads"
		[ -n "$_cur" ] && _ttl="$(path_pretty "$_cur")"
		_sel=$(printf '%s' "$MB" | pf_menu "$_ttl" "A select | R1 back")
		_at=$(pf_menu_at)
		case "$_sel" in
		I:*) screen_download_item "${_sel#I:}"; PF_MENU_INDEX=$_at ;;
		F:*)
			# Recursion, one level per screen. The tree is three deep at most --
			# library, show, season -- so this is nowhere near a shell's limits.
			PF_MENU_INDEX=0
			screen_downloads "$(path_join "$_cur" "${_sel#F:}")" "$_at"
			# Every variable in here was just used by the call that returned;
			# sh has no scoping. The loop rebuilds all of them from scratch
			# except this one, which says which folder we are looking at.
			_cur="$1" ;;
		PURGE) purge_watched; PF_MENU_INDEX=$_at ;;
		DELHERE) delete_under "$_cur"; PF_MENU_INDEX=$_at ;;
		WIPE) delete_under ""; PF_MENU_INDEX=$_at ;;
		*) PF_MENU_INDEX="${2:-0}"; return 0 ;;
		esac
	done
}

# Delete every download at or below a path. An empty path is the whole card,
# which is the "Delete all downloads" row -- one code path, so the confirmation
# and the count cannot drift apart between the two.
delete_under() {
	_dk="$PF_RUN/del.$$"
	pf_cache_keys_under "$1" >"$_dk"
	_dn=$(wc -l <"$_dk" | tr -d ' ')
	if [ "$_dn" -eq 0 ]; then
		rm -f "$_dk"
		pf_msg "Nothing here to delete."
		return 0
	fi
	_dkb=$(pf_cache_rows | awk -F"$TABC" -v cur="$1" -v sep="$PSEP" '
		cur == "" || $11 == cur || substr($11, 1, length(cur) + 1) == cur sep {
		  if ($2 == "done") kb += $5
		} END {printf "%d", kb + 0}')

	mb_reset
	mb_add NO "Keep them"
	mb_add YES "Delete $_dn downloads"
	note_reset
	note_add "-------------------------------------------------"
	note_add "This frees about $(pf_human_kb "$_dkb")."
	[ -n "$1" ] && note_add "$(path_pretty "$1")"
	note_use
	PF_MENU_INDEX=0
	if [ "$(printf '%s' "$MB" | pf_menu "Delete $_dn?" "A select | R1 back")" = "YES" ]; then
		while read -r k; do pf_cache_remove "$k"; done <"$_dk"
		pf_msg "Freed $(pf_human_kb "$_dkb")."
	fi
	rm -f "$_dk"
	unset _dk _dn _dkb
}

# A downloaded item, reachable with no network at all -- so the title and
# runtime come from the cache index rather than from the server.
screen_download_item() {
	_k="$1"
	_row=$(pf_cache_row "$_k")
	[ -z "$_row" ] && return 0
	_st=$(printf '%s' "$_row" | cut -f2)
	_ti=$(printf '%s' "$_row" | cut -f3)
	_du=$(printf '%s' "$_row" | cut -f4)
	_sz=$(printf '%s' "$_row" | cut -f5)
	_pa=$(printf '%s' "$_row" | cut -f11)
	_file=$(pf_cache_file "$_k" 2>/dev/null)

	mb_reset
	[ -n "$_file" ] && mb_add PLAY "Play"
	case "$_st" in
	queued | downloading) mb_add STOP "Cancel this download" ;;
	failed) mb_add AGAIN "Try again" ;;
	esac
	[ -n "$_file" ] && mb_add DEL "Delete from device"
	mb_back

	note_reset
	note_add "-------------------------------------------------"
	case "$_st" in
	done) note_add "$(pf_human_kb "$_sz") on this device" ;;
	failed) note_add "The download did not finish." ;;
	*) note_add "Waiting for the download to finish." ;;
	esac
	[ "$_du" -gt 0 ] 2>/dev/null && note_add "Runtime $(ms_to_hms "$_du")"
	# Reached flat from the in-progress list at the top of the root screen,
	# this is the only thing that says which show it belongs to.
	[ -n "$_pa" ] && note_add "In $(path_pretty "$_pa")"
	note_use

	PF_MENU_INDEX=0
	case "$(printf '%s' "$MB" | pf_menu "$_ti" "A select | R1 back")" in
	PLAY) confirm_play "$_ti" 0 "$_file" && request_play "$_k" "$_ti" 0 "$_du" "$_file" ;;
	DEL) pf_cache_remove "$_k"; pf_msg "Deleted." ;;
	STOP) pf_cache_remove "$_k"; pf_msg "Cancelled." ;;
	AGAIN) pf_cache_set "$_k" queued; pf_msg "Queued again." ;;
	esac
}

# The natural way a cache stays a useful size: bin what you have already seen.
# Watch state is read from the server, so this needs a connection -- offline it
# says so instead of silently doing nothing.
purge_watched() {
	if [ "$PF_OFFLINE" = "1" ]; then
		pf_msg "This needs a connection to your${NLC}Plex server to know what you${NLC}have watched."
		return 0
	fi
	pf_status "Checking what you have watched..."
	_hits="$PF_RUN/purge.$$"
	: >"$_hits"
	pf_cache_rows done | cut -f1,3 | while IFS="$TABC" read -r k ti; do
		_v=$(plex_item "$SRV_URI" "$SRV_TOK" "$k" |
			jq -r '.MediaContainer.Metadata[0].viewCount // 0' 2>/dev/null)
		[ "${_v:-0}" -gt 0 ] && printf '%s\t%s\n' "$k" "$ti" >>"$_hits"
	done
	_n=$(wc -l <"$_hits" | tr -d ' ')
	if [ "$_n" -eq 0 ]; then
		rm -f "$_hits"
		pf_msg "Nothing saved has been watched yet."
		return 0
	fi
	_kb=$(cut -f1 "$_hits" | while read -r k; do pf_cache_row "$k" | cut -f5; done |
		awk '{n += $1} END {printf "%d", n + 0}')

	mb_reset
	mb_add NO "Keep them"
	mb_add YES "Delete $_n watched items"
	note_reset
	note_add "-------------------------------------------------"
	note_add "This frees about $(pf_human_kb "$_kb")."
	head -8 "$_hits" | cut -f2 >>"$PF_NOTE"
	note_use
	PF_MENU_INDEX=0
	if [ "$(printf '%s' "$MB" | pf_menu "Delete watched?" "A select | R1 back")" = "YES" ]; then
		cut -f1 "$_hits" | while read -r k; do pf_cache_remove "$k"; done
		pf_msg "Freed $(pf_human_kb "$_kb")."
	fi
	rm -f "$_hits"
}

# ---------------------------------------------------------------------------
# Browse by letter -- an on-screen keyboard would be miserable on a d-pad.
# ---------------------------------------------------------------------------
# This was broken, and worth saying how, because it looked like it worked. It
# ran `/search?query=A`: Plex's search matches a substring anywhere in a title
# and ranks by relevance, so picking S returned every *episode* whose name
# contains an s, in no order anyone could explain, and the shows you were
# actually after were somewhere in the middle of it.
#
# What it does now is ask each library for the titles filed under that letter,
# which is a different question with a different answer: shows and films only,
# sorted, and filed by titleSort so "The Angel Next Door" is under A exactly as
# the library list has it. Episodes cannot appear because episodes are not
# top-level titles in a library.
#
# The letter index is built once per session and kept in /tmp. It is one small
# request per library and it is what puts real counts on the menu -- nobody
# should walk to Q to find it empty.
PF_LETTERS="$PF_RUN/letters.idx"

# character <tab> count <tab> sectionKey <tab> keyToFetch
letter_index() {
	[ -s "$PF_LETTERS" ] && { cat "$PF_LETTERS"; return 0; }
	pf_status "Reading libraries..."
	_secs=$(plex_sections "$SRV_URI" "$SRV_TOK" |
		awk -F"$TABC" -v hid=",$(pf_get libs_hidden '')," '
			($3=="movie" || $3=="show") && !index(hid, "," $1 ",")')
	[ -z "$_secs" ] && return 0
	printf '%s\n' "$_secs" > "$PF_RUN/lsec"
	: >"$PF_LETTERS.tmp"
	while IFS="$TABC" read -r _sk _snm _sty; do
		plex_first_characters "$SRV_URI" "$SRV_TOK" "$_sk" |
			awk -F"$TABC" -v s="$_sk" '$1 != "" {print $1 "\t" $2 "\t" s "\t" $3}' \
				>>"$PF_LETTERS.tmp"
	done <"$PF_RUN/lsec"
	rm -f "$PF_RUN/lsec"
	[ -s "$PF_LETTERS.tmp" ] && mv "$PF_LETTERS.tmp" "$PF_LETTERS" ||
		rm -f "$PF_LETTERS.tmp"
	[ -s "$PF_LETTERS" ] && cat "$PF_LETTERS"
	return 0
}

# Every title in the library that starts with one character, across all
# libraries, sorted by the same titleSort the library lists are sorted by.
#
# The server's letter index is used when it answers, and the whole section is
# fetched and filtered here when it does not -- a server too old to have
# /firstCharacter, or one that hands back a key we cannot follow, still gets a
# correct list rather than an empty screen.
letter_items() {
	_L="$1"
	_out="$PF_RUN/letter.$$"
	: >"$_out"

	if [ -s "$PF_LETTERS" ]; then
		awk -F"$TABC" -v L="$_L" '$1==L {print $3 "\t" $4}' "$PF_LETTERS" \
			>"$PF_RUN/lhit"
		while IFS="$TABC" read -r _sk _fk; do
			plex_section_letter "$SRV_URI" "$SRV_TOK" "$_sk" "$_fk" >>"$_out"
		done <"$PF_RUN/lhit"
		rm -f "$PF_RUN/lhit"
	fi

	if [ ! -s "$_out" ]; then
		log "letter browse: falling back to a local filter for $_L"
		plex_sections "$SRV_URI" "$SRV_TOK" |
			awk -F"$TABC" -v hid=",$(pf_get libs_hidden '')," '
				($3=="movie" || $3=="show") && !index(hid, "," $1 ",") {print $1}' \
			>"$PF_RUN/lsec2"
		while read -r _sk; do
			plex_section_items "$SRV_URI" "$SRV_TOK" "$_sk" |
				awk -F"$TABC" -v L="$_L" '
				{ s = ($7 != "") ? $7 : $3;
				  c = toupper(substr(s, 1, 1));
				  if (c !~ /[A-Z]/) c = "#";
				  if (c == L) print }' >>"$_out"
		done <"$PF_RUN/lsec2"
		rm -f "$PF_RUN/lsec2"
	fi

	# One list out of several libraries has to be re-sorted, or it reads as
	# three alphabetical runs stacked on each other.
	sort -f -t"$TABC" -k7,7 "$_out"
	rm -f "$_out"
	unset _L _out
}

screen_search() {
	_idx=$(letter_index)

	mb_reset
	mb_back
	if [ -n "$_idx" ]; then
		mb_block "$(printf '%s\n' "$_idx" | awk -F"$TABC" '
			{n[$1] += $2}
			END {for (c in n) printf "%s\t%s   (%d)\n", c, c, n[c]}' | sort)"
	else
		# No letter index from the server: offer the alphabet and let the
		# local filter answer for it.
		for _l in '#' A B C D E F G H I J K L M N O P Q R S T U V W X Y Z; do
			mb_add "$_l" "$_l"
		done
	fi

	note_reset
	note_add "-------------------------------------------------"
	note_add "Shows and films whose title starts with"
	note_add "the letter, from every library."
	note_use

	_sel=$(printf '%s' "$MB" | pf_menu "Browse by letter" "A select | R1 back")
	case "$_sel" in
	BACK | "") nav_pop; return 0 ;;
	esac
	nav_push letter "$_sel" "Starting with $_sel"
}

# ---------------------------------------------------------------------------
# Controls reference
# ---------------------------------------------------------------------------
# The player is OnionOS's stock ffplay, which we cannot draw an overlay onto --
# it owns the framebuffer for the whole time it runs. The next best thing is to
# state the bindings immediately before handing the screen over, so nobody has
# to discover them by pressing things during a film.
#
# Player bindings are ffplay's documented keys resolved through the Miyoo key
# map (A=SPACE, MENU=ESC, d-pad=arrows). START and SELECT emit ENTER and TAB,
# which ffplay does not bind to anything -- so they are listed as doing nothing
# rather than left for the user to wonder about.
controls_player_text() {
	cat <<EOF
DURING PLAYBACK
  A               pause / resume
  D-pad L / R     seek 10 seconds
  D-pad U / D     seek 1 minute
  MENU            stop and go back
  START / SELECT  nothing (player ignores them)
EOF
}

controls_browse_text() {
	cat <<EOF
BROWSING
  D-pad U / D     move
  D-pad L / R     jump A-Z on long lists,
                  otherwise page up / down
  L2 / R2         same as D-pad left/right
  A / START       select
  R1 / SELECT     back
  MENU            quit PocketFlex

  On the "Ready to play" card, left and
  right switch subtitles on and off.

  Long lists show the letter you are in
  down the right edge, and carry a
  "Jump to letter" row at the top.

READING A LIST
  dim title       already watched
  9/24            episodes seen of a season
  34%             where you stopped
  + (green)       saved on this device
  . (yellow)      queued or downloading

  B, X, Y and L1 send no input to a
  terminal at all, so they cannot be used.
EOF
}

screen_controls() {
	term_size
	pf_msg "$(controls_browse_text)
$(controls_player_text)"
}

# Shown right before playback starts, unless switched off in Settings.
#
# This card is also where subtitles get switched, on left/right. It is the last
# screen before the video and the moment you actually remember you wanted them,
# and it costs no menu diving -- which is the whole difference between a
# setting that exists and one that gets used. Left/right are free here: this
# screen has no list to page through, and B/X/Y send nothing at all.
#
# $3, when non-empty, is a downloaded copy, which changes what the card can
# honestly claim: no transcode, no server, no subtitle switch (they were burned
# in when the file was made).
confirm_play() {
	_ttl="$1"; _off_ms="$2"; _lfile="$3"; _skip="$4"
	[ "$(pf_get show_controls true)" != "true" ] && return 0

	term_size
	raw_on
	printf '\033[?25l' >/dev/tty

	while :; do
		if [ -n "$_lfile" ]; then
			_how="Playing the copy saved on this device"
		else
			_how="Transcoding to $(res_label "$(pf_res_get resolution 640x480)"), max $(pf_get bitrate 2000) kbps"
		fi
		# An intro skip and a resume are both "not starting at zero", and
		# saying "Resuming from 1:42" for an episode you have never opened is
		# a lie that makes the feature look broken. They are named apart.
		_res=""
		if [ "${_skip:-0}" -gt 0 ] && [ "${_skip:-0}" = "${_off_ms:-0}" ]; then
			_res="Skipping the intro - starts at $(ms_to_hms "$_off_ms")"
		elif [ "${_off_ms:-0}" -gt 60000 ]; then
			_res="Resuming from $(ms_to_hms "$_off_ms")"
		fi

		# A handheld runs out of battery mid-film, and this is the last screen
		# before a film. 20% is roughly an hour of playback on this device.
		_warn=""
		_bat=$(pf_battery_pct)
		if [ -n "$_bat" ] && [ "$_bat" -lt 20 ]; then
			_warn="Battery $_bat% - this may not last the episode"
		fi

		# A downloaded file had its subtitles decided when it was made -- they
		# are painted into the frames on the card and no switch here can undo
		# that. Everything else is transcoded on demand, so the switch is
		# always live.
		if [ -n "$_lfile" ]; then
			_sub="Subtitles: as downloaded"
		elif [ "$(pf_get subtitles on)" = "on" ]; then
			_sub="Subtitles: ON      < left / right to change >"
		else
			_sub="Subtitles: OFF     < left / right to change >"
		fi

		{
			printf '\033[H\033[2J'
			bar "Ready to play" "A start | R1 cancel" 1
			printf '\033[3;3H%s%s%s' "$C_TITLE" "$(fit "$_ttl" $((COLUMNS - 4)))" "$C_OFF"
			printf '\033[4;3H%s%s%s' "$C_HINT" "$(fit "$_how" $((COLUMNS - 4)))" "$C_OFF"
			printf '\033[5;3H\033[K%s%s%s' "$C_ACC" "$(fit "$_sub" $((COLUMNS - 4)))" "$C_OFF"
			[ -n "$_res" ] && printf '\033[6;3H%s%s%s' "$C_DIM" "$_res" "$C_OFF"
			[ -n "$_warn" ] && printf '\033[7;3H%s%s%s' "$C_WARN" "$_warn" "$C_OFF"
			_r=9
			controls_player_text | while IFS= read -r _l; do
				printf '\033[%s;3H%s' "$_r" "$(fit "$_l" $((COLUMNS - 4)))"
				_r=$((_r + 1))
			done
			bar "A = start playing" "R1 = cancel" "$LINES"
		} >/dev/tty

		case "$(read_key)" in
		LEFT | RIGHT)
			[ -n "$_lfile" ] && continue
			if [ "$(pf_get subtitles on)" = "on" ]; then pf_set subtitles off
			else pf_set subtitles on; fi ;;
		OK) raw_off; return 0 ;;
		BACK | ESC) raw_off; return 1 ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Button test
# ---------------------------------------------------------------------------
# Which physical buttons reach a terminal is genuinely uncertain: B/X/Y/SELECT
# map to bare modifier keys that normally emit nothing, and st's own key table
# only documents its on-screen-keyboard mode. This records the raw bytes each
# press produces, so the mapping can be settled by observation rather than
# guesswork. Results are appended to data/pocketflex.log.
#
# THE EXIT HAS TO BE UNCONDITIONAL. The first version of this screen said
# "press START three times to exit" and then tested for one specific byte
# (0x0d). On the actual device that never matched, so the only way out of the
# button test was to power the handheld off -- which is a spectacular way for a
# diagnostic screen to fail, since it is reached precisely when the user is
# already unsure which buttons work.
#
# So now: every plausible confirm or back byte counts towards the exit, the
# counter is on screen so it is visibly working, and a press that produces
# nothing at all cannot strand anyone, because ESC alone is enough.
screen_keytest() {
	term_size
	raw_on
	printf '\033[?25l' >/dev/tty
	log "--- button test begin ---"
	_seen=0
	_last="(none yet)"
	_run=0
	while :; do
		{
			printf '\033[H\033[2J'
			bar "Button test" "$_seen presses" 1
			printf '\033[3;3HPress each button in turn.'
			printf '\033[4;3H%sButtons that print nothing here%s' "$C_DIM" "$C_OFF"
			printf '\033[5;3H%scannot be used by the app.%s' "$C_DIM" "$C_OFF"
			printf '\033[7;3HLast byte:  %s %s %s' "$C_SEL" "$_last" "$C_OFF"
			printf '\033[9;3H%sTo leave: press START, A, R1,%s' "$C_ACC" "$C_OFF"
			printf '\033[10;3H%sSELECT or MENU three times%s' "$C_ACC" "$C_OFF"
			printf '\033[11;3H%s   %s of 3%s' "$C_TITLE" "$_run" "$C_OFF"
			bar "Recorded to data/pocketflex.log" "" "$LINES"
		} >/dev/tty

		_raw=$(dd bs=1 count=1 2>/dev/null </dev/tty | od -An -tx1 | tr -d ' \n')
		[ -z "$_raw" ] && continue
		_seen=$((_seen + 1))
		_last="0x$_raw"
		log "keytest: 0x$_raw"

		# Any confirm-ish or back-ish byte counts towards the same run of three:
		# START (0a on this build, 0d on others), A (20), R1 (08/7f),
		# SELECT (09), MENU (1b).
		#
		# MENU is counted rather than exiting on sight, because the d-pad sends
		# ESC '[' 'A' and its first byte is also 1b -- leaving immediately on a
		# bare 1b would make the d-pad impossible to test on the screen whose
		# entire job is testing it. Three *consecutive* 1b bytes cannot come
		# from the d-pad, since '[' resets the run every time.
		case "$_raw" in
		0d | 0a | 20 | 08 | 7f | 09 | 1b)
			_run=$((_run + 1))
			[ "$_run" -ge 3 ] && break ;;
		*) _run=0 ;;
		esac
	done
	log "--- button test end ---"
	raw_off
	printf '\033[?25h' >/dev/tty
	pf_msg "Recorded $_seen presses to${NLC}data/pocketflex.log"
}

# ---------------------------------------------------------------------------
# Wi-Fi
# ---------------------------------------------------------------------------
# "Connect long enough to sync the next few episodes, then drop the radio and
# go" is the pattern this device is actually used with, and it used to mean
# quitting to Onion's menu and coming back.
#
# Turning it off is not just a radio command: the download worker has to be put
# to sleep first, or a queue of items each spends a connect timeout failing, and
# the app itself has to drop into the offline mode it already has for an
# unreachable server. Turning it back on has to wait for an address and then
# re-find the server, because "on" without a lease is a screen full of timeouts.
screen_wifi() {
	while :; do
		_st=$(pf_wifi_state)
		_ip=$(pf_wifi_ip)

		mb_reset
		if ! pf_wifi_available; then
			mb_back
			note_reset
			note_add "-------------------------------------------------"
			note_add "This build of the firmware does not expose"
			note_add "the radio where PocketFlex expects it, so"
			note_add "Wi-Fi has to be switched from Onion's own"
			note_add "menu."
			note_use
			PF_MENU_INDEX=0
			printf '%s' "$MB" | pf_menu "Wi-Fi" "R1 back" >/dev/null
			return 0
		fi

		case "$_st" in
		up | connecting) mb_add OFF "Turn Wi-Fi off" ;;
		*) mb_add ON "Turn Wi-Fi on" ;;
		esac
		mb_back

		note_reset
		note_add "-------------------------------------------------"
		case "$_st" in
		up) note_add "On, connected as $_ip" ;;
		connecting) note_add "On, but no address yet" ;;
		*) note_add "Off. Downloads and browsing are paused;" ; note_add "saved titles still play." ;;
		esac
		note_add ""
		note_add "The radio is the biggest drain on this"
		note_add "device after the screen. Sync what you"
		note_add "want, then turn it off and keep watching."
		note_add ""
		note_add "This is the same switch Onion's menu uses,"
		note_add "so it stays off after you leave the app."
		note_use

		PF_MENU_INDEX=0
		case "$(printf '%s' "$MB" | pf_menu "Wi-Fi" "A select | R1 back")" in
		OFF)
			pf_status "Stopping downloads and turning Wi-Fi off..."
			pf_wifi_off
			PF_OFFLINE=1
			home_cache_clear
			nav_reset
			pf_msg "Wi-Fi is off.${NLC}${NLC}Downloads are paused and will${NLC}carry on when it is back.${NLC}${NLC}Everything saved on the card still${NLC}plays."
			return 0 ;;
		ON)
			pf_status "Turning Wi-Fi on..."
			if pf_wifi_on wifi_wait_status; then
				pf_status "Finding your Plex server..."
				pf_set server_uri ""; pf_set server_token ""
				home_cache_clear
				if ensure_server; then
					PF_OFFLINE=0
					nav_reset
					pf_msg "Connected, and $(pf_get server_name 'your server')${NLC}is back."
					return 0
				fi
				pf_msg "Wi-Fi is on at $(pf_wifi_ip),${NLC}but the Plex server did not${NLC}answer. Try Settings - Server."
			else
				pf_msg "Wi-Fi did not come up.${NLC}${NLC}It may be out of range, or the${NLC}network may need setting up in${NLC}Onion's own menu first."
			fi
			;;
		*) return 0 ;;
		esac
	done
}

# Called once a second while waiting for a lease, because fifteen silent
# seconds on a handheld reads as a crash.
wifi_wait_status() {
	pf_status "Waiting for an address... ${1}s"
}

# ---------------------------------------------------------------------------
# Which libraries you keep, and what the home screen shows
# ---------------------------------------------------------------------------
# Every official Plex client lets you pin the libraries you use and put the rest
# away. On a server with 4K Movies, Classics, Hallmark, Movies, Anime and TV
# Shows, four of those may be somebody else's, and they were taking up two
# thirds of the rail on a 3.5" screen.
#
# Hidden is stored rather than pinned -- as a list of section keys -- so a
# library added to the server later shows up by itself instead of staying
# invisible until someone remembers to pin it.
lib_hidden() {
	case ",$(pf_get libs_hidden '')," in
	*",$1,"*) return 0 ;;
	esac
	return 1
}

lib_toggle() {
	_lh=",$(pf_get libs_hidden ''),"
	case "$_lh" in
	*",$1,"*) _lh=$(printf '%s' "$_lh" | sed "s/,$1,/,/") ;;
	*) _lh="$_lh$1," ;;
	esac
	_lh=$(printf '%s' "$_lh" | sed 's/,,*/,/g; s/^,//; s/,$//')
	pf_set libs_hidden "$_lh"
	# The rail, the Recently Added rows and the letter counts all change.
	home_cache_clear
	unset _lh
}

screen_libraries() {
	pf_status "Loading libraries..."
	_secs=$(plex_sections "$SRV_URI" "$SRV_TOK")
	if [ -z "$_secs" ]; then
		pf_msg "Could not read the library list${NLC}from the server."
		return 0
	fi
	while :; do
		mb_reset
		mb_back
		mb_block "$(printf '%s\n' "$_secs" |
			awk -F"$TABC" -v hid=",$(pf_get libs_hidden '')," '
			$3=="movie" || $3=="show" {
			  h = index(hid, "," $1 ",") ? 1 : 0
			  printf "L:%s\t%s\t\t%s\t%s\n", $1, $2, (h ? "hidden" : ""), (h ? "w" : "")
			}')"
		note_reset
		note_add "-------------------------------------------------"
		note_add "A hides or shows a library."
		note_add ""
		note_add "Hidden libraries are kept off the home"
		note_add "screen, out of Browse by letter, and have"
		note_add "no Recently Added row."
		note_use
		_sel=$(printf '%s' "$MB" | pf_menu "Libraries" "A show/hide | R1 back")
		_at=$(pf_menu_at)
		case "$_sel" in
		L:*) lib_toggle "${_sel#L:}"; PF_MENU_INDEX=$_at ;;
		*) return 0 ;;
		esac
	done
}

screen_home_rows() {
	while :; do
		mb_reset
		mb_add CONT "Continue Watching: $(pf_get home_continue true)"
		mb_add RECENT "Recently Added: $(pf_get home_recent true)"
		mb_add SIZE "Items in each row: $(pf_get home_rowsize 5)"
		mb_sep
		mb_add LIBS "Libraries to show"
		mb_back
		note_reset
		note_add "-------------------------------------------------"
		note_add "The rows down the right of the home"
		note_add "screen. Recently Added draws one row per"
		note_add "library you have kept, so hiding a"
		note_add "library removes its row too."
		note_use
		_sel=$(printf '%s' "$MB" | pf_menu "Home screen" "A select | R1 back")
		_at=$(pf_menu_at)
		case "$_sel" in
		CONT)
			if [ "$(pf_get home_continue true)" = "true" ]; then pf_set home_continue false 1
			else pf_set home_continue true 1; fi
			home_cache_clear ;;
		RECENT)
			if [ "$(pf_get home_recent true)" = "true" ]; then pf_set home_recent false 1
			else pf_set home_recent true 1; fi
			home_cache_clear ;;
		SIZE)
			case "$(pf_get home_rowsize 5)" in
			3) pf_set home_rowsize 5 1 ;;
			5) pf_set home_rowsize 8 1 ;;
			*) pf_set home_rowsize 3 1 ;;
			esac
			home_cache_clear ;;
		LIBS) screen_libraries ;;
		*) return 0 ;;
		esac
		PF_MENU_INDEX=$_at
	done
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
screen_settings() {
	while :; do
		_res=$(pf_res_get resolution 640x480)
		_bit=$(pf_get bitrate 2000)
		_rly=$(pf_get allow_relay false)
		_flp=$(pf_get flip true)

		mb_reset
		mb_add SUB "Subtitles: $(pf_get subtitles on)"
		mb_add RES "Quality: $(res_label "$_res")"
		mb_add BIT "Max bitrate: $_bit kbps"
		mb_add ASPECT "Widescreen: $(pf_get aspect letterbox)"
		mb_add FLIP "Rotate screen 180: $_flp"
		mb_add TIPS "Show controls before playing: $(pf_get show_controls true)"
		mb_sep
		mb_add NEXTEP "Play the next episode: $(pf_get autoplay_next true)"
		mb_add INTRO "Skip intros: $(pf_get skip_intro on)"
		mb_sep
		mb_add DLRES "Download quality: $(res_label "$(pf_res_get dl_resolution 480x320)")"
		mb_add DLBIT "Download bitrate: $(pf_get dl_bitrate 720) kbps"
		mb_add DLPAUSE "Pause downloads while watching: $(pf_get dl_pause_play false)"
		mb_add DLDEL "Delete a download once watched: $(pf_get dl_autodelete false)"
		mb_add DLS "Downloads"
		mb_sep
		mb_add HOME "Home screen"
		mb_add WIFI "Wi-Fi: $(pf_wifi_state)"
		mb_add SRV "Server: $(pf_get server_name '(auto)')"
		mb_add RLY "Allow Plex Relay: $_rly"
		mb_add PROF "Switch profile"
		mb_add DIAG "Connection info"
		mb_sep
		mb_add HELP "Controls reference"
		mb_add KEYS "Button test"
		mb_add OUT "Sign out"
		mb_back

		_sel=$(printf '%s' "$MB" | pf_menu "Settings" "A select | R1 back")
		case "$_sel" in
		SUB)
			if [ "$(pf_get subtitles on)" = "on" ]; then pf_set subtitles off
			else pf_set subtitles on; fi ;;
		DLRES)
			case "$(pf_res_get dl_resolution 480x320)" in
			640x480) pf_set dl_resolution 480x320 ;;
			*) pf_set dl_resolution 640x480 ;;
			esac ;;
		DLBIT)
			case "$(pf_get dl_bitrate 720)" in
			320) pf_set dl_bitrate 500 1 ;;
			500) pf_set dl_bitrate 720 1 ;;
			720) pf_set dl_bitrate 1500 1 ;;
			*) pf_set dl_bitrate 320 1 ;;
			esac ;;
		DLPAUSE)
			# Pausing throws away the partial file, because the transcode
			# endpoint serves one continuous stream and cannot be resumed from
			# a byte offset. That is why this is off by default.
			if [ "$(pf_get dl_pause_play false)" = "true" ]; then pf_set dl_pause_play false 1
			else pf_set dl_pause_play true 1; fi ;;
		NEXTEP)
			if [ "$(pf_get autoplay_next true)" = "true" ]; then pf_set autoplay_next false 1
			else pf_set autoplay_next true 1; fi ;;
		INTRO)
			if [ "$(pf_get skip_intro on)" = "on" ]; then pf_set skip_intro off
			else pf_set skip_intro on; fi ;;
		DLDEL)
			# Off by default: deleting something you just watched is right up
			# until the moment you wanted to watch it again on the way home.
			if [ "$(pf_get dl_autodelete false)" = "true" ]; then pf_set dl_autodelete false 1
			else pf_set dl_autodelete true 1; fi ;;
		DLS) screen_downloads ;;
		RES)
			case "$_res" in
			640x480) pf_set resolution 480x320 ;;
			*) pf_set resolution 640x480 ;;
			esac ;;
		BIT)
			case "$_bit" in
			720) pf_set bitrate 1500 1 ;;
			1500) pf_set bitrate 2000 1 ;;
			2000) pf_set bitrate 3000 1 ;;
			*) pf_set bitrate 720 1 ;;
			esac ;;
		HOME) screen_home_rows ;;
		WIFI) screen_wifi ;;
		SRV)
			pf_set server_uri ""; pf_set server_token ""
			screen_servers
			ensure_server ;;
		RLY)
			if [ "$_rly" = "true" ]; then pf_set allow_relay false 1
			else pf_set allow_relay true 1; fi ;;
		FLIP)
			if [ "$_flp" = "true" ]; then pf_set flip false 1
			else pf_set flip true 1; fi ;;
		ASPECT)
			if [ "$(pf_get aspect letterbox)" = "letterbox" ]; then pf_set aspect stretch
			else pf_set aspect letterbox; fi ;;
		TIPS)
			if [ "$(pf_get show_controls true)" = "true" ]; then pf_set show_controls false 1
			else pf_set show_controls true 1; fi ;;
		HELP) screen_controls ;;
		PROF) screen_profiles ;;
		KEYS) screen_keytest ;;
		DIAG)
			term_size
			pf_msg "Server: $(pf_get server_name '?')${NLC}${NLC}$(printf '%s' "$SRV_URI" | fold -w $((COLUMNS - 3)) | head -3)${NLC}${NLC}Transport: $PF_TLS${NLC}Device IP: $(pf_lan_ip)"
			;;
		OUT)
			pf_token_clear
			pf_set server_uri ""; pf_set server_token ""; pf_set server_id ""
			TOKEN=""
			pf_msg "Signed out."
			nav_reset
			return 0 ;;
		*) return 0 ;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Home
# ---------------------------------------------------------------------------
# The rail on the left never goes away, and what it points at changes the pane
# on the right. That is the shape of every Plex client: Home at the top, then
# the libraries, and choosing one narrows the recommendations to it rather than
# dumping you into an alphabetical list of everything in it.
#
# So A on a library here does *not* leave this screen. It loads that library's
# rows -- its own Continue Watching, Recently Released, Recently Added -- into
# the right pane with the rail still beside it. The alphabetical list is still
# one press away: it is the first row of the pane, "All of <library>".
#
# Which view is loaded is remembered in a file, like the pane cursors, so
# leaving for an episode and coming back returns to the same rows.
PF_VIEW_FILE="$PF_RUN/home.view"
PF_HOME_TTL=90

home_view() {
	_hv="home"
	[ -r "$PF_VIEW_FILE" ] && read -r _hv <"$PF_VIEW_FILE" 2>/dev/null
	[ -z "$_hv" ] && _hv="home"
	printf '%s' "$_hv"
	unset _hv
}

# Switching view resets the right pane to its top -- it is different content,
# and row 7 of the last one means nothing here -- while leaving the rail
# exactly where the user's thumb left it.
home_view_set() {
	printf '%s\n' "$1" >"$PF_VIEW_FILE"
	pf_panes_state
	pf_panes_save "$PF_PANE_SIDE" "$PF_PANE_L" 0
}

screen_home() {
	while :; do
		_ndone=$(pf_cache_count done)
		_nq=$(pf_cache_count queued)
		_dlflag=""
		[ "$_ndone" -gt 0 ] && _dlflag="d"
		[ "$_nq" -gt 0 ] && _dlflag="q"

		if [ "$PF_OFFLINE" = "1" ]; then
			screen_home_offline
			return 0
		fi

		if ! sections_load; then
			if [ "$_ndone" -gt 0 ]; then
				PF_OFFLINE=1
				pf_msg "Lost the connection to${NLC}$(pf_get server_name 'your server').${NLC}${NLC}Switching to your downloads."
				return 0
			fi
			pf_msg "Could not read libraries from${NLC}$(pf_get server_name 'the server').${NLC}${NLC}Check Wi-Fi, or pick another${NLC}server in Settings."
			screen_settings
			return 0
		fi

		_view=$(home_view)
		# A library that has since been hidden, or a server that no longer has
		# it, must not leave the screen pointing at nothing.
		case "$_view" in
		sec:*)
			_vk=${_view#sec:}
			if ! printf '%s\n' "$_secs" | awk -F"$TABC" -v k="$_vk" \
				'$1==k {found=1} END {exit !found}' || lib_hidden "$_vk"; then
				home_view_set home
				_view=home
			fi ;;
		esac

		# --- the rail ---
		{
			printf 'HOME\tHome\t\t\t\n'
			printf '%s\n' "$_secs" |
				awk -F"$TABC" -v hid=",$(pf_get libs_hidden '')," '
				$3=="movie" || $3=="show" {
				  if (index(hid, "," $1 ",")) next
				  printf "SEC:%s|%s\t%s\t\t\t\n", $1, $2, $2
				}'
			printf -- '--\t-\t\t\ts\n'
			printf 'DOWNLOADS\tDownloads\t\t%s\t%s\n' \
				"$(deck_dl_label "$_ndone" "$_nq")" "$_dlflag"
			printf 'SEARCH\tBrowse A-Z\t\t\t\n'
			printf 'SETTINGS\tSettings\t\t\t\n'
			printf 'QUIT\tQuit\t\t\t\n'
		} >"$PF_RUN/home.left"

		# --- the rows ---
		view_load "$_view"

		if [ "$_view" = "home" ]; then
			_htitle="PocketFlex - $(pf_get server_name 'Plex')"
		else
			_htitle=$(printf '%s\n' "$_secs" |
				awk -F"$TABC" -v k="${_view#sec:}" '$1==k {print $2; exit}')
			[ -z "$_htitle" ] && _htitle="Library"
		fi

		_sel=$(pf_panes "$PF_RUN/home.left" "$PF_RUN/home.right" "$_htitle" \
			"A select | L/R switch panes | MENU quit")

		case "$_sel" in
		HOME)
			home_view_set home ;;
		SEC:*)
			_kv=${_sel#SEC:}
			home_view_set "sec:${_kv%%|*}" ;;
		ALL:*)
			_kv=${_sel#ALL:}
			nav_push library "${_kv%%|*}" "${_kv#*|}"
			return 0 ;;
		DOWNLOADS) screen_downloads ;;
		SEARCH) nav_push search "" "Browse"; return 0 ;;
		SETTINGS) screen_settings ;;
		show:*) nav_push show "${_sel#*:}" "$(home_row_title "$_sel")"; return 0 ;;
		season:*) nav_push season "${_sel#*:}" "$(home_row_title "$_sel")"; return 0 ;;
		movie:* | episode:*) nav_push item "${_sel#*:}" "$(home_row_title "$_sel")"; return 0 ;;
		BACK)
			# Out of a library view is back to Home, not out of the app. Only
			# Home itself quits, which is where the Quit row is anyway.
			if [ "$_view" != "home" ]; then
				home_view_set home
			else
				: >"$PF_QUIT"; exit 0
			fi ;;
		*) : >"$PF_QUIT"; exit 0 ;;
		esac
	done
}

# The offline home stays a plain list: there are no rows to show when there is
# no server, and a rail of libraries you cannot open would be a lie.
screen_home_offline() {
	mb_reset
	mb_add DOWNLOADS "Downloads" "$_ndone saved" "$_dlflag"
	mb_sep
	if pf_wifi_available && [ "$(pf_wifi_state)" = "off" ]; then
		mb_add WIFION "Turn Wi-Fi on"
	fi
	mb_add RETRY "Try to connect again"
	mb_add SETTINGS "Settings"
	mb_add QUIT "Quit"
	note_reset
	note_add "-------------------------------------------------"
	note_add "Offline. Your Plex server could not be"
	note_add "reached, so only downloaded titles are"
	note_add "available."
	note_use
	case "$(printf '%s' "$MB" | pf_menu "PocketFlex - offline" "A select | MENU quit")" in
	DOWNLOADS) screen_downloads ;;
	WIFION) screen_wifi ;;
	RETRY)
		pf_set server_uri ""; pf_set server_token ""
		# Whatever is cached was built while the server was unreachable.
		home_cache_clear
		if ensure_server; then
			PF_OFFLINE=0
			nav_reset
			pf_msg "Connected to $(pf_get server_name 'your server')."
		else
			pf_msg "Still no connection."
		fi ;;
	SETTINGS) screen_settings ;;
	*) : >"$PF_QUIT"; exit 0 ;;
	esac
}

# The label of a right-pane row, for the frame title of whatever it opens.
home_row_title() {
	awk -F"$TABC" -v k="$1" '$1==k {print $2; exit}' "$PF_RUN/home.right" |
		sed 's/^ *//'
}

# ---------------------------------------------------------------------------
# The library list and the view contents, both cached
# ---------------------------------------------------------------------------
# Home is redrawn every single time you back out of anything, and a view is a
# request (or several, if the server has no hubs). Both are cached with the
# epoch they were built at on their first line. Ninety seconds is set against
# what actually changes: your own watching, which clears these explicitly --
# launch.sh does it after playback -- and the server acquiring files, which
# nobody expects to see within a minute.
PF_SECS_CACHE="$PF_RUN/sections.cache"
PF_HOME_CACHE="$PF_RUN/home.cache"

# Everything read from the server and kept: the library list, every cached
# view, and the letter index. One call, because the events that invalidate any
# of them -- a different server, a different profile, a library hidden, the
# radio going off -- invalidate all of them.
home_cache_clear() {
	rm -f "$PF_SECS_CACHE" "$PF_HOME_CACHE" "$PF_RUN/letters.idx" \
		"$PF_RUN"/view.* 2>/dev/null
}

# Sets _secs. The library list changes far less often than its contents.
sections_load() {
	_now=$(date +%s)
	_ts=0
	[ -s "$PF_SECS_CACHE" ] && read -r _ts <"$PF_SECS_CACHE" 2>/dev/null
	case "$_ts" in '' | *[!0-9]*) _ts=0 ;; esac
	if [ $((_now - _ts)) -ge 300 ]; then
		pf_status "Loading libraries..."
		_s=$(plex_sections "$SRV_URI" "$SRV_TOK")
		[ -z "$_s" ] && return 1
		{ printf '%s\n' "$_now"; printf '%s\n' "$_s"; } >"$PF_SECS_CACHE"
	fi
	_secs=$(sed 1d "$PF_SECS_CACHE")
	[ -n "$_secs" ]
}

# Writes $PF_RUN/home.right for a view id: "home" or "sec:<key>".
view_load() {
	_vf="$PF_RUN/view.$(printf '%s' "$1" | tr -d ':')"
	_now=$(date +%s)
	_ts=0
	[ -s "$_vf" ] && read -r _ts <"$_vf" 2>/dev/null
	case "$_ts" in '' | *[!0-9]*) _ts=0 ;; esac
	if [ $((_now - _ts)) -ge "$PF_HOME_TTL" ]; then
		view_build "$1" "$_now" >"$_vf.tmp" && mv "$_vf.tmp" "$_vf"
	fi
	sed 1d "$_vf" >"$PF_RUN/home.right" 2>/dev/null
	unset _vf
}

view_build() {
	_vn=$(pf_get home_rowsize 5)
	printf '%s\n' "$2"
	if [ "$1" = "home" ]; then
		pf_status "Loading your home screen..."
		_vh=$(plex_hubs "$SRV_URI" "$SRV_TOK" "/hubs" "$_vn" \
			",$(pf_get libs_hidden '')," )
		[ -z "$_vh" ] && _vh=$(home_rows_fallback "$_vn")
	else
		_vk=${1#sec:}
		_vname=$(printf '%s\n' "$_secs" |
			awk -F"$TABC" -v k="$_vk" '$1==k {print $2; exit}')
		pf_status "Loading $_vname..."
		# The alphabetical list is a row, not a lost feature: it is the first
		# thing in the pane and it opens the same screen the rail used to.
		printf 'ALL:%s|%s\tAll of %s\t\tA-Z\t\n' "$_vk" "$_vname" "$_vname"
		_vh=$(plex_hubs "$SRV_URI" "$SRV_TOK" "/hubs/sections/$_vk" "$_vn")
		[ -z "$_vh" ] && _vh=$(section_rows_fallback "$_vk" "$_vn")
	fi
	[ -n "$_vh" ] && printf '%s\n' "$_vh" | items_to_menu
	return 0
}

# ---------------------------------------------------------------------------
# When the server has no hubs
# ---------------------------------------------------------------------------
# /hubs has been in Plex Media Server for years, but a server old enough not to
# have it, or one that answers with nothing, must not produce an empty home
# screen. These build the same rows out of the endpoints that predate it -- at
# the cost of a request each, which is exactly what hubs exist to avoid. Taking
# this path is logged, so the log says which one answered.
home_rows_fallback() {
	log "hubs: /hubs returned nothing; building home rows the long way"
	_fd=$(plex_ondeck "$SRV_URI" "$SRV_TOK" "$1")
	if [ -n "$_fd" ]; then
		printf 'HDR\tContinue Watching\n'
		printf '%s\n' "$_fd"
	fi
	printf '%s\n' "$_secs" | while IFS="$TABC" read -r _fk _ft _fy; do
		case "$_fy" in movie | show) ;; *) continue ;; esac
		lib_hidden "$_fk" && continue
		_fr=$(plex_recent "$SRV_URI" "$SRV_TOK" "$_fk" "$1")
		[ -z "$_fr" ] && continue
		printf 'HDR\tRecently Added in %s\n' "$_ft"
		printf '%s\n' "$_fr"
	done
}

section_rows_fallback() {
	log "hubs: /hubs/sections/$1 returned nothing; building its rows the long way"
	_sd=$(plex_section_ondeck "$SRV_URI" "$SRV_TOK" "$1" "$2")
	if [ -n "$_sd" ]; then
		printf 'HDR\tContinue Watching\n'
		printf '%s\n' "$_sd"
	fi
	_sr=$(plex_section_newest "$SRV_URI" "$SRV_TOK" "$1" "$2")
	if [ -n "$_sr" ]; then
		printf 'HDR\tRecently Released\n'
		printf '%s\n' "$_sr"
	fi
	_sa=$(plex_recent "$SRV_URI" "$SRV_TOK" "$1" "$2")
	if [ -n "$_sa" ]; then
		printf 'HDR\tRecently Added\n'
		printf '%s\n' "$_sa"
	fi
}

# Right-hand column for the Downloads row: what is on the card, and whether
# anything is still coming.
deck_dl_label() {
	if [ "${2:-0}" -gt 0 ]; then printf '%s+%s' "$1" "$2"
	elif [ "${1:-0}" -gt 0 ]; then printf '%s' "$1"
	fi
}

# ---------------------------------------------------------------------------
# Offline
# ---------------------------------------------------------------------------
# A Plex client that dead-ends when the server is unreachable is useless on a
# train, which is where this device is actually used. If anything at all has
# been downloaded, an unreachable server is a mode, not a failure.
# Returns 1 only when there is genuinely nothing to offer.
go_offline() {
	if [ "$(pf_cache_count done)" -eq 0 ]; then
		pf_msg "$1${NLC}${NLC}Check Wi-Fi is connected.${NLC}${NLC}Nothing has been downloaded yet,${NLC}so there is nothing to play offline."
		return 1
	fi
	PF_OFFLINE=1
	nav_reset
	pf_msg "$1${NLC}${NLC}Starting in offline mode.${NLC}Your $(pf_cache_count done) downloaded titles${NLC}are available."
	return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
	trap 'raw_off; printf "\033[?25h" >/dev/tty 2>/dev/null' EXIT INT TERM

	# Layout is driven by `stty size`; if busybox's stty can't report it we
	# silently fall back to 40x24 and everything is subtly misplaced. Record
	# what we actually got so that assumption is verifiable.
	term_size
	log "terminal ${COLUMNS}x${LINES}"

	pf_cache_init
	# Only on a cold start: coming back from playback should land on the list
	# you left, not on a logo.
	[ -s "$PF_STACK" ] || pf_splash "Starting up..."

	TOKEN=$(pf_token)
	if [ -z "$TOKEN" ]; then
		if do_signin; then
			TOKEN=$(pf_token)
			nav_reset
		elif go_offline "You are not signed in and plex.tv could not be reached."; then
			:
		else
			: >"$PF_QUIT"; exit 0
		fi
	fi

	# The whole point of downloading things is that this failing is survivable.
	if [ "$PF_OFFLINE" != "1" ]; then
		pf_splash "Finding your Plex server..."
		if ! ensure_server; then
			go_offline "Your Plex server could not be reached." ||
				{ : >"$PF_QUIT"; exit 0; }
		fi
	fi
	[ -s "$PF_STACK" ] || nav_reset

	# Anything playback wanted to tell us while the terminal was gone.
	if [ -s "$PF_RUN/notice" ]; then
		term_size
		pf_msg "$(fold -s -w $((COLUMNS - 3)) <"$PF_RUN/notice")"
		rm -f "$PF_RUN/notice"
	fi

	while :; do
		_frame=$(nav_top)
		if [ -z "$_frame" ]; then
			nav_reset
			_frame=$(nav_top)
		fi
		_type=$(printf '%s' "$_frame" | cut -f1)
		_key=$(printf '%s' "$_frame" | cut -f2)
		_ttl=$(printf '%s' "$_frame" | cut -f3)
		# Where this screen's cursor was the last time it handed off. A frame
		# that has never been left has no fourth field and starts at the top.
		PF_MENU_INDEX=$(printf '%s' "$_frame" | cut -f4)
		[ -z "$PF_MENU_INDEX" ] && PF_MENU_INDEX=0

		case "$_type" in
		home) screen_home ;;
		ondeck)
			pf_status "Loading..."
			screen_list "Continue Watching" "$(plex_ondeck "$SRV_URI" "$SRV_TOK")" ;;
		library)
			pf_status "Loading $_ttl..."
			screen_list "$_ttl" "$(plex_section_items "$SRV_URI" "$SRV_TOK" "$_key")" ;;
		letter)
			pf_status "Finding titles starting with $_key..."
			screen_list "$_ttl" "$(letter_items "$_key")" ;;
		show)
			pf_status "Loading seasons..."
			screen_list "$_ttl" "$(plex_children "$SRV_URI" "$SRV_TOK" "$_key")" "$_key" ;;
		season)
			pf_status "Loading episodes..."
			screen_list "$_ttl" "$(plex_children "$SRV_URI" "$SRV_TOK" "$_key")" "$_key" ;;
		item) screen_item "$_key" ;;
		search) screen_search ;;
		*) nav_reset ;;
		esac
	done
}

main "$@"
