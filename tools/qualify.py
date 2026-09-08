#!/usr/bin/env python3
"""Run the Cell gate and preserve machine-readable qualification evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
STAGE_RE = re.compile(r"^printf '\\n== (.+) ==\\n'$")
HEADING_RE = re.compile(r"^== (.+) ==$")


def command_line(command: list[str], cwd: Path) -> str | None:
    try:
        result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, check=False)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    lines = (result.stdout or result.stderr).splitlines()
    return lines[0].strip() if lines else None


def repo_root(start: Path) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], cwd=start, text=True,
        capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise RuntimeError("qualification must run inside a Git repository")
    return Path(result.stdout.strip()).resolve()


def stage_identities(gate: Path) -> list[str]:
    stages = [match.group(1) for line in gate.read_text().splitlines() if (match := STAGE_RE.match(line))]
    stages = [stage for stage in stages if stage != "verdict"]
    if len(stages) != 10 or len(set(stages)) != 10:
        raise RuntimeError(f"expected 10 unique gate stages, found {len(stages)}")
    return stages


def validate_artifact_paths(root: Path, report: Path, log: Path) -> None:
    temporary = report.with_name(report.name + ".tmp")
    artifacts = {"report": report, "log": log, "report temporary": temporary}
    resolved = {name: path.resolve(strict=False) for name, path in artifacts.items()}
    if len(set(resolved.values())) != len(resolved):
        raise ValueError("report, log, and report temporary paths must be distinct")
    tracked_files = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, capture_output=True, check=False,
    )
    if tracked_files.returncode != 0:
        raise RuntimeError("could not enumerate tracked source artifact identities")
    tracked_identities: set[tuple[int, int]] = set()
    for raw_path in tracked_files.stdout.split(b"\0"):
        if not raw_path:
            continue
        candidate = root / raw_path.decode(errors="surrogateescape")
        try:
            info = candidate.stat()
        except FileNotFoundError:
            continue
        except OSError as error:
            raise RuntimeError("could not inspect tracked source artifact identities") from error
        if stat.S_ISREG(info.st_mode):
            tracked_identities.add((info.st_dev, info.st_ino))
    artifact_identities: dict[tuple[int, int], str] = {}
    for name, path in resolved.items():
        try:
            relative = path.relative_to(root)
        except ValueError:
            continue
        tracked = subprocess.run(
            ["git", "ls-files", "--error-unmatch", "--", os.fsdecode(relative)],
            cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        if tracked.returncode == 0:
            raise ValueError(f"{name} path resolves to tracked source: {path}")
        if tracked.returncode not in (0, 1):
            raise RuntimeError(f"could not validate {name} path against tracked source")
        try:
            info = path.stat()
        except FileNotFoundError:
            continue
        except OSError as error:
            raise RuntimeError(f"could not inspect {name} path identity") from error
        if not stat.S_ISREG(info.st_mode):
            continue
        identity = (info.st_dev, info.st_ino)
        if identity in tracked_identities:
            raise ValueError(f"{name} path is a hardlink to tracked source: {path}")
        if identity in artifact_identities:
            raise ValueError(f"{name} path is a hardlink alias of {artifact_identities[identity]}")
        artifact_identities[identity] = name


def porcelain_entries(data: bytes) -> list[tuple[bytes, list[bytes]]]:
    tokens = data.split(b"\0")
    entries: list[tuple[bytes, list[bytes]]] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if not token:
            continue
        if len(token) < 3 or token[2:3] != b" ":
            raise ValueError("malformed git status entry")
        status = token[:2]
        paths = [token[3:]]
        if b"R" in status or b"C" in status:
            if index >= len(tokens) or not tokens[index]:
                raise ValueError("truncated git rename/copy entry")
            paths.append(tokens[index])
            index += 1
        entries.append((status, paths))
    return entries


def source_identity(root: Path, ignored: set[Path]) -> dict[str, Any]:
    def git(*args: str) -> str:
        result = subprocess.run(["git", *args], cwd=root, text=True, capture_output=True, check=False)
        return result.stdout.strip() if result.returncode == 0 else ""

    head = git("rev-parse", "HEAD")
    branch = git("branch", "--show-current")
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root, capture_output=True, check=False,
    )
    indexed = subprocess.run(["git", "ls-files", "-s", "-z"], cwd=root, capture_output=True, check=False)
    status = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd=root, capture_output=True, check=False,
    )
    valid = bool(head) and listed.returncode == indexed.returncode == status.returncode == 0
    dirty = False
    if valid:
        try:
            status_entries = porcelain_entries(status.stdout)
        except ValueError:
            valid = False
            status_entries = []
        for _, paths in status_entries:
            if any(
                (root / raw.decode(errors="surrogateescape")).absolute().resolve(strict=False) not in ignored
                for raw in paths
            ):
                dirty = True
                break
    digest = hashlib.sha256()
    if valid:
        digest.update(indexed.stdout)
        for raw_path in listed.stdout.split(b"\0"):
            if not raw_path:
                continue
            relative = raw_path.decode(errors="surrogateescape")
            candidate = (root / relative).absolute()
            if candidate.resolve(strict=False) in ignored:
                continue
            digest.update(b"path\0" + raw_path + b"\0")
            try:
                info = candidate.lstat()
                digest.update(f"{info.st_mode}:{info.st_size}".encode())
                if candidate.is_symlink():
                    digest.update(os.readlink(candidate).encode(errors="surrogateescape"))
                elif candidate.is_file():
                    with candidate.open("rb") as source:
                        for chunk in iter(lambda: source.read(1024 * 1024), b""):
                            digest.update(chunk)
            except FileNotFoundError:
                digest.update(b"absent")
            except OSError as error:
                valid = False
                digest.update(f"unreadable:{error.errno}".encode())
    return {
        "head": head or None,
        "branch": branch or None,
        "dirty": dirty if valid else None,
        "dirty_fingerprint": digest.hexdigest() if valid else None,
        "valid": valid,
    }


def parse_gate(lines: list[str], identities: list[str]) -> dict[str, Any]:
    records = {name: {"name": name, "ran": False, "completed": False, "outcome": "missing", "skips": [], "failures": []} for name in identities}
    current: str | None = None
    skips: list[str] = []
    failures: list[str] = []
    leak_disclosures: list[dict[str, Any]] = []
    signature_disclosures: list[str] = []
    final_clean = False
    library_count: int | None = None
    for line in lines:
        heading = HEADING_RE.match(line)
        if heading:
            name = heading.group(1)
            if current:
                records[current]["completed"] = True
            current = name if name in records else None
            if current:
                records[current]["ran"] = True
            continue
        count = re.search(r"All (\d+) tests passed\.", line)
        if count and current == "tests":
            library_count = int(count.group(1))
        if "SKIP" in line:
            text = line.strip()
            skips.append(text)
            if current:
                records[current]["skips"].append(text)
        if re.match(r"\s*FAIL\s", line):
            text = line.strip()
            failures.append(text)
            if current:
                records[current]["failures"].append(text)
        leak = re.search(r"leaks ([^ ]+) -> (\d+) leaks \(pinned", line)
        if leak and int(leak.group(2)) != 0:
            leak_disclosures.append({"fixture": leak.group(1), "count": int(leak.group(2))})
        if "disagrees with C (DISCLOSED" in line:
            signature_disclosures.append(line.strip())
        if line.strip() == "clean" and current is None:
            final_clean = True
    for record in records.values():
        if record["ran"]:
            if record["failures"]:
                record["outcome"] = "failed"
            elif not record["completed"]:
                record["outcome"] = "incomplete"
            elif record["skips"]:
                record["outcome"] = "skipped"
            else:
                record["outcome"] = "passed"
    return {
        "stages": list(records.values()), "skips": skips, "failures": failures,
        "disclosed_defects": {"pinned_leaks": leak_disclosures, "abi_signatures": signature_disclosures},
        "test_counts": {"library": library_count, "cli": None, "runtime": None},
        "gate_printed_clean": final_clean,
    }


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args(argv)

    root = repo_root(Path.cwd())
    gate = root / "tools/check.sh"
    report_path = (args.report or root / ".cell-cache/qualification/report.json").resolve()
    log_path = (args.log or report_path.with_name("gate.log")).resolve()
    try:
        validate_artifact_paths(root, report_path, log_path)
    except (ValueError, RuntimeError) as error:
        parser.error(str(error))
    ignored = {report_path, log_path, report_path.with_name(report_path.name + ".tmp")}
    errors: list[str] = []
    try:
        identities = stage_identities(gate)
    except (OSError, RuntimeError) as error:
        identities = []
        errors.append(str(error))
    before = source_identity(root, ignored)
    if not before["valid"]:
        errors.append("could not sample source identity before the gate")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    gate_returncode: int | None = None
    launch_error: str | None = None
    try:
        with log_path.open("w") as log:
            process = subprocess.Popen(
                [str(gate)], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log.write(line)
                log.flush()
                lines.append(line.rstrip("\n"))
            gate_returncode = process.wait()
    except OSError as error:
        launch_error = f"could not launch gate: {error}"
        errors.append(launch_error)
        log_path.write_text(launch_error + "\n")

    after = source_identity(root, ignored)
    if not after["valid"]:
        errors.append("could not sample source identity after the gate")
    parsed = parse_gate(lines, identities)
    missing = [record["name"] for record in parsed["stages"] if not record["ran"]]
    if missing:
        errors.append("required stages did not run: " + ", ".join(missing))
    if before != after:
        errors.append("source identity drifted while the gate ran")
    if gate_returncode is None:
        errors.append("gate return code is unavailable")
    elif gate_returncode != 0:
        errors.append(f"gate exited with status {gate_returncode}")
    if gate_returncode is not None and gate_returncode < 0:
        errors.append(f"gate terminated by signal {-gate_returncode}")
    if gate_returncode == 0 and not parsed["gate_printed_clean"]:
        errors.append("gate output ended without a clean verdict")

    disclosures = parsed["disclosed_defects"]
    has_disclosures = bool(disclosures["pinned_leaks"] or disclosures["abi_signatures"])
    strict = args.strict or args.release
    if strict and parsed["skips"]:
        errors.append("strict qualification forbids skipped checks")
    if args.release and has_disclosures:
        errors.append("release qualification forbids disclosed defects")
    if args.release and before["dirty"]:
        errors.append("release qualification requires clean input")

    if errors:
        verdict = "failed"
    elif parsed["skips"]:
        verdict = "partial"
    elif has_disclosures:
        verdict = "disclosed"
    else:
        verdict = "qualified"
    report = {
        "schema_version": SCHEMA_VERSION,
        "mode": "release" if args.release else "strict" if args.strict else "ordinary",
        "source": {"before": before, "after": after, "drifted": before != after},
        "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
        "tools": {
            "python": platform.python_version(),
            "zig": command_line([os.environ.get("ZIG", "zig"), "version"], root),
            "clang": command_line([os.environ.get("CC", "cc"), "--version"], root),
            "llvm": command_line([str(Path(os.environ.get("LLVM_BIN", "/opt/homebrew/opt/llvm/bin")) / "mlir-opt"), "--version"], root),
        },
        "gate": {"path": str(gate), "returncode": gate_returncode, "launch_error": launch_error},
        **parsed,
        "required_stage_names": identities,
        "missing_required_stages": missing,
        "errors": errors,
        "artifacts": {"report": str(report_path), "log": str(log_path)},
        "verdict": verdict,
        "release_ready": bool(args.release and verdict == "qualified"),
    }
    write_report(report_path, report)
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
