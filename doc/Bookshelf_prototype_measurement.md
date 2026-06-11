# Bookshelf Prototype Measurement and QA

This is the lightweight measurement harness for the bookshelf prototype. It is
kept outside provider and UI code so provider/UI workers can add or remove
instrumentation without changing the evidence format.

The summary CSV schema is:

```csv
timestamp,commit,device,scenario,cache_state,library_size,median_ms,p95_ms,max_ms,notes
```

Raw samples are local scratch. The helper writes them to
`.tmp/bookshelf-measure/samples.csv` by default and aggregates them into the
schema above.

## Scenarios

Use these scenario names exactly:

| Scenario | Start | Stop |
|---|---|---|
| `default_bookshelf_launch` | KOReader is launched without a file or directory argument and Library is the configured home view (`start_with=library` or `home_view=library`) | Bookshelf Home is the first app surface, after any upstream one-time notices are dismissed |
| `reader_home_bookshelf_return` | Home action is invoked from an open document | The document is closed and Bookshelf Home is visible |
| `enter_home_bookshelf` | Home/Library launch, or Home action from another view | My Library content is visible and the view accepts input |
| `downloaded_books_cached_load` | Library requests cached book rows for the visible page | Cached book data returns to the caller |
| `first_visible_paint` | Home/Library entry or library page transition starts | First non-placeholder library content is visibly painted |
| `first_thumbnail_row_resolved` | Home/Library entry or library page transition starts | Every thumbnail slot in the first visible row has resolved to a cover or no-cover placeholder |
| `shelf_page_transition` | Library page swipe/tap is accepted | The next library page is visible and stable |
| `tap_acknowledgement` | Finger/key activation begins | Visual focus, pressed state, haptic feedback, or resulting navigation confirms the tap |
| `downloaded_book_open` | Downloaded-book activation begins | The selected book starts opening or an actionable book error is visible |
| `dictionary_lookup_open` | Dictionary lookup action begins | Dictionary lookup opens or an actionable dictionary-unavailable state is visible |
| `add_books_open` | Add Books action begins | Add Books view or an actionable error state is visible |

Keep the same start and stop point for all iterations in a run. Use `notes` for
anything that may explain variance, such as first run after reboot, OPDS server
disabled, or dictionaries missing.

Scenarios that end on Bookshelf Home assume Library is the configured home
view. The stock launch default remains the file manager; the Library home is
an opt-in setting, not a changed default.

## Recording Timings

List supported scenarios:

```sh
python3 tools/bookshelf_measure.py scenarios
```

Record one manual sample:

```sh
python3 tools/bookshelf_measure.py add \
  --device remarkable2 \
  --scenario enter_home_bookshelf \
  --cache-state warm \
  --library-size 250 \
  --elapsed-ms 184.6 \
  --notes "rm2, first page already cached"
```

Record at least 10 manual iterations. The helper prompts for one elapsed
millisecond value per iteration:

```sh
python3 tools/bookshelf_measure.py repeat \
  --iterations 10 \
  --device remarkable2 \
  --scenario first_visible_paint \
  --cache-state cold \
  --library-size 250
```

For non-interactive entry, pass values directly:

```sh
python3 tools/bookshelf_measure.py repeat \
  --iterations 10 \
  --device remarkable2 \
  --scenario downloaded_books_cached_load \
  --cache-state warm \
  --library-size 250 \
  --values 31,29,30,32,29,30,31,33,30,29
```

For emulator or host-side wrappers that perform exactly one scenario and exit,
the helper can repeat and time the command:

```sh
python3 tools/bookshelf_measure.py run \
  --iterations 10 \
  --device emulator \
  --scenario add_books_open \
  --cache-state warm \
  --library-size 250 \
  -- ./path/to/one-scenario-wrapper
```

Summarize raw samples into the required schema:

```sh
python3 tools/bookshelf_measure.py summarize \
  --samples .tmp/bookshelf-measure/samples.csv \
  --output .tmp/bookshelf-measure/summary.csv
```

`p95_ms` uses nearest-rank p95. With 10 iterations, that is the slowest sample.

## Manual Visual QA Checklist for reMarkable

Record the date, device model, build commit, cache state, library size, and
tester in the evidence notes before starting.

