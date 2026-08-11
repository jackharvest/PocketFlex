# Changelog

Versioning:

- **v0.1.X** — bug fixes and small-to-medium features. Normal work.
- **v0.X.0** — a major breakthrough in capability.
- **vX.0.0** — only with the maintainer's explicit permission.

---

## v0.4.3

A text-size setting, built and then taken back out because the device will not
have it. What survives is the two things that were not really about fonts.

### Tried and reverted: four text sizes

The request was to roughly double the font without wrecking the layout. The
font itself cannot be changed — `st` links `libc`, `libSDL-1.2` and
`libpthread` and nothing else, so the `[-f font]` in its usage line and the
`fonts/FIXED_V0.TTF` in its strings have no loader behind them and no such file
on the card. The glyphs are compiled in at 12x16.

`-g` was the plan. `st` carries `set videomode %dx%d`, Onion's SDL calls
`MI_GFX_BitBlit` (the SigmaStar hardware scaler), and a 320x240 emulator fills
this panel, so a smaller terminal should have been a bigger font at no cost:
53x29 native, then 40x22, 32x18 and 27x15 — kept near 4:3 so the scaler would
not stretch the glyphs.

Every screen was reflowed for it in the mock harness at all four sizes: the
home screen collapsed to a single list below 40 columns, the title bar learned
to shed its hint rather than its title, the player controls stacked instead of
tabulating and led with MENU, and the collapsed home's partial-repaint
invariant held at 27x15.

**None of it survives contact with `st`, which exits rc=1 the moment it is
given `-g`.** No video mode is set and `ui.sh` never starts:

```
terminal geometry -g 40x22
terminal exited rc=1 with no request; leaving
```

The worse half is what that did to the app. The size was a saved setting, so
once written it was passed on every launch — and every launch died the same
way. This did not degrade to a feature that quietly did nothing; it degraded to
**an app that would not open**, recoverable only by editing `settings.json` on
the card. Anything that changes how `st` is invoked has to be proven before it
is allowed to persist.

Recorded as trap 27 in the README so it is not attempted again. Reverted in
full: no setting, no geometry, no narrow-width layout paths.

### Kept

Two things came out of the attempt that stand on their own and are staying.

- **`pf_set` now logs a failed write.** The text-size row spent a round of
  hardware testing doing nothing at all, because it shipped as `pf_set
  text_size large 1` — and that third argument means *the value is raw JSON*,
  selecting jq's `--argjson` over `--arg`. Handed `--argjson v large`, jq
  rejected it, printed its complaint to `/dev/null`, and wrote nothing; the
  empty temp file was discarded rather than moved; and `pf_set` had already
  updated the in-memory copy by design, so a card-write failure does not make
  the current screen lie. The result was a Settings row that agreed with the
  user while the file disagreed with both, and silence everywhere. A setting
  that does not save is now a line in the log, whatever the cause — bad value,
  full card, read-only mount.

- **A settings round-trip check in `tools/lint-busybox.sh`**, covering the nine
  shapes the settings screen writes, in both spellings. Verified to fail on the
  exact bug above.

  It needed two goes itself, and both mistakes are the same species:

  - `pf_settings_load` only ever *adds* `PFS_*` variables, so it never clears
    one the file does not have. Reading a setting back without unsetting it
    first returns what `pf_set` put in memory and proves nothing about the
    file — which is precisely why the original bug was invisible.
  - `common.sh` honours `PF_DIR` from the environment but assigns `PF_DATA`
    and `PF_SETTINGS` outright. They have to be set *after* the source, the way
    `tools/mockscreen.sh` does it. Set before, the check wrote its test values
    into the repo's own `data/settings.json`. (Restored; that file is
    gitignored and `deploy.sh` never copies it to the card.)

---

## v0.4.2

A bug-hunting round on hardware. Four of the five reports turned out to have
causes worth writing down; the fifth is somebody else's bug and is recorded as
such.

### Fixed

- **Films playing in slow motion with no sound.** "The Bad Guys" is 1080p h264
  and plays at roughly half speed, silent, on a device where "Robots" — also
  1080p h264 — is fine. It looked like a title that was quietly skipping the
  transcoder.

  It was not. The log proves both were transcoded: 480x200 for one, 480x260 for
  the other. The difference is the **audio**, and it was invisible because the
  log only ever recorded the video line.

  `X-Plex-Platform` is `Chrome`, because that is the only built-in profile this
  server will start a transcode for at all (see v0.2.1). Chrome can decode
  multichannel AAC, so Plex's Chrome profile treats AAC 5.1 as something the
  client handles and passes it through untouched — however small a picture it is
  wrapped around. Probing the real server with PocketFlex's exact parameters:

  | title | source audio | what arrives |
  |---|---|---|
  | The Bad Guys | AAC 5.1 | video h264 480x200, **audio aac 6ch 5.1** |
  | Robots | DTS 5.1 | video h264 480x260, audio mp3 2ch stereo |

  Robots only ever worked by luck. DTS is *not* in the Chrome profile, so its
  audio had to be transcoded — and transcoding is what made it stereo. Anything
  whose source is already AAC 5.1 arrives as 5.1, and on this library that is
  most of it: a scan of one movie section found AAC 5.1 on title after title.

  The device cannot play six channels. `ffplay` here is an ffmpeg 2.8 build
  against an SDL that opens a stereo device — `init audio 20` in the log — and
  handed 5.1 the audio path stalls. A stalled audio clock is what drags the
  video into slow motion. No sound and half speed were one bug, not two.

  Fixed in the filter graph rather than by asking the server, because asking the
  server does not work: `maxAudioChannels=2` is rejected with a bare 400 by Plex
  1.43.2 on this path. `-af aformat=channel_layouts=stereo` is unconditional,
  needs nothing from the server, and also fixes **files already downloaded** —
  they were fetched through the same parameters and have the same 5.1 audio
  baked in.

  `aformat` is the portable spelling on purpose. The swresample-style options
  (`ocl`, `out_channel_layout`) exist in ffmpeg 2.8 but were removed in later
  ffmpeg, so a filter written that way could not be tested anywhere but the
  device. `aformat` has been in libavfilter throughout and is a no-op when the
  audio is already stereo.

