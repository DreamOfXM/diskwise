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
- Emptying the Trash is always handed to Finder (`emptyTrashViaFinder`, AppleScript) so macOS asks
  for confirmation once more.
- The Docker page is read-only. Images and volumes live inside a virtual disk with no per-item
  path, so the app points at Docker Desktop instead of pretending to prune.

## Dev setup

You only need the Xcode Command Line Tools — full Xcode is not required, and `xcodebuild` being
missing is normal here.

```bash
swift build          # debug build
swift run SelfTest   # 27 checks — all green is the bar for any PR
swift run DiskCleaner
```

`swift test` does not exist in this repo: the Command Line Tools ship no XCTest, so regression
coverage lives in the `SelfTest` executable target. Add a check there when you add logic.

## The easiest useful contribution: cache knowledge base

`Sources/DiskCleaner/Resources/safety_db.json` is the list of things the Caches page understands.
More real entries = a more useful app. One entry:

```json
{
  "name": "Codex 崩溃转储",
  "what": "Codex 崩溃时生成的 .dmp 报告，只用于上报诊断",
  "whatif": "删掉不影响任何功能",
  "rec": "无需恢复；下次程序崩溃会自动生成新的报告",
  "path": "~/Library/Application Support/Codex/Crashpad/pending",
  "level": "safe",
  "grp": "general"
}
```

- `path` supports `*` globs and must be written from `~` — never an absolute machine path.
- `level` is `safe` or `warn`. When in doubt, `warn`: an entry that is too cautious still tells the
  user something; one that is too confident deletes their work.
- Overlapping paths are fine (they happen a lot), but the UI never sums them — keep it that way.
- Entries are grouped by `grp`; the Caches page shows the group under each name.

## Translations

Chinese source text **is** the localization key. There is no `zh.lproj`; you only maintain
`Sources/DiskCleaner/Resources/en.lproj/Localizable.strings`.

- Wrap every user-visible string: `L("…")`, or `LF("已选 %d 项", n)` when it takes arguments.
- Counts go through `cnt(n, "个文件")` so English gets singular/plural. Don't also write the unit
  inside the template — that's how "27 items items listed" was born.
- `%@` in `String(format:)` only accepts objects. Passing a Swift `Int` is an `EXC_BAD_ACCESS` that
  reproduces in English only. Use `%d`.
- `bash build_app/build.sh` fails the build if coverage, positional specifiers, or the `%@`-with-Int
  pattern check out of line. Run it before opening a PR.

## Visual changes

Screenshot them. `SnapshotMode` renders every page to PNG without needing screen-recording
permission, and it runs against a synthetic home folder so no real files appear:

```bash
bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome
defaults write com.dreamofxm.diskcleaner diskcleaner.language en
DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome DISKWISE_SHOTS=/tmp/shots \
  DISKWISE_SKIN=dawn ./build_app/DiskWise.app/Contents/MacOS/DiskCleaner
```

Two knobs narrow a run so you're not re-rendering 13 pages to look at one:

- `DISKWISE_ONLY=overview,dup` — only these pages (the names are the `AppPanel` cases).
- `DISKWISE_WIN=1280x1543` — window size, default `1280x820`. Raise the height for long
  scrolling pages, otherwise the shot just cuts off mid-card.

English copy runs ~30% wider than Chinese, so check **both** languages — a lot of layout bugs are
only visible in one of them.

## Before opening a PR

```bash
swift run SelfTest        # 27/27
bash build_app/build.sh   # localization gate + self-test + resource assertions + DMG
```

You won't need to sign or notarize anything — maintainers do that in CI;
[docs/RELEASE.md](docs/RELEASE.md) describes how.

## Also welcome

- Bug reports, especially "it wanted to delete something it shouldn't" — those are treated as
  security-grade.
- Ideas for what a *developer* machine actually needs, which is the niche this tool occupies.

Please don't send: telemetry/analytics of any kind, a background agent, an auto-updater, or a
"deep clean" that shells out to `rm`.
