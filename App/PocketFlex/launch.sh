#!/bin/sh
# PocketFlex - OnionOS entry point.
#
# Owns the loop: run the interface inside `st`, and when it asks for playback,
# take over the framebuffer and run ffplay. The two cannot coexist -- both
# want SDL's video device -- which is why this alternates instead of nesting.

progdir=$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)
sysdir=/mnt/SDCARD/.tmp_update

export PF_DIR="$progdir"
export PF_SYS="$sysdir"

. "$progdir/lib/common.sh"

# ---------------------------------------------------------------------------
# Boot splash
# ---------------------------------------------------------------------------
# Everything before `st` is up draws nothing at all, so launching PocketFlex
# from Onion's menu began with a stretch of black panel. imgpop is Onion's own
# framebuffer blitter -- it mmaps /dev/fb0, blits an image and holds -- so the
# logo can be on screen from the first moment, before there is a terminal to
# draw a terminal splash into.
#
# The image is pre-composed at exactly 640x480 with the logo centred on black,
# because imgpop blits at an x/y offset and does no scaling or centring of its
# own. Being panel-sized also means it covers the launcher's last frame
# completely, so there is nothing to clear first. Keep content off the outer
# couple of pixels: the rotation below is done with SDL_gfx's general rotozoom,
# which sizes its output with ceil() and so returns 642x482 for a 180 that
# ought to be exact, and the overhang is clipped at the right and bottom.
#
# Three facts about imgpop, none of them documented anywhere and each of them a
# way to end up looking at a black screen. They are read out of the binary:
#
#   1. It links libSDL, libSDL_image, libSDL_ttf, libSDL_gfx, libpng and libz.
#      libSDL_ttf lives *only* in miyoo/lib, so anything short of the full
#      library path and it dies at the dynamic loader without printing a word.
#      common.sh now names that directory rather than inheriting it.
#   2. It rotates every image 180 degrees before blitting -- hard-coded,
#      `rotozoomSurface(img, 180.0, 1.0, 1)`. That is the same panel-versus-
#      framebuffer offset the `flip` setting compensates for in the video path,
#      which is why every icon Onion ships for it is authored upright. So a
#      unit that needs the flip wants the *upright* file handed to it, and the
#      selection below is the opposite of what it looks like it should be.
#   3. Its first argument is seconds of display, counted from *after* the image
#      is loaded. So the process outlives its own start-up cost by that much,
#      and asking for 0 seconds makes it exit without ever blitting.
#
# Which is where v0.2.1 went wrong: the splash was started in the background
# and killed a fraction of a second later at the top of the main loop. Before
# imgpop can put a single pixel down it has to load six shared libraries off an
# SD card, decode a 640x480 PNG and rotozoom it -- seconds on this SoC, not
# milliseconds. It lost that race every time, which is why the terminal splash
# was the only one ever seen and the logo appeared to be "not loading".
#
# So it now starts before the rest of start-up instead of after it, so the
# loading overlaps with our own; it is given a finite display time so it ends
# its own run; and it is waited for rather than killed. Waiting costs less than
# it sounds, because a dead imgpop leaves its last blit sitting in the
# framebuffer -- the logo stays on the panel for free while `st` starts up.
SPLASH_SECS=2     # seconds imgpop is asked to hold the logo up, after loading
SPLASH_CEILING=10 # a wedged blitter must never hold the boot up longer
SPLASH_OUT="$PF_RUN/imgpop.out"

splash_show() {
	[ -x "$sysdir/bin/imgpop" ] || return 0
	# The one setting we need, read without the settings machinery: pf_get
	# would fork jq, and that fork is time the logo is not on screen yet.
	# Default (no match, including no file at all) is flip=true, matching
	# common.sh -- and per (2) above that is the upright image.
	_simg="$progdir/res/splash.png"
	grep -q '"flip"[^,}]*false' "$PF_SETTINGS" 2>/dev/null &&
		_simg="$progdir/res/splash180.png"
	[ -f "$_simg" ] || return 0
	# imgpop's failures all go to *stdout* -- it reports them with printf, not
	# perror -- and it is silent when it works, so keeping both streams costs
	# nothing and is the difference between "the splash did not appear" and a
	# named reason. There is no way to see this screen from the desktop.
	"$sysdir/bin/imgpop" "$SPLASH_SECS" 0 "$_simg" 0 0 >"$SPLASH_OUT" 2>&1 &
	SPLASH_PID=$!
	SPLASH_T0=$(date +%s)
	log "boot splash $(basename "$_simg") via imgpop pid $SPLASH_PID"
	unset _simg
}