- **The audio line is now logged too**, next to the video one. Its absence is
  why a film arriving with unplayable 5.1 audio looked, in the log, exactly like
  a film that played perfectly. `stereo` means the downmix worked; `5.1` means
  it did not.

- **"Recently Added" on a TV library was five rows of "S01  Season 1"** with no
  show name on any of them.

  What a TV library adds *is* seasons, so that is what the hub returns — and a
  season's own title is "Season 1". The show name is sitting right there in
  `parentTitle`; it was simply never read. Episodes had been given this
  treatment already (`grandparentTitle` in front of the episode name, since
  "Stone World" identifies nothing on its own); seasons had not.

  Now the row reads "S01  Dragon Quest: The Adventure of Dai". When the season
  title is the generic "Season *n*" the number is dropped from the label rather
  than repeated, because the list already prints an `S01` prefix in front of it.
  A season with a real name of its own — "Specials", a named arc — keeps it.
  The generic case is spotted by comparing against the index rather than by
  matching a pattern, so this asks no regex support of `jq`.

- **Switching profile dropped the connection to the server.** Switch user, back
  out, and up comes "Lost the connection to Homeflix. Switching to your
  downloads." — on a network that never went anywhere. Pressing "Try again"
  reconnected immediately, which was the clue.

  Throwing the cached connection away on a profile switch is correct: the
  per-server access token belongs to the user you just stopped being. But
  nothing was putting a new one in its place. `ensure_server` runs at start-up
  and from Settings, not on the way out of the profile screen, so `SRV_URI`
  stayed empty; the next thing to ask the server anything got an empty answer,
  and the home screen reads an empty answer as the connection having dropped.
  "Try again" worked because that path *does* call `ensure_server`.

  The switch now reconnects before returning, and clears the cached media
  endpoint as well — that was probed with the old user's token too.

### Added

- **"Go to season" and "Go to show" on an episode.** An episode reached from the
  home screen has no season or show behind it on the navigation stack — you came
  from a row of recommendations, so backing out returns to the home screen.
  Landing on episode 11 because it was newly released and then wanting episode
  12, or just the season list, meant walking back to the library and down
  through the show by hand.

  Both keys are already in the metadata the item screen reads, so the two rows
  cost no extra request, and they are absent on a film because a film has no
  parent. They *replace* the episode frame rather than stacking on it: backing
  out of the season you just jumped to should go where the season came from, not
  to the episode screen that would send you straight back.

### Known, and not ours

- **Seeking past the end of an episode stalls playback**, leaving the last frame
  on the panel. MENU gets you back.

  The seek keys belong to `ffplay`, not to us — they are compiled in, and the
  big stride is its page-up/page-down binding of ±10 minutes. There is no
  rebinding them without patching the binary, and nothing in this app is between
  the button and the player while the player owns the framebuffer. Seeking past
  the available segments of a Plex HLS transcode is what wedges it; MENU is ESC,
  which `ffplay` does honour, which is why that works.

  What has changed is only that it can now be identified after the fact: an
  `ffplay` exit with a non-zero status is logged with its status and how long it
  ran, so a stall is distinguishable from a normal end-of-episode in the log.

### Found while testing

- **This server needs roughly 30 seconds between transcode session starts.**
  Starting sessions faster than that makes `/video/:/transcode/universal/start`
  answer a bare 400 — no body, no reason — for perfectly valid requests,
  including ones that had just succeeded. It recovers on its own once left
  alone. This is the same behaviour `plex_preflight` already retries around
  (v0.2.1); what is new is knowing the rate that provokes it, which matters
  because it makes rapid A/B testing against a live server unreliable.

---

## v0.4.1

### Fixed

- **The app could not be used after the screen slept.** Wake the device and the
  interface is still on the panel, but nothing responds — not the d-pad, not
  MENU — and the only way out is to power the unit off.

  What is on screen after a wake is not evidence the app is alive. This
  framebuffer keeps whatever was last written to it; that is the same property
  that lets a *dead* `imgpop` leave the boot logo up while `st` starts. A frozen
  picture of the interface and a live interface look identical.

  `st` opens the input device once, at start-up. If that handle stops delivering
  events, nothing inside `st` — or inside a shell script running in it — can ask
  for it back. But `launch.sh` is not `st`: it can throw the terminal away and
  start a new one, which re-opens everything. The navigation stack, the menu
  cursor and the pane cursors are all files, so the same screen comes back with
  the cursor where it was.

  Two independent detectors, because Onion's sleep is undocumented:

  - **The backlight.** Onion drives it through the PWM at
    `/sys/devices/soc0/soc/1f003400.pwm/pwm/pwmchip0/pwm0/` — the path is read
    out of `batmon` and `mainUiBatPerc` — and sleeping turns it off. Seeing it
    go dark and come back is a wake, whatever else happened.
  - **A gap in our own clock.** If the process group was stopped, or the system
    suspended, a 3-second sleep in the watchdog takes far longer than 3 seconds
    to return from. That covers a sleep which never touches the backlight.

  And the interface watches its own input: a tty that has gone away returns
  end-of-file instantly and forever, which from inside the app is
  indistinguishable from START — a LF is stripped by command substitution and
  arrives as the empty string, which is *why* an empty read means "select". So
  the difference is measured rather than read. A thousand empty reads inside
  three seconds is not a thumb; that asks for a new terminal too. A thousand
  spread over a minute is a person leaning on START, and is ignored.

  Both paths are logged with which detector fired, and restarts are capped at
  five per session so a genuine fault cannot become a redraw loop.

### Added — a Plex-shaped home

- **Home at the top of the rail, then the libraries**, and the rail never goes
  away. Choosing a library no longer leaves the screen: it loads *that
  library's* rows into the right pane — its own Continue Watching, Recently
  Released, Recently Added, Recently Played — with the rail still beside it.
  The alphabetical list is still one press away as the first row of the pane,
  "All of <library>".

