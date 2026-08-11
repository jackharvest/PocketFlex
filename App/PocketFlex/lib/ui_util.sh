#!/bin/sh
# PocketFlex - terminal drawing + gamepad input primitives.
#
# CONTROLS, and why they are what they are:
#   OnionOS runs scripts inside `st`, an SDL terminal. The Miyoo maps buttons
#   to keyboard keys: A=SPACE, B=LCTRL, X=LSHIFT, Y=LALT, START=ENTER,
#   SELECT=RCTRL, MENU=ESC. LCTRL/LSHIFT/LALT/RCTRL are bare *modifiers*, so a
#   terminal receives no bytes at all when they are pressed. That is exactly
#   why the existing OnionOS Jellyfin client documents "back button in menus
#   does not work" -- B genuinely cannot be read from a terminal.
#
#   So we bind only keys that actually emit bytes:
#     D-pad  -> arrow escape sequences
#     A      -> SPACE  (select)
#     START  -> ENTER  (select / confirm)
#     MENU   -> ESC    (OnionOS kills st; launch.sh treats that as "exit")
#   and every list carries an explicit ".. Back" row instead of a back button.
#
# I/O DISCIPLINE:
#   These helpers are called inside command substitution, so stdout carries the
#   *return value*. All drawing therefore goes to /dev/tty and all key reads
#   come from /dev/tty. Menu items arrive on stdin. Mixing these up silently
#   captures escape codes into the result, which is maddening to debug.

ESC=$(printf '\033')
CR=$(printf '\r')
TABC=$(printf '\t')
BS=$(printf '\010')   # ^H  - R1
DEL=$(printf '\177')  # DEL - R1 on some builds
TABK=$(printf '\011') # TAB - SELECT

# ---------------------------------------------------------------------------
# Palette.
#
# st renders on a small, glossy 3.5" panel. Dim/bold-black on colour reads as
# grey-on-lime and is genuinely hard to see -- so nothing here uses colour to
# carry meaning on its own. Selection is reverse video, which is the highest
# contrast a terminal can produce and stays correct whatever the palette is.
# ---------------------------------------------------------------------------
C_OFF=$(printf '\033[0m')
C_SEL=$(printf '\033[7m')       # reverse video - selected row
C_TITLE=$(printf '\033[1;37m')  # bright white - headers, unwatched titles
C_HINT=$(printf '\033[1;36m')   # bright cyan - footer hints
C_WARN=$(printf '\033[1;31m')   # bright red
C_ACC=$(printf '\033[38;5;208m') # orange - accents, and the brand
C_DIM=$(printf '\033[0;37m')    # plain white - secondary text, watched titles
C_OK=$(printf '\033[1;32m')     # bright green - available offline

# Two weights of white is the whole hierarchy. It survives the panel's glare
# where a colour pair does not, and it is what lets a watched episode recede
# without becoming unreadable -- the thing an artwork-less client needs most.
#
# White and orange on black is the identity, taken from the splash logo, and
# the accent is a real orange rather than the bright yellow that used to stand
# in for one. That needs 256-colour indexing, which is safe here: this st
# implements SGR 38;5;N -- its binary carries both the "bad fgcolor %d" and
# "erresc(38): gfx attr %d unknown" diagnostics from that code path. Index 208
# is #ff8700, which is the orange in the logo.

# ---------------------------------------------------------------------------
# 5-row block font, for the sign-in code. The PIN is the one thing a user has
# to read off this screen and copy onto another device, so it gets rendered
# large instead of as a colour-swapped run of normal text.
# ---------------------------------------------------------------------------
glyph_row() {
	case "$1$2" in
	00) echo " ### " ;; 01) echo "#   #" ;; 02) echo "#   #" ;; 03) echo "#   #" ;; 04) echo " ### " ;;
	10) echo "  #  " ;; 11) echo " ##  " ;; 12) echo "  #  " ;; 13) echo "  #  " ;; 14) echo " ### " ;;
	20) echo " ### " ;; 21) echo "#   #" ;; 22) echo "  ## " ;; 23) echo " #   " ;; 24) echo "#####" ;;
	30) echo "#### " ;; 31) echo "    #" ;; 32) echo " ### " ;; 33) echo "    #" ;; 34) echo "#### " ;;
	40) echo "#   #" ;; 41) echo "#   #" ;; 42) echo "#####" ;; 43) echo "    #" ;; 44) echo "    #" ;;
	50) echo "#####" ;; 51) echo "#    " ;; 52) echo "#### " ;; 53) echo "    #" ;; 54) echo "#### " ;;
	60) echo " ### " ;; 61) echo "#    " ;; 62) echo "#### " ;; 63) echo "#   #" ;; 64) echo " ### " ;;
	70) echo "#####" ;; 71) echo "    #" ;; 72) echo "   # " ;; 73) echo "  #  " ;; 74) echo "  #  " ;;
	80) echo " ### " ;; 81) echo "#   #" ;; 82) echo " ### " ;; 83) echo "#   #" ;; 84) echo " ### " ;;
	90) echo " ### " ;; 91) echo "#   #" ;; 92) echo " ####" ;; 93) echo "    #" ;; 94) echo " ### " ;;
	A0) echo " ### " ;; A1) echo "#   #" ;; A2) echo "#####" ;; A3) echo "#   #" ;; A4) echo "#   #" ;;
	B0) echo "#### " ;; B1) echo "#   #" ;; B2) echo "#### " ;; B3) echo "#   #" ;; B4) echo "#### " ;;
	C0) echo " ####" ;; C1) echo "#    " ;; C2) echo "#    " ;; C3) echo "#    " ;; C4) echo " ####" ;;
	D0) echo "#### " ;; D1) echo "#   #" ;; D2) echo "#   #" ;; D3) echo "#   #" ;; D4) echo "#### " ;;
	E0) echo "#####" ;; E1) echo "#    " ;; E2) echo "#### " ;; E3) echo "#    " ;; E4) echo "#####" ;;
	F0) echo "#####" ;; F1) echo "#    " ;; F2) echo "#### " ;; F3) echo "#    " ;; F4) echo "#    " ;;
	G0) echo " ####" ;; G1) echo "#    " ;; G2) echo "#  ##" ;; G3) echo "#   #" ;; G4) echo " ### " ;;
	H0) echo "#   #" ;; H1) echo "#   #" ;; H2) echo "#####" ;; H3) echo "#   #" ;; H4) echo "#   #" ;;
	I0) echo " ### " ;; I1) echo "  #  " ;; I2) echo "  #  " ;; I3) echo "  #  " ;; I4) echo " ### " ;;
	J0) echo "#####" ;; J1) echo "   # " ;; J2) echo "   # " ;; J3) echo "#  # " ;; J4) echo " ##  " ;;
	K0) echo "#   #" ;; K1) echo "#  # " ;; K2) echo "###  " ;; K3) echo "#  # " ;; K4) echo "#   #" ;;
	L0) echo "#    " ;; L1) echo "#    " ;; L2) echo "#    " ;; L3) echo "#    " ;; L4) echo "#####" ;;
	M0) echo "#   #" ;; M1) echo "## ##" ;; M2) echo "# # #" ;; M3) echo "#   #" ;; M4) echo "#   #" ;;
	N0) echo "#   #" ;; N1) echo "##  #" ;; N2) echo "# # #" ;; N3) echo "#  ##" ;; N4) echo "#   #" ;;
	O0) echo " ### " ;; O1) echo "#   #" ;; O2) echo "#   #" ;; O3) echo "#   #" ;; O4) echo " ### " ;;
	P0) echo "#### " ;; P1) echo "#   #" ;; P2) echo "#### " ;; P3) echo "#    " ;; P4) echo "#    " ;;
	Q0) echo " ### " ;; Q1) echo "#   #" ;; Q2) echo "# # #" ;; Q3) echo "#  # " ;; Q4) echo " ## #" ;;
	R0) echo "#### " ;; R1) echo "#   #" ;; R2) echo "#### " ;; R3) echo "#  # " ;; R4) echo "#   #" ;;
	S0) echo " ####" ;; S1) echo "#    " ;; S2) echo " ### " ;; S3) echo "    #" ;; S4) echo "#### " ;;
	T0) echo "#####" ;; T1) echo "  #  " ;; T2) echo "  #  " ;; T3) echo "  #  " ;; T4) echo "  #  " ;;
	U0) echo "#   #" ;; U1) echo "#   #" ;; U2) echo "#   #" ;; U3) echo "#   #" ;; U4) echo " ### " ;;
	V0) echo "#   #" ;; V1) echo "#   #" ;; V2) echo "#   #" ;; V3) echo " # # " ;; V4) echo "  #  " ;;
	W0) echo "#   #" ;; W1) echo "#   #" ;; W2) echo "# # #" ;; W3) echo "## ##" ;; W4) echo "#   #" ;;
	X0) echo "#   #" ;; X1) echo " # # " ;; X2) echo "  #  " ;; X3) echo " # # " ;; X4) echo "#   #" ;;
	Y0) echo "#   #" ;; Y1) echo " # # " ;; Y2) echo "  #  " ;; Y3) echo "  #  " ;; Y4) echo "  #  " ;;
	Z0) echo "#####" ;; Z1) echo "   # " ;; Z2) echo "  #  " ;; Z3) echo " #   " ;; Z4) echo "#####" ;;
	*) echo "     " ;;
	esac
}

