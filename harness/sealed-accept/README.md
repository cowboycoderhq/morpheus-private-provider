# sealed-accept

One command runs the sealed Splash verification on one Mac and writes a JSON
report. A registry (`matrix.json`) says which device and OS build are
accepted at a level. Design: `DESIGN.md`.

## Usage

```
./accept.sh --level A                  # this Mac: preflight, identity, artifacts, 3 suites (~30 min)
./accept.sh --level B                  # A + installed root kit + root suite (sudo grant)
./accept.sh --level A --dry-run        # identity and artifacts only; suites SKIP
./accept.sh --remote <ssh-host> --level A [--dry-run]   # copy this script over ssh, run, fetch the report
./matrix.py add reports/*.json
./matrix.py accepted --device Mac17,7 [--os 27.2-beta] [--commit <h16>] --level A
./matrix.py list
```

Output: `reports/<hw.model>-<osbuild>-<utcstamp>.json`, and a folder with the
same name that holds the raw output of each suite. `accept.sh` exits 0 if
the level is ACCEPTED, 1 if REJECTED, 2 if INCOMPLETE. Only one run at a
time (`/tmp/sealed-accept.lock`). It waits up to `--wait` seconds (default
7200) for another suite run on this Mac to end.

| Level | Steps |
|---|---|
| A | SIP on; engine repo on `feat/sealed-v2-splash-engine`, no tracked changes; child build id; child CD hash = `child/pin.txt`; engine signature; `neg/run-all.sh` (77 cases); `scripts/evidence.sh` (12 checks, temp copy of the app's own profile); consumer chat through `tools/tee-rootkit/sealed-chat`, pinned to the measured engine CD hash and model hash, with a wrong-CD-hash control |
| B | A, then the installed kit (`/usr/local/libexec/tee-rootkit`) hashes, its equality with the source kit, its engine pins, then `sudo -n .../tee-rootpass.sh --yes` (13 arms) |
| C | Not implemented (rebuild compare and second-party attestation) |

## Acceptance rule

- Each check is PASS, FAIL, SKIP or INCONCLUSIVE. A check without evidence
  is SKIP, never PASS. A PASS whose control did not fire is INCONCLUSIVE.
- A level is ACCEPTED only if every required check is PASS. One FAIL makes
  it REJECTED. Any SKIP or INCONCLUSIVE makes it INCOMPLETE.
- `matrix.py accepted` uses the newest report that covers the level for the
  device (and the OS build and commit, if given). It exits 0 only if that
  report has `tool_version` 1 and every required check is PASS.
- Without the sudo grant, the root suite is SKIP, so level B is INCOMPLETE.
  The grant is `sudo -n true` or the one sudoers line for
  `tee-rootpass.sh --yes`.
- `matrix.py add` refuses dry-run reports and reports whose verdict does not
  follow from their results.
- Each suite must run alone. Before a suite, the run waits for other
  processes that use the kit. During a suite, it records them, and it
  compares the suite inputs before and after (child, test builds, spawner,
  launcher, tools, model package, child sources). If another process ran or
  an input changed, the suite's PASS and FAIL lines become INCONCLUSIVE, and
  `run/<suite>-isolated` is INCONCLUSIVE. Other runs share
  `/tmp/sealed-reason.log` and give false results.

## Expansion rule

The key is (`hw.model`, macOS build, source commit). A new device or OS
build is supported when one new report at the wanted level exists. Make it
with `accept.sh` on that Mac, then `matrix.py add` it. Do not edit
`matrix.json` by hand. Reports for older commits stay under their own key.
Thus, a consumer pins the device, the OS build and the commit together.

## Side effects

- `neg/run-all.sh` writes `neg/final-<date>.txt`. If a file of that date
  exists, the run puts the old file back. The new output stays in the
  report folder.
- `evidence.sh` writes `build/evidence-*.txt` in the engine repo (ignored by
  git), builds in `/tmp`, and restarts the engine on :29452. If no engine
  ran before the run, the run stops the engine at the end.
