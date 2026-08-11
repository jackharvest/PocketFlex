#!/bin/sh
# Render one screen against synthetic data, with no Plex server and no SD card.
#
# Layout bugs are the ones that survive every other kind of testing: the code
# runs, the API is fine, and the screen is still wrong. This draws real screens
# from fixtures so they can be looked at.
#
#   expect tools/drive.exp.mock list "down down" | tools/screen.py 29 53
#
# Screens: splash list longlist item downloads home subs

here=$(cd -- "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)
PF_DIR="$here/App/PocketFlex"
PF_SYS="$here/.testsys"
export PF_DIR PF_SYS

# Fixtures live outside the app so a test run never touches real state.
FIX="${PF_FIX:-/tmp/pfmock}"
mkdir -p "$FIX"
PF_CACHE="$FIX/cache"
export PF_CACHE

. "$PF_DIR/lib/common.sh"
. "$PF_DIR/lib/plex.sh"
. "$PF_DIR/lib/cache.sh"
. "$PF_DIR/lib/ui_util.sh"
. "$PF_DIR/lib/wifi.sh"

NLC='
'
PF_NOTE="$PF_RUN/note"
PF_OFFLINE=0

mb_reset() { MB=""; }
mb_row() { MB="$MB$1$TABC$2$TABC$3$TABC$4$TABC$5$NLC"; }
mb_add() { mb_row "$1" "$2" "" "$3" "$4"; }
mb_sep() { mb_row "--" "-" "" "" "s"; }
mb_block() { [ -n "$1" ] && MB="$MB$1$NLC"; }
mb_back() { mb_add BACK ".. Back"; }
note_reset() { : >"$PF_NOTE"; }
note_add() { printf '%s\n' "$1" >>"$PF_NOTE"; }
note_use() { [ -s "$PF_NOTE" ] && PF_MENU_NOTE="$PF_NOTE"; return 0; }

# Same converter the real UI uses, so what is drawn here is what ships.
items_to_menu() {
	sed -n '/^items_to_menu()/,/^}/p' "$PF_DIR/lib/ui.sh" >"$FIX/itm.sh"
	. "$FIX/itm.sh"
	items_to_menu
}

pf_cache_init

# --- fixtures ---------------------------------------------------------------
# PF_ROW: key type title year viewOffset duration titleSort index parentIndex
#         viewCount leafCount viewedLeafCount
eps() {
	i=1
	while [ "$i" -le 23 ]; do
		vc=0; vo=0
		[ "$i" -le 4 ] && vc=1
		[ "$i" -eq 5 ] && vo=500000
		printf '90%s\tepisode\t%s\t2019\t%s\t1442000\t%s\t%s\t1\t%s\t0\t0\n' \
			"$i" "$(ep_title "$i")" "$vo" "$(ep_title "$i")" "$i" "$vc"
		i=$((i + 1))
	done
}
ep_title() {
	case "$1" in
	1) echo "Stone World" ;; 2) echo "King of the Stone World" ;;
	3) echo "Weapons of Science" ;; 4) echo "Fire the Smoke Signal" ;;
	5) echo "Stone World The Beginning" ;;
	6) echo "Two Nations of the Stone World" ;;
	7) echo "Where Two Million Years Have Gone" ;;
	9) echo "Let There Be the Light of Science" ;;
	15) echo "The Culmination of Two Million Years" ;;
	17) echo "A Hundred Nights and a Thousand Skies" ;;
	*) echo "Episode $1" ;;
	esac
}