# st and imgpop both want SDL and the framebuffer, so the splash has to be gone
# before the terminal starts -- the same constraint that keeps ffplay and st
# from ever running at once. imgpop ends its own run after SPLASH_SECS, so this
# is normally just waiting for that; the watchdog exists only so that a blitter
# which wedges cannot hold the boot up indefinitely.
#
# The elapsed time is logged because it is the number that says whether
# SPLASH_SECS is set sensibly: it is imgpop's whole life, load time included,
# minus however much of it our own start-up work already covered.
splash_hide() {
	if [ -n "$SPLASH_PID" ]; then
		# The braces are there to carry the redirect: retiring the watchdog is
		# the shell reaping a job it started, and it announces that on stderr.
		# Everything inside here already routes its own errors.
		{
			(
				sleep "$SPLASH_CEILING"
				kill -9 "$SPLASH_PID"
			) &
			_wd=$!
			wait "$SPLASH_PID"
			_rc=$?
			kill "$_wd"
			wait "$_wd"
		} 2>/dev/null
		log "boot splash held the panel $(( $(date +%s) - SPLASH_T0 ))s, imgpop rc=$_rc"
		# A near-zero hold with something on stdout is a blitter that never
		# started: a library it could not resolve, or an image it could not
		# decode. Both are silent on the panel and indistinguishable from a
		# splash that simply was not reached.
		_msg=$(cat "$SPLASH_OUT" 2>/dev/null)
		[ -n "$_msg" ] && log "imgpop: $_msg"
		rm -f "$SPLASH_OUT"
		unset _wd _rc _msg
	fi
	killall -9 imgpop 2>/dev/null
	SPLASH_PID=""
}

SPLASH_PID=""
SPLASH_T0=0
splash_show

. "$progdir/lib/plex.sh"
. "$progdir/lib/cache.sh"

PF_REQ="$PF_RUN/play.req"
PF_QUIT="$PF_RUN/quit"
POSLOG="$PF_RUN/ffplay.err"
DL_STOP="$PF_RUN/dl.stop"
DL_PAUSE="$PF_RUN/dl.pause"

: >"$PF_RUN/stack"
rm -f "$PF_QUIT" "$DL_STOP" "$DL_PAUSE" "$PF_RUN/wifi.off"

log "=== PocketFlex $PF_VERSION starting ==="
log "clock reads $(date '+%Y-%m-%d %H:%M:%S')"

# The handheld has no battery-backed RTC, so it boots somewhere in 1979 and
# every TLS certificate looks "not yet valid" (curl exit 60). Nudging the clock
# lets certificate verification actually succeed instead of silently
# downgrading to an unverified connection. Best effort, never fatal.
if [ ! -f "$PF_RUN/.timeset" ]; then
	(
		for _srv in pool.ntp.org time.google.com time.cloudflare.com; do
			if "$sysdir/bin/ntpdate" -b -t 5 "$_srv" >/dev/null 2>&1; then
				log "clock synced from $_srv -> $(date '+%Y-%m-%d %H:%M:%S')"
				break
			fi
		done
		: >"$PF_RUN/.timeset"
	) &
fi