- **The rows come from Plex's own hubs.** `/hubs` and `/hubs/sections/<id>` are
  what the official clients draw: the server decides what the rows are and what
  they are called, and returns all of them, titled, in **one request**. Building
  the same thing by hand is a request per row per library, on a device where a
  request is expensive and home is redrawn constantly — and it means the rows
  track whatever the server offers rather than a list hard-coded here.

  Music and photo hubs come back too and are dropped, along with any hub left
  empty by that filtering, so a row never appears with nothing under it. A
  server with no `/hubs` at all falls back to building Continue Watching,
  Recently Released and Recently Added from the endpoints that predate it, and
  says so in the log.

- Views are cached per library with the same 90-second rule, and R1 in a library
  view goes back to Home rather than out of the app.

### Fixed — in the new code

- **A jq scoping bug in the hub filter**, found against a captured `/hubs`
  response: inside `$hid | index(f)`, `f` is evaluated with **`$hid`** as its
  input, not the hub — so `.librarySectionID` was being read from a string, and
  jq aborted the entire response. One hidden library made the whole home screen
  empty. The section id is bound before the pipe now. A hub with no section at
  all (Continue Watching spans every library) is never hidden.

## v0.4.0

### Added — Wi-Fi, from inside the app

- **Settings → Wi-Fi turns the radio on and off**, and the offline home screen
  carries the same switch, because that is exactly where somebody decides to
  sync. The pattern this device is used with is "connect long enough to pull
  the next few episodes, then drop the radio and go", and it used to mean
  quitting to Onion's menu and coming back.

  Every command is the one OnionOS's own `script/network/update_networking.sh`
  runs, in the same order — `axp_test wifion`, `ifconfig wlan0 up`,
  `wpa_supplicant -B -D nl80211`, `udhcpc`, `iw dev wlan0 set power_save off`,
  and the pkill/`wifioff` pair on the way down. The firmware's idea of "Wi-Fi is
  on" is a state to join, not to replace.

  Three things beyond the radio itself, which are what make it not "freak out":

  - **The download worker is put to sleep first** and its transfer re-queued.
    Without that, every queued item spends a connect timeout failing and the
    whole queue reads as failed by the time anyone looks.
  - **MainUI's own flag in `/appconfigs/system.json` is updated**, so the choice
    survives leaving the app. Onion re-runs the whole sequence from that value
    on the way back to its menu and would otherwise undo us. It is never written
    if `jq` cannot parse what is already there, a copy of the original is kept
    the first time, and the new content is `cat` into place rather than moved,
    so the firmware keeps its own file.
  - **Turning it on waits for an address** — up to 20 seconds, with the count on
    screen — and then re-finds the Plex server, because "on" without a lease is
    a screen full of timeouts.

  On a firmware that does not expose `axp_test` where we expect it, the screen
  says so instead of offering a switch that does nothing.

### Added — the home screen

- **Two columns.** The libraries are a rail down the left; the rows are stacked
  down the right. A single column spent most of a 29-row screen on a library
  list that never changes and left no room for the things you actually came to
  look at. The rail costs 14 columns and gives the whole height back.

  Left and right switch panes, up and down move inside one — those keys are
  free here for the same reason the Ready-to-play card can use them, because
  this screen has no long list to page through. The unfocused pane keeps its
  place underlined rather than reversed, so there is never a question which side
  has the keys.

- **Recently Added, one row per library**, alongside Continue Watching. Group
  headers are a row type the list renderer skips over, which is what lets one
  scrolling column hold four labelled groups the way every other Plex client
  stacks its rows.

- **Pin the libraries you use.** Settings → Home screen → Libraries. On a server
  with 4K Movies, Classics, Hallmark, Movies, Anime and TV Shows, four of them
  may be somebody else's and they were taking two thirds of the rail. Hidden
  libraries stay out of the rail, out of Browse by letter, and have no Recently
  Added row. What is stored is the *hidden* list, not the pinned one, so a
  library added to the server later appears by itself rather than staying
  invisible until someone remembers to pin it.

- **Choose what the home screen shows**: Continue Watching on or off, Recently
  Added on or off, and 3, 5 or 8 items per row.

- Home content is a **90-second cache** with the epoch on its first line — one
  file holding both the library list and the rows. Continue Watching plus one
  Recently Added row per library is a request per library, and home is redrawn
  every time you back out of anything. Playback deletes the cache on its way
  out, because your own watching is the thing that makes it wrong.

### Fixed

- **Two printf bugs in the new two-pane renderer**, both found by rendering the
  screen rather than by reading it: an argument more than the format string had
  specifiers, which dropped the trailing reset and leaked reverse video to the
  end of the row; and a focused row that painted one column more than an
  unfocused one, which left a reversed cell behind every time the cursor moved
  away. There is no `\033[K` in a two-pane layout — clearing to end of line
  would take the other pane with it — so every branch has to paint exactly the
  same width.

### Added — watching a series, not an episode

- **The next episode plays by itself.** When an episode runs to the end — the
  same 90% test that already marked it watched — the next one starts. Stopping
  halfway does not trigger it, which is the whole reason the test is what it is.

  There is no "up next" countdown card, because there is nowhere to draw one:
  `st` is not running during playback (this is the process that took the
  framebuffer from it), and putting the terminal back up between episodes would
  cost a start-up and a longer black screen than the gap itself.

  The lookup is the next episode in the season, then the first of the next
  season — deliberately not `allLeaves`, which is one request but 291 rows on
  Dragon Ball Z, at the end of every single episode. **With no server it falls
  back to the card**: same folder, next episode code. So a downloaded season
  binges on a train with the Wi-Fi off, which is the case this device exists
  for. Off in Settings if you want one episode at a time.

- **Audio track selection.** The other half of the job the subtitle switch only
  did half of: on an anime library, dub versus original-with-subtitles is the
  choice people actually make, and it could not be made from the device at all.
  Same server-side write as subtitles (`audioStreamID` on the part), so the
  choice sticks everywhere. It costs nothing to honour because everything is
  transcoded — the server simply builds the stream from a different track.

