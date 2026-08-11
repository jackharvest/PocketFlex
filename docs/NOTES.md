# Development notes

Background on how PocketFlex works and what it ran into, kept out of the README
so that stays about installing and using it. Most of this is here because it
cost time to find out.

## How it works

```
launch.sh                  owns the loop and the framebuffer
  └─ st -e lib/ui.sh       the interface, inside OnionOS's SDL terminal
       └─ writes play.req  then exits
  └─ ffplay <url>          plays, reports progress, tears the session down
```

`ffplay` and `st` both want SDL's video device, so they can never run at the
same time. The interface exits before playback and is restarted afterwards;
the navigation stack is persisted to `/tmp` so you land back on the episode
list you came from.

| File | Role |
|---|---|
| `launch.sh` | Onion entry point, playback, progress reporting |
| `lib/common.sh` | paths, settings, HTTP transport, TLS |
| `lib/plex.sh` | Plex API |
| `lib/cache.sh` | download queue, index, storage accounting |
| `lib/dlworker.sh` | background download loop |
| `lib/ui_util.sh` | terminal drawing, input, list picker, PIN pad |
| `lib/ui.sh` | screens and navigation |
| `res/cacert.pem` | CA bundle (the firmware ships none) |
| `res/splash*.png` | boot logo, 640×480; `splash.png` is for a unit that flips |
| `res/icon*.png` | Apps-menu icon, 74×74, built by `tools/mkicon.py` |
| `cache/` | downloaded video — never touched by an install |

The download worker is started by `launch.sh`, not by the interface. The
interface exits and restarts on every playback and would take its children with
it; `launch.sh` is the one process that lives for the whole session, so it is
the only one that can own a 40-minute download.


## Things that cost real time to discover

These are documented because each one fails *silently* or with a misleading
error, and they're the traps worth knowing about:

1. **`X-Plex-Platform` must be a platform Plex has a built-in client profile
   for.** With `Linux`, every `/video/:/transcode/universal/*` request returns a
   bare `400 Bad Request` with no body and no explanation. With `Chrome` it
   works. Verified against Plex 1.43.2.

2. **Plex's transcoder returns transient 400s** under rapid session churn and
   recovers after a few seconds. Playback preflights the stream and retries
   before handing the screen to ffplay, so you get a readable message instead of
   a black screen.

3. **Always stop transcode sessions.** Skipping
   `/video/:/transcode/universal/stop` leaves ffmpeg processes running on the
   server until they time out.

4. **`strong=true` on the PIN endpoint returns a 25-character code** that can't
   be typed into `plex.tv/link`. The short 4-character PIN needs `strong=false`.

5. **ffplay's `-headers` needs CRLF separators**, and its handling differs from
   ffmpeg's. Identity is passed as URL query parameters instead — understood by
   every build.

6. **Command substitution strips trailing newlines**, which silently glues the
   last row of one menu block onto the first row of the next. All menu building
   goes through helpers that keep line breaks explicit.

7. **A `case` statement inside `$(...)` breaks some `sh` parsers** — the close
   paren in the pattern terminates the substitution early. Menu generation uses
   `awk` instead.

8. **The firmware ships no CA bundle**, which is why OnionOS's own scripts all
   use `curl -k`. We bundle `cacert.pem` so the token exchange is genuinely
   verified, falling back to unverified only if the device clock is wrong.

9. **Set the CPU governor to `performance` during playback** and `touch
   /tmp/stay_awake`, or software decoding stutters and the device sleeps
   mid-film.

10. **A process spawn is the expensive unit on this SoC, and `jq` is the
    expensive process.** Reading one setting with `jq` costs a dynamically
    linked binary loaded off an SD card. Do it eleven times to draw a menu and
    the menu takes seconds. Read the file once into shell variables; use
    `@sh` so values come back shell-quoted and a server name cannot become
    code.

