# Contributing

Thanks for taking a look. Two things up front:

1. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before touching code, and
   [docs/DESIGN.md](docs/DESIGN.md) before touching anything visual. Both encode rules that were
   learned the expensive way.
2. This is a tool that walks a person's whole home folder. **Safety rules are not negotiable** —
   see below. A PR that weakens any of them will be closed.

## The four safety rules

- Exactly one delete path in the entire app: `trashItem()` (`FileManager.trashItem`). Nothing is
  ever unlinked. If you find yourself writing `removeItem`, stop.
- Paths matched by `isProtected()` (the home directory itself, `~/Library`, …) can never be removed
  as a whole; their children can.
- Emptying the Trash is always performed *by* Finder. Outside the sandbox the app asks Finder to do
  it (`emptyTrashViaFinder`, AppleScript). In the App Store sandbox macOS refuses that event
  outright — no consent prompt is ever shown — so the app instead opens the Trash in Finder and the
  user empties it there. Either way, this app never unlinks anything itself.
- The Docker page is read-only. Images and volumes live inside a virtual disk with no per-item
  path, so the app points at Docker Desktop instead of pretending to prune.

## Dev setup

You only need the Xcode Command Line Tools — full Xcode is not required, and `xcodebuild` being
missing is normal here.

```bash
swift build          # debug build
swift run SelfTest   # every check must pass before a PR is mergeable
swift run DiskCleaner
```

`swift test` does not exist in this repo: the Command Line Tools ship no XCTest, so regression
coverage lives in the `SelfTest` executable target. Add a check there when you add logic.

## The easiest useful contribution: cache knowledge base

`Sources/DiskCleaner/Resources/safety_db.json` is the list the two cache pages understand —
**App Caches** and **Dev Caches**. More real entries = a more useful app. One entry:

```json
{
  "name": "Codex 崩溃转储",
  "what": "Codex 崩溃时生成的 .dmp 报告，只用于上报诊断",
  "whatif": "删掉不影响任何功能",
  "rec": "无需恢复；下次程序崩溃会自动生成新的报告",
  "path": "~/Library/Application Support/Codex/Crashpad/pending",
  "level": "safe",
  "grp": "general",
  "app": "com.openai.codex",
  "icon": "openai"
}
```

- `path` supports `*` globs and must be written from `~` — never an absolute machine path.
- `level` is `safe` or `warn`. When in doubt, `warn`: an entry that is too cautious still tells the
  user something; one that is too confident deletes their work.
- `cost` splits `warn` in two, and **every `warn` entry needs it**. One question decides it: once
  this is deleted, can the thing be fetched again?
  - `redo` — yes. Model weights, dependency caches, simulator runtimes, toolchains. Deleting costs
    time and bandwidth, not data.
  - `data` — no. App data inside an emulator, photos in a chat, session records, a state snapshot.
    There is no second copy anywhere to download.
  The app shows these as two different badges (Re-downloadable / Data loss) and counts them as two
  separate buckets, so getting this wrong tells the user to delete something that can't come back.
  A missing `cost` falls back to `data` and fails `SelfTest`, so it can't slip through quietly.
  `safe` entries carry no `cost` — no cost is not the same as an empty cost.
- Overlapping paths are fine (they happen a lot), but the UI never sums them — keep it that way.
- Entries are grouped by `grp`: `general` and `cn_app` render on App Caches, `dev` on Dev Caches.
- `app` is the owning app's bundle id, `icon` the brand mark's file name under
  `Sources/DiskCleaner/Resources/BrandIcons/`. The leading tile resolves in one order across every
  page: real app icon → brand mark → SF Symbol (rows with no path) → one generic fallback. Only ship
  an `icon` whose official vector exists there, and keep `SelfTest`'s slug check green.
- `name`, `what`, `whatif` and `rec` are Chinese source text too, and go through the same coverage
  gate as the UI: every new entry adds **four** strings to translate into all nine tables. Mention
  it in the PR description so a reviewer knows to expect them.

## Skins

The six themes are data. They live in `Sources/DiskCleaner/Resources/skins.json` — one array, one
object per theme — and the file documents every field it accepts under `_字段` at the top. The app
parses it at launch with per-field fallbacks and drops back to a plain built-in theme if the file is
unreadable, so a malformed PR can't leave anyone with a blank window; `SelfTest` will still fail,
so run it anyway.

To add a theme:

