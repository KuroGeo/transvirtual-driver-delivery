#!/usr/bin/env python3
"""One observable entry point for local engineering checks and native probes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

import checks
import gate
import state

ROOT = checks.ROOT
RUNS = ROOT / "harness" / "runs"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def stages(command, run_dir, candidate, manifest=None, targets=None):
    python = sys.executable
    check = ("repository", [python, "harness/run.py", "_check"], ROOT)
    tooling = ("tooling-tests", [python, "-m", "unittest", "discover", "-s", "harness/tests", "-v"], ROOT)
    sdk = ("sdk", [python, "harness/run.py", "_sdk"], ROOT)
    quality = [check, tooling, sdk,
               ("format", ["dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test"], ROOT / "app"),
               ("analyze", ["flutter", "analyze", "--no-pub"], ROOT / "app"),
               ("flutter-tests", ["flutter", "test", "--no-pub", "--reporter", "expanded"], ROOT / "app")]
    if command == "test":
        return [sdk, ("flutter-tests", ["flutter", "test", "--no-pub", "--reporter", "expanded", *(targets or [])], ROOT / "app")]
    if command == "preflight":
        return [sdk, ("doctor", ["flutter", "doctor", "-v"], ROOT / "app")]
    if command == "check":
        return [check, tooling]
    if command == "quality":
        return quality
    if command == "build":
        return [sdk, ("ios-build", ["flutter", "build", "ios", "--simulator", "--debug", "--no-pub"], ROOT / "app")]
    if command == "native":
        return [sdk,
                ("probe-build", ["flutter", "build", "ios", "--simulator", "--debug", "--no-pub", "--target", "lib/harness_probe.dart"], ROOT / "app"),
                ("process-restart", [python, "harness/native.py", "--output", str(run_dir / "native"), "--candidate", candidate], ROOT)]
    if command == "gate":
        return [("production-gate", [python, "harness/run.py", "_gate", "--manifest", str(manifest)], ROOT)]
    raise ValueError(command)


def subprocess_stage(argv, cwd, log, timeout, lock_fds, on_spawn):
    env = os.environ.copy()
    for key in ("NO_PROXY", "no_proxy"):
        current = env.get(key, "")
        env[key] = ",".join(filter(None, [current, "localhost", "127.0.0.1", "::1"]))
    with log.open("w") as output:
        wrapper = [sys.executable, str(ROOT / "harness/run.py"), "_stage", "--stage-argv", json.dumps(argv)]
        process = subprocess.Popen(wrapper, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True, pass_fds=tuple(lock_fds))
        try:
            on_spawn(process.pid)
            return process.wait(timeout=timeout)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["preflight", "check", "quality", "test", "build", "native", "gate", "_check", "_sdk", "_gate", "_stage"])
    parser.add_argument("--target", action="append", default=[], help="A file/directory under app/test; repeat for scoped tests")
    parser.add_argument("--stage-argv", help=argparse.SUPPRESS)
    parser.add_argument("--resume", type=Path, help="Reuse verified passed stages of an interrupted run of this same candidate")
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--timeout", type=int, default=900, help="Per-stage timeout in seconds")
    args = parser.parse_args()
    if args.command == "_stage":
        # Keep inherited lease FDs alive while the whole stage runs. If the
        # coordinator is SIGKILLed, this wrapper still owns the OS lease.
        # TERM is also delivered to the child in this process group. Keep
        # waiting so the parent can kill the entire group if it ignores TERM.
        signal.signal(signal.SIGTERM, lambda signum, frame: None)
        signal.signal(signal.SIGINT, lambda signum, frame: None)
        return subprocess.call(json.loads(args.stage_argv))
    if args.command == "_check":
        errors = checks.repository()
        print("\n".join(errors) if errors else "Repository links, requirement DAG and Dart boundaries passed")
        return bool(errors)
    if args.command == "_sdk":
        try:
            resolved = json.loads(subprocess.check_output(["flutter", "--version", "--machine"], text=True))
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f"Flutter SDK unavailable: {error}; install the version in app/.fvmrc")
            return 1
        pinned = json.loads((ROOT / "app/.fvmrc").read_text())["flutter"]
        print(json.dumps(resolved, indent=2))
        if resolved["frameworkVersion"] != pinned:
            print(f"SDK mismatch: expected Flutter {pinned}; select the pinned SDK before continuing")
            return 1
        return 0
    if args.command == "_gate":
        if not args.manifest:
            parser.error("--manifest is required for gate")
        result = gate.evaluate(json.loads(args.manifest.read_text()), checks.fingerprint(), args.manifest.parent)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return int(not result["allowed"])
    if args.command == "gate" and not args.manifest:
        parser.error("--manifest is required for gate")
    if args.target and args.command != "test":
        parser.error("--target applies to test only")
    for target in args.target:
        path = (ROOT / "app" / target).resolve()
        if not path.is_relative_to(ROOT / "app/test") or not path.exists():
            parser.error(f"test target must exist under app/test: {target}")
    RUNS.mkdir(exist_ok=True)
    candidate = {"source_fingerprint": checks.fingerprint()}
    if args.resume:
        run_dir = args.resume.resolve()
        report = json.loads((run_dir / "report.json").read_text())
        validation = state.validate_resume(report, candidate)
        if report.get("command") != args.command:
            validation["reasons"].append("resume command differs from saved command")
        if validation["reasons"]:
            print(json.dumps(validation, ensure_ascii=False, indent=2))
            return 1
        report["resume_count"] = report.get("resume_count", 0) + 1
    else:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        run_dir = RUNS / f"{stamp}-{args.command}"
        run_dir.mkdir()
        report = {"command": args.command, "candidate": candidate, "started_at": stamp, "stages": []}
    resource = "app-workspace" if args.command in {"quality", "test", "build", "native", "preflight"} else "repository-checks"
    print(f"Run: {run_dir}", flush=True)
    report["job"] = {"pid": os.getpid(), "status": "running"}
    def interrupted(signum, frame):
        raise InterruptedError(f"received signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    status = "failed"
    try:
        with state.lease([resource], run_dir, RUNS / "locks") as metadata:
            report["lease"] = {key: value for key, value in metadata.items() if key != "lock_fds"}
            save(run_dir / "report.json", report)
            for stage_id, argv, cwd in stages(args.command, run_dir, candidate["source_fingerprint"], args.manifest.resolve() if args.manifest else None, args.target):
                prior = next((item for item in report["stages"] if item["id"] == stage_id), None)
                if args.command != "gate" and prior and prior["status"] == "passed" and prior["command"] == argv and prior["cwd"] == str(cwd):
                    previous_log = Path(prior["log_path"])
                    if not previous_log.exists() or sha(previous_log) != prior["sha256"]:
                        raise ValueError(f"{stage_id}: saved log missing or changed; completed stage cannot be reused")
                    print(f"{stage_id}: reused verified stage", flush=True)
                    continue
                record = {"id": stage_id, "command": argv, "cwd": str(cwd), "status": "running", "log_path": str(run_dir / f"{stage_id}.log")}
                if prior:
                    report["stages"].remove(prior)
                report["stages"].append(record)
                save(run_dir / "report.json", report)
                started = time.monotonic()
                def on_spawn(pid):
                    record["job_pid"] = pid
                    save(run_dir / "report.json", report)
                code = subprocess_stage(argv, cwd, Path(record["log_path"]), args.timeout, metadata["lock_fds"], on_spawn)
                record.update(status="passed" if code == 0 else "failed", exit_code=code, elapsed_seconds=round(time.monotonic() - started, 3), sha256=sha(record["log_path"]))
                save(run_dir / "report.json", report)
                print(f"{stage_id}: {record['status']} ({record['elapsed_seconds']}s); {record['log_path']}", flush=True)
                if code:
                    print(Path(record["log_path"]).read_text()[-6000:])
                    break
            else:
                status = "passed"
    except (KeyboardInterrupt, InterruptedError):
        status = "interrupted"
        print("Interrupted; subprocess stopped, lease released. Resume only after checking candidate and saved logs.")
    except (OSError, ValueError, state.BusyError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        print(f"Cannot complete run: {error}")
    finally:
        current = checks.fingerprint()
        report["candidate_after"] = {"source_fingerprint": current}
        if current != candidate["source_fingerprint"]:
            status = "stale"
            print("Sources changed during run; retain diagnostic logs and start a new run for the final candidate.")
        report["job"]["status"] = status
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["lease"] = json.loads((run_dir / "lease.json").read_text()) if (run_dir / "lease.json").exists() else {}
        save(run_dir / "report.json", report)
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
