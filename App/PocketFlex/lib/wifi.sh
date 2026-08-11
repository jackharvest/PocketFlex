#!/bin/sh
# PocketFlex - turning the radio on and off from inside the app.
#
# The reason this exists: the useful pattern on a handheld is "connect long
# enough to sync the next few episodes, then drop the radio and go". Wi-Fi is
# the largest continuous draw on this device after the backlight, and until now
# the only way to stop it was to quit to Onion's menu, walk into its settings,
# and come back.
#
# NOTHING HERE IS INVENTED. Every command is the one OnionOS's own
# `script/network/update_networking.sh` runs, in the same order, because the
# firmware's idea of "wifi is on" is a state we are joining, not replacing:
#
#   on  : axp_test wifion; ifconfig wlan0 up; wpa_supplicant -B; udhcpc; iw
#   off : pkill wpa_supplicant; pkill udhcpc; axp_test wifioff
#
# The one addition is that we also write MainUI's own flag in
# /appconfigs/system.json. Onion reads that on the way back into its menu and
# will happily undo whatever we did if it disagrees -- runtime.sh's check_wifi
# re-runs the whole sequence from that value. Writing it is what makes the
# choice stick after leaving PocketFlex rather than being silently reverted.

# The device paths. All of these live in the rootfs or on the card, and none of
# them exist on a desktop, which is exactly how pf_wifi_available() decides
# whether to offer any of this at all.
PF_AXP="/customer/app/axp_test"
PF_JSONVAL="/customer/app/jsonval"
PF_SYSJSON="/appconfigs/system.json"
PF_WPACONF="/appconfigs/wpa_supplicant.conf"
PF_WPA="$PF_MIYOO/app/wpa_supplicant"
PF_UDHCPC_SCRIPT="/etc/init.d/udhcpc.script"

# Set while the radio is deliberately down, so the download worker idles
# instead of spending a connect timeout per item and marking a whole queue
# failed. That is the "it freaks out" this feature has to avoid.
PF_WIFI_OFF="$PF_RUN/wifi.off"

pf_wifi_available() { [ -x "$PF_AXP" ]; }

# The address we actually hold, or nothing. This is the honest test: the flag in
# system.json says what was *asked* for, and an interface can be up with no
# lease yet.
pf_wifi_ip() {
	ifconfig wlan0 2>/dev/null |
		sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1
}

# on | off -- what the firmware has been told to do.
pf_wifi_flag() {
	if [ -x "$PF_JSONVAL" ] && [ "$("$PF_JSONVAL" wifi 2>/dev/null)" = "1" ]; then
		printf 'on'
	elif grep -q '"wifi"[^,}]*1' "$PF_SYSJSON" 2>/dev/null; then
		printf 'on'
	else
		printf 'off'
	fi
}

# up | connecting | off
pf_wifi_state() {
	if [ -n "$(pf_wifi_ip)" ]; then printf 'up'
	elif [ "$(pf_wifi_flag)" = "on" ] && [ ! -f "$PF_WIFI_OFF" ]; then printf 'connecting'
	else printf 'off'; fi
}

# MainUI's flag. Never written at all if jq cannot parse what is already there:
# a corrupted system.json is a device that boots into a broken launcher, which
# is not a price worth paying for a Wi-Fi toggle. A copy of the original is kept
# once, the first time we ever touch it.
#
# The new content is `cat` into place rather than `mv`d over it. This file
# belongs to the firmware; replacing it with a temp file would replace its
# ownership and permissions with ours, and it lives on a different filesystem
# from /tmp anyway.
pf_wifi_set_flag() {
	[ -f "$PF_SYSJSON" ] || return 0
	[ ! -f "$PF_SYSJSON.pocketflex.bak" ] &&
		cp "$PF_SYSJSON" "$PF_SYSJSON.pocketflex.bak" 2>/dev/null
	_wt="/tmp/system.json.$$"
	if jq --argjson v "$1" '.wifi=$v' "$PF_SYSJSON" >"$_wt" 2>/dev/null &&
		[ -s "$_wt" ]; then
		cat "$_wt" >"$PF_SYSJSON" 2>/dev/null
		log "wifi: system.json flag set to $1"
	else
		log "wifi: could not update system.json; leaving it alone"
	fi
	rm -f "$_wt"
	unset _wt
}

# Bring the radio up. Returns 0 once an address is held.
#
# Waiting is the whole point: every caller wants to do something over the
# network next, and "on" without a lease is a screen full of timeouts. The wait
# is bounded and reports progress through the callback in $1, because 15 seconds
# with no feedback reads as a crash.
pf_wifi_on() {
	pf_wifi_available || return 1
	rm -f "$PF_WIFI_OFF"
	log "wifi: turning on"

	pf_wifi_set_flag 1
	"$PF_AXP" wifion >/dev/null 2>&1
	sleep 2
	ifconfig wlan0 up >/dev/null 2>&1

	# LD_PRELOAD is cleared for these two deliberately. Onion runs MainUI with
	# libpadsp.so preloaded, and its own notes say wpa_supplicant and udhcpc
	# inheriting that is what locks the device up on entering an app afterwards.
	# We are not launched from MainUI's environment, but starting long-lived
	# daemons that outlive this app with whatever we happened to inherit is how
	# that bug gets recreated from a new direction.
	if [ -x "$PF_WPA" ] && ! pgrep wpa_supplicant >/dev/null 2>&1; then
		LD_PRELOAD="" "$PF_WPA" -B -D nl80211 -iwlan0 -c "$PF_WPACONF" \
			>/dev/null 2>&1
	fi
	if ! pgrep udhcpc >/dev/null 2>&1; then
		LD_PRELOAD="" udhcpc -i wlan0 -s "$PF_UDHCPC_SCRIPT" >/dev/null 2>&1 &
	fi
	iw dev wlan0 set power_save off >/dev/null 2>&1

	_w=0
	while [ "$_w" -lt 20 ]; do
		if [ -n "$(pf_wifi_ip)" ]; then
			log "wifi: up at $(pf_wifi_ip) after ${_w}s"
			unset _w
			return 0
		fi
		[ -n "$1" ] && "$1" "$_w"
		sleep 1
		_w=$((_w + 1))
	done
	log "wifi: no address after ${_w}s"
	unset _w
	return 1
}

# Take the radio down. Downloads are stopped *first* and put back in the queue,
# because the alternative is a curl that sits through its connect timeout and a
# queue of items marked failed by the time anyone looks.
pf_wifi_off() {
	pf_wifi_available || return 1
	: >"$PF_WIFI_OFF"
	log "wifi: turning off"
	# Give the worker a moment to notice the flag and put its download back.
	sleep 2
	pkill -9 wpa_supplicant >/dev/null 2>&1
	pkill -9 udhcpc >/dev/null 2>&1
	"$PF_AXP" wifioff >/dev/null 2>&1
	pf_wifi_set_flag 0
	return 0
}