1. Append one object to `skins` in `skins.json`. `id` must be new, lowercase and hyphenated —
   changing an existing `id` is a different theme as far as saved preferences are concerned.
2. `name` and `tagline` are Chinese source text. They go through the same gate as the rest of the
   UI, so a new theme adds two strings that need translating into all nine tables. Mention it in the
   PR description so a reviewer knows to expect them.
3. Leave `tier` at `free` unless you are the maintainer — `premium` only groups anything when
   `Channel.showsPricing` is true.
4. Keep the house rule: `ink` / `inkSecondary` carry all body text and are never tinted; colour goes
   only to icon tiles, the ring chart, buttons and badges; a page header never gets a saturated fill.

Array order is the order on the Skins page, and the first entry is the default theme. The page
renders a live thumbnail of each theme from its own tokens, so a new theme shows a reviewer what it
looks like before anyone installs it.

## Translations

Chinese source text **is** the localization key: `L("扫描完成")` looks up the string `扫描完成`.
Simplified Chinese needs no table at all — reading the key *is* the Simplified rendering — which is
why `zh-Hans.lproj` holds only `InfoPlist.strings`. Every other language owns one
`Sources/DiskCleaner/Resources/<code>.lproj/Localizable.strings`, and there are nine of them:
`en`, `zh-Hant`, `ja`, `ko`, `de`, `es`, `fr`, `ru`, `pt-BR`.

- Wrap every user-visible string: `L("…")`, or `LF("已选 %d 项", n)` when it takes arguments.
- Counts go through `cnt(n, "个文件")`; each language inflects its own measure word. English and the
  Romance languages pick singular/plural, Russian picks a separate form for 2–4 (`3 файла` but
  `11 групп`), Japanese and Korean don't inflect. Don't also write the unit inside the template —
  that's how "27 items items listed" was born.
- `%@` in `String(format:)` only accepts objects. Passing a Swift `Int` is an `EXC_BAD_ACCESS` that
  reproduces in English only. Use `%d`.
- `bash build_app/build.sh` fails the build if coverage, positional specifiers, or the `%@`-with-Int
  pattern check out of line. Run it before opening a PR.

Languages are discovered by directory, so there is no registry to update — dropping in a
`<code>.lproj/Localizable.strings` and adding the case to `AppLanguage` is the whole wiring.

**Adding a language**

1. Copy `en.lproj/Localizable.strings` to `<code>.lproj/Localizable.strings` — the keys stay Chinese.
2. Translate the values. Keep the leading space where the English value has one (some values are
   fragments concatenated after a `。`), and keep `%1$@`-style positional specifiers exactly as they
   are: mixing positional and non-positional in one string is an `EXC_BAD_ACCESS`.
3. Add the case plus its `code` and `menuLabel` to `AppLanguage` in `Sources/DiskCleaner/L10n.swift`.
   Language self-names don't get translated; mark them `// l10n-scan: skip` or the gate will ask
   every table to translate the word "日本語".
4. Unless the language is Chinese (which `cnt(…)` short-circuits), add a measure-word table to
   `measureWords(_:)` in the same file. Follow the `measureGap(_:)` next to it for spacing — Korean
   measure words attach to the numeral (`6개`), Latin and Cyrillic ones need the space.
5. `swift build_app/l10n_tool.swift check .` must end with `N 种语言覆盖完整 ✓`.

## Translated READMEs

`README.md` is the source of truth. Every other `README.<code>.md` is a translation of it, and each
one says so at the top — where a translation and the English file disagree, the English file wins.

Nothing checks them. `l10n_tool.swift` guards the nine in-app tables and nothing else, so forgetting
a translation will not fail the build. Change `README.md` and the translated files in the same PR, or
say in the PR description that the translations are still behind.

They share assets. The screenshots under `docs/screenshots/` and `docs/demo/` are shot in English and
referenced by every translation, which is why each one carries a note saying so. Don't shoot a set
per language — the app's ten languages are the app's job, not the README's.

## Visual changes

Screenshot them. `SnapshotMode` renders every page to PNG without needing screen-recording
permission, and it runs against a synthetic home folder so no real files appear:

```bash
bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome   # writes ~55 GB — once, not per run
DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome DISKWISE_SHOTS=/tmp/shots \
  DISKWISE_DEMO_USAGE=96:16 DISKWISE_SKIN=dawn DISKWISE_LANG=en \
  ./build_app/DiskWise.app/Contents/MacOS/DiskCleaner
```