# ---------------------------------------------------------------------------
# Waking up
# ---------------------------------------------------------------------------
# Reported symptom: leave the device on the menu, it sleeps, press power to wake
# it, and the app is still on screen but nothing responds -- not the d-pad, not
# MENU. The only way out is to power the unit off.
#
# What is actually on screen after a wake is not proof the app is alive. This
# framebuffer keeps whatever was last written to it: that is the same property
# that lets a *dead* imgpop leave the boot logo on the panel while `st` starts
# (see the splash notes above). A frozen picture of the interface and a live
# interface look identical.
#
# The terminal is where this is recoverable. `st` is an SDL program that opens
# the input device once, at start-up; if that handle stops delivering events --
# because the driver was re-initialised underneath it, or because something else
# took the device while the screen was off -- there is nothing inside `st` or
# inside our script that can ask for it back. But this process is not `st`, and
# it can throw the terminal away and start a new one, which re-opens everything
# from scratch. The navigation stack and the cursor live in files, so the same
# screen comes back with the cursor where it was.
#
# Detecting the wake is deliberately two independent tests, because the exact
# sleep mechanism is Onion's and is not documented:
#
#   1. The backlight. Onion drives it through this PWM -- the path is read out
#      of `batmon` and `mainUiBatPerc`, which both carry it -- and sleeping
#      turns it off. Seeing it go dark and come back is a wake, whatever else
#      happened.
#   2. A gap in our own clock. If the process group was stopped (or the whole
#      system suspended), a 3-second sleep in this loop takes far longer than 3
#      seconds to come back from. That covers a sleep that never touches this
#      PWM at all.
#
# Both are logged with which one fired, so the next round on hardware can say
# what Onion actually does rather than guessing again.
BL_DUTY=/sys/devices/soc0/soc/1f003400.pwm/pwm/pwmchip0/pwm0/duty_cycle
BL_ENABLE=/sys/devices/soc0/soc/1f003400.pwm/pwm/pwmchip0/pwm0/enable
ST_RESTART="$PF_RUN/st.restart"

screen_is_off() {
	_bl_e=""; _bl_d=""
	[ -r "$BL_ENABLE" ] && read -r _bl_e <"$BL_ENABLE" 2>/dev/null
	[ -r "$BL_DUTY" ] && read -r _bl_d <"$BL_DUTY" 2>/dev/null
	[ "$_bl_e" = "0" ] && return 0
	[ "$_bl_d" = "0" ] && return 0
	return 1
}

# Watches while the terminal is up. $1 is st's pid.
resume_watchdog() {
	_wd_off=0
	_wd_last=$(date +%s)
	while kill -0 "$1" 2>/dev/null; do
		sleep 3
		_wd_now=$(date +%s)
		_wd_gap=$((_wd_now - _wd_last))
		_wd_last=$_wd_now

		if screen_is_off; then
			[ "$_wd_off" = "0" ] && log "resume: backlight went off"
			_wd_off=1
			continue
		fi
		if [ "$_wd_off" = "1" ]; then
			log "resume: backlight is back; restarting the terminal"
			: >"$ST_RESTART"
			kill "$1" 2>/dev/null
			return 0
		fi
		if [ "$_wd_gap" -gt 20 ]; then
			log "resume: ${_wd_gap}s passed in a 3s loop; restarting the terminal"
			: >"$ST_RESTART"
			kill "$1" 2>/dev/null
			return 0
		fi
	done
}

# Onion's own video player does this: without it the CPU sits at its idle
# governor and software decoding stutters badly.
set_performance() {
	echo performance >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
}
set_ondemand() {
	echo ondemand >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
}

# How far playback got, in seconds.
#
# Position is measured by wall clock, not by parsing the player. OnionOS's
# ffplay build prints no progress line at all -- the binary contains none of
# the "aq=" / "A-V:" / "fd=" format strings a normal ffplay has -- so an
# earlier build that parsed stderr recorded 0s for every session, including a
# 17-minute film, and silently saved no resume position ever.
#
# Elapsed time equals playback time as long as playback runs at 1x, which is
# the normal case. Pausing inflates the estimate, so the result is clamped to
# the item runtime by the caller. This is an approximation, but a correct-most
# -of-the-time resume point beats a guaranteed-wrong one.
played_seconds() {
	printf '%s' "${1:-0}"
}