shows() {
	cat <<'EOF'
1	show	7th Time Loop: The Villainess Enjoys a Carefree Life	2024	0	0	7th Time Loop	 	 	0	12	0
2	show	The Angel Next Door Spoils Me Rotten	2023	0	0	Angel Next Door Spoils Me Rotten	 	 	0	12	5
3	show	Astra Lost in Space	2019	0	0	Astra Lost in Space	 	 	0	12	12
4	show	Barakamon	2014	0	0	Barakamon	 	 	0	12	0
5	show	Blue Period	2021	0	0	Blue Period	 	 	0	12	0
6	show	Boarding School Juliet	2018	0	0	Boarding School Juliet	 	 	0	12	3
7	show	Campfire Cooking in Another World with My Absurd Skill	2023	0	0	Campfire Cooking in Another World	 	 	0	12	0
8	show	Chillin in Another World with Level 2 Super Cheat Powers	2024	0	0	Chillin in Another World	 	 	0	12	0
9	show	Clannad	2007	0	0	Clannad	 	 	0	23	23
10	show	The Day I Became a God	2020	0	0	Day I Became a God	 	 	0	12	0
11	show	Deca-Dence	2020	0	0	Deca-Dence	 	 	0	12	0
12	show	The Devil Is a Part-Timer!	2013	0	0	Devil Is a Part-Timer	 	 	0	13	13
13	show	Dr. STONE	2019	0	0	Dr. STONE	 	 	0	24	9
14	show	Dragon Ball	1986	0	0	Dragon Ball	 	 	0	153	0
15	show	Dragon Ball Super	2015	0	0	Dragon Ball Super	 	 	0	131	0
16	show	Dragon Ball Z	1989	0	0	Dragon Ball Z	 	 	0	291	0
17	show	Dragon Quest: The Adventure of Dai	2020	0	0	Dragon Quest	 	 	0	100	0
18	show	Eden	2021	0	0	Eden	 	 	0	4	4
19	show	Erased	2017	0	0	Erased	 	 	0	12	0
20	show	ERASED	2016	0	0	ERASED live	 	 	0	8	0
21	show	The Fragrant Flower Blooms with Dignity	2025	0	0	Fragrant Flower	 	 	0	12	0
22	show	Fruits Basket	2019	0	0	Fruits Basket	 	 	0	63	0
23	show	Frieren: Beyond Journey's End	2023	0	0	Frieren	 	 	0	28	4
24	show	Gintama	2006	0	0	Gintama	 	 	0	367	0
25	show	Grand Blue Dreaming	2018	0	0	Grand Blue Dreaming	 	 	0	12	12
26	show	Haikyu!!	2014	0	0	Haikyu	 	 	0	85	0
27	show	Hell's Paradise	2023	0	0	Hells Paradise	 	 	0	13	0
28	show	Horimiya	2021	0	0	Horimiya	 	 	0	13	13
29	show	Hunter x Hunter	2011	0	0	Hunter x Hunter	 	 	0	148	0
30	show	Jujutsu Kaisen	2020	0	0	Jujutsu Kaisen	 	 	0	47	20
31	show	Kaguya-sama: Love Is War	2019	0	0	Kaguya-sama	 	 	0	37	0
32	show	Kill la Kill	2013	0	0	Kill la Kill	 	 	0	25	0
33	show	Made in Abyss	2017	0	0	Made in Abyss	 	 	0	13	0
34	show	Mob Psycho 100	2016	0	0	Mob Psycho 100	 	 	0	37	37
35	show	Monster	2004	0	0	Monster	 	 	0	74	0
36	show	Mushishi	2005	0	0	Mushishi	 	 	0	26	0
37	show	Nichijou	2011	0	0	Nichijou	 	 	0	26	0
38	show	One Punch Man	2015	0	0	One Punch Man	 	 	0	24	24
39	show	Ping Pong the Animation	2014	0	0	Ping Pong	 	 	0	11	0
40	show	Ranking of Kings	2021	0	0	Ranking of Kings	 	 	0	23	0
41	show	Re:ZERO	2016	0	0	ReZERO	 	 	0	50	12
42	show	Samurai Champloo	2004	0	0	Samurai Champloo	 	 	0	26	0
43	show	Steins;Gate	2011	0	0	SteinsGate	 	 	0	24	0
44	show	Vinland Saga	2019	0	0	Vinland Saga	 	 	0	48	0
45	show	Violet Evergarden	2018	0	0	Violet Evergarden	 	 	0	13	13
EOF
}

