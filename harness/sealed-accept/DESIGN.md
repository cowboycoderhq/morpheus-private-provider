# Device acceptance harness — design

Goal: one command runs the full verification on any Mac and writes a machine-readable report. A registry collects reports and answers "is this device and OS build accepted at level N".

## What a run records (per device)

Report file `reports/<hw.model>-<osbuild>-<utcstamp>.json`:

- `schema`: 1
- `device`: `hw.model`, `hw.ncpu`, `memsize`, `macos` (`sw_vers -buildVersion`), `legal_boot` (`csrutil status`, `bputil -d` when root is available)
- `source`: git commit of the engine repo, child source hash, `SPLASH_BUILD_ID`
- `artifacts`: child CD hash, engine CD hash, model hash
- `levels`:
  - `A`: child negative suite (N cases), engine evidence suite, consumer chat
  - `B`: A plus the root suite with controls (needs the sudo grant)
  - `C`: B plus rebuild compare (unsigned vs published) and a second-party attestation report
- `results`: per check `{name, status: PASS|FAIL|SKIP|INCONCLUSIVE, control: PASS|FAIL|NA, evidence: path|inline}`
- `totals`, `verdict` per level
- `tool_version`

## Registry

`matrix.json` merges reports. Query: `matrix.py accepted --level A --device Mac17,7` answers yes or no with the newest report. A new OS build or a new `hw.model` changes the key, so support expands only by adding a report, never by editing the matrix by hand.

## Commands

```
sealed-accept/accept.sh --level A            # run on this Mac
sealed-accept/accept.sh --level B            # A plus the root suite (sudo grant required)
sealed-accept/accept.sh --remote <ssh-host> --level A   # run on a remote Mac over ssh
sealed-accept/matrix.py add reports/*.json
sealed-accept/matrix.py accepted --device Mac17,7 --level A
sealed-accept/matrix.py list
```

`accept.sh` fails closed: a missing step is `SKIP`, never `PASS`. Every PASS carries a fired control where the check defines one.

## Expansion rule

A device or OS build becomes accepted when one report exists at the wanted level, produced by `accept.sh` at the same `tool_version` and from the same source commit. Reports from an older source commit stay in the matrix with their commit, so the consumer pins both.

## What the consumer checks

`sealed-chat` pins the engine CD hash. The consumer also reads `matrix.py accepted` output for the device's attestation fields (`hw.model`, OS build) when the provider publishes one. The router side is a later step; the report format is what matters now.
