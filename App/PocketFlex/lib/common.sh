#!/bin/sh
# PocketFlex - shared environment, HTTP helpers, settings store.
# POSIX sh only (busybox ash on the Miyoo Mini Plus). No bashisms.

PF_DIR="${PF_DIR:-/mnt/SDCARD/App/PocketFlex}"
PF_SYS="${PF_SYS:-/mnt/SDCARD/.tmp_update}"
PF_MIYOO="${PF_MIYOO:-/mnt/SDCARD/miyoo}"
PF_DATA="$PF_DIR/data"
PF_RUN="/tmp/pocketflex"
PF_LOG="$PF_DATA/pocketflex.log"

PF_SETTINGS="$PF_DATA/settings.json"
PF_CACERT="$PF_DIR/res/cacert.pem"
PF_CURLRC="$PF_RUN/curlrc"

PATH="$PF_SYS/bin:$PATH"
# miyoo/lib is named explicitly rather than inherited. Onion's runtime.sh does
# export it, so this looks redundant -- but `imgpop` links libSDL_ttf, which
# exists *only* there, and a binary that cannot resolve a library dies at the
# dynamic loader with no output at all. Depending on a launcher's environment
# for that is a silent "the splash never appeared" waiting to happen.
LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$PF_MIYOO/lib:$PF_SYS/lib:$PF_SYS/lib/parasyte"
export PATH LD_LIBRARY_PATH

mkdir -p "$PF_DATA" "$PF_RUN" 2>/dev/null

PF_PRODUCT="PocketFlex"
PF_VERSION="0.4.2"
# X-Plex-Platform MUST be a platform the server has a built-in client profile
# for. Verified against Plex 1.43.2: "Linux" makes every
# /video/:/transcode/universal/* request fail with a bare 400 Bad Request and
# no explanation, while "Chrome" works. Product/Device below stay honest, so
# the device still shows up as PocketFlex in Plex's device list.
PF_PLATFORM="Chrome"
PF_DEVICE="Miyoo Mini Plus"

# Physical panel. Used to letterbox rather than stretch widescreen material.
PF_PANEL_W=640
PF_PANEL_H=480

TABC=$(printf '\t')

# Separator inside a *field*. Downloads remember where they were found -- the
# library, the show and the season -- and that path lives in one column of a
# tab-separated index, so it needs a joiner that cannot occur in a title and
# cannot be confused with the column separator. US (0x1f) is the one character
# in ASCII whose entire job is this, and Plex will never return it in a title.
PSEP=$(printf '\037')

# path_join <existing> <segment> -- appends, skipping empty segments.
# Tabs and separators are stripped from the segment with shell pattern
# replacement rather than `tr`, so joining a three-level path costs no
# processes at all.
path_join() {
	_pj="$2"
	case "$_pj" in
	*"$TABC"* | *"$PSEP"*) _pj=$(printf '%s' "$_pj" | tr "$TABC$PSEP" '  ') ;;
	esac
	if [ -z "$_pj" ]; then printf '%s' "$1"
	elif [ -z "$1" ]; then printf '%s' "$_pj"
	else printf '%s%s%s' "$1" "$PSEP" "$_pj"; fi
	unset _pj
}

# The last segment of a path, which is what a folder screen is called.
path_leaf() { printf '%s' "${1##*"$PSEP"}"; }

# A path as a human breadcrumb.
path_pretty() {
	printf '%s' "$1" | tr "$PSEP" '/' | sed 's|/| / |g'
}

# Queue a message for the interface to show. Playback runs after the terminal
# has exited, so errors there have nowhere to draw; ui.sh picks this up and
# displays it the next time it starts.
pf_notify() { printf '%s' "$1" >"$PF_RUN/notice"; }

log() {
	printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >>"$PF_LOG" 2>/dev/null
}

# Keep the log bounded; nobody ever cleans these up on a handheld.
if [ -f "$PF_LOG" ]; then
	_sz=$(wc -c <"$PF_LOG" 2>/dev/null || echo 0)
	[ "$_sz" -gt 262144 ] && : >"$PF_LOG"
	unset _sz
fi