The README images are that output downscaled to 1500 px wide, from `DISKWISE_WIN=1280x800`
(the skins grid needs `1280x920`) — keep those two numbers so a re-shoot lands on the same
canvas and the README tables don't start wrapping.

Five knobs narrow a run so you're not re-rendering 13 pages to look at one:

- `DISKWISE_ONLY=overview,dup` — only these pages (the names are the `AppPanel` cases).
- `DISKWISE_LANG=ja` — the language to shoot in; it accepts either the `code` or the raw value, so
  `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `de`, `es`, `fr`, `ru` and `pt-BR` all work. Don't
  `defaults write` the stored choice instead: while an instance is running, `cfprefsd` serves that
  process's cached copy back and the app reads the old value. Same trap as `DISKWISE_SKIN` — both are
  per-run overrides.
- `DISKWISE_PICK=dup,caches` — press that page's bottom-bar select-all twice and shoot
  `-selected` / `-deselected`. A checkbox list you can't un-check is a defect, and only an
  actual press proves it's gone.
- `DISKWISE_WIN=1280x920` — window size, default `1280x820`. Raise it for long pages such as
  the skins grid. Shots come from the window server's composite of that window, so a window
  taller than your display gets its bottom cut off — keep it inside the screen.
- `DISKWISE_DEMO_USAGE=96:16` — pin the reported volume as `<total GB>:<free GB>`, decimal,
  same units the UI prints. Only honoured with a demo home, and a demo home always reports a
  pinned volume: with no value here it falls back to `96:16`, which is the size tier that
  `make_demo_home.sh`'s tree actually fills. It never reads your real disk — that would put a
  few-dozen-GB demo tree next to your machine's real usage total and make the ring look like
  the scanner can't reach 80% of your disk.

- `DISKWISE_FILM=10` — instead of one PNG per page, burst the Overview page at that frame rate
  into `<DISKWISE_SHOTS>/film/f0001.png` …: it scans, settles, unfolds a ledger row, collapses it,
  arms an arc, moves it to the Trash, then undoes. This is how `docs/demo/overview-*.gif` at the top
  of the README is made — the frames are real UI states, nothing is animated afterwards except
  timing. Keep the same `DISKWISE_WIN=1280x800` and demo home as the still shots, then drop the
  moving frames into `gifski` at 1500 px wide; encoding every frame at a flat 10 fps costs ~10× the
  bytes for no extra motion, because most of the run is a screen sitting still.
  Two things about that run are only true because the script keeps them true:
  - The ring's orbiting glint and its breathing halo **do** move in the burst. Snapshot mode
    normally stops both (`waitSettled` compares consecutive frames), so the burst advances its own
    clock one tick per captured frame — same 9 s/revolution and 6.5 s/breath as the live app,
    just driven by the frame counter instead of the wall clock.
  - Beat ⑤ (first tap, armed) is only 5 frames. A frame costs more wall-clock than its nominal
    1/10 s — the PNG encode and write land on top of the pump — and the arc's two-step confirm
    expires after 3.2 s. Give ⑤ more room and the second tap arrives on a disarmed ring: the run
    still prints 155 frames, but ⑥⑦ silently become "armed, then timed out", and the GIF ends up
    advertising a move that never happened. The run says so on stderr (`放回 0 处` plus a ✗ line) —
    read that line before you encode.
  Cut the scan beat (f0001…f0042) when you assemble the GIF: the README already carries
  `01-overview-scanning.png` as a still, and starting the loop on a settled ring means the last
  frame and the first frame match. 113 frames ≈ 3.1 MB.

English copy runs ~30% wider than Chinese, so check more than one language — a lot of layout bugs
are only visible in one of them, and `DISKWISE_LANG` takes any of the ten.

## Before opening a PR

```bash
swift run SelfTest        # must end in ALL PASS
bash build_app/build.sh   # localization gate + self-test + resource assertions + DMG
```

You won't need to sign or notarize anything — maintainers do that in CI.

## Also welcome

- Bug reports, especially "it wanted to delete something it shouldn't" — those are treated as
  security-grade.
- Ideas for what a *developer* machine actually needs, which is the niche this tool occupies.

Please don't send: telemetry/analytics of any kind, a background agent, an auto-updater, or a
"deep clean" that shells out to `rm`.