- **Skip intros**, on by default. Plex publishes chapter markers only when asked
  (`includeMarkers=1`), which the item screen now does as part of the one
  request it already makes — so this costs no extra round trip. There is no way
  to draw a Skip Intro button over `ffplay`, so the decision is made before the
  stream starts and the Ready-to-play card **says so**: *"Skipping the intro -
  starts at 1:42"*, never "Resuming from 1:42", which would be a lie about an
  episode you have never opened. Only a marker starting inside the first five
  minutes counts; a credits marker is not something to silently seek past.

- **Delete a download once watched**, off by default — right up until the moment
  you wanted it again on the way home. Applies when an episode finishes, to the
  copy that was actually played from the card.

- **Low-battery warning on the Ready-to-play card.** Under 20%, in red, next to
  the runtime you are about to start. Roughly an hour of playback left.

- **A storage floor.** Queueing now refuses to take the card below 300 MB free,
  on both the single-item and the whole-season paths, with the numbers in the
  message. A full card has no in-app recovery: there is no file manager on this
  device, and the person filling it is the person about to get on a plane.

## v0.3.0

Downloads are now a place rather than a pile, browse-by-letter does what its
name says, and the interface remembers where you were.

### Fixed

- **Browse by letter did not browse by letter.** It ran `/search?query=A`.
  Plex's search matches a substring *anywhere* in a title and ranks by
  relevance, so choosing S returned every episode whose name contains an s,
  ordered by an internal score, with the shows somewhere in the middle. Nothing
  about that is a letter index; it only looked like one because the first
  result usually did start with the right letter.

  It now asks each library for its **first-character index** — the same
  `/library/sections/K/firstCharacter` listing Plex's own clients draw their
  A–Z rail from — and follows the key it hands back. That means:

  - **Only shows and films.** Episodes are not top-level titles in a library,
    so they cannot appear. Nobody picks a letter looking for "Stone World".
  - **Starts with, not contains.**
  - **The server's own idea of the letter**, which is `titleSort`-based, so
    *The Angel Next Door* files under A exactly as the library list has it —
    the same rule the A–Z gutter already follows.
  - **Real counts on the menu** (`A   (23)`), aggregated across every library,
    and only letters that actually have something under them.

  The index is built once per session and kept in `/tmp`; it is one small
  request per library. A server that does not answer `/firstCharacter`, or
  hands back a key we cannot follow, falls through to fetching the section and
  filtering on `titleSort` here — so the screen is never empty, and the
  fallback says so in the log.

- **The cursor was lost on every screen change.** `pf_menu` sets
  `PF_MENU_INDEX` before returning, and that assignment went nowhere: every
  caller reads its result through `$(...)`, and the pipe into it is a second
  subshell again, so the value died with the subshell that made it. Coming back
  from an episode landed at the top of a 600-row library, every time.

  The index is now written to a file, and the navigation stack carries it as a
  fourth field per frame. Backing out of an episode lands on that episode;
  backing out of a season lands on that season. Because the stack is a file and
  this interface *exits* for playback, it also means finishing a film returns
  you to the row you played it from.

### Added

- **Downloads are organised the way you found them.** Something saved from
  Anime → Dragon Ball Z → Season 3 → S03E05 now appears under exactly that,
  three folders deep, instead of loose in one flat list. A card with sixty
  episodes on it was unusable as a single list, and sixty episodes is what a
  card fills up with.

  - Folders carry their own totals: a size when everything under them is on the
    card, `12/24` when it is not — the same right-hand column the library lists
    use.
  - Inside a folder, rows lose the show name they no longer need and gain the
    **episode code**, so a season reads `S03E02`, `S03E05`, `S03E11` in that
    order rather than alphabetically by episode title.
  - **Anything still downloading is also listed flat at the top level**, with
    its percentage. Progress is why this screen gets opened mid-download, and
    having to remember which season a file was under to watch it tick is not an
    answer to that.
  - **Delete everything in here** works at any level — a season, a show, a
    whole library — and is the same code path as "delete all downloads", so the
    count and the confirmation cannot drift apart.
  - The path is taken from the **item's own metadata**, not from the navigation
    stack, so the same episode saved from Continue Watching, from a letter
    browse, or by walking the library lands in one folder rather than three.
  - Rows written by earlier versions have no path column. They read back as an
    empty path and sit at the top level, which is where they already were.
    Nothing to migrate.

- **Battery percentage in the header bar**, on every screen in the app. The app
  takes the whole panel, so while it is open there was no way to see the
  battery short of quitting to Onion's menu — a poor thing to have to do forty
  minutes into a film. It is read from `/tmp/percBat`, which Onion's own
  `batmon` writes for the whole session, so it costs no process at all: a shell
  builtin `read` on every redraw. Absent or non-numeric and nothing is drawn.

- **Continue Watching shows five, not three.** Three was chosen when the home
  screen carried more rows than it does now; five still leaves room for the
  libraries and the status panel at 29 lines.

### Changed

- **The item screen reads its metadata with one `jq` instead of eleven.** Every
  field was its own `printf | jq` — eleven dynamically linked binaries loaded
  off an SD card to draw the screen you pass through on the way to everything
  you watch. It is the same fix the settings screen got in v0.2.1, in the place
  it costs the most.

- `plex_search` is gone with the search that used it. `PF_ROW` gained three
  columns — library, show and season titles — which is where the download tree
  gets its folder names.

### Things that cost real time to discover

- **`read` collapses runs of IFS whitespace, and tab is whitespace.** A
  tab-separated record with an empty field in the middle silently shifts every
  field after it by one, which is a bug that only appears for the rows that
  happen to have a gap — films with no season, episodes with no library name.
  The existing twelve-field loop survived it purely because everything it read
  sat before the first empty column. Records that cross a `read` are joined
  with **US (0x1f)** now, which is not whitespace, so an empty field stays an
  empty field.