11. **`pad` alone does not letterbox — it only centres.** Plex returns the
    stream at the source aspect and no larger than the size requested, so what
    arrives is rarely panel-sized. Scale to fit first, or a small stream lands
    as a small picture with black on all four sides. `min(iw,ih)` arithmetic
    works in every libavfilter; `force_original_aspect_ratio` cannot be assumed
    in libavfilter 5, and the library is in the device rootfs where it cannot
    be checked from the card.

12. **`setsar=1` after any scale-to-panel.** ffplay applies the pixel aspect
    ratio when it sizes its window, so a stream tagged SAR 901:900 gets
    re-inset after being fitted. Observed on a real downloaded file.

13. **Quote `-vf`.** Fitting expressions contain `*`, and an unquoted
    expansion hands that to pathname expansion on its way to argv.

14. **`imgpop duration delay image x y`** is Onion's framebuffer blitter, and
    nothing about it is documented. Four things it actually does, read out of
    the binary, each of which is a way to get a black screen:

    - It **rotates every image 180°** before blitting — hard-coded,
      `rotozoomSurface(img, 180.0, 1.0, 1)`. That is the same panel-versus-
      framebuffer offset the `flip` setting compensates for in the video path,
      which is why every icon Onion ships for it is drawn upright. **A unit
      that needs the flip wants the upright file handed to it**, so the
      selection reads backwards and is correct.
    - `duration` is **seconds of display counted after the image is loaded**,
      so the process outlives its own start-up cost by that much — and `0`
      makes it exit without ever blitting.
    - It links **libSDL, libSDL_image, libSDL_ttf, libSDL_gfx, libpng, libz**,
      and `libSDL_ttf` lives *only* in `miyoo/lib`. A binary that cannot
      resolve a library dies at the dynamic loader without printing anything,
      so `LD_LIBRARY_PATH` is named explicitly rather than inherited.
    - It does no scaling or centring, so a splash must be pre-composed at
      exactly 640×480 — and content should stay off the outer couple of
      pixels, because SDL_gfx sizes a rotation with `ceil()` and hands back
      642×482 for a 180° that ought to be exact.

    It holds the framebuffer, so it has to be gone before `st` starts — the
    same constraint that keeps `ffplay` and `st` apart. But *killed* is the
    wrong way to end it: see 16.

15. **This `st` does support 256 colours**, whatever its lack of a colour
    table in `strings` suggests. The binary carries `bad fgcolor %d` and
    `erresc(38): gfx attr %d unknown`, which exist only in the SGR 38;5;N
    code path.

16. **A backgrounded blitter needs seconds, not milliseconds, before its first
    pixel.** v0.2.1 started `imgpop` and killed it at the top of the main loop
    a fraction of a second later. Before it can blit anything it has to load
    six shared libraries off an SD card, decode a 640×480 PNG and rotozoom it.
    It lost that race every time, so the boot logo never appeared once and the
    terminal splash was the only one ever seen — which reads exactly like an
    unsupported image format, and is not.

    The fix is not a longer sleep. It starts before the rest of start-up
    rather than after, so its loading overlaps with ours; it is given a finite
    `duration` so it ends its own run; and it is *waited for*. Waiting is
    nearly free, because **a dead `imgpop` leaves its last blit sitting in the
    framebuffer** — the logo stays on the panel by itself while `st` starts.

17. **A frozen app and a live app look identical on this panel.** The
    framebuffer keeps its last contents, so an interface that has lost its
    input still sits there looking fine — the same property that lets a dead
    `imgpop` hold the boot logo while `st` starts. After a sleep, `st` can stop
    receiving input entirely and nothing inside it can recover: the fix has to
    come from `launch.sh`, which can kill the terminal and start another. The
    backlight PWM (`/sys/devices/soc0/soc/1f003400.pwm/…`, read out of
    `batmon`) going dark and coming back is the signal that a wake happened.

18. **Onion's Wi-Fi state is two things, and both have to be set.** The radio
    is `/customer/app/axp_test wifion|wifioff` plus the
    `wpa_supplicant`/`udhcpc` pair, but MainUI's *intent* lives in
    `/appconfigs/system.json` as `"wifi": 0|1`, and `runtime.sh` re-runs the
    whole sequence from that value on the way back into the menu. Change only
    the radio and the launcher quietly undoes it; change only the flag and
    nothing happens until you leave. Onion's own notes also say
    `wpa_supplicant` and `udhcpc` inheriting MainUI's preloaded `libpadsp.so`
    is what locks the device up when entering an app afterwards, so ours are
    started with `LD_PRELOAD` cleared.

