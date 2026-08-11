#!/bin/sh
# PocketFlex - offline cache.
#
# The point of this file: a handheld is used on trains and in bed, not next to
# the Plex server. Anything listed here plays with the Wi-Fi off.
#
# Downloads are *transcoded* copies, not the originals. A 3.5" 640x480 panel
# gains nothing from a 12 GB remux, and the SoC cannot decode one anyway, so
# the same universal-transcode endpoint that serves live playback writes a
# small file instead -- roughly 130 MB for a 24-minute episode at the default
# 720 kbps.
#
# STATE lives in one TSV index rather than a directory scan, because the index
# also has to remember *queued* items, which have no file yet.
#
#   1 ratingKey   2 state    3 title     4 durationMs  5 sizeKB
#   6 file        7 addedAt  8 showTitle 9 sortTitle  10 estKB
#  11 path        12 code
#
# state: queued | downloading | done | failed
#
# `path` is where the item was found -- "Anime<US>Dragon Ball Z<US>Season 3" --
# and it is what lets the Downloads screen be browsed the way the library it
# came from is browsed. A flat list is fine for six episodes and unusable for
# sixty, which is the size a card fills to. Rows written before v0.3.0 have no
# eleventh column; they read back as an empty path and sit at the top level,
# which is exactly where they were before, so there is nothing to migrate.
#
# `code` is "S03E05", and it is what makes a season folder sort into episode
# order rather than alphabetical order. Twenty-four episodes sorted by title is
# a list nobody can read down.
#
# Sizes are kept in KB. Bytes overflow 32-bit shell arithmetic on a feature
# film (a 2-hour download is ~6e9 bytes) and busybox ash cannot be relied on
# for 64-bit maths.

PF_CACHE="${PF_CACHE:-$PF_DIR/cache}"
PF_CACHE_IDX="$PF_CACHE/index.tsv"
PF_CACHE_LOCK="$PF_CACHE/.lock"

pf_cache_init() {
	mkdir -p "$PF_CACHE" 2>/dev/null
	[ -f "$PF_CACHE_IDX" ] || : >"$PF_CACHE_IDX"
}

# ---------------------------------------------------------------------------
# Index locking.
#
# The download worker and the interface both rewrite this file, and both do it
# read-modify-write. mkdir is the only atomic primitive busybox reliably gives
# us, so it is the lock. A stale lock is broken after ~15s rather than hanging
# the app forever -- a wedged download must never make the UI unusable.
# ---------------------------------------------------------------------------
pf_idx_lock() {
	_n=0
	while ! mkdir "$PF_CACHE_LOCK" 2>/dev/null; do
		_n=$((_n + 1))
		if [ "$_n" -gt 15 ]; then
			log "cache: breaking stale index lock"
			rm -rf "$PF_CACHE_LOCK" 2>/dev/null
			mkdir "$PF_CACHE_LOCK" 2>/dev/null
			break
		fi
		sleep 1
	done
	unset _n
}

pf_idx_unlock() { rmdir "$PF_CACHE_LOCK" 2>/dev/null; }

# Replace the index atomically. Reads the new content from stdin.
pf_idx_write() {
	_t="$PF_CACHE/.index.tmp"
	cat >"$_t"
	mv "$_t" "$PF_CACHE_IDX"
	unset _t
}

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------
# pf_cache_state <ratingKey> -- prints queued|downloading|done|failed, or nothing
pf_cache_state() {
	[ -s "$PF_CACHE_IDX" ] || return 0
	awk -F"$TABC" -v k="$1" '$1==k {print $2; exit}' "$PF_CACHE_IDX"
}

# pf_cache_row <ratingKey> -- prints the whole row
pf_cache_row() {
	[ -s "$PF_CACHE_IDX" ] || return 0
	awk -F"$TABC" -v k="$1" '$1==k {print; exit}' "$PF_CACHE_IDX"
}