- **Onion publishes the battery level as a file.** `batmon`, started by
  `runtime.sh` at boot, writes the percentage to `/tmp/percBat` and the
  charger-detect GPIO is `gpio59`. No i2c conversation with the AXP is needed;
  `axp` is for register pokes, not for this. The charging *polarity* of gpio59
  is not yet confirmed, so nothing is drawn for it.

## v0.2.2

The boot logo shipped in v0.2.1 never appeared on the device. Reported as "the
PNG isn't loading, only the text one" — which is what it looks like, and is not
what it was. The image format was never the problem: both `libSDL_image` builds
on the card decode PNG, and every 640x480 asset OnionOS ships for this purpose
is a PNG. Nothing needed converting to BMP or JPG.

What follows came out of disassembling `imgpop`, because none of it is written
down anywhere and the failure is completely silent.

### Fixed

- **The splash was killed before it could draw a single pixel.** `launch.sh`
  started `imgpop` in the background and then called `splash_hide` at the top
  of the main loop — after four cheap shell operations, so a fraction of a
  second later. Before `imgpop` can blit anything it has to load six shared
  libraries off an SD card, decode a 640x480 PNG and rotozoom it. That is
  seconds on a 1.2 GHz Cortex-A7, not milliseconds. It lost the race every
  time.

  Three changes, none of them a longer sleep:

  - It now starts **before** the rest of start-up rather than after, so its
    loading overlaps with sourcing `plex.sh` and `cache.sh`, cache recovery
    and the download worker instead of following them. The one setting it
    needs is read with `grep` rather than `pf_get`, because `pf_get` would
    fork `jq` first and that fork is time the logo is not on screen.
  - It is given a **finite duration** (2s) so it ends its own run, instead of
    the old 600s ceiling that only a kill could end.
  - `splash_hide` **waits** for it rather than killing it, with a 10s watchdog
    so a wedged blitter cannot hold up the boot. Waiting costs far less than
    it sounds: a dead `imgpop` leaves its last blit sitting in the
    framebuffer, so the logo stays on the panel by itself while `st` starts.

- **The two splash orientations were the wrong way round.** `imgpop` rotates
  every image 180° before blitting — hard-coded, `rotozoomSurface(img, 180.0,
  1.0, 1)`. It is compensating for the same panel-versus-framebuffer offset
  that `flip` compensates for in the video path, which is why every icon Onion
  ships for it is drawn upright: `wpsfail.png` reads "WPS" the right way up on
  disk, and would be upside down on the panel if the rotation were not there.

  So on a unit that needs the flip — the default — the **upright** file is the
  one to hand `imgpop`, and the pre-rotated copy is for a unit that does not.
  `launch.sh` had it exactly inverted, which would have shown the logo upside
  down had it ever got as far as showing it at all.

- **`LD_LIBRARY_PATH` no longer relies on inheritance.** `imgpop` links
  `libSDL_ttf`, which exists **only** in `miyoo/lib` — a directory `common.sh`
  never named, trusting Onion's `runtime.sh` to have exported it. That holds
  when the app is launched from the Apps menu and nowhere else, and a binary
  that cannot resolve a library dies at the dynamic loader without printing a
  word. It is named explicitly now.

### Added

- **A PocketFlex icon in the Apps menu.** It had been pointing at
  `Icons/Default/app/ffplay.png` — Onion's generic blue film-strip glyph, which
  is what a device photo of the Favorites list showed sitting next to the
  PocketFlex row.

  The slot is **74x74 RGBA**, the same across everything in
  `Icons/Default/app`, and MainUI blits it rather than fitting it, so the size
  is not a suggestion. The house style is a rounded rect with a light outline
  filling most of the square; the outline is doing real work for us, because a
  black-on-black logo has no edge of its own against a dark theme.

  `tools/mkicon.py` builds it from `image_assets/`, supersampled 8x so a 74px
  rounded corner is not a staircase, and emits two: `icon.png`, the whole logo
  including the wordmark, which stays legible at this size; and
  `icon-mark.png`, the pocket alone, if the wordmark ever proves too dense on
  a real panel. Switching between them is one line of `config.json`.
  `config.json` takes an absolute path, so both install with the app rather
  than being dropped into Onion's shared icon set.

- **The splash logs what happened.** There is no way to see this screen from a
  desktop harness, so `launch.sh` records the image it chose, how long
  `imgpop` held the panel, its exit status, and anything it printed —
  `imgpop`'s errors go to *stdout*, via `printf`, and it is silent when it
  works. That is the difference between "the logo did not appear" and a named
  reason, and it is what the next device session should be read against:

  | log says | means |
  |---|---|
  | held the panel ~0s, `rc=1`, plus a message | never started — library or decode |
  | held the panel ~3-5s, `rc=0` | drew; anything still wrong is the framebuffer |
  | drew, but upside down on the panel | this unit wants `flip` the other way |

### Notes

- Verified on the desktop with a stubbed `imgpop` that models the real one —
  slow to load, then blitting, then holding: the frame now lands before
  teardown, the watchdog releases a blitter that never exits, a missing
  binary is still a no-op, and both `flip` settings pick the file they should.
  What that cannot verify is the panel itself.
- Keep splash artwork off the outer couple of pixels. SDL_gfx sizes a rotation
  with `ceil()` and returns **642x482** for a 180° that ought to be exact, and
  the overhang is clipped at the right and bottom.

---

## v0.2.1

Device session of 2026-07-28. Four things came back from the handheld, and
every one of them was a case of the app being technically right and
practically wrong.

### Fixed

- **Every choice cost three to four seconds of black screen.** `pf_get` forked
  `jq` on *every single settings lookup*. The Settings screen reads eleven
  settings to build its rows, so changing one option cost twelve `jq`
  processes — one write and eleven reads — each one a dynamically linked binary
  loaded off an SD card on a 1.2 GHz Cortex-A7. That is the blank screen with a
  block cursor in the corner after every press.

  Settings are now read into shell variables once per process and looked up
  with no fork at all. The same Settings screen render measures **1 `jq`
  spawn** instead of twelve. `launch.sh` and `dlworker.sh` clear the flag when
  they need to see what the interface just wrote, so the file stays the source
  of truth between processes — one `jq` per playback and one per download,
  neither of which is a moment anyone is waiting on a menu.

  Values are loaded through `jq`'s `@sh`, so a server name containing quotes,
  semicolons or spaces is data and not code. Verified with a deliberately
  hostile name.