# big_text <text> <row> [column]
# Render <text> as 5-row block characters starting at terminal row $2.
big_text() {
	_txt=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
	_col=${3:-3}
	_row=0
	while [ "$_row" -lt 5 ]; do
		_line=""
		_i=1
		while [ "$_i" -le "${#_txt}" ]; do
			_ch=$(printf '%s' "$_txt" | cut -c"$_i")
			_line="$_line$(glyph_row "$_ch" "$_row") "
			_i=$((_i + 1))
		done
		printf '\033[%s;%sH\033[K\033[%s;%sH%s' \
			"$(($2 + _row))" "1" "$(($2 + _row))" "$_col" "$_line"
		_row=$((_row + 1))
	done
	unset _txt _row _line _i _ch _col
}

# Centre a block-text string of $1 characters on the current terminal width.
big_col() {
	_w=$((${#1} * 6 - 1))
	_c=$(((COLUMNS - _w) / 2 + 1))
	[ "$_c" -lt 1 ] && _c=1
	printf '%s' "$_c"
	unset _w _c
}

# pf_bar <percent> <width>  ->  [####------]
# Used where there is room for it (the item screen, the download list). Lists
# get a bare "34%" instead: on a 53-column panel a bar costs a dozen columns
# that a long anime title needs more.
pf_bar() {
	_p=${1:-0}; _w=${2:-10}
	[ "$_p" -gt 100 ] && _p=100
	[ "$_p" -lt 0 ] && _p=0
	_fill=$((_p * _w / 100))
	_i=0
	printf '['
	while [ "$_i" -lt "$_w" ]; do
		if [ "$_i" -lt "$_fill" ]; then printf '#'; else printf '-'; fi
		_i=$((_i + 1))
	done
	printf ']'
	unset _p _w _fill _i
}

# The first thing anyone sees. Sign-in, server discovery and the library fetch
# together take several seconds on this hardware, and staring at a black
# terminal for those seconds is what makes a thing feel like a script rather
# than an app.
pf_splash() {
	term_size
	{
		printf '\033[H\033[2J'
		# POCKET white over FLEX orange, matching the boot logo -- the
		# terminal splash takes over from the framebuffer one the moment st
		# starts, and they should read as the same screen carrying on.
		printf '%s' "$C_TITLE"
		big_text "POCKET" 4 "$(big_col POCKET)"
		printf '%s' "$C_ACC"
		big_text "FLEX" 10 "$(big_col FLEX)"
		printf '%s' "$C_OFF"
		_t="Plex, in your pocket"
		printf '\033[17;%sH%s%s%s' \
			"$(((COLUMNS - ${#_t}) / 2 + 1))" "$C_DIM" "$_t" "$C_OFF"
		bar "v$PF_VERSION" "" "$LINES"
		[ -n "$1" ] && pf_status "$1"
	} >/dev/tty
	unset _t
}

# The battery as a bare number, or nothing. `bar` reads /tmp/percBat inline
# rather than calling this, because a command substitution is a fork and `bar`
# runs on every redraw; anything drawing once per screen can afford this.
pf_battery_pct() {
	_bp=""
	[ -r /tmp/percBat ] && read -r _bp </tmp/percBat 2>/dev/null
	case "$_bp" in
	'' | *[!0-9]*) ;;
	*) printf '%s' "$_bp" ;;
	esac
	unset _bp
}

term_size() {
	# shellcheck disable=SC2046
	set -- $(stty size </dev/tty 2>/dev/null)
	LINES=${1:-24}
	COLUMNS=${2:-40}
	[ "$LINES" -lt 6 ] 2>/dev/null || [ -z "$LINES" ] && LINES=24
	[ "$COLUMNS" -lt 20 ] 2>/dev/null || [ -z "$COLUMNS" ] && COLUMNS=40
}

raw_on() { stty -icanon -echo </dev/tty 2>/dev/null; }
raw_off() { stty icanon echo </dev/tty 2>/dev/null; }

# Read one logical key, collapsing arrow escape sequences into names.
# Prints one of: UP DOWN LEFT RIGHT OK ESC PGUP PGDN or a literal character.
# A tty that has gone away returns end-of-file instantly and forever, and from
# in here that is indistinguishable from START: a LF is stripped by command
# substitution and arrives as the empty string, which is why an empty read means
# "select" at all. So the difference has to be measured rather than read -- a
# dead stream delivers thousands of these per second and a thumb cannot.
#
# This is the interface's own half of the wake-up recovery in launch.sh: if the
# terminal loses its input, the app asks for a new one instead of sitting there
# looking alive.
PF_EOF_FILE="$PF_RUN/eof.run"

read_key() {
	_k=$(dd bs=1 count=1 2>/dev/null </dev/tty)
	# START sends LINE FEED, not carriage return -- settled by a device
	# button-test log showing 25 consecutive 0x0a while the user held down
	# START, and not one 0x0d in the entire session.
	#
	# And a LF byte cannot survive the line above: command substitution strips
	# trailing newlines, so it arrives here as the empty string. That is the
	# whole reason START silently did nothing in menus while A worked, despite
	# both being documented as "select". Test for the absence, not for "\n" --
	# a "$LF" pattern built with $(printf '\n') is itself empty and matches
	# everything.
	if [ -z "$_k" ]; then
		# The run has to be counted in a file. read_key is always called inside
		# `$(...)`, so a variable incremented here dies with the subshell -- the
		# same thing that lost the menu cursor before v0.3.0.
		_er=0; _et=0
		[ -r "$PF_EOF_FILE" ] && read -r _er _et <"$PF_EOF_FILE" 2>/dev/null
		case "$_er" in '' | *[!0-9]*) _er=0 ;; esac
		case "$_et" in '' | *[!0-9]*) _et=0 ;; esac
		_er=$((_er + 1))
		# One clock read at each end of the run rather than one per press: the
		# counter is free, `date` is a process.
		[ "$_er" = "1" ] && _et=$(date +%s)
		printf '%s %s\n' "$_er" "$_et" >"$PF_EOF_FILE"
		if [ "$_er" -ge 1000 ]; then
			if [ $(( $(date +%s) - _et )) -le 3 ]; then
				log "input is dead: 1000 empty reads in 3s; asking for a new terminal"
				: >"$PF_RUN/st.restart"
				raw_off
				# $$ is the interface's own pid even in here: a subshell
				# inherits it rather than taking its own.
				kill -TERM $$ 2>/dev/null
				sleep 5
			fi
			rm -f "$PF_EOF_FILE"
		fi
		printf 'OK'
		return
	fi
	# Only ever a process when a run actually happened.
	[ -f "$PF_EOF_FILE" ] && rm -f "$PF_EOF_FILE"
	case "$_k" in
	"$ESC")
		_k2=$(dd bs=1 count=1 2>/dev/null </dev/tty)
		[ "$_k2" != "[" ] && { printf 'ESC'; return; }
		_k3=$(dd bs=1 count=1 2>/dev/null </dev/tty)
		case "$_k3" in
		A) printf 'UP' ;;
		B) printf 'DOWN' ;;
		C) printf 'RIGHT' ;;
		D) printf 'LEFT' ;;
		5) dd bs=1 count=1 >/dev/null 2>&1 </dev/tty; printf 'PGUP' ;;
		6) dd bs=1 count=1 >/dev/null 2>&1 </dev/tty; printf 'PGDN' ;;
		*) printf 'ESC' ;;
		esac
		;;
	' ' | "$CR") printf 'OK' ;;
	# R1 sends backspace and SELECT sends tab (both per st's own key table),
	# and either is a far better "back" than making the user walk all the way
	# up a 637-row list to reach the .. Back row. B/X/Y are bare modifiers and
	# emit nothing at all, so they cannot be used however much we'd like to.
	"$BS" | "$DEL" | "$TABK") printf 'BACK' ;;
	*) printf '%s' "$_k" ;;
	esac
	unset _k _k2 _k3
}