# pf_cache_file <ratingKey> -- absolute path, only if the download finished
pf_cache_file() {
	_r=$(pf_cache_row "$1")
	[ -z "$_r" ] && return 1
	[ "$(printf '%s' "$_r" | cut -f2)" = "done" ] || return 1
	_f=$(printf '%s' "$_r" | cut -f6)
	[ -z "$_f" ] && return 1
	[ -f "$PF_CACHE/$_f" ] || return 1
	printf '%s/%s' "$PF_CACHE" "$_f"
	unset _r _f
}

# pf_cache_rows [state] -- all rows, or only those in one state
pf_cache_rows() {
	[ -s "$PF_CACHE_IDX" ] || return 0
	if [ -n "$1" ]; then
		awk -F"$TABC" -v s="$1" '$2==s' "$PF_CACHE_IDX"
	else
		cat "$PF_CACHE_IDX"
	fi
}

pf_cache_count() {
	pf_cache_rows "$1" | awk 'END {print NR + 0}'
}

# Every key at or below a folder in the download tree. An empty path means the
# whole index, which is what makes "delete everything in here" one code path
# whether "here" is a season or the root.
pf_cache_keys_under() {
	[ -s "$PF_CACHE_IDX" ] || return 0
	awk -F"$TABC" -v cur="$1" -v sep="$PSEP" '
		cur == "" { print $1; next }
		$11 == cur { print $1; next }
		substr($11, 1, length(cur) + 1) == cur sep { print $1 }' "$PF_CACHE_IDX"
}

# Total KB actually on disk (finished downloads only).
pf_cache_size_kb() {
	[ -s "$PF_CACHE_IDX" ] || { echo 0; return 0; }
	awk -F"$TABC" '$2=="done" {n += $5} END {printf "%d", n + 0}' "$PF_CACHE_IDX"
}

# Free space on the card holding the cache, in KB.
pf_cache_free_kb() {
	df -k "$PF_CACHE" 2>/dev/null |
		awk 'NR==2 {n = $4} END {print n + 0}'
}

# Never fill the card to the last byte. There is no file manager on this device
# and no way to recover from a full card except by taking it out and putting it
# in a computer, which is exactly the situation someone downloading a series
# before a flight is not in.
PF_CACHE_FLOOR_KB=307200 # 300 MB

# pf_cache_room <estimatedKB> -- 0 if that would still leave the floor free.
pf_cache_room() {
	_fr=$(pf_cache_free_kb)
	[ $((_fr - ${1:-0})) -gt "$PF_CACHE_FLOOR_KB" ]
}

