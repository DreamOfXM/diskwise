# Homebrew tap for DiskWise

One-command install (fully-qualified, so Homebrew trusts just this cask):

```sh
brew install --cask dreamofxm/diskwise/diskwise
```

Or tap once and use the short name — since Homebrew 6, third-party taps are untrusted by
default, so the `brew trust` step is required:

```sh
brew tap DreamOfXM/diskwise
brew trust --cask dreamofxm/diskwise/diskwise
brew install --cask diskwise
```

[DiskWise](https://github.com/DreamOfXM/diskwise) is a free, open-source macOS disk cleaner:
every removal goes to the Trash and stays undoable, no telemetry, no daemon, no network access.

Homebrew is not an update channel here: the cask is bumped by hand, so check
[the releases page](https://github.com/DreamOfXM/diskwise/releases) or `brew livecheck diskwise`
if you want the newest build. `livecheck :github_latest` in the cask is what `brew livecheck`
queries.

## Why a personal tap instead of official homebrew-cask

Earlier builds were ad-hoc signed, which is why this tap exists at all. Current releases are
Developer ID signed and notarized (see Status), so the Gatekeeper objection no longer applies —
what remains is homebrew-cask's acceptance policy, which asks for existing notability
(forks / watchers / stars well above what this project has today). Once that bar is met, the
intent is to submit upstream and retire this tap.

Trust policy: <https://docs.brew.sh/Tap-Trust> ·
Acceptable casks: <https://docs.brew.sh/Acceptable-Casks> ·
Acceptance policy: <https://docs.brew.sh/Package-Acceptance-Policy>

## Bumping the version

`Casks/diskwise.rb` pins a version and a SHA-256, and the asset name follows the release tag
plus the architecture it was built for: tag `v1.2.0` shipped `DiskWise-1.2.dmg` (arm64 only),
tag `v1.3` ships `DiskWise-1.3-universal.dmg`, tag `v2.0` ships `DiskWise-2.0-universal.dmg`.
To bump:

```sh
shasum -a 256 DiskWise-<version>-universal.dmg   # from the release asset, not a local rebuild
# edit version + sha256 in Casks/diskwise.rb, then:
brew audit --cask --strict --online dreamofxm/diskwise/diskwise
brew style --cask Casks/diskwise.rb
```

GitHub also publishes a `digest: sha256:…` on each release asset — cross-check the two before
committing.

## Status

The install path was last exercised end to end on 2026-09-17 on an Apple Silicon Mac:

```console
$ brew install --cask dreamofxm/diskwise/diskwise
🍺  diskwise was successfully installed!
```

Homebrew downloaded the release DMG, accepted the pinned SHA-256, and moved `DiskWise.app` to
`/Applications`. The 2.0 bump changed only `version` and `sha256`; it is checked by
`brew audit --cask --strict --online` and `brew style --cask`, not by a fresh install.

The v2.0 DMG itself was inspected by mounting it read-only on 2026-10-25 rather than assuming:

| Check | Result |
|-------|--------|
| `CFBundleShortVersionString` | `2.0` |
| `codesign -dv --verbose=2` | `Authority=Developer ID Application: Xiaoming Guo (448JJF25MY)`, `flags=0x10000(runtime)` |
| `codesign` architecture | `Mach-O universal (x86_64 arm64)` |
| `spctl --assess --type execute` | `accepted`, `source=Notarized Developer ID` |
| `xcrun stapler validate` on the DMG | `The validate action worked!` |

So a first launch straight from `/Applications` no longer needs the right-click workaround, and
the cask carries no `caveats` block.
