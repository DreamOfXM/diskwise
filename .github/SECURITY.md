# Security Policy

DiskWise exists because a disk cleaner is the one kind of utility that should not be
able to destroy your data. A bug that breaks that promise is the most serious bug this
project can have, and it is treated that way.

## Supported versions

Only the newest release is supported. Fixes ship as a new release rather than as a patch
to an older tag.

| Build | Supported |
|---|---|
| Newest GitHub release | Yes |
| Newest Mac App Store version | Yes |
| Older releases | No |
| A build from a modified source tree | No |

## Reporting a vulnerability

Do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting:
https://github.com/DreamOfXM/diskwise/security/advisories/new

If that form is not available to you, open a public issue containing only the sentence
"security report, please open a private channel" and no technical detail. A private
channel will be opened from there.

A useful report includes the version, the macOS version, whether the build came from the
App Store, Homebrew, or a local build, and the smallest sequence of steps that shows the
problem. A proof of concept that touches only files you created for the purpose is worth
more than a description of an attack.

## How removal works

This is worth stating plainly, because most reports concern it.

There is one removal primitive for user data, `trashItem` in `DiskCleanerCore`. It runs
two guards and then calls `FileManager.trashItem`:

1. `isProtected` rejects the wholesale removal of locations that must never move as a
   whole, such as the home directory, `~/Library`, `/`, `/System`, and `/usr`.
2. `isDeletable` restricts the target to the home directory, `/Applications`, `/tmp`, and
   `/var/tmp`.

The CLI and the MCP server call the same primitive. No other delete path is exposed: no
shell, no `/bin/rm`, no permanent unlink of a user-selected path. The only `removeItem`
calls in shipping code target DiskWise's own temporary plan files in the agent handoff
directory.

One detail matters for anyone reviewing this code. Both path checks use
`standardizedFileURL`, which does not resolve symbolic links. That is deliberate:
`/tmp` and `/var/tmp` are symlinks to `/private`, and resolving them would make the same
file reachable and unreachable through two spellings. The consequence is that the checks
compare path text, not resolved inodes, and there is no `isSymbolicLink` filter in the
removal path. Reports that turn that gap into a removal outside the intended scope are
in scope for this policy rather than out of it.

## In scope

- Anything that results in permanent deletion of a user file. The product has no such
  path on purpose, so any way to reach one is critical.
- Escaping the home, `/Applications`, `/tmp`, `/var/tmp` boundary with `..`, a symlink, a
  hard link, a bind mount, a Unicode normalization difference, or a case-folding
  difference.
- A path that resolves differently between the guard and the `trashItem` call.
- Prompt injection against the MCP server. The server is built to be driven by an agent,
  so a file name, cache entry, or repository name that makes the agent propose something
  outside the intended scope is a real finding, not a curiosity.
- Elevation of privilege. DiskWise installs no privileged helper, no launch daemon, and
  no login item. Anything that gains elevated rights through the app or the CLI is in
  scope.
- Network. The app makes no network requests and contains no telemetry. An outbound
  connection originating from the app process is in scope.
- Distribution. Anything that lets a third party ship a modified build under this name,
  or substitute an artifact behind the Homebrew tap, is in scope.
- Restoration. `untrash` must never overwrite an existing file. A restore that clobbers
  the destination is in scope.

## Out of scope

- Deleting a file the interface offered and the user confirmed. That is the product
  working as designed. The design intent is that the file is in the Trash and reversible,
  not that it was a good idea to delete.
- Data loss inside a cache or build directory the user deliberately pointed the app at.
- Anything that requires the attacker to already have the user's account, an unlocked
  session, or physical access.
- A scan that is slow or memory hungry on a very large directory.
- Issues in the third party tools the app only reports on, such as Docker, Homebrew, or
  Xcode.
- A missing code signature check on a build you compiled yourself.
- The absence of a notarization check inside the app, since Gatekeeper performs it.

## What to expect

- An acknowledgement, usually within three days.
- An assessment and a rough timeline after triage.
- Credit in the release notes and the advisory, unless you prefer to stay anonymous.

There is no bug bounty. This is a free project under Apache-2.0.