# Field 11 is the path a download was filed under, joined with US (0x1f).
# Everything here is under Anime except the film, which is loose in Movies, and
# one row deliberately has *no* path at all -- that is what an index written
# before v0.3.0 looks like, and it has to keep working.
seed_cache() {
	: >"$PF_CACHE_IDX"
	_dbz="Anime${PSEP}Dragon Ball Z${PSEP}Season 3"
	_st1="Anime${PSEP}Dr. STONE${PSEP}Season 1"
	printf '901\tdone\tDr. STONE - Stone World\t1442000\t128500\ta.mkv\t1\tDr. STONE\t\t129600\t%s\tS01E01\n' "$_st1" >>"$PF_CACHE_IDX"
	printf '902\tdone\tDr. STONE - King of the Stone World\t1442000\t131200\tb.mkv\t1\tDr. STONE\t\t129600\t%s\tS01E02\n' "$_st1" >>"$PF_CACHE_IDX"
	printf '903\tdownloading\tDr. STONE - Weapons of Science\t1442000\t0\tc.mkv\t1\tDr. STONE\t\t129600\t%s\tS01E03\n' "$_st1" >>"$PF_CACHE_IDX"
	printf '904\tqueued\tDr. STONE - Fire the Smoke Signal\t1442000\t0\td.mkv\t1\tDr. STONE\t\t129600\t%s\tS01E04\n' "$_st1" >>"$PF_CACHE_IDX"
	printf '511\tdone\tDragon Ball Z - Gohan Attacks\t1442000\t141000\tf.mkv\t1\tDragon Ball Z\t\t129600\t%s\tS03E05\n' "$_dbz" >>"$PF_CACHE_IDX"
	printf '512\tdone\tDragon Ball Z - The Ultimate Gamble\t1442000\t139000\tg.mkv\t1\tDragon Ball Z\t\t129600\t%s\tS03E02\n' "$_dbz" >>"$PF_CACHE_IDX"
	printf '513\tqueued\tDragon Ball Z - Full-Power Frieza\t1442000\t0\th.mkv\t1\tDragon Ball Z\t\t129600\t%s\tS03E11\n' "$_dbz" >>"$PF_CACHE_IDX"
	printf '88\tdone\tBlade Runner 2049\t9840000\t1150000\ti.mkv\t1\t\t\t1180000\tMovies\t\n' >>"$PF_CACHE_IDX"
	printf '13\tqueued\tFrieren\t1442000\t0\te.mkv\t1\t\t\t129600\n' >>"$PF_CACHE_IDX"
}

# The real renderer, pulled straight out of ui.sh, so what is drawn here is
# what ships rather than a copy that drifts.
dl_rows() {
	sed -n '/^dl_rows()/,/^}/p' "$PF_DIR/lib/ui.sh" >"$FIX/dlr.sh"
	. "$FIX/dlr.sh"
	dl_rows "$@"
}

# Whole functions lifted out of ui.sh by name. The screens above are fixtures
# that reproduce a layout; this runs the shipping code, which is the only way to
# test *navigation* -- that pressing A on a folder opens it, that backing out of
# an emptied folder does not strand you on a screen with one row.
ui_fns() {
	: >"$FIX/ui_fns.sh"
	for _f in "$@"; do
		sed -n "/^$_f()/,/^}/p" "$PF_DIR/lib/ui.sh" >>"$FIX/ui_fns.sh"
	done
	. "$FIX/ui_fns.sh"
}

# Hub streams in the exact shape plex_hubs emits: an HDR line naming the row,
# then PF_ROWs for its items.
hub_fixture_home() {
	printf 'HDR\tContinue Watching\n'
	printf '%s\n' '905	episode	Dr. STONE - Stone World The Beginning	2019	500000	1442000	Dr STONE	5	1	0	0	0	Anime	Dr. STONE	Season 1
511	episode	Dragon Ball Z - Gohan Attacks	1991	240000	1442000	Dragon Ball Z	5	3	0	0	0	Anime	Dragon Ball Z	Season 3
88	movie	Blade Runner 2049	2017	900000	9840000	Blade Runner 2049			0	0	0	Movies		'
	printf 'HDR\tRecently Added in Anime\n'
	printf '%s\n' '930	episode	Frieren - Aureole	2024	0	1420000	Frieren	28	1	0	0	0	Anime	Frieren	Season 1
931	episode	Dr. STONE - Science Future	2025	0	1442000	Dr STONE	1	4	0	0	0	Anime	Dr. STONE	Season 4'
	printf 'HDR\tRecently Released\n'
	printf '%s\n' '940	movie	Dune: Part Two	2024	0	9960000	Dune Part Two			0	0	0	Movies		
941	movie	The Wild Robot	2024	0	6120000	Wild Robot			0	0	0	Movies		'
}