- **Direct play never worked, and it was the default.** Two sessions in the
  device log show `mode=direct` playing for one and two seconds and dropping
  straight back to the launcher — and not only on the 1080p remux, where it
  could be written off as the SoC being overwhelmed, but equally on an
  848x480 500 kbps file that should have decoded easily. So it is not a
  performance ceiling, and it is now simply gone: everything is transcoded.

  The preflight failure path used to *fall back* to direct play, which was
  worse than dead-ending — it replaced a legible error with a mysterious
  bounce back to the menu. It now reports the HTTP status and says that
  restarting Plex Media Server usually clears a stuck transcoder.

- **Downloaded video played as a small picture with black bars on all four
  sides.** The video filter only ever padded: it centred whatever it was given
  on a 640x480 canvas and never scaled anything up. Plex returns the stream at
  the source aspect and no larger than the size asked for, so a 16:9 episode
  downloaded at the 480x320 setting arrives as **480x272** — which padding
  centres with 80px pillars either side, on top of the letterboxing it already
  has for being widescreen. Exactly what the device showed.

  The filter now fits to the panel before padding, scaling by the smaller of
  the two axis ratios so the aspect is preserved, truncated to even numbers
  because yuv420p cannot represent odd dimensions. Verified against a real
  ffmpeg across eight source sizes; every one of them now spans the full 640px
  width:

  | source | fitted | on the panel |
  |---|---|---|
  | 640x360 | 640x360 | letterbox 60px |
  | 480x270 | 640x360 | letterbox 60px |
  | **480x272** | **640x362** | **letterbox 59px — was 80px pillars each side** |
  | 1920x1080 | 640x360 | letterbox 60px |
  | 640x480 | 640x480 | fills the panel |
  | 720x480 | 640x426 | letterbox 27px |

  Three things had to be got right around it. `setsar=1` after the scale,
  because a downloaded file came back tagged SAR 901:900 and ffplay applies
  SAR when sizing its window — which would re-inset the frame just fitted to
  the panel. Plain `iw`/`ih` arithmetic rather than
  `force_original_aspect_ratio`, because libavfilter 5 is what the firmware
  ships and the library lives in the device rootfs where it cannot be checked
  from the card. And `-vf` is now passed **quoted**: the filter contains `*`,
  and the old unquoted expansion would have handed it to pathname expansion on
  its way to argv.

  This costs nothing in the common case — `vf_scale` short-circuits to a
  passthrough when input and output dimensions match, so only the 320p setting
  actually pays for a resample.

- **The screen went black between every pair of screens.** `pf_menu` cleared
  the display and restored the cursor on its way out, so the gap between
  choosing something and the next screen appearing was an empty panel with a
  block cursor blinking in the corner. Every screen clears and draws itself
  anyway, so that bought nothing. The old screen now stays up — with
  "Loading..." along the bottom — until the new one replaces it in one paint.

- **Moving the cursor repainted all 29 rows.** A d-pad press changes exactly
  two rows: the one the cursor left and the one it arrived on. Those two are
  now drawn on their own, in a single `awk` pass that also handles the A–Z
  gutter, and the position counter is tracked incrementally instead of being
  recomputed with `awk` on every keystroke. No clear, so nothing flickers.

  Letter jumps still take the full path — they move an arbitrary distance,
  which an incremental counter cannot follow.

### Added

- **A boot splash on the framebuffer.** Everything before `st` is up drew
  nothing at all, so launching from Onion's menu began with a stretch of black.
  `imgpop` — Onion's own framebuffer blitter — puts the logo on screen from the
  first moment, and the terminal splash takes over when `st` starts.

  The image is pre-composed at exactly 640x480 with the logo centred on black,
  because `imgpop` blits at an x/y offset and does no scaling or centring of
  its own. Being panel-sized also means it covers the launcher's last frame,
  so there is nothing to clear first.

- **White and orange.** The accent colour is a real orange (`38;5;208`,
  `#ff8700`, the orange in the logo) rather than the bright yellow that used to
  stand in for one, and the terminal splash renders POCKET white over FLEX
  orange to match the boot logo. 256-colour indexing is safe here: this `st`
  binary carries both the `bad fgcolor %d` and `erresc(38): gfx attr %d
  unknown` diagnostics, which only exist in the SGR 38;5;N code path.

  Selection is still reverse video and nothing uses colour to carry meaning on
  its own — the panel's glare is why.

- **Subtitles are switchable everywhere they matter.** The row on the item
  screen used to disappear entirely whenever the streaming mode was direct,
  which was the default — so the feature was invisible to anyone who had not
  changed a setting first. Everything transcodes now, so it is always there,
  alongside left/right on the "Ready to play" card.

  The season/series download screen gained the same switch, because a download
  has its subtitles burned in at the moment it is fetched and cannot be changed
  afterwards without fetching the whole thing again. Queueing a single item now
  says which way the switch was set, for the same reason.

- `tools/mockscreen.sh` gained `settings` and `ready` screens, and a `PF_START`
  variable that seeds the cursor before the first draw. That is what makes the
  partial-redraw path testable: render index N by starting there, render it
  again by walking down to it, and the two have to come out byte-identical.
  They do, across four screens, separator skipping, window scrolling and
  wraparound.

### Changed

- Quality is two panel-sized options — **480p (640x480)** and **320p
  (480x320)** — named by what they are rather than by their pixel box. The old
  1280x720 option asked the server for more pixels than a 3.5" panel can show;
  anything still holding that value in an existing settings file is snapped
  back to the panel on read.
- Download quality now defaults to 320p rather than 480p. It is the setting
  whose whole point is fitting a lot of episodes on a card, and with the scale
  filter in place it fills the screen properly.