| State | Setup | Check |
|---|---|---|
| Empty | Library has zero books | Empty library state is legible, centered/aligned, and has one clear path to Discover |
| Single book | Library has one book with normal metadata and cover | Continue, Recently added, and All books are positioned intentionally without odd empty-row artifacts |
| Normal | Library has enough books to fill more than one page | Rows, page transitions, selection, and thumbnails remain stable across navigation |
| Grid rhythm | Inspect Library, Continue, Recently added, All books, and bottom navigation | Header actions, chevrons, counts, sort/view controls, covers, labels, and bottom nav share a visible grid and baseline rhythm |
| Typographic hierarchy | Inspect title, section labels, item titles, metadata, and controls | Heading feels literary but not oversized; section labels and item text have clear emphasis without visual shouting |
| Placeholder cover | Use Quickstart or a no-cover book | Placeholder line breaks are intentional, centered, and do not create awkward orphan letters or cramped text |
| Long title | Add a book with a very long title and author | Title truncates or wraps without overlapping cover, metadata, or adjacent items |
| Japanese title | Add a book with Japanese title and author metadata | Glyphs render, line breaks are acceptable, and fallback fonts do not change row height unexpectedly |
| No cover | Add a supported book with missing/invalid cover art | Placeholder is visible, sized like covers, and resolves without repeated redraw flicker |
| OPDS down | Configure an OPDS catalog URL that refuses or times out | Discover paints the last cached rails with an "as of" timestamp; library search's catalog section degrades without blocking device results; Library stays usable |
| Wi-Fi off | Disable Wi-Fi before opening Discover | Offline is a mode: the cached rails paint with the staleness whisper, no spinner is left running, and local Library remains usable |
| Dictionary ready | Install at least one dictionary | Dictionary action is visible and lookup opens after Library navigation |
| Dictionary missing | Remove or disable dictionaries | Missing-dictionary state is clear and lookup reports an actionable unavailable state |
| Configured-home launch | Start KOReader without file/directory arguments and Library set as the home view | Bookshelf Home appears; with no home setting, the stock file manager remains the default |
| Reader Home | Open a book, then invoke Home | Reader closes to Bookshelf Home, not the folder browser |
| Files escape hatch | Tap Files from Bookshelf | Existing KOReader file manager opens only as an explicit secondary path |
| Ghosting/refresh | Page through several shelf pages on the device | Text and thumbnails do not leave distracting residue after expected refresh behavior |
| Suspend/resume | Suspend from Library, then resume | Library state, selection, thumbnails, and touch handling survive resume |

Do not depend on framebuffer capture, device-private scripts, global package
installs, or network services that are not part of the scenario under test.

## Local Emulator Harness

KOReader's SDL emulator can be exposed for manual QA through a disposable
noVNC container. The wrapper lives in local scratch at
`.tmp/bookshelf-novnc/` and installs only container packages, not host Lua or
other global runtimes.

The current reMarkable-sized run target is:

```sh
docker run -d --name koreader-bookshelf-novnc -p 6080:6080 \
  -e KO_HOME=/kobuild/install/koreader \
  -e EMULATE_READER_W=1404 \
  -e EMULATE_READER_H=1872 \
  -e EMULATE_READER_DPI=226 \
  -v "$PWD:/work" \
  -v "$PWD/plugins/bookshelf.koplugin:/kobuild/install/koreader/plugins/bookshelf.koplugin:ro" \
  -v koreader-bookshelf-build:/kobuild \
  koreader-bookshelf-novnc
```

Open `http://localhost:6080/vnc.html?autoconnect=true&resize=scale` to inspect
the live SDL window. Computer Use can see that browser surface; `xdotool` inside
the container can inject deterministic taps against the Xvfb display when
browser-canvas pixel clicks are unreliable.

Prefer recreating the disposable container over `docker restart` when validating
startup. A restart can leave Xvfb display `:99` marked active and break noVNC
while KOReader continues running. On a fresh emulator profile, KOReader may show
its upstream one-time color-rendering notice before Bookshelf; dismiss that
notice before judging the shelf, or launch with `KO_HOME=/kobuild/install/koreader`
so the existing emulator settings file is used.

Observed on 2026-05-05:

- noVNC exposed KOReader on `localhost:6080` at 1404x1872.
- The first manual Bookshelf open caught a `TextBoxWidget` width crash caused by
  long Continue metadata in the mandatory column.
- After constraining the Continue row hierarchy, the first Shelf layout opened
  cleanly with Dictionary status, Continue, Downloaded, Add Books, and tertiary
  Files.
- The second manual pass caught a path leaking into Continue metadata; current
  detection now labels the active book as `Reading`.
- Z supplied a `My Library` visual target: title/status, continue-reading card,
  recently-added cover row, all-books grid, and bottom actions. The prototype now
  follows that hierarchy with deterministic placeholder covers and cached
  KOReader cover bitmaps.
- No-argument startup now uses the `library` startup target and dispatches the
  Library plugin instead of showing FileManager directly. Explicit file paths
  still open the reader, explicit directory paths still open FileManager, and
  the Library `Files` action remains the recovery hatch.
- Reader Home now closes the document, opens FileManager as KOReader's shell,
  and emits generic `ShowHome`; the Library plugin claims that event only when
  Library is the configured home view.
- Container verification added `spec/unit/bookshelf_home_spec.lua` for launcher
  behavior and lazy integrations. The live noVNC startup path reached Bookshelf,
  with KOReader's first-run color notice as the only visible blocker before
  dismissal.