hub_fixture_movies() {
	printf 'HDR\tContinue Watching\n'
	printf '%s\n' '88	movie	Blade Runner 2049	2017	900000	9840000	Blade Runner 2049			0	0	0	Movies		'
	printf 'HDR\tRecently Released\n'
	printf '%s\n' '940	movie	Dune: Part Two	2024	0	9960000	Dune Part Two			0	0	0	Movies		
941	movie	The Wild Robot	2024	0	6120000	Wild Robot			0	0	0	Movies		'
	printf 'HDR\tRecently Added\n'
	printf '%s\n' '942	movie	The Substance	2024	0	8400000	Substance			0	0	0	Movies		
943	movie	Flow	2024	0	5100000	Flow			0	0	0	Movies		'
	printf 'HDR\tRecently Played\n'
	printf '%s\n' '944	movie	Past Lives	2023	0	6660000	Past Lives			1	0	0	Movies		'
}

# --- screens ----------------------------------------------------------------
seed_cache
term_size

# PF_START seeds the cursor before the first draw, which is always a full
# repaint. That is what makes the partial-redraw path testable: render index N
# by starting there, render it again by walking down to it, and the two have to
# come out byte-identical. A partial redraw that disagrees with a full one is
# the whole failure mode of drawing only the rows that changed.
PF_MENU_INDEX=${PF_START:-0}

case "$1" in
splash)
	pf_splash "Finding your Plex server..."
	sleep 4 ;;

list)
	mb_reset
	mb_back
	mb_add DLALL "Download all not yet saved"
	mb_block "$(eps | items_to_menu)"
	printf '%s' "$MB" | pf_menu "Dr. STONE - Season 1" "A select | R1 back | L/R jump letter" ;;

longlist)
	mb_reset
	mb_back
	mb_add DLALL "Download all not yet saved"
	mb_add JUMP "-- Jump to letter --"
	mb_block "$(shows | items_to_menu)"
	printf '%s' "$MB" | pf_menu "Anime" "A select | R1 back | L/R jump letter" ;;

item)
	mb_reset
	mb_add RESUME "Resume from 8:20"
	mb_add PLAY "Play from start"
	mb_add SUBS "Subtitles: ON  - burned in"
	mb_add AUDIO "Audio track"
	mb_add ADDDL "Download for offline"
	mb_add WATCHED "Mark as watched"
	mb_add GOSEASON "Go to season"
	mb_add GOSHOW "Go to show"
	mb_back
	note_reset
	note_add "-------------------------------------------------"
	note_add "2019  24 min  1080p h264  TV-14"
	note_add "$(pf_bar 34 20)  8:20 of 24:02"
	note_add ""
	printf '%s' "Several thousand years after all of humanity was turned to stone, the brilliant scientist Senku wakes up and sets out to rebuild civilisation from nothing." |
		fold -s -w $((COLUMNS - 4)) | head -8 >>"$PF_NOTE"
	note_use
	printf '%s' "$MB" | pf_menu "Dr. STONE - Stone World  [24:02]" "A select | R1 back" ;;

home)
	mb_reset
	mb_add ONDECK "Continue Watching"
	mb_block "$(printf '905\tepisode\tDr. STONE - Stone World The Beginning\t2019\t500000\t1442000\tDr STONE\t5\t1\t0\t0\t0\tAnime\tDr. STONE\tSeason 1