# Full-width reverse-video bar with left- and right-aligned text.
# Header and footer bars give the screen a frame, which matters more here than
# usual: with no artwork, structure is the only thing separating chrome from
# content.
#
# The header bar also carries the battery, because a handheld is used away from
# a charger and the app takes the whole screen: while PocketFlex is open there
# is no other way to see it short of quitting to Onion's menu, which is a poor
# thing to have to do forty minutes into a film.
#
# It is read from /tmp/percBat, which Onion's own `batmon` writes -- runtime.sh
# starts it at boot and it runs for the whole session, so the number is already
# there for the taking and no i2c conversation with the AXP is needed. `read`
# is a builtin and the redirect costs nothing, so this is free on every redraw:
# no process spawn, which is the unit that actually costs time on this SoC.
# Absent or non-numeric (the desktop harnesses, or a build without batmon) and
# nothing is drawn at all.
bar() {
	_bl="$1"; _br="$2"; _brow="$3"
	if [ "$_brow" = "1" ]; then
		_bat=""
		[ -r /tmp/percBat ] && read -r _bat </tmp/percBat 2>/dev/null
		case "$_bat" in
		'' | *[!0-9]*) ;;
		*)
			if [ -n "$_br" ]; then _br="$_br  ${_bat}%"
			else _br="${_bat}%"; fi ;;
		esac
		unset _bat
	fi
	_bpad=$((COLUMNS - ${#_bl} - ${#_br} - 2))
	if [ "$_bpad" -lt 1 ]; then
		_bl=$(fit "$_bl" $((COLUMNS - ${#_br} - 3)))
		_bpad=$((COLUMNS - ${#_bl} - ${#_br} - 2))
		[ "$_bpad" -lt 1 ] && _bpad=1
	fi
	printf '\033[%s;1H\033[K%s %s' "$_brow" "$C_SEL" "$_bl"
	_bi=0
	while [ "$_bi" -lt "$_bpad" ]; do printf ' '; _bi=$((_bi + 1)); done
	printf '%s %s' "$_br" "$C_OFF"
	unset _bl _br _brow _bpad _bi
}

# Truncate so long titles never wrap and corrupt the list layout.
fit() {
	_w=$2
	[ "$_w" -lt 4 ] && _w=4
	if [ "${#1}" -le "$_w" ]; then
		printf '%s' "$1"
	else
		printf '%s..' "$(printf '%s' "$1" | cut -c1-$((_w - 2)))"
	fi
	unset _w
}

# ---------------------------------------------------------------------------
# pf_menu -- the core list picker.
#
# stdin : one row per line, tab separated:
#
#   1 payload   2 label   3 sortLetter   4 rightText   5 flags
#
# Only the payload is required. flags is a bag of single characters:
#
#   w  watched      -- title is dimmed, so unwatched items are what stands out
#   d  downloaded   -- green "+" in the marker column; plays with Wi-Fi off
#   q  queued       -- yellow "." in the marker column
#   s  separator    -- a rule, drawn full width, that the cursor skips over
#
# $1    : title      $2 : hint line
# PF_MENU_NOTE : optional path to a file drawn under the list, when it fits.
#
# Prints the selected payload to stdout. Returns 1 if the list was empty.
#
# Only the visible window is rendered, so a 2000-episode library costs the same
# to draw as a 5-item menu. Written from scratch rather than reusing the system
# shellect.sh so the app keeps working across OnionOS updates.
# ---------------------------------------------------------------------------
PF_MENU_INDEX=0
PF_MENU_NOTE=""
PF_MENU_AT="$PF_RUN/menu.idx"

# Where the cursor was when the last menu handed off.
#
# pf_menu sets PF_MENU_INDEX before it returns, and that assignment goes
# nowhere: every caller reads its result through `$(...)`, and the pipe into it
# is a second subshell again. A variable set in there dies with it -- which is
# why coming back from an episode used to land at the top of a 600-row library
# instead of on the episode. A file crosses that boundary, and it crosses the
# bigger one too: the interface *exits* for playback and is started again
# afterwards, so this is also what makes "watch something, come back to the row
# you played" work.
pf_menu_at() {
	_mi=0
	[ -r "$PF_MENU_AT" ] && read -r _mi <"$PF_MENU_AT" 2>/dev/null
	case "$_mi" in
	'' | *[!0-9]*) printf '0' ;;
	*) printf '%s' "$_mi" ;;
	esac
	unset _mi
}

# menu_draw_rows <indexA> <indexB> -- repaint just these two list rows.
#
# Moving the cursor used to clear the screen and repaint all 29 rows for a
# change that touches exactly two: the row the cursor left and the row it
# arrived on. The clear is what makes the list flash black under the cursor on
# every d-pad press, and the repaint is a few kilobytes of escape codes through
# st's renderer each time.
#
# One awk pass does both rows, including the A-Z gutter letter, because a
# process spawn is the expensive unit on this SoC -- doing it as two calls plus
# a couple of seds for the gutter would have cost more than the full repaint it
# replaces. Rows outside the visible window are skipped by the awk itself.
#
# Operates on pf_menu's locals: $_f $_off $_page $_top $_lw $_gut $_cur.
menu_draw_rows() {
	awk -F"$TABC" -v a="$1" -v b="$2" -v cur="$_cur" -v off="$_off" \
		-v page="$_page" -v top="$_top" -v lw="$_lw" -v gut="$_gut" \
		-v cols="$COLUMNS" -v sel="$C_SEL" -v acc="$C_ACC" -v ok="$C_OK" \
		-v ttl="$C_TITLE" -v dim="$C_DIM" -v off_="$C_OFF" '
	{
	  idx = NR - 1
	  # The gutter letter is drawn only on a row that starts a new initial, so
	  # the previous row must be seen even when it is not being repainted.
	  # Reading the file in order gives that for free.
	  want = (idx == a || idx == b) && idx >= off && idx < off + page
	  if (!want) { prev = $3; next }
	  row = top + idx - off
	  label = (NF > 1) ? $2 : $1
	  right = (NF > 3) ? $4 : ""
	  flags = (NF > 4) ? $5 : ""
	  printf "\033[%d;1H\033[K", row

	  if (index(flags, "s")) {
	    rule = ""
	    while (length(rule) < lw + 2) rule = rule "-"
	    printf "  %s%s%s", dim, rule, off_
	    prev = $3
	    next
	  }

	  mark = " "; mcol = ""
	  if (index(flags, "d"))      { mark = "+"; mcol = ok }
	  else if (index(flags, "q")) { mark = "."; mcol = acc }

	  avail = lw - (length(right) ? length(right) + 2 : 0)
	  disp  = label
	  if (length(disp) > avail) disp = substr(disp, 1, avail - 2) ".."
	  # Pad by hand: busybox awk rejects "%-*s" outright.
	  while (length(disp) < avail) disp = disp " "
	  rpad = ""
	  if (length(right)) {
	    rpad = right
	    while (length(rpad) < length(right) + 2) rpad = " " rpad
	  }

	  if (idx == cur) {
	    printf " %s>%s%s%s %s", sel, mark, disp, rpad, off_
	  } else {
	    tc = index(flags, "w") ? dim : ttl
	    printf "  %s%s%s%s%s%s%s%s%s", \
	      mcol, mark, off_, tc, disp, off_, dim, rpad, off_
	  }

	  # The first visible row always shows its letter: the full repaint starts
	  # with an empty `prev` at the top of the window, and this has to match or
	  # the badge would appear and disappear as you scrolled past it.
	  if (gut && NF > 2 && $3 != "" && $3 != "-" && ($3 != prev || idx == off))
	    printf "\033[%d;%dH%s%s%s", row, cols - 1, acc, $3, off_
	  prev = $3
	}' "$_f"
}

# Separator rows are decoration, so the cursor must never come to rest on one.
# Operates on pf_menu's locals ($_f, $_cur, $_count, $_dir) -- sh has no scoping
# to speak of and pulling this out keeps the key handler readable.
menu_skip_sep() {
	_g=0
	while [ "$_g" -lt "$_count" ]; do
		case "$(sed -n "$((_cur + 1))p" "$_f" | cut -f5)" in
		*s*) ;;
		*) return 0 ;;
		esac
		if [ "$_dir" = "up" ]; then
			if [ "$_cur" -gt 0 ]; then _cur=$((_cur - 1)); else _cur=$((_count - 1)); fi
		else
			if [ "$_cur" -lt $((_count - 1)) ]; then _cur=$((_cur + 1)); else _cur=0; fi
		fi
		_g=$((_g + 1))
	done
	unset _g
}

pf_menu() {
	_title="$1"
	_hint="${2:-A select | R1 back | MENU quit}"

	# Items land in a file rather than a variable: a 637-row library would
	# otherwise be re-split by the shell on every single redraw.
	_f="$PF_RUN/menu.$$"
	cat >"$_f"
	_count=$(wc -l <"$_f" | tr -d ' ')
	[ "$_count" -eq 0 ] && { rm -f "$_f"; PF_MENU_NOTE=""; return 1; }

	term_size
	# Row 1 header bar, row 2 blank, list, blank, row LINES footer bar.
	_top=3
	_page=$((LINES - 2 - _top))
	[ "$_page" -lt 1 ] && _page=1

	# Letter gutter down the right edge, marking where each new initial
	# starts -- the text-mode equivalent of the A-Z rail in a Plex client.
	# Only worth the column on lists long enough to get lost in.
	_gut=0
	[ "$_count" -gt 40 ] && _gut=1
	# Two columns are reserved for the offline/queued marker on every row, so
	# that marker sits in a straight line the eye can run down instead of
	# jittering with the length of each title.
	_lw=$((COLUMNS - 6))
	[ "$_gut" = "1" ] && _lw=$((COLUMNS - 8))

	# Separators are decoration and must not be counted: an "8/20" that you
	# cannot actually move to row 20 of is worse than no counter.
	_seln=$(awk -F"$TABC" '$5 !~ /s/ {n++} END {print n + 0}' "$_f")

	_cur=${PF_MENU_INDEX:-0}
	[ "$_cur" -ge "$_count" ] && _cur=0
	[ "$_cur" -lt 0 ] && _cur=0
	_dir=down
	menu_skip_sep
	_off=0
	[ "$_cur" -ge "$_page" ] && _off=$((_cur - _page + 1))
	_prev=$_cur

	# The detail panel goes under the list, and only if the whole thing fits
	# without pushing the footer off the screen. A truncated synopsis is worse
	# than no synopsis.
	_note=""
	if [ -n "$PF_MENU_NOTE" ] && [ -s "$PF_MENU_NOTE" ]; then
		_nl=$(wc -l <"$PF_MENU_NOTE" | tr -d ' ')
		[ $((_top + _count + 1 + _nl)) -le $((LINES - 1)) ] && _note="$PF_MENU_NOTE"
	fi

	raw_on
	printf '\033[?25l' >/dev/tty
	_redraw=1

	while :; do
		if [ "$_redraw" = "1" ]; then
			# On long lists, show which letter block the cursor sits in.
			_badge=""
			if [ "$_gut" = "1" ]; then
				_badge=$(sed -n "$((_cur + 1))p" "$_f" | cut -f3)
				[ -n "$_badge" ] && _badge="[$_badge]"
			fi
			{
				_pos=$(awk -F"$TABC" -v c="$((_cur + 1))" \
					'NR<=c && $5 !~ /s/ {n++} END {print n + 0}' "$_f")
				printf '\033[H\033[2J'
				bar "$_title" "$_pos/$_seln" 1

				# "right" is right-aligned (year, progress, seen) so the eye can
				# scan one column instead of hunting inside titles.
				sed -n "$((_off + 1)),$((_off + _page))p" "$_f" |
					awk -F"$TABC" -v cur="$_cur" -v off="$_off" -v top="$_top" \
						-v lw="$_lw" -v gut="$_gut" -v cols="$COLUMNS" \
						-v sel="$C_SEL" -v acc="$C_ACC" -v ok="$C_OK" \
						-v ttl="$C_TITLE" -v dim="$C_DIM" -v off_="$C_OFF" '
					{
					  label = (NF > 1) ? $2 : $1
					  right = (NF > 3) ? $4 : ""
					  flags = (NF > 4) ? $5 : ""
					  idx   = off + NR - 1
					  printf "\033[%d;1H\033[K", top + NR - 1

					  if (index(flags, "s")) {
					    rule = ""
					    while (length(rule) < lw + 2) rule = rule "-"
					    printf "  %s%s%s", dim, rule, off_
					    next
					  }

					  mark = " "; mcol = ""
					  if (index(flags, "d"))      { mark = "+"; mcol = ok }
					  else if (index(flags, "q")) { mark = "."; mcol = acc }

					  avail = lw - (length(right) ? length(right) + 2 : 0)
					  disp  = label
					  if (length(disp) > avail) disp = substr(disp, 1, avail - 2) ".."
					  # Pad by hand: busybox awk rejects "%-*s" outright with
					  # "%*x formats are not supported".
					  while (length(disp) < avail) disp = disp " "
					  rpad = ""
					  if (length(right)) {
					    rpad = right
					    while (length(rpad) < length(right) + 2) rpad = " " rpad
					  }

					  if (idx == cur) {
					    printf " %s>%s%s%s %s", sel, mark, disp, rpad, off_
					  } else {
					    # A watched title recedes to plain white; the right-hand
					    # column is always secondary and always dim.
					    tc = index(flags, "w") ? dim : ttl
					    printf "  %s%s%s%s%s%s%s%s%s", \
					      mcol, mark, off_, tc, disp, off_, dim, rpad, off_
					  }

					  # Field 3 is the sort initial, supplied only by real
					  # content rows -- so Back/Jump never get a marker.
					  if (gut && NF > 2 && $3 != "" && $3 != "-") {
					    if ($3 != prev) printf "\033[%d;%dH%s%s%s", top + NR - 1, cols - 1, acc, $3, off_
					    prev = $3
					  }
					}'

				if [ -n "$_note" ]; then
					_nr=$((_top + _count + 1))
					# The `|| [ -n ... ]` matters: a panel built with fold(1)
					# from a summary has no trailing newline, and plain `read`
					# silently drops that last line -- which reads as a synopsis
					# that stops mid-sentence.
					while IFS= read -r _nline || [ -n "$_nline" ]; do
						printf '\033[%s;3H\033[K%s%s%s' \
							"$_nr" "$C_DIM" "$(fit "$_nline" $((COLUMNS - 4)))" "$C_OFF"
						_nr=$((_nr + 1))
					done <"$_note"
				fi

				bar "$_hint" "$_badge" "$LINES"
			} >/dev/tty
			_redraw=0
		fi

		_prev=$_cur
		_full=1
		_key=$(read_key)
		case "$_key" in
		UP)
			if [ "$_cur" -gt 0 ]; then _cur=$((_cur - 1)); else _cur=$((_count - 1)); fi
			_dir=up; menu_skip_sep
			# menu_skip_sep only ever steps over separators, which are not
			# counted, so a single move changes the position by exactly one
			# selectable row. Tracking it costs no process; recomputing it with
			# awk on every keypress did.
			if [ "$_pos" -gt 1 ]; then _pos=$((_pos - 1)); else _pos=$_seln; fi
			_full=0
			_redraw=1 ;;
		DOWN)
			if [ "$_cur" -lt $((_count - 1)) ]; then _cur=$((_cur + 1)); else _cur=0; fi
			_dir=down; menu_skip_sep
			if [ "$_pos" -lt "$_seln" ]; then _pos=$((_pos + 1)); else _pos=1; fi
			_full=0
			_redraw=1 ;;
		LEFT | PGUP)
			# On a long list, left/right move between letter blocks rather
			# than by page: 638 shows is 30+ page presses but at most a
			# handful of letter hops. The shoulder buttons can't help here --
			# L1 is a bare modifier that emits nothing and R1 is Back -- so
			# these are the only keys available for it.
			if [ "$_gut" = "1" ]; then
				_cl=$(sed -n "$((_cur + 1))p" "$_f" | cut -f3)
				_bs=$(awk -F"$TABC" -v c="$((_cur + 1))" -v L="$_cl" \
					'NR<=c && $3==L {print NR; exit}' "$_f")
				if [ -n "$_bs" ] && [ "$((_cur + 1))" -gt "$_bs" ]; then
					_cur=$((_bs - 1))
				elif [ -n "$_bs" ] && [ "$_bs" -gt 1 ]; then
					_pl=$(sed -n "$((_bs - 1))p" "$_f" | cut -f3)
					_ps=$(awk -F"$TABC" -v L="$_pl" \
						'$3==L {print NR; exit}' "$_f")
					[ -n "$_ps" ] && _cur=$((_ps - 1)) || _cur=0
				else
					_cur=0
				fi
			else
				_cur=$((_cur - _page))
			fi
			[ "$_cur" -lt 0 ] && _cur=0
			_dir=up; menu_skip_sep
			_redraw=1 ;;
		RIGHT | PGDN)
			if [ "$_gut" = "1" ]; then
				_cl=$(sed -n "$((_cur + 1))p" "$_f" | cut -f3)
				_nx=$(awk -F"$TABC" -v c="$((_cur + 1))" -v L="$_cl" \
					'NR>c && $3!="" && $3!=L {print NR; exit}' "$_f")
				if [ -n "$_nx" ]; then _cur=$((_nx - 1))
				else _cur=$((_count - 1)); fi
			else
				_cur=$((_cur + _page))
			fi
			[ "$_cur" -gt $((_count - 1)) ] && _cur=$((_count - 1))
			_dir=down; menu_skip_sep
			_redraw=1 ;;
		BACK)
			raw_off
			# Deliberately no clear and no cursor here.
			#
			# Every screen begins by clearing and drawing itself, so wiping on
			# the way out only buys a window of empty screen with a block
			# cursor blinking in the corner -- which is precisely what the gap
			# between two screens looked like, and what made a menu choice feel
			# like the app had gone away and come back. Leaving the old screen
			# up means the wait shows the list you were just on, with
			# "Loading..." along the bottom, and the new screen replaces it in
			# one paint. The cursor stays hidden until main()'s exit trap.
			PF_MENU_INDEX=$_cur
			printf '%s' "$_cur" >"$PF_MENU_AT"
			# One screen's detail panel must never bleed into the next.
			PF_MENU_NOTE=""
			rm -f "$_f"
			printf 'BACK'
			return 0 ;;
		OK)
			_sel=$(sed -n "$((_cur + 1))p" "$_f")
			raw_off
			PF_MENU_INDEX=$_cur
			printf '%s' "$_cur" >"$PF_MENU_AT"
			# One screen's detail panel must never bleed into the next.
			PF_MENU_NOTE=""
			rm -f "$_f"
			case "$_sel" in
			*"$TABC"*) printf '%s' "${_sel%%"$TABC"*}" ;;
			*) printf '%s' "$_sel" ;;
			esac
			return 0 ;;
		esac

		# Keep the selection inside the visible window.
		_scrolled=0
		[ "$_cur" -lt "$_off" ] && { _off=$_cur; _scrolled=1; }
		[ "$_cur" -ge $((_off + _page)) ] && { _off=$((_cur - _page + 1)); _scrolled=1; }

		# If the window did not move, only two rows changed: the one the cursor
		# left and the one it arrived on. Repaint those instead of clearing the
		# screen and redrawing all of it. Letter jumps take the full path --
		# they move an arbitrary distance, which the incremental position
		# counter above cannot follow.
		if [ "$_redraw" = "1" ] && [ "$_full" = "0" ] &&
			[ "$_scrolled" = "0" ] && [ "$_prev" != "$_cur" ]; then
			_badge=""
			if [ "$_gut" = "1" ]; then
				_badge=$(sed -n "$((_cur + 1))p" "$_f" | cut -f3)
				[ -n "$_badge" ] && _badge="[$_badge]"
			fi
			{
				menu_draw_rows "$_prev" "$_cur"
				bar "$_title" "$_pos/$_seln" 1
				bar "$_hint" "$_badge" "$LINES"
			} >/dev/tty
			_redraw=0
		fi
	done
}