19. **`read` collapses runs of IFS whitespace, and tab is whitespace.** A
    tab-separated record with an *empty field in the middle* loses it, and
    every field after it shifts by one — so the bug only appears for the rows
    that have a gap, which is films (no season) and episodes from endpoints
    that omit the library name. Anything crossing a `read` is joined with
    **US (0x1f)** instead, which is not whitespace and therefore delimits
    exactly once per occurrence. `awk -F` has no such rule and is unaffected,
    which is why the same data is fine in a pipeline and wrong in a loop.

20. **A variable set inside `$( )` does not come back.** `pf_menu` is always
    called as `_sel=$(... | pf_menu ...)`, which is two nested subshells, so
    the cursor index it assigned to `PF_MENU_INDEX` on the way out was
    discarded every single time. That is why the list always reopened at the
    top. Anything a menu needs to tell its caller beyond the payload has to
    travel through a file.

21. **Onion publishes the battery level as a file.** `batmon` — started by
    `runtime.sh` at boot and running for the whole session — writes the
    percentage to **`/tmp/percBat`**, and the charger-detect line is
    `/sys/devices/gpiochip0/gpio/gpio59/value`. So a battery readout costs a
    builtin `read`, not a process, and `axp` (which pokes i2c registers) is not
    the way in. The polarity of gpio59 is unconfirmed, so charging state is not
    drawn yet.

22. **Plex's `/search` is not a letter index and cannot be made into one.** It
    matches a substring anywhere in a title and ranks by relevance, across
    every type including episodes. The letter index is a separate endpoint,
    `/library/sections/K/firstCharacter`, which returns the characters, their
    counts and a key to fetch each one — keyed to `titleSort`, so it agrees
    with the A–Z gutter for free.

23. **The Apps-menu icon slot is 74×74 RGBA**, uniformly across everything in
    `Icons/Default/app`, and MainUI blits it rather than fitting it. The house
    style is a rounded rect with a light outline filling most of the square —
    that outline is load-bearing for us, because a black-on-black logo has no
    edge of its own against a dark theme. `config.json` takes an absolute path,
    so the icon can live in the app's own `res/` and be installed with it
    rather than dropped into Onion's shared icon set.

24. **Transcoding the video does not mean transcoding the audio, and Plex will
    pass 5.1 straight through.** Because `X-Plex-Platform` has to be `Chrome`
    (see 1), Plex applies the *Chrome* client profile — and Chrome decodes
    multichannel AAC, so a source with AAC 5.1 has its audio copied through
    untouched no matter how small the picture it is wrapped around. The device
    cannot play it: `ffplay` here is ffmpeg 2.8 against an SDL that opens a
    stereo device (`init audio 20`), and handed six channels the audio path
    stalls. A stalled audio clock drags the video with it, so the symptom is a
    film playing at half speed **in silence** — which reads like a title that
    skipped the transcoder, and is not.

    It is invisible unless the audio stream is logged next to the video one.
    Two 1080p h264 films, one fine and one broken, produce identical video log
    lines.

    Asking the server to fix it does not work — `maxAudioChannels=2` is
    rejected with a bare 400 on this path. Force it in the filter graph with
    **`-af aformat=channel_layouts=stereo`**, which also repairs downloads
    fetched before the fix. Use `aformat`, not the swresample options `ocl` /
    `out_channel_layout`: those exist in 2.8 but were removed in later ffmpeg,
    so a filter written that way cannot be tested anywhere but the device.

25. **This server wants ~30 seconds between transcode session starts.** Faster
    than that and `/video/:/transcode/universal/start` answers a bare 400 for
    valid requests, including ones that had just succeeded, then recovers on
    its own once left alone. It is the same transient 400 as 2; what matters
    is that it makes rapid A/B testing against a live server actively
    misleading — a parameter can look rejected when the server was simply
    still busy. Space the probes, and interleave a known-good baseline.