play_media() {
	PF_LOCAL=""
	# shellcheck disable=SC1090
	. "$PF_REQ"
	rm -f "$PF_REQ"

	# The interface has been running since the last playback and may have
	# changed quality or subtitles; our in-memory copy predates that.
	PF_S_LOADED=0

	_sess=$(pf_new_session)
	_off_s=$((${PF_OFFSET_MS:-0} / 1000))
	_media=""
	_used="transcode"
	_seek=""
	_url=""

	# A downloaded copy short-circuits everything below: no server, no
	# transcode session, no plain-http endpoint to derive. This is the path
	# that has to work on a train, so it must not touch the network at all.
	if [ -n "$PF_LOCAL" ] && [ -f "$PF_LOCAL" ]; then
		_used="local"
		_url="$PF_LOCAL"
		[ "$_off_s" -gt 0 ] && _seek="-ss $_off_s"
		log "play $PF_TITLE from cache: $PF_LOCAL"
		play_file
		return $?
	fi

	# ffplay has no TLS backend, so media must come from the plain-http
	# endpoint even though the API talks https. See plex_media_base().
	_media=$(pf_get media_uri "")
	[ -z "$_media" ] && _media=$(plex_media_base "$PF_URI")
	if [ -z "$_media" ]; then
		log "no plain-http endpoint derivable from $PF_URI"
		pf_notify "This server is only reachable over a secure connection, and the device's player cannot use one. Pick a server on your local network in Settings."
		return 1
	fi

	_url=$(plex_transcode_url "$_media" "$PF_STOK" "$PF_KEY" "$_sess" "$_off_s")
	# The server starts the transcode at the offset, so no client seek.
	_code=$(plex_preflight "$_url")
	if [ "$_code" != "200" ]; then
		# A wedged Plex transcoder answers every start request with a bare 400
		# while /decision still cheerfully reports "Conversion OK", so there is
		# nothing to detect ahead of time; plex_preflight has already retried
		# three times over about ten seconds.
		#
		# This used to fall back to direct play, which was worse than
		# dead-ending: direct play does not work on this device at all. Two
		# device sessions in the log show it exiting after one and two seconds
		# on a 1080p remux and on a 848x480 500 kbps file alike, dropping
		# straight back to the launcher. Handing someone that as a "recovery"
		# just replaces a legible error with a mysterious bounce.
		log "transcode preflight failed HTTP $_code"
		plex_transcode_stop "$_media" "$PF_STOK" "$_sess"
		pf_notify "The server would not start a transcode (HTTP $_code) after three tries. Restarting Plex Media Server usually clears a stuck transcoder. Everything on this device is transcoded, so there is nothing to fall back to."
		return 1
	fi

	if [ -z "$_url" ]; then
		log "no playable URL for $PF_KEY"
		pf_notify "Could not build a stream URL for this item."
		return 1
	fi
	log "play $PF_TITLE mode=$_used offset=${_off_s}s session=$_sess"
	play_file
	return $?
}

