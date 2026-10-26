#!/usr/bin/env python3
"""Acceptance registry for accept.sh reports (see DESIGN.md).

  matrix.py add <report.json ...>
  matrix.py accepted --device <hw.model> [--os <build>] [--commit <prefix>] --level A|B
  matrix.py list

matrix.json (next to this script) holds one entry per key
(hw.model, macOS build, source commit). Each entry keeps every report added
for that key; the newest decides. Reports from older commits stay under their
own key.

`accepted` picks the newest report that covers the level for the device (and
OS build and commit when given), and exits 0 only when that report is from
this tool_version and every required check of the level is PASS. SKIP and
INCONCLUSIVE do not count. Exit 1 = not accepted, 2 = usage or input error.
"""
import argparse
import hashlib
import json
import re
import os
import sys
import tempfile
from pathlib import Path

TOOL_VERSION = 3
LEVELS = ("A", "B")
MATRIX = Path(__file__).resolve().parent / "matrix.json"
STATUSES = {"PASS", "FAIL", "SKIP", "INCONCLUSIVE", "EXEMPT"}

# The only names a report may mark EXEMPT. Mirrors accept.sh's list; a report
# that marks any other name EXEMPT is refused as inconsistent.
EXEMPT_OK = {
    "root/A-4-endpoint-security",
    "root/R4-T5-pid-domain",
    "root/R4-T5-control",
    "root/A-2-dtrace-read",
}

# Each EXEMPT must carry its documented cause in the evidence, so an
# exemption cannot silently cover a different failure (audit F-4, A4-04).
EXEMPT_CAUSE = {
    # Each pattern must match the WHOLE line that the arm wrote, read from the
    # cited file (audits R2-4-05, R3-4-04, R3-4-05). Any other text, an
    # appended cause, or a non-zero child count fails the match.
    "root/A-4-endpoint-security":
        r"INCONCLUSIVE \[A-4-endpoint-security\] es_new_client never ran \(exit=137, es\.txt 0 bytes\): "
        r"AMFI refuses the exec without a provisioning profile that grants com\.apple\.developer\.endpoint-security\.client",
    "root/R4-T5-pid-domain":
        r"INCONCLUSIVE \[R4-T5-pid-domain\] CONTROL DID NOT FIRE: Apple-named fake never ran \(rc=5\), "
        r"but the test-named fake did not run either \(rc=5\), so the refusal is not specific to the Apple name",
    "root/R4-T5-control":
        r"INCONCLUSIVE \[R4-T5-control\] CONTROL DID NOT FIRE: test-named fake did not run "
        r"\(bootstrap rc=5: Bootstrap failed: 5: Input/output error\); launchd refuses outside bootstraps into a pid domain",
    "root/A-2-dtrace-read":
        r"INFO \[A-2-dtrace-read\] control got no copies either \(dtrace syscall copyin unavailable under SIP for all processes\): "
        r"child=0; [^|]*probe description syscall::read:entry does not match any probes\. "
        r"System Integrity Protection is on ?",
}

# Checks that every report must require at its level: the claim rests on
# them, so a report with a short required list is refused (audit A4-05).
REQUIRED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "required.json")


def full_required(report_path=None):
    # Use the copy kept with the report (its hash is checked above); fall back
    # to the live file only when no report folder is given.
    path = REQUIRED_FILE
    if report_path:
        path = Path(report_path).resolve().with_suffix("") / "harness" / "required.json"
    with open(path) as f:
        d = json.load(f)
    return {"A": set(d["A"]), "B": set(d["B"])}


CORE_REQUIRED = {
    "A": {
        "engine/child-pin-in-engine", "engine/verified-chat",
        "engine/refuse-wrong-cdhash", "engine/refuse-wrong-model", "engine/refuse-wrong-appid",
        "engine/p10-canary-served", "engine/p10-no-file-copy", "engine/p10-no-log-copy",
        "engine/p10-no-python-hop", "artifacts/no-forbidden-entitlement",
    },
    "B": {
        "root/P10-engine-task-ports", "root/P10-engine-dtrace-attach",
        "root/P10-engine-child-task-ports", "root/P10-engine-child-dtrace-attach",
        "root/P10-lo0-ciphertext-only",
    },
}