- `plex_direct_url` is gone.

### Known issues

- Which way the boot splash is oriented depends on how the panel is mounted,
  which is the same question the `flip` setting already answers for the video
  path — so `flip` selects between two shipped copies, one rotated 180. If the
  logo comes up upside down, the setting is what fixes it. This has not been
  seen on hardware yet.

---

## v0.2.0

Offline downloads. The device stops needing the server.

### Added

- **Cached downloads.** Any film or episode can be saved to the card, and a
  whole season or series can be queued in one press from its list. Downloads
  run in the background while you carry on browsing or watching, and the
  Downloads screen shows what is saved, what is still coming, and what it is
  costing in space.

  These are *transcoded* copies, not the originals — the same universal
  transcode endpoint that serves live playback, asked for `protocol=http`,
  which returns one continuous Matroska stream that curl writes straight to
  the card. Default quality is 640x480 at 720 kbps, which is roughly 150 MB
  for a 24-minute episode and is already more than a 3.5" panel resolves. The
  original 12 GB remux would neither fit nor decode.

- **Offline mode.** If the server cannot be reached, PocketFlex no longer
  quits — it opens on the downloads instead. Local playback touches no network
  at all, and watch state reporting is skipped rather than left to time out
  after the credits.

- **Subtitles on and off.** A setting, a row on every item, and — the one that
  matters — **left/right on the "Ready to play" card**, which is the screen
  you are already looking at when you remember you wanted them. Individual
  tracks can be picked per item, and the choice is written back to the server
  the way any Plex client does it.

  Subtitles are burned in by the server, so they exist only when transcoding.
  The device's ffplay is an ffmpeg 2.8 build with no libass and cannot draw a
  subtitle track itself. Direct play therefore says so instead of offering a
  switch that does nothing.

- **Watched state in every list.** Seen titles are dimmed and marked `seen`;
  seasons and shows carry `9/24`. With no artwork this was the missing piece —
  there was previously nothing at all distinguishing an episode watched last
  night from one never opened.

- **A detail panel** under the item menu: year, runtime, stream, rating, a
  progress bar and the synopsis. "Details" is gone as a destination because the
  details are simply on screen. That screen used to be four rows and twenty
  blank ones.

- **Home opens on what you were watching** — the top three Continue Watching
  titles, by name, selectable, above the libraries. One extra LAN request.

- **A splash screen**, because several seconds of black terminal during sign-in
  and server discovery is what made this feel like a script rather than an app.

- **Separator rows** the cursor skips over, and a status strip on home and on
  Downloads.

- `tools/mockscreen.sh` + `tools/drivemock.exp` render real screens from
  fixtures at the device's exact 53x29, with no Plex server and no SD card.
  Layout bugs are the ones that survive every other kind of test: the code
  runs, the API is fine, and the screen is still wrong.

### Fixed

- **START never worked as "select".** It sends **line feed**, not carriage
  return — a device button-test log shows 25 consecutive `0x0a` while START was
  being pressed and not one `0x0d` in the entire session. Worse, a LF byte
  cannot survive `_k=$(dd bs=1 count=1)` at all: command substitution strips
  trailing newlines, so it arrives as the empty string and matches nothing. The
  key reader now tests for that absence. (A `"$LF"` pattern built with
  `$(printf '\n')` would be its own trap — that variable is itself empty, and
  would match every key.) Only A has ever worked, despite both being documented
  as select since v0.1.1.
- **The button test could not be escaped.** It said "press START three times to
  exit" and then tested for `0x0d` — the byte the device never sends — so the
  only way out was to power the handheld off. Any of START, A, R1, SELECT or
  MENU now counts, three in a row, with the count on screen so it is visibly
  working.

  MENU is counted rather than exiting on sight, because the d-pad sends
  `ESC [ A` and its first byte is also `0x1b`: leaving on a bare `0x1b` would
  make the d-pad impossible to test on the screen whose whole job is testing
  it. Three *consecutive* `0x1b` cannot come from the d-pad, since `[` resets
  the run.
- **The proof-of-transcode log line proved nothing.** It cut the ffplay stream
  description at the first `(` to drop the codec profile, which removed
  everything after it too — every real log line read `decoded stream: h264`
  with no resolution, which is precisely the part that distinguishes a working
  transcode from the original file arriving untouched.
- The item count in list headers counted separator rows, so it could offer a
  number you could not navigate to.
- A synopsis built with `fold` lost its last line: the final line carries no
  trailing newline and plain `read` drops it, which reads as a summary that
  stops mid-sentence.

### Changed

- PF_ROW carries `viewCount`, `leafCount` and `viewedLeafCount` (12 fields).
- Menu rows carry a fifth `flags` field (`w` watched, `d` downloaded,
  `q` queued, `s` separator).
- Transcode and download URLs are built from one shared parameter block, so a
  downloaded file cannot drift from the same title streamed.

### Known issues

- **The download endpoint is unverified against a real server.** `start.mkv`
  with `protocol=http` is the documented single-stream form of the universal
  transcoder, but it has not yet been exercised against Plex 1.43.2 from this
  client. Everything around it — queue, index, progress, cancel, delete,
  offline playback — is tested.
- Downloads cannot be resumed. The transcode endpoint serves one continuous
  stream and honours no byte ranges, so an interrupted download is re-queued
  from the start and the fragment discarded. This is why "pause downloads while
  watching" is off by default.
- Downloads only run while PocketFlex is open. Leaving the app stops them,
  deliberately: a curl left running after the user is back in Onion's menu
  would hold the Wi-Fi and the CPU with nothing on screen to explain it.

---

## v0.1.3

Playback confirmed working on hardware. This round is presentation and
navigation.

### Added

- **Screen chrome.** Full-width reverse-video header and footer bars, with the
  title and position in the header and the live control hints in the footer.
  The previous layout assumed a 40-column terminal; the device actually gives
  about 64x25, so titles no longer truncate and the year/progress column is
  right-aligned in the space that was going unused.