# Run the player on whatever $_url points at -- a transcode stream, the
# original file, or a downloaded copy on the card -- then report where it got
# to. Shared so a cached file behaves exactly like a streamed one.
play_file() {
	# Video filters: fit the picture to the panel, then centre it.
	#
	# Plex returns the stream at the source aspect and no larger than the size
	# we asked for, so what arrives is rarely panel-sized: 16:9 material at the
	# 640x480 setting comes back 640x360, and at the 480x320 setting it comes
	# back 480x270. Padding alone -- which is all this used to do -- centres
	# whatever it is given on a 640x480 canvas, so a 480x270 stream landed as a
	# small picture with black bars on *all four* sides. That is exactly what a
	# downloaded episode looked like on the device: already letterboxed top and
	# bottom for being widescreen, and then pillarboxed left and right for
	# being small.
	#
	# So scale up to touch the panel on its limiting axis first. The scale
	# factor is the smaller of the two ratios, applied to both axes, which
	# preserves the aspect; results are truncated to even numbers because
	# yuv420p has half-resolution chroma planes and cannot represent an odd
	# width or height.
	#
	# Everything here is plain iw/ih arithmetic. libavfilter 5 (ffmpeg 2.8) is
	# what the firmware ships, and rather than gamble on whether its vf_scale
	# carries force_original_aspect_ratio -- the library lives in the device
	# rootfs and is not on the card to check -- this uses expression syntax
	# that has worked in every version. Single quotes are ffmpeg's own token
	# quoting, kept literal by the shell's double quotes, and they are what let
	# min()'s comma sit inside a filter argument unescaped.
	#
	# vf_scale short-circuits to a passthrough when input and output dimensions
	# match, so the common 640x360 case costs nothing at all; only the 480x320
	# quality setting actually pays for a resample.
	_fit="scale=w='trunc(iw*min($PF_PANEL_W/iw,$PF_PANEL_H/ih)/2)*2'"
	_fit="$_fit:h='trunc(ih*min($PF_PANEL_W/iw,$PF_PANEL_H/ih)/2)*2'"
	# Normalise pixel aspect afterwards: a downloaded file came back tagged SAR
	# 901:900, and ffplay applies SAR to size its window, which would re-inset
	# the very frame we just fitted to the panel.
	_fit="$_fit,setsar=1"

	if [ "$(pf_get aspect letterbox)" = "letterbox" ]; then
		_vf="$_fit,pad=$PF_PANEL_W:$PF_PANEL_H:($PF_PANEL_W-iw)/2:($PF_PANEL_H-ih)/2"
	else
		_vf="scale=$PF_PANEL_W:$PF_PANEL_H,setsar=1"
	fi
	[ "$(pf_get flip true)" = "true" ] && _vf="$_vf,hflip,vflip"

	# Force a stereo downmix before the audio ever reaches the device.
	#
	# The symptom this fixes is a film that plays in slow motion with no sound at
	# all, while another film of the same codec and resolution is perfectly fine.
	# It is not a transcoding failure: the log proves the video was transcoded in
	# both cases (480x200 for "The Bad Guys", 480x260 for "Robots"). The
	# difference is the *audio*.
	#
	# X-Plex-Platform is "Chrome", because that is the only built-in profile the
	# server will start a transcode for at all (see common.sh). Chrome can decode
	# multichannel AAC, so Plex's Chrome profile treats AAC 5.1 as something the
	# client handles and passes it straight through untouched, however small a
	# picture it is wrapping. Probing the real server with our exact parameters
	# shows it plainly:
	#
	#   The Bad Guys (source AAC 5.1) -> video h264 480x200, audio aac 6ch 5.1
	#   Robots       (source DTS 5.1) -> video h264 480x260, audio mp3 2ch stereo
	#
	# Robots only worked by luck: DTS is *not* in the Chrome profile, so its audio
	# had to be transcoded, and transcoding is what makes it stereo. Anything
	# whose source is already AAC 5.1 arrives as 5.1 -- and on this library that
	# is most of it.
	#
	# The device cannot play that. ffplay here is an ffmpeg 2.8 build against an
	# SDL that opens a stereo device ("init audio 20" in the log); handed six
	# channels, the audio path stalls, and a stalled audio clock is what drags the
	# video into slow motion. No sound and half speed are one bug, not two.
	#
	# Asking the server to fix it does not work: `maxAudioChannels=2` is rejected
	# with a bare 400 by Plex 1.43.2 on this path, and a client-profile override
	# is one more thing to get wrong on a server we do not control. Doing it in
	# the filter graph is unconditional, needs nothing from the server, and covers
	# already-downloaded files -- which were fetched through the same parameters
	# and therefore have the same 5.1 audio baked in.
	#
	# aformat is the portable spelling. The swresample-style options (ocl,
	# out_channel_layout) exist in ffmpeg 2.8 but were removed later, so a filter
	# written that way could not be tested anywhere but the device; aformat has
	# been in libavfilter throughout and is a no-op when the audio is already
	# stereo.
	_af="aformat=channel_layouts=stereo"

	set_performance
	touch /tmp/stay_awake
	: >"$POSLOG"
	# Downloading and decoding at once is a lot to ask of two 1.2 GHz cores on
	# a shared Wi-Fi link. Pausing is opt-in because it discards the partial
	# file -- the transcode endpoint has no byte-range resume to come back to.
	[ "$(pf_get dl_pause_play false)" = "true" ] && : >"$DL_PAUSE"
	_t0=$(date +%s)

	# Identity travels in the URL query, so no -headers plumbing is needed.
	#
	# -vf is passed quoted, and must be: the filter now contains `*`, and an
	# unquoted expansion would be handed to pathname expansion on its way to
	# argv. Only $_seek is left to split, and it is either empty or "-ss 123".
	# shellcheck disable=SC2086
	"$sysdir/bin/ffplay" \
		-autoexit \
		-loglevel info \
		-vf "$_vf" \
		-af "$_af" \
		$_seek \
		-i "$_url" 2>"$POSLOG"
	_prc=$?

	_elapsed=$(( $(date +%s) - _t0 ))
	rm -f /tmp/stay_awake "$DL_PAUSE"
	set_ondemand

	[ "$_used" = "transcode" ] && plex_transcode_stop "$_media" "$PF_STOK" "$_sess"

	_secs=$(played_seconds "$_elapsed")
	log "ffplay ran ${_elapsed}s"

	# Record what was actually decoded. This is the only unambiguous evidence
	# of whether the server really transcoded: a line reading "h264 640x346"
	# proves it did, while "hevc 1920x1080" would mean the original file came
	# through untouched and the CPU was doing far more work than intended.
	#
	# The old expression cut at the first "(" to drop the profile, which also
	# removed everything after it -- every real log line read "decoded stream:
	# h264" with no resolution, i.e. it proved nothing at all. Strip only the
	# parenthesised groups.
	_stream=$(grep -m1 'Video:' "$POSLOG" 2>/dev/null |
		sed 's/.*Video: //; s/([^)]*)//g; s/ ,/,/g; s/  */ /g; s/^ //' | cut -c1-70)
	[ -n "$_stream" ] && log "decoded stream: $_stream"

	# The audio line is the other half of that evidence, and until now it was
	# never recorded -- which is why a film arriving with 5.1 audio the device
	# cannot play looked, in the log, exactly like one that played perfectly.
	# What matters here is the channel count: "stereo" means the downmix filter
	# did its job, "5.1" means it did not.
	_astream=$(grep -m1 'Audio:' "$POSLOG" 2>/dev/null |
		sed 's/.*Audio: //; s/([^)]*)//g; s/ ,/,/g; s/  */ /g; s/^ //' | cut -c1-70)
	[ -n "$_astream" ] && log "decoded audio: $_astream"

	# ffplay dying mid-stream is not the same event as reaching the end, and the
	# difference is worth having in the log: seeking past the end of a transcode
	# is one way to make it happen (the seek keys are ffplay's own and jump in
	# ten-minute strides), and the last frame stays on the panel afterwards
	# either way, so the screen alone does not say which occurred.
	[ "${_prc:-0}" -ne 0 ] && log "ffplay exited rc=$_prc after ${_elapsed}s"

	# The home screen's content rows are a cache with a TTL; watching something
	# is precisely the event that makes Continue Watching wrong.
	rm -f "$PF_RUN/home.cache" "$PF_RUN"/view.*

	# Never report progress for a player that died on startup: an earlier build
	# scrobbled three episodes as watched when ffplay exited instantly on an
	# https URL it could not open.
	if [ "$_elapsed" -lt 15 ]; then
		pf_notify "Playback stopped almost immediately. Nothing was marked as watched. See data/pocketflex.log for details."
		log "too short to count as playback; leaving watch state untouched"
		return 0
	fi

	# Clamp: the parsed value is best-effort and must never exceed the runtime.
	_dur_s=$((${PF_DURATION_MS:-0} / 1000))
	[ "$_dur_s" -gt 0 ] && [ "$_secs" -gt "$_dur_s" ] && _secs=$_dur_s

	_pos_ms=$(( (_off_s + _secs) * 1000 ))

	# "Finished" is the same 90% test the scrobble already used, promoted to a
	# variable because two more things now hang off it. Both must be false when
	# somebody stops halfway: nothing is deleted, and nothing starts playing on
	# its own.
	_finished=0
	[ "${PF_DURATION_MS:-0}" -gt 0 ] &&
		[ "$_pos_ms" -ge $((PF_DURATION_MS * 90 / 100)) ] && _finished=1

	# Offline, every one of these calls would sit through curl's full timeout
	# before failing, which the user experiences as the app hanging after the
	# credits. Watching a download at home still reports normally.
	if [ "${PF_OFFLINE:-0}" = "1" ] || [ -z "$PF_URI" ]; then
		log "offline; watch state not reported"
	elif [ "${PF_DURATION_MS:-0}" -gt 0 ]; then
		if [ "$_finished" = "1" ]; then
			srv_get "$PF_URI" "$PF_STOK" \
				"/:/scrobble?key=$PF_KEY&identifier=com.plexapp.plugins.library" >/dev/null 2>&1
			log "scrobbled $PF_TITLE as watched"
		else
			plex_timeline "$PF_URI" "$PF_STOK" "$PF_KEY" stopped "$_pos_ms" "$PF_DURATION_MS"
			log "timeline $PF_TITLE at ${_pos_ms}ms"
		fi
	fi

	[ "$_finished" = "1" ] && after_finished
	return 0
}