def load_matrix():
    if MATRIX.exists():
        return json.loads(MATRIX.read_text())
    return {"schema": 1, "entries": {}}


def save_matrix(m):
    fd, tmp = tempfile.mkstemp(prefix="matrix.", suffix=".json", dir=MATRIX.parent)
    with os.fdopen(fd, "w") as f:
        json.dump(m, f, indent=2, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, MATRIX)


def recompute(report):
    """Verdict per level from the results, ignoring the report's own verdict."""
    status = {r["name"]: r["status"] for r in report["results"]}
    out = {}
    for lv, spec in report["levels"].items():
        req = spec["required"]
        got = [status.get(n) for n in req]
        if any(g == "FAIL" for g in got):
            out[lv] = "REJECTED"
        elif req and all(g in ("PASS", "EXEMPT") for g in got):
            out[lv] = "ACCEPTED"
        else:
            out[lv] = "INCOMPLETE"
    return out


# Engine and child CD hashes that must never be accepted again (audit
# R3-4-08): builds before a fix that the claim depends on.
# Revoked pins live in revoked.json next to this file (one list per kind, each
# entry a full hash or a prefix and the reason). The file is private: an old
# pin is an artifact hash of source that is not published.
def _load_revoked():
    f = Path(__file__).resolve().parent / "revoked.json"
    if not f.exists():
        return {"engine": set(), "child": set()}
    d = json.loads(f.read_text())
    return {k: {e["hash"] for e in d.get(k, [])} for k in ("engine", "child")}


REVOKED_ARTIFACTS = _load_revoked()