# ---------------------------------------------------------------------------
# pf_panes -- the two-column picker the home screen is built from.
#
#   pf_panes <leftFile> <rightFile> <title> <hint>
#
# Both files carry pf_menu's row format: payload, label, sortLetter (unused
# here), right, flags. Two flags matter beyond the usual ones:
#
#   s  separator -- a rule the cursor skips
#   h  header    -- a group title in the right pane. Drawn in the accent
#                   colour, skipped by the cursor, and the reason this exists:
#                   it is what lets one scrolling column hold "CONTINUE
#                   WATCHING" and three "RECENTLY ADDED - <library>" groups the
#                   way every other Plex client stacks its rows.
#
# Why two panes at all: a single column on a 29-row screen spends most of its
# height on the library list, which never changes, and leaves no room for the
# rows you actually came to look at. Splitting them puts the libraries in a rail
# that costs 14 columns and gives the whole height back to content.
#
# Left/right switch panes; up/down move inside one. Those keys are free here
# precisely because this screen has no long list to page through -- the same
# reason the Ready-to-play card can use them for subtitles.
#
# Prints the selected payload, or BACK.
# ---------------------------------------------------------------------------
PF_PANE_AT="$PF_RUN/panes.idx"

# side, left index, right index -- remembered across screens and across
# playback, for the same reason pf_menu_at exists.
pf_panes_state() {
	PF_PANE_SIDE=0; PF_PANE_L=0; PF_PANE_R=0
	[ -r "$PF_PANE_AT" ] || return 0
	read -r _ps _pl _pr <"$PF_PANE_AT" 2>/dev/null
	case "$_ps$_pl$_pr" in
	'' | *[!0-9]*) ;;
	*) PF_PANE_SIDE=$_ps; PF_PANE_L=$_pl; PF_PANE_R=$_pr ;;
	esac
	unset _ps _pl _pr
}