- Launching the noVNC container with `KO_HOME=/kobuild/install/koreader`
  produced a clean startup screenshot of Bookshelf at
  `.tmp/bookshelf-visual-pass/startup-home-install-ko-home.png`.

Observed on 2026-06-11:

- The Discover surface replaced Add Books: two anchor rails (New in your
  library, Popular at home) plus one rail per custom catalog shelf, painted
  from a persisted snapshot and refreshed in the background. The rail stack
  pages vertically with a square pager above the nav.
- The refresh chain runs exactly one network fetch per scheduled UI pass with
  a positive inter-step delay; a zero-delay (nextTick) chain starves input
  because UIManager drains every due task before polling. Verified in the
  emulator: vertical swipes page the stack while the chain is mid-fetch.
- A rail fetch failure carries the standing snapshot's rows forward instead
  of erasing them; a successful empty fetch on a shelf drops the rail.
  Persisted snapshots are bounded (12 shelf rails, 24 rows per rail).
- Pre-shelf map-shaped snapshots are treated as cache misses: the anchor
  skeleton paints and the first online refresh rewrites the array shape.
- Catalog book identity is the acquisition URL path; thumbnails are artwork
  only. Legacy thumb-path download-map keys migrate lazily on first resolve,
  verified live with an on-device mark surviving the re-key.
- Suite state at `b6c8a7264`: 111 bookshelf spec successes, luacheck clean.

## Sample Library Corpus

Use the seeder to build a local, gitignored QA library with public-domain EPUBs,
plain-text no-cover documents, and local overflow fixtures:

```sh
python3 tools/bookshelf_seed_sample_library.py
```

For the noVNC container that stores settings under the `koreader-bookshelf-build`
volume, also apply the same settings inside the installed KOReader tree:

```sh
docker run --rm --entrypoint python3 \
  -v "$PWD:/work" \
  -v koreader-bookshelf-build:/kobuild \
  koreader-bookshelf-novnc \
  /work/tools/bookshelf_seed_sample_library.py \
  --settings /kobuild/install/koreader/settings.reader.lua \
  --runtime-library /work/.tmp/bookshelf-sample-library
```

Observed on 2026-05-06: the seeded corpus contains 52 files. KOReader metadata
extraction produced 52 bookinfo rows and 45 cached cover bitmaps, leaving a useful
mix of real covers and intentional placeholder/no-cover cases for visual QA.
Captured emulator screenshots live under `.tmp/bookshelf-sample-library-*.png`.

## Harness Operating Model (2026-06-10)

The container start script supervises all four services (Xvfb, x11vnc,
websockify, KOReader) in relaunch loops with stale X-lock cleanup, so the
container never exits and its published port registers with the host exactly
once. Do not recreate the container for code changes:

- Plugin module changes (`ui.lua`, `provider.lua`, `gridlayout.lua`, etc.)
  apply on the next library open; they are `dofile`d live via the bind mount.
- `main.lua` changes need a KOReader process restart only (the plugin loader
  caches it per process): `docker exec <container> pkill luajit` relaunches
  KOReader in seconds with the viewer session still connected.
- Recreate the container only for image or mount changes.

Headless captures: install imagemagick inside the container (ephemeral), then
`docker exec -e DISPLAY=:99 <container> import -window root /tmp/shot.png`.

Unit specs run inside the container via the busted farm script (rebuilds its
symlink workspace after container recreation):

```sh
.tmp/run-bookshelf-specs.sh                 # all bookshelf_*_spec files
.tmp/run-bookshelf-specs.sh bookshelf_ui_spec.lua
```

Note: `./kodev test` cannot run in this setup (it re-resolves CMake against
the original build path and fails on permission-preserving copies through the
VM mount), and a missing `spec/front` link makes the meson runner report
success with zero tests — always confirm the printed test count.

## Fonts

KOReader resolves user fonts from its data-dir `fonts/` directory on every
platform; the bookshelf reading-preset work selects faces through a candidate
chain that queries installed faces at runtime and falls back to the bundled
Noto family when a preferred face is absent. Font binaries are intentionally
not part of this repository or any upstream patch: the upstream-facing
instruction is "install your preferred text face into `koreader/fonts/`", and
preset derivation adapts to whatever is present. For QA, drop TTFs into the
emulator's `fonts/` directory (on the build volume, so they persist) and
restart the KOReader process.

## Upstreaming Shape

The prototype decomposes into independent upstream candidates, in submission
order:

1. ReaderFooter three-zone status bar layout: standalone, no bookshelf
   dependencies.
2. The Library home: `bookshelf.koplugin` plus minimal core seams, offered as
   an opt-in home-view setting (the file manager remains the default), with
   the spec suite and this measurement/QA evidence attached.
3. The reading-presets engine: derives typography (font size, margins) from a
   characters-per-line target measured with the actual installed font, with
   graceful font-candidate fallback. Opinionated preset values ship as
   configurable defaults, not fixed policy.

Fonts and personal configuration bundles are out of scope for all of the
above (see Fonts).
