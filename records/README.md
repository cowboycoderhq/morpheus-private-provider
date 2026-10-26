# Records

These files are copies of the project's measurement records. Read
`CLAIM-v2-2026-10-24.md` first, then `OPEN-ITEMS-CLOSURE-2026-10-24.md`. The
records cite their files as `review/<name>`; in this release they are
`records/<name>`. Files that a record cites but that are not here are private
run output (logs, traces, the raw accept-report folder).

## What is here

- The claim and the closure matrix for the build that `README.md` names.
- The measurement records that the claim cites, the two open-gap records
  (`SPEC-TEMP-2026-10-25.md`, `PREFIX-CACHE-GAP-2026-10-25.md`) and older
  records that later ones supersede (`CLAIM-v2-2026-10-23.md`,
  `OPEN-ITEMS-CLOSURE-2026-10-22.md`).
- `accept-results-Mac17,7-27.2-beta-20261026ThhmmssZ.md`: each check of the accept run with its
  result. The raw run files are not published, because they hold host data.
- The second-Mac rebuilds: `SECOND-MAC-REBUILD-2026-10-25-r5.txt` (these
  pins) and `SECOND-MAC-REBUILD-r4-2026-10-25.txt` (the previous pins).
- Audit reports: round 2 (child), round 4 (child, engine, root kit,
  harness, claims) and round 5 (rebuild, claims, code). AI auditors wrote
  them, read-only, from the same model family as the author, so they are not
  independent reviews. Two round-5 reports (publish safety, harness
  readiness) are not published: they describe private host data.

## Redaction

The records come from the project's private test Macs. Before publication,
these values were replaced in the records and in the documents:

| Class | Replacement |
|---|---|
| User names and home folders | `<user>`, `<second-user>`, `<other-home>`, `~` |
| Signing identity, certificate, team, App ID, bundle IDs | `<developer>`, `<cert-id>`, `<team>`, `<TEAM>`, `<bundle-id>`, `<es-bundle-id>`, `<org>` |
| Engine CD hashes (they cover the team ID and bundle ID) | `<engine CD hash withheld>`, `<engine-N>` |
| Host names of the test Macs and the git hub | `<host-a>`, `<host-b>`, `<host-c>`, `hub`, `<studio>` |
| Network addresses | `<tailnet-ip>`, `<lan-ip>` |
| macOS build numbers | `27.2-beta`, `27.0-build` |
| Local times of day and time-zone names | `<time>`, `local` (UTC times stay) |
| Per-user temporary folders | `/var/folders/<id>` |
| clang build numbers | `clang-<build>` (the publish check reads them as IP addresses) |
| Links to the project's private notes | plain words |

Two file names changed in the same way (`SECOND-MAC-REBUILD-r4-…`,
`tools/second-mac-rebuild.sh`). No code changed: `engine/`, `child/` and
`router/` are byte-equal to the named commits.