# panes_draw <file> <off> <cur> <focused> <x> <w> <a> <b> <all>
#
# Paint rows a and b of one pane, or its whole visible window when all=1.
# Every row is padded to exactly w characters and printed at a fixed column:
# \033[K would clear to the end of the line and take the other pane with it.
panes_draw() {
	awk -F"$TABC" -v off="$2" -v cur="$3" -v foc="$4" -v x="$5" -v w="$6" \
		-v a="$7" -v b="$8" -v all="$9" -v top="$_top" -v page="$_page" \
		-v sel="$C_SEL" -v acc="$C_ACC" -v ok="$C_OK" -v ttl="$C_TITLE" \
		-v dim="$C_DIM" -v off_="$C_OFF" '
	{
	  idx = NR - 1
	  if (idx < off || idx >= off + page) next
	  if (!all && idx != a && idx != b) next
	  row = top + idx - off
	  label = (NF > 1) ? $2 : $1
	  right = (NF > 3) ? $4 : ""
	  flags = (NF > 4) ? $5 : ""

	  if (index(flags, "s")) {
	    rule = ""
	    while (length(rule) < w) rule = rule "-"
	    printf "\033[%d;%dH %s%s%s", row, x, dim, rule, off_
	    next
	  }

	  mark = " "; mcol = ""
	  if (index(flags, "d"))      { mark = "+"; mcol = ok }
	  else if (index(flags, "q")) { mark = "."; mcol = acc }

	  avail = w - (length(right) ? length(right) + 2 : 0)
	  disp = label
	  if (length(disp) > avail) disp = substr(disp, 1, avail - 2) ".."
	  while (length(disp) < avail) disp = disp " "
	  rpad = ""
	  if (length(right)) {
	    rpad = right
	    while (length(rpad) < length(right) + 2) rpad = " " rpad
	  }

	  # A header names the group under it and is never selected, so it never
	  # takes the cursor highlight even when the cursor is on this side.
	  if (index(flags, "h")) {
	    printf "\033[%d;%dH %s%s%s%s", row, x, acc, disp, rpad, off_
	    next
	  }

	  if (idx == cur && foc == 1) {
	    printf "\033[%d;%dH%s%s%s%s%s", row, x, sel, mark, disp, rpad, off_
	  } else if (idx == cur) {
	    # The unfocused pane still shows where it will resume, underlined
	    # rather than reversed so there is never a question which side has the
	    # keys.
	    printf "\033[%d;%dH%s%s%s\033[4m%s%s%s%s%s", row, x, mcol, mark, off_, \
	      disp, off_, dim, rpad, off_
	  } else {
	    tc = index(flags, "w") ? dim : ttl
	    printf "\033[%d;%dH%s%s%s%s%s%s%s%s%s", row, x, mcol, mark, off_, \
	      tc, disp, off_, dim, rpad, off_
	  }
	}' "$1"
}

