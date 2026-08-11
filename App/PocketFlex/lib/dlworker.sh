#!/bin/sh
# PocketFlex - background download worker.
#
# Started by launch.sh and lives as long as the app is open, so downloads keep
# running while you browse and while you watch. Leaving PocketFlex stops it --
# deliberately. A stray curl left transcoding on the server and holding the
# Wi-Fi awake after the user has gone back to Onion's menu would drain the
# battery for no reason they could see.
#
# It talks to the interface only through files:
#   cache/index.tsv     the queue and its states
#   /tmp/.../dl.pause   set while ffplay owns the screen, if the user asked for it
#   /tmp/.../dl.stop    set on app exit
#
# NOT RESUMABLE, on purpose. The universal transcode endpoint serves one
# continuous stream and honours no byte ranges, so there is no such thing as
# "carry on from 40 MB" -- a partial file can only be thrown away. Everything
# here is arranged around that: interrupted items go back to `queued` and the
# fragment is deleted.

PF_DIR="${PF_DIR:-/mnt/SDCARD/App/PocketFlex}"
. "$PF_DIR/lib/common.sh"
. "$PF_DIR/lib/plex.sh"
. "$PF_DIR/lib/cache.sh"

pf_cache_init

DL_STOP="$PF_RUN/dl.stop"
DL_PAUSE="$PF_RUN/dl.pause"
DL_NOW="$PF_RUN/dl.now"
# Set by the Wi-Fi screen while the radio is deliberately down. Without it,
# every queued item would spend a connect timeout failing and the whole queue
# would be marked failed by the time anyone looked at it.
DL_NONET="$PF_RUN/wifi.off"

cleanup() { rm -f "$DL_NOW"; exit 0; }
trap cleanup INT TERM

log "dlworker: started"

while :; do
	[ -f "$DL_STOP" ] && break

	if [ -f "$DL_PAUSE" ] || [ -f "$DL_NONET" ]; then
		rm -f "$DL_NOW"
		sleep 3
		continue
	fi

	row=$(pf_cache_next_queued) || { rm -f "$DL_NOW"; sleep 5; continue; }

	# This process outlives every run of the interface, so its cached settings
	# go stale the moment the user changes quality or subtitles. Re-read them
	# per download rather than per lookup: one jq at the head of a transfer
	# that runs for minutes is free, and it means each file is fetched at
	# whatever quality is currently set rather than whatever was set when the
	# worker started.
	PF_S_LOADED=0

	key=$(printf '%s' "$row" | cut -f1)
	title=$(printf '%s' "$row" | cut -f3)
	file=$(printf '%s' "$row" | cut -f6)

	# Credentials come from settings, not from the UI process -- the worker
	# outlives any single run of ui.sh and cannot be handed anything.
	uri=$(pf_get media_uri "")
	[ -z "$uri" ] && uri=$(plex_media_base "$(pf_get server_uri '')")
	tok=$(pf_get server_token "")
	if [ -z "$uri" ] || [ -z "$tok" ]; then
		log "dlworker: no server configured; waiting"
		sleep 15
		continue
	fi

	sess=$(pf_new_session)
	url=$(plex_download_url "$uri" "$tok" "$key" "$sess")
	out="$PF_CACHE/$file"

	pf_cache_set "$key" downloading
	printf '%s' "$key" >"$DL_NOW"
	log "dlworker: downloading $title"

	rm -f "$out.part"
	# max-time 0 cancels the 45s ceiling set in the shared curlrc; a feature
	# film takes far longer than that to transcode and fetch. The speed floor
	# is what catches a genuinely dead transfer instead: no meaningful bytes
	# for 90 seconds and we give up rather than hang forever.
	curl -K "$PF_CURLRC" \
		--max-time 0 \
		--speed-limit 2048 --speed-time 90 \
		-o "$out.part" "$url" >/dev/null 2>>"$PF_LOG" &
	cpid=$!

	# Poll rather than `wait`, so a stop or pause request is honoured within a
	# couple of seconds instead of at the end of a 40-minute download.
	interrupted=0
	while kill -0 "$cpid" 2>/dev/null; do
		if [ -f "$DL_STOP" ] || [ -f "$DL_PAUSE" ] || [ -f "$DL_NONET" ]; then
			interrupted=1
			kill "$cpid" 2>/dev/null
			break
		fi
		# The interface cancels a download by deleting its row.
		[ -z "$(pf_cache_state "$key")" ] && { interrupted=2; kill "$cpid" 2>/dev/null; break; }
		sleep 2
	done
	wait "$cpid" 2>/dev/null
	rc=$?
	rm -f "$DL_NOW"

	plex_transcode_stop "$uri" "$tok" "$sess"

	kb=$(wc -c <"$out.part" 2>/dev/null || echo 0)
	kb=$((${kb:-0} / 1024))

	if [ "$interrupted" = "2" ]; then
		rm -f "$out.part"
		log "dlworker: $title cancelled"
		continue
	fi
	if [ "$interrupted" = "1" ]; then
		rm -f "$out.part"
		pf_cache_set "$key" queued
		log "dlworker: $title interrupted at ${kb}KB; re-queued"
		continue
	fi

	# A transcode that dies early still leaves a valid-looking small file, so
	# size is the only honest success test we have -- curl exits 0 on a stream
	# the server truncated.
	if [ "$rc" = "0" ] && [ "$kb" -gt 256 ]; then
		mv "$out.part" "$out"
		pf_cache_set "$key" done "$kb"
		log "dlworker: finished $title ($kb KB)"
	else
		rm -f "$out.part"
		pf_cache_set "$key" failed "$kb"
		log "dlworker: FAILED $title (curl rc=$rc, ${kb}KB)"
	fi
done

rm -f "$DL_NOW"
log "dlworker: stopped"