# What happens the moment an episode ends. Both of these are the difference
# between a device you watch a series on and a device you watch an episode on.
after_finished() {
	# The copy on the card has served its purpose, if that is what was asked
	# for. Off by default: deleting what you just watched is right up until the
	# moment you wanted it again on the way home.
	if [ -n "$PF_LOCAL" ] && [ "$(pf_get dl_autodelete false)" = "true" ]; then
		pf_cache_remove "$PF_KEY" &&
			log "auto-deleted $PF_TITLE from the card after watching"
	fi

	[ "$(pf_get autoplay_next true)" = "true" ] || return 0
	chain_next
}

# Write a play request for whatever comes next, which the loop below picks up
# exactly as if the interface had asked for it.
#
# There is no countdown and no "up next" card, because there is nowhere to draw
# one: `st` is not running -- this process took the framebuffer from it to run
# ffplay, and putting the terminal back up between episodes would cost a
# start-up and a black screen longer than the gap itself.
chain_next() {
	_nk=""; _nt=""; _nd=0; _nrow=""

	if [ "${PF_OFFLINE:-0}" != "1" ] && [ -n "$PF_URI" ]; then
		_nrow=$(plex_next_episode "$PF_URI" "$PF_STOK" "$PF_KEY") || _nrow=""
		if [ -n "$_nrow" ]; then
			_nk=$(printf '%s' "$_nrow" | cut -f1)
			_nt=$(printf '%s' "$_nrow" | cut -f3)
			_nd=$(printf '%s' "$_nrow" | cut -f6)
			# The episode title alone identifies nothing outside its own list.
			_ns=$(printf '%s' "$_nrow" | cut -f14)
			[ -n "$_ns" ] && _nt="$_ns - $_nt"
		fi
	fi

	# No server, or the end of the show as far as the server is concerned: the
	# card may still hold the next one, which is the entire point of having
	# downloaded a season. This is the path a train journey runs on.
	if [ -z "$_nk" ]; then
		_nrow=$(pf_cache_next "$PF_KEY") || _nrow=""
		if [ -n "$_nrow" ]; then
			_nk=$(printf '%s' "$_nrow" | cut -f1)
			_nt=$(printf '%s' "$_nrow" | cut -f3)
			_nd=$(printf '%s' "$_nrow" | cut -f4)
		fi
	fi

	# Never chain to what just played: a server that answers oddly must not put
	# this into a loop that only a battery pull ends.
	if [ -z "$_nk" ] || [ "$_nk" = "$PF_KEY" ]; then
		log "autoplay: nothing follows $PF_TITLE"
		return 0
	fi

	_nlocal=$(pf_cache_file "$_nk" 2>/dev/null)
	_nstart=0
	if [ "${PF_OFFLINE:-0}" != "1" ] && [ -n "$PF_URI" ] &&
		[ "$(pf_get skip_intro on)" = "on" ]; then
		_nstart=$(plex_intro_end "$PF_URI" "$PF_STOK" "$_nk")
		[ -z "$_nstart" ] && _nstart=0
	fi

	{
		printf 'PF_KEY=%s\n' "$_nk"
		printf "PF_TITLE='%s'\n" "$(printf '%s' "$_nt" | sed "s/'/'\\\\''/g")"
		printf 'PF_OFFSET_MS=%s\n' "$_nstart"
		printf 'PF_DURATION_MS=%s\n' "${_nd:-0}"
		printf "PF_LOCAL='%s'\n" "$(printf '%s' "$_nlocal" | sed "s/'/'\\\\''/g")"
		printf "PF_URI='%s'\n" "$PF_URI"
		printf "PF_STOK='%s'\n" "$PF_STOK"
		printf 'PF_OFFLINE=%s\n' "${PF_OFFLINE:-0}"
	} >"$PF_REQ"
	_how="streaming"
	[ -n "$_nlocal" ] && _how="from the card"
	[ "${_nstart:-0}" -gt 0 ] && _how="$_how, past a ${_nstart}ms intro"
	log "autoplay: continuing with $_nt ($_how)"
	unset _nk _nt _nd _nrow _ns _nlocal _nstart
}