71\tepisode\tThe Angel Next Door - Two Weeks\t2023\t180000\t1420000\tAngel\t2\t1\t0\t0\t0\tAnime\tThe Angel Next Door\tSeason 1
511\tepisode\tDragon Ball Z - Gohan Attacks\t1991\t240000\t1442000\tDragon Ball Z\t5\t3\t0\t0\t0\tAnime\tDragon Ball Z\tSeason 3
42\tepisode\tSeverance - Good News About Hell\t2022\t660000\t3180000\tSeverance\t2\t1\t0\t0\t0\tTV Shows\tSeverance\tSeason 1
88\tmovie\tBlade Runner 2049\t2017\t900000\t9840000\tBlade Runner 2049\t\t\t0\t0\t0\tMovies\t\t' |
		items_to_menu | awk -F"$TABC" -v OFS="$TABC" '{ $2 = "   " $2; $3 = ""; print }')"
	mb_add DOWNLOADS "Downloads" "5+3" "q"
	mb_sep
	mb_add "SEC:1|4K Movies" "4K Movies"
	mb_add "SEC:2|Classics" "Classics"
	mb_add "SEC:3|Hallmark" "Hallmark"
	mb_add "SEC:4|Movies" "Movies"
	mb_add "SEC:5|Anime" "Anime"
	mb_add "SEC:6|TV Shows" "TV Shows"
	mb_sep
	mb_add SEARCH "Browse by letter"
	mb_add SETTINGS "Settings"
	mb_add QUIT "Quit"
	note_reset
	note_add "-------------------------------------------------"
	note_add "6 libraries on Homeflix"
	note_add "5 downloaded, 3 downloading now"
	note_use
	printf '%s' "$MB" | pf_menu "PocketFlex - Homeflix" "A select | R1 back | MENU quit" ;;

downloads)
	# The top of the tree: what is still coming down, flat, then the folders.
	mb_reset
	mb_back
	mb_block "$(pf_cache_rows | dl_rows "" 903 48210 active | sort -f | cut -f2-)"
	mb_sep
	mb_block "$(pf_cache_rows | dl_rows "" 903 48210 | sort -f | cut -f2-)"
	mb_sep
	mb_add PURGE "Delete everything watched"
	mb_add WIPE "Delete all downloads"
	note_reset
	note_add "-------------------------------------------------"
	note_add "5 saved, 1.5 GB used"
	note_add "12.4 GB free on the card"
	note_add "3 waiting - these download while"
	note_add "PocketFlex is open."
	note_use
	printf '%s' "$MB" | pf_menu "Downloads" "A select | R1 back" ;;

dlfolder)
	# One level in: a show, with its seasons under it.
	_p="Anime"
	mb_reset
	mb_back
	mb_block "$(pf_cache_rows | dl_rows "$_p" 903 48210 | sort -f | cut -f2-)"
	mb_sep
	mb_add DELHERE "Delete everything in here"
	note_reset
	note_add "-------------------------------------------------"
	note_add "4 of 7 saved here, 539 MB"
	note_add "12.4 GB free on the card"
	note_use
	printf '%s' "$MB" | pf_menu "Anime" "A select | R1 back" ;;

dlseason)
	_p="Anime${PSEP}Dr. STONE${PSEP}Season 1"
	mb_reset
	mb_back
	mb_block "$(pf_cache_rows | dl_rows "$_p" 903 48210 | sort -f | cut -f2-)"
	mb_sep
	mb_add DELHERE "Delete everything in here"
	note_reset
	note_add "-------------------------------------------------"
	note_add "2 of 4 saved here, 253 MB"
	note_add "12.4 GB free on the card"
	note_use
	printf '%s' "$MB" | pf_menu "Anime / Dr. STONE / Season 1" "A select | R1 back" ;;