# Step the cursor off a separator or a header, in the direction of travel.
# Operates on pf_panes locals, like menu_skip_sep does for pf_menu.
panes_skip() {
	_ps=0
	while [ "$_ps" -lt "$_pn" ]; do
		case "$(sed -n "$((_pc + 1))p" "$_pf" | cut -f5)" in
		*s* | *h*) ;;
		*) return 0 ;;
		esac
		if [ "$_pdir" = "up" ]; then
			if [ "$_pc" -gt 0 ]; then _pc=$((_pc - 1)); else _pc=$((_pn - 1)); fi
		else
			if [ "$_pc" -lt $((_pn - 1)) ]; then _pc=$((_pc + 1)); else _pc=0; fi
		fi
		_ps=$((_ps + 1))
	done
	unset _ps
}

pf_panes() {
	_lf="$1"; _rf="$2"; _ptitle="$3"; _phint="${4:-A select | L/R switch | MENU quit}"

	_ln=$(wc -l <"$_lf" | tr -d ' ')
	_rn=0
	[ -s "$_rf" ] && _rn=$(wc -l <"$_rf" | tr -d ' ')
	[ "$_ln" -eq 0 ] && return 1

	term_size
	_top=3
	_page=$((LINES - 2 - _top))
	[ "$_page" -lt 1 ] && _page=1

	# The rail is sized to its own contents, within reason: wide enough for
	# "Browse by letter", never wide enough to squeeze the titles opposite.
	_lw=$(awk -F"$TABC" '{
		n = length($2) + (length($4) ? length($4) + 2 : 0)
		if (n > m) m = n
	} END {print m + 0}' "$_lf")
	[ "$_lw" -lt 10 ] && _lw=10
	[ "$_lw" -gt 18 ] && _lw=18
	_lx=2
	_div=$((_lx + _lw + 2))
	_rx=$((_div + 2))
	_rw=$((COLUMNS - _rx - 1))
	if [ "$_rw" -lt 16 ]; then
		_lw=$((_lw - (16 - _rw)))
		[ "$_lw" -lt 8 ] && _lw=8
		_div=$((_lx + _lw + 2)); _rx=$((_div + 2)); _rw=$((COLUMNS - _rx - 1))
	fi

	pf_panes_state
	_side=$PF_PANE_SIDE
	_cl=$PF_PANE_L
	_cr=$PF_PANE_R
	[ "$_cl" -ge "$_ln" ] && _cl=0
	[ "$_rn" -eq 0 ] && _side=0
	[ "$_cr" -ge "$_rn" ] && _cr=0

	# Land the cursor somewhere selectable in both panes before anything is
	# drawn: the right pane starts with a header, always.
	_pf="$_lf"; _pn=$_ln; _pc=$_cl; _pdir=down; panes_skip; _cl=$_pc
	if [ "$_rn" -gt 0 ]; then
		_pf="$_rf"; _pn=$_rn; _pc=$_cr; _pdir=down; panes_skip; _cr=$_pc
	fi

	_offl=0; _offr=0
	[ "$_cl" -ge "$_page" ] && _offl=$((_cl - _page + 1))
	[ "$_cr" -ge "$_page" ] && _offr=$((_cr - _page + 1))

	raw_on
	printf '\033[?25l' >/dev/tty
	_full=1

	while :; do
		# Which side has the keys, as plain values: this is read on every
		# repaint and a `$(... && echo 1)` would be a fork each time.
		if [ "$_side" = "0" ]; then _focl=1; _focr=0; else _focl=0; _focr=1; fi

		if [ "$_full" = "1" ]; then
			{
				printf '\033[H\033[2J'
				bar "$_ptitle" "" 1
				# The rule between the panes, drawn once per full repaint.
				_dr=$_top
				while [ "$_dr" -le $((LINES - 2)) ]; do
					printf '\033[%s;%sH%s|%s' "$_dr" "$_div" "$C_DIM" "$C_OFF"
					_dr=$((_dr + 1))
				done
				panes_draw "$_lf" "$_offl" "$_cl" "$_focl" "$_lx" "$_lw" -1 -1 1
				[ "$_rn" -gt 0 ] &&
					panes_draw "$_rf" "$_offr" "$_cr" "$_focr" "$_rx" "$_rw" -1 -1 1
				bar "$_phint" "" "$LINES"
			} >/dev/tty
			_full=0
		fi

		_prevl=$_cl; _prevr=$_cr; _prevside=$_side
		_key=$(read_key)
		case "$_key" in
		UP | DOWN | PGUP | PGDN)
			if [ "$_side" = "0" ]; then _pf="$_lf"; _pn=$_ln; _pc=$_cl
			else _pf="$_rf"; _pn=$_rn; _pc=$_cr; fi
			if [ "$_pn" -gt 0 ]; then
				case "$_key" in
				UP | PGUP)
					if [ "$_pc" -gt 0 ]; then _pc=$((_pc - 1)); else _pc=$((_pn - 1)); fi
					_pdir=up ;;
				*)
					if [ "$_pc" -lt $((_pn - 1)) ]; then _pc=$((_pc + 1)); else _pc=0; fi
					_pdir=down ;;
				esac
				panes_skip
				if [ "$_side" = "0" ]; then _cl=$_pc; else _cr=$_pc; fi
			fi ;;
		LEFT) _side=0 ;;
		RIGHT) [ "$_rn" -gt 0 ] && _side=1 ;;
		BACK)
			raw_off
			pf_panes_save "$_side" "$_cl" "$_cr"
			printf 'BACK'
			return 0 ;;
		OK)
			if [ "$_side" = "0" ]; then _sel=$(sed -n "$((_cl + 1))p" "$_lf")
			else _sel=$(sed -n "$((_cr + 1))p" "$_rf"); fi
			raw_off
			pf_panes_save "$_side" "$_cl" "$_cr"
			case "$_sel" in
			*"$TABC"*) printf '%s' "${_sel%%"$TABC"*}" ;;
			*) printf '%s' "$_sel" ;;
			esac
			return 0 ;;
		esac

		# Keep the cursor inside its own pane's window.
		_scr=0
		if [ "$_cl" -lt "$_offl" ]; then _offl=$_cl; _scr=1; fi
		if [ "$_cl" -ge $((_offl + _page)) ]; then _offl=$((_cl - _page + 1)); _scr=1; fi
		if [ "$_rn" -gt 0 ]; then
			if [ "$_cr" -lt "$_offr" ]; then _offr=$_cr; _scr=1; fi
			if [ "$_cr" -ge $((_offr + _page)) ]; then _offr=$((_cr - _page + 1)); _scr=1; fi
		fi
		if [ "$_scr" = "1" ]; then
			_full=1
			continue
		fi

		# Nothing scrolled, so at most two rows changed: the one the cursor left
		# and the one it arrived on. Switching panes changes one row on each
		# side, which is the same two paints.
		if [ "$_side" = "0" ]; then _focl=1; _focr=0; else _focl=0; _focr=1; fi
		{
			if [ "$_prevside" = "$_side" ]; then
				if [ "$_side" = "0" ]; then
					panes_draw "$_lf" "$_offl" "$_cl" 1 "$_lx" "$_lw" "$_prevl" "$_cl" 0
				else
					panes_draw "$_rf" "$_offr" "$_cr" 1 "$_rx" "$_rw" "$_prevr" "$_cr" 0
				fi
			else
				panes_draw "$_lf" "$_offl" "$_cl" "$_focl" "$_lx" "$_lw" "$_cl" "$_cl" 0
				[ "$_rn" -gt 0 ] &&
					panes_draw "$_rf" "$_offr" "$_cr" "$_focr" "$_rx" "$_rw" "$_cr" "$_cr" 0
			fi
			bar "$_ptitle" "" 1
		} >/dev/tty
	done
}