def _approved(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    try:
        with open(path) as f:
            return {l.split()[0] for l in f if l.strip() and not l.startswith("#")}
    except OSError:
        return set()


def check_evidence_line(report_path, arm_evidence):
    """The arm's cited line must be in the cited file, character for character
    (audit R3-4-04). The cite format is '<dir>/<file>:<n> | <line>'."""
    m = re.match(r"^(?P<file>[^|:]+):(?P<n>\d+) \| (?P<line>.*)$", arm_evidence, re.S)
    if not m or not report_path:
        raise ValueError("arm evidence has no '<file>:<line> | <text>' citation")
    # Only the report's own evidence folder counts (audit R4-4-02): a cite of
    # a sibling report's folder is refused.
    own = Path(report_path).resolve().with_suffix("")
    if not m["file"].startswith(own.name + "/"):
        raise ValueError(f"arm evidence cites a file outside the report's own folder: {m['file']}")
    f = (own.parent / m["file"]).resolve()
    if own not in f.parents:
        raise ValueError(f"arm evidence cites a file outside the report's own folder: {m['file']}")
    try:
        lines = f.read_text(errors="replace").splitlines()
    except OSError:
        raise ValueError(f"arm evidence cites a file that is not there: {m['file']}")
    n = int(m["n"])
    if not (1 <= n <= len(lines)) or lines[n - 1] != m["line"]:
        raise ValueError(f"arm evidence line {m['file']}:{n} does not equal the line in the file")
    return lines[n - 1]


def check_report(report, report_path=None):
    for k in ("schema", "tool_version", "device", "source", "artifacts", "levels", "results", "totals", "verdict"):
        if k not in report:
            raise ValueError(f"missing field {k}")
    if report["schema"] != 1:
        raise ValueError(f"schema {report['schema']} is not 1")
    if report["tool_version"] != TOOL_VERSION:
        raise ValueError(f"tool_version {report['tool_version']!r} is not {TOOL_VERSION}")
    # The harness and the required list that made the report must be known,
    # and the copies kept with the report must have those hashes (R3-4-06/07).
    th = report.get("tool_sha256") or ""
    if th not in _approved("approved-harness.txt"):
        raise ValueError(f"tool_sha256 {th[:16]} is not an approved harness")
    rh = report.get("required_sha256") or ""
    if rh not in _approved("approved-required.txt"):
        raise ValueError(f"required_sha256 {rh[:16]} is not an approved required list")
    if report_path:
        hd = Path(report_path).resolve().with_suffix("") / "harness"
        # The gate code kept with the report must be an approved version (audit R4-4-06).
        try:
            mh = hashlib.sha256((hd / "matrix.py").read_bytes()).hexdigest()
        except OSError:
            raise ValueError("harness copy matrix.py is missing from the report folder")
        if mh not in _approved("approved-matrix.txt"):
            raise ValueError(f"harness copy matrix.py {mh[:16]} is not an approved gate version")
        for fname, want in (("accept.sh", th), ("required.json", rh)):
            try:
                got = hashlib.sha256((hd / fname).read_bytes()).hexdigest()
            except OSError:
                raise ValueError(f"harness copy {fname} is missing from the report folder")
            if got != want:
                raise ValueError(f"harness copy {fname} does not have the recorded hash")
    for role, cd in (("engine", report["artifacts"].get("engine_cdhash") or ""),):
        if not re.fullmatch(r"[0-9a-f]{64}", cd):
            raise ValueError(f"{role} CD hash {cd!r} is not 64 hex characters")
        if any(cd.startswith(r) for r in REVOKED_ARTIFACTS[role]):
            raise ValueError(f"{role} CD hash {cd[:16]} is revoked")
    a = report["artifacts"]
    if not re.fullmatch(r"[0-9a-f]{40}", a.get("child_cdhash") or "") or a.get("child_pin") != a.get("child_cdhash"):
        raise ValueError("child CD hash is not 40 hex characters, or it is not equal to the child pin")
    if any(a["child_cdhash"].startswith(r) for r in REVOKED_ARTIFACTS["child"]):
        raise ValueError(f"child CD hash {a['child_cdhash'][:16]} is revoked")
    for k, want in (("kit_engine_cdhash", "engine_cdhash"), ("kit_engine_modelhash", "model_hash")):
        if a.get(k) != a.get(want):
            raise ValueError(f"{k} {str(a.get(k))[:16]} is not equal to {want} {str(a.get(want))[:16]}")
    # Every evidence file must still have the hash recorded at the end of the
    # run, and the report must name its own folder (audit R4-4-02).
    if report_path:
        own = Path(report_path).resolve().with_suffix("")
        if report.get("evidence_dir") != own.name:
            raise ValueError(f"evidence_dir {report.get('evidence_dir')!r} is not the report's own folder {own.name}")
        hashes = report.get("evidence_sha256") or {}
        if not hashes:
            raise ValueError("the report records no evidence file hashes")
        for rel_name, want in hashes.items():
            f = (own / rel_name).resolve()
            if own not in f.parents:
                raise ValueError(f"evidence hash names a file outside the folder: {rel_name}")
            try:
                got = hashlib.sha256(f.read_bytes()).hexdigest()
            except OSError:
                raise ValueError(f"evidence file {rel_name} is missing")
            if got != want:
                raise ValueError(f"evidence file {rel_name} changed after the run")
        on_disk = {str(f.relative_to(own)) for f in own.rglob("*") if f.is_file() and f.relative_to(own).parts[0] != "harness"}
        extra = sorted(on_disk - set(hashes))
        if extra:
            raise ValueError(f"evidence folder holds files with no recorded hash: {extra[:3]}")
    if report.get("dry_run"):
        raise ValueError("dry-run report (the suites did not run)")
    for k in ("hw.model", "macos"):
        if not report["device"].get(k):
            raise ValueError(f"device.{k} is empty")
    if not report["source"].get("commit"):
        raise ValueError("source.commit is empty")
    for r in report["results"]:
        keys = {"name", "status", "control", "evidence"}
        if r.get("status") == "EXEMPT":
            keys = keys | {"arm_evidence"}
        if set(r) != keys or r["status"] not in STATUSES:
            raise ValueError(f"malformed result {r}")
    names = [r["name"] for r in report["results"]]
    if len(names) != len(set(names)):
        raise ValueError("duplicate result names")
    for r in report["results"]:
        # A PASS needs a fired control and evidence; an EXEMPT needs evidence
        # (audit R3-4-10, R4-4-09).
        if r["status"] == "PASS" and r["control"] == "FAIL":
            raise ValueError(f"{r['name']} is PASS but its control is FAIL")
        if r["status"] in ("PASS", "EXEMPT") and not str(r["evidence"]).strip():
            raise ValueError(f"{r['name']} is {r['status']} with empty evidence")
    req_all = full_required(report_path)
    for lv, spec in report["levels"].items():
        junk = [n for n in spec["required"] if n not in req_all.get(lv, set())]
        if junk:
            raise ValueError(f"level {lv} required list names checks that required.json does not list: {junk[:3]}")
        st = {r["name"]: r["status"] for r in report["results"]}
        t = {k: sum(1 for n in spec["required"] if st.get(n) == k) for k in ("PASS", "FAIL", "SKIP", "INCONCLUSIVE", "EXEMPT")}
        t["required"] = len(spec["required"])
        if report["totals"].get(lv) != t:
            raise ValueError(f"totals for level {lv} do not follow from the rows: {report['totals'].get(lv)} vs {t}")
    for lv, spec in report["levels"].items():
        missing = [n for n in spec["required"] if n not in names]
        if missing:
            raise ValueError(f"level {lv} requires checks with no result: {missing[:5]}")
        core = set(CORE_REQUIRED.get("A", set()))
        if lv == "B":
            core |= CORE_REQUIRED["B"]
        core |= full_required(report_path).get(lv, set())
        short = sorted(core - set(spec["required"]))
        if short:
            raise ValueError(f"level {lv} required list omits {len(short)} required checks, e.g. {short[:5]}")
        if len(spec["required"]) != len(set(spec["required"])):
            raise ValueError(f"level {lv} required list has duplicate names")
    for r in report["results"]:
        if r["status"] != "EXEMPT":
            continue
        if r["name"] not in EXEMPT_OK:
            raise ValueError(f"{r['name']} is marked EXEMPT but is not on the exemption list")
        arm = str(r.get("arm_evidence", ""))
        if not arm or "no PASS/FAIL/INCONCLUSIVE line" in arm:
            raise ValueError(f"{r['name']} is EXEMPT but its arm produced no line")
        line = check_evidence_line(report_path, arm)
        if not re.fullmatch(EXEMPT_CAUSE[r["name"]], line):
            raise ValueError(f"{r['name']} is EXEMPT but its arm line does not show the documented cause")
    if recompute(report) != report["verdict"]:
        raise ValueError(f"verdict {report['verdict']} does not follow from the results {recompute(report)}")


def cmd_add(args):
    m = load_matrix()
    rc = 0
    for p in args.reports:
        path = Path(p).resolve()
        try:
            raw = path.read_bytes()
            report = json.loads(raw)
            check_report(report, path)
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"refused {p}: {e}", file=sys.stderr)
            rc = 2
            continue
        d, s = report["device"], report["source"]
        key = f"{d['hw.model']}|{d['macos']}|{s['commit']}"
        sha = hashlib.sha256(raw).hexdigest()
        e = m["entries"].setdefault(key, {"hw.model": d["hw.model"], "macos": d["macos"], "commit": s["commit"], "reports": []})
        if any(r["sha256"] == sha for r in e["reports"]):
            print(f"already in the matrix: {path.name}")
            continue
        e["reports"].append({
            "path": str(path), "sha256": sha, "started_utc": report.get("started_utc"),
            "tool_version": report["tool_version"], "requested_level": report.get("requested_level"),
            "source": s, "artifacts": report["artifacts"], "levels": report["levels"],
            "results": report["results"], "totals": report["totals"], "verdict": report["verdict"],
        })
        e["reports"].sort(key=lambda r: r["started_utc"] or "")
        print(f"added {path.name}: {key} " + " ".join(f"{k}={v}" for k, v in report["verdict"].items()))
    save_matrix(m)
    return rc