# The download worker is started here rather than from the interface, because
# the interface exits and restarts on every playback and would take its
# children with it. This process is the one thing that lives for the whole
# session, so it is the one that can own a long download.
#
# Anything left mid-flight by a battery pull is re-queued first: a partial file
# from the transcode endpoint cannot be resumed and is only ever dead weight.
pf_cache_init
pf_cache_recover
sh "$progdir/lib/dlworker.sh" >/dev/null 2>&1 &
dlpid=$!
log "download worker pid $dlpid"

# Onion kills the terminal with SIGKILL when MENU is pressed; that lands here
# as exit 137 and means "leave the app".
restarts=0
rm -f "$ST_RESTART"

while :; do
	rm -f "$PF_REQ"
	cd "$sysdir" || exit 1
	splash_hide

	# st runs in the background so the watchdog above can outlive a wake and
	# kill it. Waiting on it is exactly equivalent to running it in front.
	./bin/st -q -e "$progdir/lib/ui.sh" &
	stpid=$!
	resume_watchdog "$stpid" &
	wdpid=$!
	wait "$stpid"
	rc=$?
	kill "$wdpid" 2>/dev/null
	wait "$wdpid" 2>/dev/null

	if [ -f "$PF_QUIT" ]; then
		rm -f "$PF_QUIT"
		break
	fi

	# The interface asks for this too, when its own input stream has gone dead
	# under it -- see read_key in lib/ui_util.sh.
	if [ -f "$ST_RESTART" ]; then
		rm -f "$ST_RESTART"
		restarts=$((restarts + 1))
		if [ "$restarts" -le 5 ]; then
			log "restarting the interface (#$restarts)"
			continue
		fi
		# Five in one session is not a wake any more, it is a loop, and a loop
		# that redraws the whole interface forever is worse than quitting.
		log "too many terminal restarts; leaving"
		break
	fi
	# A loop, not a single call: an episode that runs to the end writes the next
	# one's request on its way out, and going round here plays it without
	# putting the terminal back up in between. The top of the outer loop
	# deletes any stale request, so a chained one has to be consumed in here.
	if [ -f "$PF_REQ" ]; then
		while [ -f "$PF_REQ" ]; do
			play_media
		done
		continue
	fi
	log "terminal exited rc=$rc with no request; leaving"
	break
done

# Stop downloading on the way out. Leaving curl running after the user is back
# in Onion's menu would hold the Wi-Fi and the CPU up with nothing on screen to
# explain why the battery is going.
splash_hide
: >"$DL_STOP"
kill "$dlpid" 2>/dev/null
sleep 1
rm -f "$DL_STOP" "$DL_PAUSE" "$PF_RUN/dl.now"
# The radio is left exactly as the user set it -- that is the entire point of
# the switch -- but the flag that stops the worker is ours and goes with us.
rm -f "$PF_RUN/wifi.off"

set_ondemand
rm -f /tmp/stay_awake
log "=== PocketFlex exit ==="