home2)
	# The Home view: rail with Home at the top, hub rows on the right. The rows
	# are built from a captured /hubs shape run through the shipping
	# items_to_menu, so the HDR passthrough is exercised rather than faked.
	{
		printf 'HOME\tHome\t\t\t\n'
		printf 'SEC:5|Anime\tAnime\t\t\t\n'
		printf 'SEC:4|Movies\tMovies\t\t\t\n'
		printf 'SEC:6|TV Shows\tTV Shows\t\t\t\n'
		printf -- '--\t-\t\t\ts\n'
		printf 'DOWNLOADS\tDownloads\t\t5+3\tq\n'
		printf 'SEARCH\tBrowse A-Z\t\t\t\n'
		printf 'SETTINGS\tSettings\t\t\t\n'
		printf 'QUIT\tQuit\t\t\t\n'
	} >"$FIX/home.left"
	hub_fixture_home | items_to_menu >"$FIX/home.right"
	printf '%s %s %s\n' "${PF_PANE_SIDE:-0}" "${PF_PANE_L:-0}" "${PF_PANE_R:-0}" \
		>"$PF_RUN/panes.idx"
	pf_panes "$FIX/home.left" "$FIX/home.right" "PocketFlex - Homeflix" \
		"A select | L/R switch panes | MENU quit" ;;

libview)
	# The same rail with a library's own view loaded: its A-Z list first, then
	# the rows the server returns for that library alone.
	{
		printf 'HOME\tHome\t\t\t\n'
		printf 'SEC:5|Anime\tAnime\t\t\t\n'
		printf 'SEC:4|Movies\tMovies\t\t\t\n'
		printf 'SEC:6|TV Shows\tTV Shows\t\t\t\n'
		printf -- '--\t-\t\t\ts\n'
		printf 'DOWNLOADS\tDownloads\t\t5+3\tq\n'
		printf 'SEARCH\tBrowse A-Z\t\t\t\n'
		printf 'SETTINGS\tSettings\t\t\t\n'
		printf 'QUIT\tQuit\t\t\t\n'
	} >"$FIX/home.left"
	{
		printf 'ALL:4|Movies\tAll of Movies\t\tA-Z\t\n'
		hub_fixture_movies | items_to_menu
	} >"$FIX/home.right"
	printf '%s %s %s\n' "${PF_PANE_SIDE:-0}" "${PF_PANE_L:-2}" "${PF_PANE_R:-0}" \
		>"$PF_RUN/panes.idx"
	pf_panes "$FIX/home.left" "$FIX/home.right" "Movies" \
		"A select | L/R switch panes | MENU quit" ;;

dltree)
	# The real Downloads screen, navigable. Offline so that "delete everything
	# watched" says it needs a server rather than reaching for one.
	PF_OFFLINE=1
	ui_fns ms_to_hms res_label controls_player_text confirm_play request_play \
		dl_rows screen_download_item purge_watched delete_under screen_downloads
	screen_downloads "" ;;

letters)
	# Browse by letter, with the counts the server's own index reports.
	mb_reset
	mb_back
	mb_block "$(printf '#\t3\t5\tA\nA\t14\t5\t/library/sections/5/firstCharacter/A
A\t9\t4\t/library/sections/4/firstCharacter/A\nB\t7\t5\tB\nC\t11\t5\tC
D\t18\t5\tD\nE\t4\t5\tE\nF\t9\t5\tF\nG\t6\t5\tG\nH\t8\t5\tH\nJ\t3\t5\tJ
K\t7\t5\tK\nM\t12\t5\tM\nN\t5\t5\tN\nO\t3\t5\tO\nP\t4\t5\tP\nR\t6\t5\tR
S\t15\t5\tS\nT\t9\t5\tT\nV\t3\t5\tV\nW\t2\t5\tW' |
		awk -F"$TABC" '{n[$1] += $2} END {for (c in n) printf "%s\t%s   (%d)\n", c, c, n[c]}' |
		sort)"
	note_reset
	note_add "-------------------------------------------------"
	note_add "Shows and films whose title starts with"
	note_add "the letter, from every library."
	note_use
	printf '%s' "$MB" | pf_menu "Browse by letter" "A select | R1 back" ;;