- **Episode codes lead the line** — `S01E04  Cornflakes`, and `S01` on season
  rows. With no artwork, the code is the primary way to tell episodes apart, so
  it belongs where it can be scanned rather than after the title.
- **Left/right jump between letter blocks** on long lists instead of paging.
  638 shows is 30+ page presses but at most a handful of letter hops. The
  shoulder buttons cannot help — L1 is a bare modifier that emits nothing and
  R1 is Back — so the d-pad takes the job. Short lists still page.
- **Controls are stated up front.** A card before playback names the film, says
  whether it is transcoding or direct playing, and lists what every button does
  during the video. The stock ffplay owns the framebuffer and cannot be given
  an overlay, so saying it beforehand is the only honest option. Also available
  any time from Settings → Controls reference, and switchable off once learned.
- **Letterboxing.** Plex returns the stream at source aspect (a 16:9 film comes
  back 640x360), and ffplay stretched that to fill the panel. A `pad` filter now
  centres it on a 640x480 canvas. Settings → Widescreen switches back to
  stretch. Uses only `iw`/`ih` expressions, since libavfilter 5 has no
  `force_original_aspect_ratio`.
- **The decoded stream is logged.** A line reading `h264 640x346` is proof the
  server really transcoded; `hevc 1920x1080` would mean the original came
  through untouched.

### Fixed

- **Resume and watched-marking never worked.** Progress was read by parsing
  ffplay's status line, but OnionOS's ffplay build prints no status line at
  all — the binary contains none of the `aq=` / `A-V:` / `fd=` format strings
  a normal ffplay has. Every session logged `parsed 0s`, including a 17-minute
  film, so no resume point was ever saved. Position is now measured by wall
  clock and clamped to the item runtime.
- Layout was built against an assumed 40-column terminal, then 64x25 estimated
  from a photo. The device logs **53x29**, which is what it is now tested at.

### Changed

- All list endpoints now return one 9-field row shape (PF_ROW), carrying
  `titleSort`, `index` and `parentIndex`.

---

## v0.1.2

### Fixed

- **Crashed on launch: `awk: cmd. line:8: %*x formats are not supported`.**
  The list renderer padded the selected row with `%-*s` (dynamic field width).
  BWK awk on macOS accepts it, busybox awk on the device rejects it outright,
  so it passed every desktop test and then failed on the first real screen.
  Padding is now done by hand.

### Added

- `tools/lint-busybox.sh` — static checks for constructs busybox ash/awk
  reject but macOS accepts (dynamic printf widths, gawk-only builtins, `[[`,
  `local`, `echo -e`), plus a load-and-smoke pass that executes the library
  helpers so errors inside command substitutions surface locally. Verified to
  catch the exact `%-*s` regression above.
- Terminal dimensions are logged at startup. Layout depends on `stty size`,
  and if busybox can't report it everything silently shifts against a 40x24
  fallback.

---

## v0.1.1

First round of fixes after hardware testing.

### Fixed

- **Playback never started.** OnionOS's `ffplay` links `libavformat.so.56`
  (ffmpeg 2.8 era) built with no TLS backend — the library contains the literal
  string *"https protocol not found, recompile with openssl or gnutls
  enabled."* Every server connection was an `https://` plex.direct URL, so the
  player exited within a second, producing the "Loading… then straight back to
  the menu" symptom. Media URLs are now built against the server's plain-http
  endpoint; the API still uses verified https via curl.
- **Three episodes were wrongly marked as watched.** When ffplay died instantly
  the progress parser read junk off stderr and reported a near-complete
  position, which scrobbled the item. Progress is now only reported when ffplay
  ran ≥15s wall-clock *and* ≥10s of parsed playback, the parse requires the
  `aq=` field that only real progress lines carry, and the value is clamped to
  the item runtime. (The affected episodes were restored.)
- Sign-in code was unreadable — dim text on a dark yellow background.

### Added

- **Large block-text rendering** for the sign-in code and PIN pad. The code has
  to be read off a 3.5" panel and typed on another device, so it now fills the
  screen instead of being one small colour-swapped word.
- **R1 / SELECT go back.** B, X, Y and SELECT map to bare modifier keys
  (LCTRL/LSHIFT/LALT/RCTRL) which send *no bytes at all* to a terminal, so B
  cannot be read no matter what. Per st's own key table R1 sends backspace and
  SELECT sends tab, and both are now bound to Back everywhere.
- **A–Z gutter** down the right edge of long lists, marking where each initial
  begins — keyed to Plex's `titleSort`, so *The 10th Kingdom* files under `1`
  exactly as the server sorts it.
- **Jump to letter** row on lists over 40 items, offering only the initials
  that actually occur, with counts.
- **Button test** screen in Settings, which logs the raw byte each button
  produces so the mapping can be settled by observation.
- **Automatic direct-play fallback** when the server refuses to start a
  transcode.
- **Clock sync via ntpdate** at startup. The handheld has no battery-backed
  RTC, boots in 1979, and therefore rejected every TLS certificate as "not yet
  valid" (curl exit 60), silently downgrading to an unverified connection.
- Higher contrast throughout: selection is reverse video rather than a colour
  pair, so it can't degrade into grey-on-lime.

### Known issues

- The Plex server intermittently answers *every* universal-transcode start with
  a bare `400 Bad Request` while `/decision` still reports "Conversion OK".
  Observed against 1.43.2, independent of parameters, scheme, token, transport
  and session count. Restarting Plex Media Server usually clears it. The app
  now preflights, retries, and falls back to direct play.
- Decode headroom on the handheld is still unmeasured.

---

## v0.1.0

Initial working client. Not tracked in git — this repository starts at v0.1.1.

PIN sign-in via plex.tv/link, Plex Home profile switching with on-screen PIN
entry, automatic LAN server detection, library browsing, Continue Watching,
resume, mark watched/unwatched, forced transcode to panel resolution, and a
settings screen. Built entirely from binaries already present on the card
(`st`, `ffplay`, `curl`, `jq`) so there is no toolchain to maintain.
