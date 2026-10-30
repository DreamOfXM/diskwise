# The Homebrew cask

`Casks/diskwise.rb` lives in this repository, next to the release it pins. It is not a
`homebrew-*` repository of its own, so Homebrew cannot find it by name — point `brew tap` at
this repository once:

```sh
brew tap DreamOfXM/diskwise https://github.com/DreamOfXM/diskwise
brew install --cask dreamofxm/diskwise/diskwise
```

Since Homebrew 6, non-official taps are untrusted by default. Installing by the fully
qualified name trusts just this cask; if Homebrew asks for more, `brew trust --cask
dreamofxm/diskwise/diskwise` covers it and nothing else.

Once the tap exists, the usual commands work on the short name:

```sh
brew upgrade --cask diskwise
brew uninstall --cask diskwise
```

## What the cask pins

| Field | Value |
|-------|-------|
| `version` | the release tag without the `v` |
| `sha256` | checksum of `DiskWise-<version>-universal.dmg` as published on the release |
| `url` | `releases/download/v<version>/DiskWise-<version>-universal.dmg` |
| `livecheck` | `:github_latest` against the releases page |

From v1.3 every published DMG is a universal binary, so the cask pins no architecture. The
cask is bumped by hand at release time — it is not an automatic channel.

## Bumping it

Run this against the **published asset**, not a local rebuild: a DMG re-exported on the build
machine has a different checksum even when the version string matches.

```sh
shasum -a 256 DiskWise-<version>-universal.dmg
```

GitHub also lists `digest: sha256:…` on each release asset — cross-check the two before
committing. Then update `version` and `sha256` in `Casks/diskwise.rb` and run:

```sh
brew audit --cask --strict --online DreamOfXM/diskwise/diskwise
brew style --cask Casks/diskwise.rb
brew livecheck --cask DreamOfXM/diskwise/diskwise
```

`brew audit` also checks the artifact itself, so it catches a DMG that is signed ad-hoc or
has no notarization ticket stapled to it — both of which stop Gatekeeper from opening the app
on a machine that downloaded it.