subs)
	mb_reset
	mb_add SOFF "Turn subtitles off"
	mb_sep
	mb_add S:1234 "English (SRT)  (selected)"
	mb_add S:1235 "English [Signs & Songs] (ASS)"
	mb_add S:1236 "Spanish (SRT)"
	mb_back
	note_reset
	note_add "-------------------------------------------------"
	note_add "Subtitles are burned into the picture by"
	note_add "the server. Choosing a track here selects"
	note_add "it on your Plex account too."
	note_use
	printf '%s' "$MB" | pf_menu "Subtitles" "A select | R1 back" ;;

wifiup)
	# The same screen with the radio up: the device paths are stubbed, and
	# ifconfig is shadowed so pf_wifi_ip finds an address. This is the layout
	# the handheld will show.
	PF_DATA="$FIX"; PF_SETTINGS="$FIX/settings.json"; PF_S_LOADED=0
	pf_settings_init
	PF_AXP=/usr/bin/true
	ifconfig() { printf 'wlan0  Link encap:Ethernet\n  inet addr:192.168.1.42  Bcast:192.168.1.255\n'; }
	pf_wifi_flag() { printf 'on'; }
	ui_fns wifi_wait_status screen_wifi
	screen_wifi ;;

wifi)
	# The Wi-Fi screen as a desktop sees it: none of the device paths exist, so
	# this is the "cannot switch it from here" path -- which is also what a
	# firmware that moved axp_test would show, and it must not be a dead end.
	PF_DATA="$FIX"; PF_SETTINGS="$FIX/settings.json"; PF_S_LOADED=0
	pf_settings_init
	ui_fns wifi_wait_status screen_wifi
	screen_wifi ;;

homerows)
	# The real Home screen settings, which need no server at all.
	PF_DATA="$FIX"; PF_SETTINGS="$FIX/settings.json"; PF_S_LOADED=0
	pf_settings_init
	ui_fns screen_home_rows
	screen_home_rows ;;

settings)
	# The real screen_settings, lifted out of ui.sh and run -- so the row list
	# here is the one that ships instead of a copy that drifts, which is what
	# this fixture had quietly become. Settings are pointed at the fixture
	# directory so a stray keypress cannot rewrite the repo's own defaults.
	PF_DATA="$FIX"
	PF_SETTINGS="$FIX/settings.json"
	PF_S_LOADED=0
	pf_settings_init
	pf_set server_name "Homeflix"
	ui_fns res_label screen_settings
	screen_settings ;;

ready)
	# The "Ready to play" card, which is where subtitles are switched.
	sed -n '/^controls_player_text()/,/^}/p' "$PF_DIR/lib/ui.sh" >"$FIX/cp.sh"
	sed -n '/^res_label()/,/^}/p' "$PF_DIR/lib/ui.sh" >>"$FIX/cp.sh"
	sed -n '/^ms_to_hms()/,/^}/p' "$PF_DIR/lib/ui.sh" >>"$FIX/cp.sh"
	sed -n '/^confirm_play()/,/^}/p' "$PF_DIR/lib/ui.sh" >>"$FIX/cp.sh"
	. "$FIX/cp.sh"
	confirm_play "Dr. STONE - Stone World" 500000 "" ;;

readyskip)
	# The same card, starting past an intro rather than resuming -- the two
	# must not be worded the same way, and the battery warning shares the row
	# below them.
	sed -n '/^controls_player_text()/,/^}/p' "$PF_DIR/lib/ui.sh" >"$FIX/cp.sh"
	sed -n '/^res_label()/,/^}/p' "$PF_DIR/lib/ui.sh" >>"$FIX/cp.sh"
	sed -n '/^ms_to_hms()/,/^}/p' "$PF_DIR/lib/ui.sh" >>"$FIX/cp.sh"
	sed -n '/^confirm_play()/,/^}/p' "$PF_DIR/lib/ui.sh" >>"$FIX/cp.sh"
	. "$FIX/cp.sh"
	confirm_play "Dr. STONE - Weapons of Science" 102000 "" 102000 ;;

*) echo "screens: splash list longlist item home downloads dlfolder dlseason dltree letters home2 libview homerows wifi wifiup subs settings ready readyskip" ;;
esac