pf_panes_save() { printf '%s %s %s\n' "$1" "$2" "$3" >"$PF_PANE_AT"; }

# Full-screen message. Waits for A unless $2 is "nowait".
pf_msg() {
	term_size
	{
		printf '\033[H\033[2J'
		bar "PocketFlex" "" 1
		_r=3
		printf '%s\n' "$1" | while IFS= read -r _l; do
			printf '\033[%s;3H%s' "$_r" "$(fit "$_l" $((COLUMNS - 4)))"
			_r=$((_r + 1))
		done
	} >/dev/tty
	[ "$2" = "nowait" ] && return 0
	{
		bar "Press A to continue" "" "$LINES"
		printf '\033[?25l'
	} >/dev/tty
	raw_on
	while :; do
		case "$(read_key)" in OK | BACK) break ;; esac
	done
	raw_off
}

# Transient one-line status on the second-to-last row.
pf_status() {
	term_size
	printf '\033[%s;1H\033[K%s %s%s' \
		"$((LINES - 1))" "$C_HINT" "$(fit "$1" $((COLUMNS - 2)))" "$C_OFF" >/dev/tty
}

# ---------------------------------------------------------------------------
# pf_pinpad -- numeric entry for profile PINs.
#
# There is no keyboard, so a text `read` cannot work. Up/Down changes the digit
# under the cursor, Left/Right moves between digits, A confirms.
# ---------------------------------------------------------------------------
pf_pinpad() {
	_n=${2:-4}
	_pos=0
	_d0=0; _d1=0; _d2=0; _d3=0; _d4=0; _d5=0
	term_size
	raw_on
	printf '\033[?25l' >/dev/tty

	while :; do
		{
			printf '\033[H\033[2J'
			printf '%s %s%s\n\n' "$C_TITLE" "$1" "$C_OFF"
			printf '%s Up/Down = digit   Left/Right = move%s\n' "$C_HINT" "$C_OFF"
			# Digits rendered large, same as the sign-in code.
			_i=0; _str=""
			while [ "$_i" -lt "$_n" ]; do
				eval "_v=\$_d$_i"
				_str="$_str$_v"
				_i=$((_i + 1))
			done
			big_text "$_str" 5
			# Underline the digit being edited.
			printf '\033[11;1H\033[K  '
			_i=0
			while [ "$_i" -lt "$_n" ]; do
				if [ "$_i" -eq "$_pos" ]; then printf '%s^^^^^%s ' "$C_ACC" "$C_OFF"
				else printf '      '; fi
				_i=$((_i + 1))
			done
			printf '\033[%s;1H%s A = confirm%s' "$LINES" "$C_HINT" "$C_OFF"
		} >/dev/tty

		case "$(read_key)" in
		UP)   eval "_v=\$_d$_pos"; _v=$(((_v + 1) % 10)); eval "_d$_pos=$_v" ;;
		DOWN) eval "_v=\$_d$_pos"; _v=$(((_v + 9) % 10)); eval "_d$_pos=$_v" ;;
		LEFT)  [ "$_pos" -gt 0 ] && _pos=$((_pos - 1)) ;;
		RIGHT) [ "$_pos" -lt $((_n - 1)) ] && _pos=$((_pos + 1)) ;;
		OK)
			raw_off
			printf '\033[?25h\033[2J\033[H' >/dev/tty
			_i=0; _out=""
			while [ "$_i" -lt "$_n" ]; do
				eval "_out=\$_out\$_d$_i"
				_i=$((_i + 1))
			done
			printf '%s' "$_out"
			return 0
			;;
		esac
	done
}