# pf_cache_next <ratingKey> -- the next finished download in the same folder.
#
# What autoplay uses with no network: same path, next episode code. Rows with
# no code (a film, or anything queued before v0.3.0) cannot be ordered and are
# deliberately not chained to.
pf_cache_next() {
	_r=$(pf_cache_row "$1")
	[ -z "$_r" ] && return 1
	_p=$(printf '%s' "$_r" | cut -f11)
	_c=$(printf '%s' "$_r" | cut -f12)
	[ -z "$_p" ] || [ -z "$_c" ] && return 1
	_n=$(awk -F"$TABC" -v p="$_p" -v c="$_c" '
		$2=="done" && $11==p && $12 != "" && $12 > c {
		  if (b == "" || $12 < bc) { b = $0; bc = $12 }
		}
		END {print b}' "$PF_CACHE_IDX")
	[ -z "$_n" ] && return 1
	printf '%s' "$_n"
	unset _r _p _c _n
}

# The first thing the worker should pick up.
pf_cache_next_queued() {
	[ -s "$PF_CACHE_IDX" ] || return 1
	_r=$(awk -F"$TABC" '$2=="queued" {print; exit}' "$PF_CACHE_IDX")
	[ -z "$_r" ] && return 1
	printf '%s' "$_r"
	unset _r
}

# ---------------------------------------------------------------------------
# Mutation
# ---------------------------------------------------------------------------
# Filenames carry the title so the cache folder is legible when the card is in
# a computer, and the ratingKey so they are unique and reversible.
pf_cache_name() {
	_s=$(printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_' | cut -c1-60)
	_s=$(printf '%s' "$_s" | sed 's/_*$//')
	[ -z "$_s" ] && _s="item"
	printf '%s-%s.mkv' "$_s" "$2"
	unset _s
}

# pf_cache_add <key> <title> <durationMs> <showTitle> <sortTitle> [path] [code]
# Returns 1 if the item was already queued or downloaded.
pf_cache_add() {
	pf_cache_init
	pf_idx_lock
	if awk -F"$TABC" -v k="$1" '$1==k {found=1} END {exit !found}' "$PF_CACHE_IDX"; then
		pf_idx_unlock
		return 1
	fi
	# Estimated size, in KB: (video + a nominal 128 kbps of audio) x runtime.
	# Only ever used to draw a progress bar, so it does not need to be exact --
	# but a download with no visible progress feels broken, and this is the only
	# way to have any, since the server never declares a Content-Length for a
	# stream it is still transcoding.
	_dur_s=$(( ${3:-0} / 1000 ))
	_est=$(( ($(pf_get dl_bitrate 720) + 128) * _dur_s / 8 ))
	[ "$_est" -lt 1 ] && _est=0
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$1" "queued" "$2" "${3:-0}" "0" \
		"$(pf_cache_name "$2" "$1")" "$(date +%s)" "$4" "$5" "$_est" "$6" "$7" \
		>>"$PF_CACHE_IDX"
	pf_idx_unlock
	log "cache: queued $2 (~${_est}KB)"
	unset _dur_s _est
	return 0
}

# pf_cache_set <key> <state> [sizeKB]
pf_cache_set() {
	pf_idx_lock
	awk -F"$TABC" -v OFS="$TABC" -v k="$1" -v s="$2" -v b="$3" '
		$1==k { $2 = s; if (b != "") $5 = b }
		{ print }' "$PF_CACHE_IDX" | pf_idx_write
	pf_idx_unlock
}

# Drop the row and the file with it.
pf_cache_remove() {
	_r=$(pf_cache_row "$1")
	[ -z "$_r" ] && return 1
	_f=$(printf '%s' "$_r" | cut -f6)
	pf_idx_lock
	awk -F"$TABC" -v k="$1" '$1!=k' "$PF_CACHE_IDX" | pf_idx_write
	pf_idx_unlock
	[ -n "$_f" ] && rm -f "$PF_CACHE/$_f" "$PF_CACHE/$_f.part" 2>/dev/null
	log "cache: removed $(printf '%s' "$_r" | cut -f3)"
	unset _r _f
	return 0
}

# Anything left mid-flight by a crash or a battery pull is not resumable: the
# transcode endpoint serves one continuous stream and does not honour byte
# ranges. Re-queue it and bin the fragment rather than leaving a row that
# claims to be downloading with nothing behind it.
pf_cache_recover() {
	pf_cache_init
	pf_cache_rows downloading | while IFS="$TABC" read -r k st ti du sz fi ad sh so es pa; do
		rm -f "$PF_CACHE/$fi.part" 2>/dev/null
		log "cache: re-queueing interrupted download $ti"
	done
	pf_idx_lock
	awk -F"$TABC" -v OFS="$TABC" '$2=="downloading" { $2="queued" } { print }' \
		"$PF_CACHE_IDX" | pf_idx_write
	pf_idx_unlock
}

# Bytes fetched so far for an in-flight download, in KB.
pf_cache_partial_kb() {
	_r=$(pf_cache_row "$1")
	[ -z "$_r" ] && { echo 0; return 0; }
	_f=$(printf '%s' "$_r" | cut -f6)
	_b=$(wc -c <"$PF_CACHE/$_f.part" 2>/dev/null || echo 0)
	echo $((${_b:-0} / 1024))
	unset _r _f _b
}

pf_human_kb() {
	_k=${1:-0}
	if [ "$_k" -ge 1048576 ]; then
		printf '%d.%d GB' $((_k / 1048576)) $(((_k % 1048576) * 10 / 1048576))
	elif [ "$_k" -ge 1024 ]; then
		printf '%d MB' $((_k / 1024))
	else
		printf '%d KB' "$_k"
	fi
	unset _k
}