def cmd_accepted(args):
    m = load_matrix()
    cands = []
    for e in m["entries"].values():
        if e["hw.model"] != args.device:
            continue
        if args.os and e["macos"] != args.os:
            continue
        if args.commit and not e["commit"].startswith(args.commit):
            continue
        for r in e["reports"]:
            if args.level in r["levels"]:
                cands.append((r["started_utc"] or "", e, r))
    where = f"{args.device}" + (f" {args.os}" if args.os else "") + (f" commit {args.commit}" if args.commit else "")
    if not cands:
        print(f"no: no level {args.level} report for {where}")
        return 1
    _, e, r = max(cands, key=lambda c: c[0])
    # Stored rows were added under the gates of their day. Run today's gates
    # again on the stored report: a row that fails them is revoked, not
    # accepted (audit R2-4-07).
    try:
        with open(r["path"], "rb") as f:
            raw = f.read()
        if hashlib.sha256(raw).hexdigest() != r["sha256"]:
            raise ValueError("the report file changed after it was added")
        check_report(json.loads(raw), r["path"])
    except (OSError, ValueError) as err:
        print(f"no: {e['hw.model']} {e['macos']} commit {e['commit'][:12]} report {Path(r['path']).name}: REVOKED by the current gates: {err}")
        return 1
    status = {x["name"]: x["status"] for x in r["results"]}
    req = r["levels"][args.level]["required"]
    notpass = [(n, status.get(n, "MISSING")) for n in req if status.get(n) not in ("PASS", "EXEMPT")]
    head = f"{e['hw.model']} {e['macos']} commit {e['commit'][:12]} report {Path(r['path']).name}"
    if r["tool_version"] != TOOL_VERSION:
        print(f"no: {head}: tool_version {r['tool_version']} is not {TOOL_VERSION}")
        return 1
    if not req or notpass:
        print(f"no: {head}: {len(req) - len(notpass)}/{len(req)} required level {args.level} checks PASS")
        for n, st in notpass[:30]:
            print(f"  {st} {n}")
        if len(notpass) > 30:
            print(f"  ... {len(notpass) - 30} more")
        return 1
    a = r["artifacts"]
    nx = sum(1 for n in req if status.get(n) == "EXEMPT")
    print(f"yes: {head}: {len(req)}/{len(req)} required level {args.level} checks PASS" + (f" ({nx} documented EXEMPT)" if nx else ""))
    print(f"  engine CD hash {a.get('engine_cdhash')}  child CD hash {a.get('child_cdhash')}  model hash {a.get('model_hash')}")
    return 0


def cmd_list(args):
    m = load_matrix()
    if not m["entries"]:
        print("matrix is empty")
        return 0
    print(f"{'device':<12} {'macOS':<10} {'commit':<13} {'reports':>7}  newest report (verdicts)")
    for key in sorted(m["entries"]):
        e = m["entries"][key]
        r = e["reports"][-1]
        v = " ".join(f"{k}={x}" for k, x in r["verdict"].items())
        print(f"{e['hw.model']:<12} {e['macos']:<10} {e['commit'][:12]:<13} {len(e['reports']):>7}  {r['started_utc']} {v}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("reports", nargs="+")
    q = sub.add_parser("accepted")
    q.add_argument("--device", required=True)
    q.add_argument("--os")
    q.add_argument("--commit")
    q.add_argument("--level", required=True, choices=LEVELS)
    sub.add_parser("list")
    args = ap.parse_args()
    return {"add": cmd_add, "accepted": cmd_accepted, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