26. **The seek keys belong to `ffplay` and cannot be rebound.** They are
    compiled in; the large stride is its page-up/page-down binding of ±10
    minutes. Nothing in this app sits between the button and the player while
    the player owns the framebuffer. Seeking past the available segments of a
    Plex HLS transcode wedges it with the last frame still on the panel; MENU
    is ESC, which `ffplay` does honour, which is why that gets you out.

27. **The font size cannot be changed, and `-g` is not the way round it.**
    Tried and reverted; this is here so it is not tried again.

    `st` advertises `[-f font]` and carries the string
    `fonts/FIXED_V0.TTF`, which reads like an invitation. It is not. That path
    exists nowhere on the card, and the binary links `libc`, `libSDL-1.2` and
    `libpthread` — **no `SDL_ttf`, no `SDL_image`, no `SDL_LoadBMP`.** There is
    no font loader behind the flag and no image decoder anywhere in it. The
    font is compiled in at 12x16, which is where 53x29 comes from, and the
    usage line is inherited verbatim from upstream st-sdl.

    `-g` looked like the way in. `st` carries `set videomode %dx%d` and Onion's
    SDL calls `MI_GFX_BitBlit`, the SigmaStar hardware scaler, so the reasoning
    was that a mode smaller than the panel would be scaled up to fill it — the
    same path that makes a 320x240 emulator fill this screen — and a smaller
    terminal would therefore be a bigger font for free.

    **On the device `st -q -g 40x22 -e …` exits rc=1 immediately.** No video
    mode is set, `ui.sh` never starts, and `launch.sh` sees a terminal that
    exited with no request and leaves. The log is two lines:

    ```
    terminal geometry -g 40x22
    terminal exited rc=1 with no request; leaving
    ```

    The trap inside the trap: the size was a **saved setting**, so once it was
    written the app passed `-g` on every launch and died the same way every
    time. It was not a failed feature, it was an app that would not open, and
    the only fix from outside was editing `settings.json` on the card. Anything
    that changes how `st` is invoked has to be proven before it can be
    persisted, not after.

    The same two missing libraries are why there is **no artwork of any kind
    inside the interface** — no thumbnails, no watermark, no logo in a corner.
    That is a property of the terminal, not of the device: `imgpop` and
    `infoPanel` both draw PNGs perfectly well, but only by holding the
    framebuffer, which is the same constraint that keeps `ffplay` and `st`
    apart.

## Testing without the SD card

`tools/pftest.sh` runs the same `lib/*.sh` against a local data directory:

```sh
tools/pftest.sh login      # PIN sign-in
tools/pftest.sh sections   # list libraries
tools/pftest.sh url <key>  # print the transcode URL
```

`tools/drive.exp` replays keystrokes into the real UI inside a pty:

```sh
expect tools/drive.exp "$PWD/App/PocketFlex" "wait:10 ok wait:6 down ok wait:6"
```

`tools/mockscreen.sh` draws real screens from fixtures at the device's exact
53x29, with no server and no card — which is what catches layout bugs, the ones
where the code runs, the API is fine, and the screen is still wrong:

```sh
expect tools/drivemock.exp home "down down" | tools/screen.py 29 53
# screens: splash list longlist item home downloads dlfolder dlseason
#          dltree letters subs settings ready
```

Most of those are fixtures that reproduce a layout. **`dltree` is different**:
it lifts the shipping `screen_downloads` out of `lib/ui.sh` by name and runs it,
which is the only way to test *navigation* rather than drawing — that A on a
folder opens it, that backing out lands on the folder you left, that a folder
emptied by a delete does not strand you on a screen with one row:

```sh
expect tools/drivemock.exp dltree "down down down down ok down down ok down ok"
```

`PF_START` seeds the cursor before the first draw, which is always a full
repaint — that is what makes the partial-redraw path testable. Render a row by
starting on it, render it again by walking down to it, and the two have to come
out byte-identical:

```sh
PF_START=0  expect tools/drivemock.exp longlist "down down down" | tools/screen.py 29 53
PF_START=3  expect tools/drivemock.exp longlist ""               | tools/screen.py 29 53
```

`tools/lint-busybox.sh` catches constructs macOS accepts and busybox rejects.
Run it before every deploy; it is what would have caught the `%-*s` that shipped
in v0.1.1.

## The home screen

Two columns: Home and the libraries you keep down the left, the rows down the
right. Left and right switch panes, up and down move inside one. **The rail
never goes away** — choosing a library changes what is beside it, it does not
replace the screen.

```
 Home           |  CONTINUE WATCHING          Movies         |  All of Movies      A-Z
 Anime          |  S01E05  Dr. STONE - S 34%   Home          |  CONTINUE WATCHING
 Movies         | +S03E05  Dragon Ball Z 16%   Anime         | +Blade Runner 2049   9%
 TV Shows       |  RECENTLY ADDED IN ANIME    >Movies        |  RECENTLY RELEASED
 -------------- |  S01E28  Frieren - Aureole   TV Shows      |  Dune: Part Two    2024
.Downloads  5+3 |  RECENTLY RELEASED          -------------- |  RECENTLY ADDED
 Browse A-Z     |  Dune: Part Two        2024 .Downloads 5+3 |  The Substance     2024
 Settings       |  The Wild Robot        2024  Browse A-Z    |  RECENTLY PLAYED
```

A single column spent most of a 29-row screen on a library list that never
changes. The rail costs 14 columns and gives the whole height back to content.

The rows are **Plex's own hubs** — `/hubs` for Home, `/hubs/sections/<id>` for a
library. The server decides what the rows are and what they are called, and
returns all of them in one request, which is the only affordable shape on this
device: building them by hand is a request per row per library. Music and photo
hubs are dropped, and so is any hub left empty by that. A server too old to have
hubs falls back to Continue Watching / Recently Released / Recently Added built
the long way, and says so in the log.

**Settings → Home screen** turns Continue Watching and Recently Added on and
off and sets how many items each row holds; **Libraries** under it hides the
libraries you do not use — off the rail, out of Browse by letter, and with no
Recently Added row. What is stored is the hidden list, not the pinned one, so a
library added to the server later turns up by itself.

The content behind those rows is cached for 90 seconds, because it is a request
per library and home is drawn again every time you back out of anything.
Playback deletes the cache on its way out.

## Navigating a large library

Lists over 40 items get an **A–Z gutter** down the right edge marking where each
initial starts, plus a **Jump to letter** row offering only the initials that
actually occur, with counts. Both are keyed to Plex's `titleSort`, so *The 10th
Kingdom* files under `1` exactly as the server sorts it.

**Browse by letter** on the home screen is the same idea across every library at
once. It uses Plex's own `/library/sections/K/firstCharacter` index — the
listing its web client draws its A–Z rail from — so the letters carry real
counts and the results are shows and films only. It deliberately does *not* use
`/search`: search matches a substring anywhere in a title, which returned every
episode containing the letter somewhere, and that is what this screen used to do.

The cursor is remembered per screen, in the navigation stack itself, so backing
out of an episode lands on that episode and finishing a film returns you to the
row you played it from.

## Why it feels quick now

Two things made the interface feel like a script rather than an app, and both
were self-inflicted:

1. **`pf_get` forked `jq` on every settings lookup.** The Settings screen reads
   eleven settings to draw its rows, so changing one option cost twelve `jq`
   processes off an SD card — three to four seconds of black screen after every
   press. Settings are now read into shell variables once per process. Same
   screen, **1 `jq` spawn instead of 12**.

2. **Every keystroke repainted all 29 rows, and every screen change cleared the
   display.** A d-pad press changes two rows; those two are now drawn on their
   own, and the old screen stays up until the new one replaces it in one paint.

The `tools/mockscreen.sh` harness proves the partial repaint agrees with the
full one: render a row by starting on it, render it again by walking down to
it, and the two come out byte-identical — across four screens, separator
skipping, scrolling and wraparound.