# The client identifier must stay stable forever: regenerating it invalidates
# every token plex.tv ever issued us and silently breaks sign-in.
client_id() {
	if [ ! -s "$PF_DATA/client_id" ]; then
		_cid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
		[ -z "$_cid" ] && _cid="pocketflex-$(date +%s)-$$"
		printf '%s' "$_cid" >"$PF_DATA/client_id"
		unset _cid
	fi
	cat "$PF_DATA/client_id"
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# Defaults are deliberately conservative. This SoC decodes in software via an
# ffmpeg built with --disable-yasm (no assembly optimisations), so everything
# is transcoded down to panel resolution before it ever reaches the device.
pf_settings_init() {
	[ -s "$PF_SETTINGS" ] && return 0
	cat >"$PF_SETTINGS" <<'EOF'
{
  "resolution": "640x480",
  "bitrate": 2000,
  "subtitles": "on",
  "prefer_local": true,
  "allow_relay": false,
  "resume": true,
  "flip": true,
  "aspect": "letterbox",
  "show_controls": true,
  "dl_resolution": "480x320",
  "dl_bitrate": 720,
  "dl_pause_play": false,
  "dl_autodelete": false,
  "autoplay_next": true,
  "skip_intro": true,
  "home_continue": true,
  "home_recent": true,
  "home_rowsize": 5,
  "libs_hidden": "",
  "server_id": "",
  "server_name": "",
  "server_uri": ""
}
EOF
}

# Settings are read into shell variables once, not re-read per lookup.
#
# This is not a micro-optimisation. Every pf_get used to fork jq, and the
# settings screen alone does fifteen of them each time it redraws -- so
# changing any single option cost sixteen jq processes, each loading a
# dynamically linked binary off an SD card. That is the three-to-four second
# black screen with a block cursor in the corner that follows every choice, and
# it is entirely self-inflicted. In-memory it is zero processes.
#
# The file stays the source of truth across processes: launch.sh and dlworker
# each clear PF_S_LOADED when they need to see what the interface just wrote.
PF_S_LOADED=0

pf_settings_load() {
	PF_S_LOADED=1
	# @sh shell-quotes each value, so a server name containing a quote or a
	# space cannot become code in the eval below, and the key filter means only
	# valid identifiers are ever assigned to.
	_pfa=$(jq -r 'to_entries[]
		| select(.key | test("^[a-z_][a-z0-9_]*$"))
		| "PFS_\(.key)=\(.value | tostring | @sh)"' "$PF_SETTINGS" 2>/dev/null)
	[ -n "$_pfa" ] && eval "$_pfa"
	unset _pfa
}

pf_get() {
	[ "$PF_S_LOADED" = "1" ] || pf_settings_load
	eval "_v=\${PFS_$1-}"
	[ -z "$_v" ] && _v="$2"
	printf '%s' "$_v"
	unset _v
}

# pf_set <key> <value> [raw]  -- raw=1 writes value unquoted (numbers/booleans)
#
# The in-memory copy is updated first so the next pf_get is correct even if the
# card write fails; the file write is what makes the choice outlive the session.
pf_set() {
	[ "$PF_S_LOADED" = "1" ] || pf_settings_load
	eval "PFS_$1=\$2"
	_tmp="$PF_DATA/.settings.tmp"
	if [ "$3" = "1" ]; then
		jq --arg k "$1" --argjson v "$2" '.[$k]=$v' "$PF_SETTINGS" >"$_tmp" 2>/dev/null
	else
		jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$PF_SETTINGS" >"$_tmp" 2>/dev/null
	fi
	# An empty temp file means jq rejected something and its complaint went to
	# /dev/null, so the setting silently does not change while the in-memory
	# copy set above says it did -- the screen agrees with the user and the
	# file disagrees with both. That is a genuinely hard failure to see: an
	# abandoned text-size experiment wrote `pf_set text_size large 1` for a
	# string value, which makes `--argjson v large` a parse error, and the
	# symptom was a Settings row that did nothing at all with no clue anywhere.
	# Whatever the cause -- bad value, full card, read-only mount -- say so.
	if [ -s "$_tmp" ]; then
		mv "$_tmp" "$PF_SETTINGS"
	else
		rm -f "$_tmp"
		log "pf_set: $1 was not written (jq rejected the value '$2')"
	fi
	unset _tmp
}

# Quality is now only ever one of two panel-sized options. Older settings files
# may still hold 1280x720 from when that was offered; snap anything unknown
# back to the panel rather than asking the server for a size that cannot help.
pf_res_get() {
	case "$(pf_get "$1" "$2")" in
	480x320) printf '480x320' ;;
	*) printf '640x480' ;;
	esac
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
# Stock OnionOS scripts all use `curl -k` because the firmware ships no CA
# bundle. We bundle our own so the plex.tv token exchange is genuinely
# verified. Headers live in a curl config file to sidestep shell quoting
# entirely -- building header argv by hand is how these scripts usually break.
pf_curlrc_write() {
	{
		printf 'silent\n'
		printf 'location\n'
		printf 'connect-timeout = 10\n'
		printf 'max-time = 45\n'
		printf 'header = "X-Plex-Product: %s"\n' "$PF_PRODUCT"
		printf 'header = "X-Plex-Version: %s"\n' "$PF_VERSION"
		printf 'header = "X-Plex-Client-Identifier: %s"\n' "$(client_id)"
		printf 'header = "X-Plex-Platform: %s"\n' "$PF_PLATFORM"
		printf 'header = "X-Plex-Device: %s"\n' "$PF_DEVICE"
		printf 'header = "X-Plex-Device-Name: %s"\n' "$PF_PRODUCT"
		printf 'header = "Accept: application/json"\n'
		if [ "$PF_TLS" = "insecure" ]; then
			printf 'insecure\n'
		else
			printf 'cacert = "%s"\n' "$PF_CACERT"
		fi
	} >"$PF_CURLRC"
}

if [ -f "$PF_CACERT" ]; then PF_TLS="verified"; else PF_TLS="insecure"; fi
pf_curlrc_write

# pf_curl <curl args...> -- prints body, returns curl's exit status
pf_curl() {
	_out=$(curl -K "$PF_CURLRC" "$@" 2>>"$PF_LOG")
	_rc=$?
	# curl 60 = certificate problem. A handheld with a dead RTC will have a
	# bogus clock and fail verification; degrade rather than dead-end.
	if [ "$_rc" -eq 60 ] && [ "$PF_TLS" = "verified" ]; then
		log "TLS verification failed (curl 60); falling back to unverified"
		PF_TLS="insecure"
		pf_curlrc_write
		_out=$(curl -K "$PF_CURLRC" "$@" 2>>"$PF_LOG")
		_rc=$?
	fi
	printf '%s' "$_out"
	unset _out
	return "$_rc"
}

# URL-encode via jq: shell-only encoding costs two processes per character,
# which is visibly slow on this CPU for long titles and paths.
urlencode() {
	printf '%s' "$1" | jq -sRr '@uri' 2>/dev/null
}

# XML attribute extraction, for the v1 endpoints that only speak XML.
xml_attr() {
	printf '%s' "$2" | tr '>' '>\n' | grep -o "$1=\"[^\"]*\"" | head -1 |
		sed "s/^$1=\"//; s/\"$//"
}

pf_settings_init
