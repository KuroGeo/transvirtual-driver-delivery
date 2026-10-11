#!/usr/bin/env python3
"""One observable entry point for local engineering checks and native probes."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

try:
    from . import checks, gate, state, native_workbench, f1
except ImportError:  # CLI script entrypoint
    import checks
    import gate
    import state
    import native_workbench
    import f1

ROOT = checks.ROOT
RUNS = ROOT / "harness" / "runs"
NATIVE_ENTRIES = {"probe": "lib/harness_probe.dart", "startup": "lib/main.dart", "workbench": native_workbench.ENTRY}
STARTUP_TILES = "http://127.0.0.1:1/tiles/{z}/{x}/{y}.png"
NATIVE_OPTION_KEYS = ("runtime", "device_type", "scenario", "content_size", "reduce_motion", "initial_tiles", "cold_fixture", "migration_fault")


def read_manifest(path):
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_file():
        raise ValueError("manifest must be a canonical regular file without symlinks")
    limit = 8 * 1024 * 1024
    if not 0 < path.stat().st_size <= limit:
        raise ValueError("manifest must contain 1..8388608 bytes")
    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate manifest key: {key}")
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError(f"non-finite manifest constant: {value}")
    def finite_float(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("non-finite manifest number")
        return result
    raw = path.read_bytes()
    if not 0 < len(raw) <= limit:
        raise ValueError("manifest byte bound changed while reading")
    value = json.loads(raw, object_pairs_hook=object_pairs, parse_constant=invalid_constant, parse_float=finite_float)
    if not isinstance(value, dict):
        raise ValueError("manifest must be a JSON object")
    return value


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def resume_report(run_dir):
    run_dir = Path(run_dir).absolute()
    if run_dir.resolve() != run_dir or not run_dir.is_dir():
        raise ValueError("resume requires a canonical logical run root")
    pointer = run_dir / "latest.json"
    if pointer.is_symlink():
        raise ValueError("latest attempt pointer cannot be a symlink")
    if not pointer.exists():
        legacy = read_manifest(run_dir / "report.json")
        if "latest_attempt_report" in legacy or (run_dir / "attempts").exists() or (run_dir / "attempts").is_symlink():
            raise ValueError("modern attempt pointer is missing; cannot fall back to a status mirror")
        return legacy, run_dir / "report.json", "latest-report.json"
    latest = read_manifest(pointer)
    name, mirror = latest.get("latest_attempt_report"), latest.get("status_mirror")
    if latest.get("schema") != 1 or type(latest.get("schema")) is not int or not isinstance(name, str) or not re.fullmatch(r"attempts/\d{6}/report\.json", name) or mirror not in {"report.json", "latest-report.json"}:
        raise ValueError("invalid latest attempt pointer")
    leaf = run_dir / name
    report = read_manifest(leaf)
    if sha(leaf) != latest.get("sha256") or report.get("latest_attempt_report") != name:
        raise ValueError("latest attempt report hash/path mismatch")
    read_manifest(run_dir / mirror)
    if sha(run_dir / mirror) != latest["sha256"]:
        raise ValueError("latest status mirror differs from immutable attempt report")
    return report, leaf, mirror


def attempt_directory(run_dir):
    directory = run_dir / "attempts"
    if directory.is_symlink() or directory.resolve() != directory:
        raise ValueError("attempts must be a canonical task-owned directory")
    directory.mkdir(exist_ok=True)
    entries = list(directory.iterdir())
    if any(not re.fullmatch(r"\d{6}", path.name) or path.is_symlink() or not path.is_dir() for path in entries):
        raise ValueError("unexpected/symlink attempt directory")
    number = max((int(path.name) for path in entries), default=0) + 1
    if number > 999999:
        raise ValueError("attempt directory capacity exceeded")
    result = directory / f"{number:06d}"
    result.mkdir()
    return result


def save_attempt(run_dir, attempt, report, mirror):
    leaf = attempt / "report.json"
    save(leaf, report)
    save(run_dir / mirror, report)
    save(run_dir / "latest.json", {"schema": 1, "latest_attempt_report": leaf.relative_to(run_dir).as_posix(), "sha256": sha(leaf), "status_mirror": mirror})


def native_resume_ready(report, directory):
    application_stages = [stage for stage in report.get("stages", []) if stage.get("id") in {"process-restart", "startup-smoke", "workbench-smoke"}]
    if report.get("command") != "native" or not application_stages:
        return
    if all(stage.get("completion", {}).get("spawned") is False and stage.get("job_pid") is None for stage in application_stages):
        return  # The recorded wrapper never started; it could not allocate a device.
    path = directory / "native/result.json"
    if not path.exists():
        raise ValueError("prior native cleanup is unknown; evidenced task-owner cleanup is required before resume")
    native = read_manifest(path)
    device, commands = native.get("device"), native.get("commands")
    expected = report.get("options", {})
    if (native.get("candidate") != report.get("candidate", {}).get("source_fingerprint")
            or native.get("configuration") != expected.get("configuration")
            or native.get("entrypoint") != expected.get("entrypoint")
            or not isinstance(device, dict) or device.get("task_owned") is not True
            or not isinstance(device.get("udid"), str) or not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", device["udid"])
            or device.get("runtime") != expected.get("runtime") or device.get("type") != expected.get("device_type")
            or native.get("device_cleaned") is not True
            or any(key.endswith("cleanup_error") for key in native)
            or not isinstance(commands, list)):
        raise ValueError("prior native task device/descendant cleanup is not verified; no automatic orphan cleanup")
    name = "OceanDelivery-Workbench" if expected.get("scope") == "workbench" else "OceanDelivery-Harness"
    created = any(isinstance(record, dict) and record.get("argv") == ["xcrun", "simctl", "create", name, device["type"], device["runtime"]] and type(record.get("exit_code")) is int and record["exit_code"] == 0 and isinstance(record.get("stdout"), str) and record["stdout"].strip() == device["udid"] for record in commands)
    deleted = any(isinstance(record, dict) and record.get("argv") == ["xcrun", "simctl", "delete", device["udid"]] and type(record.get("exit_code")) is int and record["exit_code"] == 0 for record in commands)
    if not created or not deleted:
        raise ValueError("prior native cleanup lacks actual owned-device create/delete receipts")


def cleanup_grace(stage_id):
    return 150 if stage_id in {"process-restart", "startup-smoke", "workbench-smoke"} else 5


def build_arguments(options):
    arguments = ["flutter", "build", "ios", f"--{options['build_mode']}", "--no-pub", "--target", options["entrypoint"], f"--dart-define=OCEAN_MODE={options['configuration']}"]
    if options["ios_target"] == "simulator":
        arguments.append("--simulator")
    else:
        # Device builds are unsigned local candidates. Production signing and
        # distribution require the independent release handoff.
        arguments.append("--no-codesign")
    if options.get("tile_url"):
        arguments.append("--dart-define=OCEAN_TILE_URL=" + options["tile_url"])
    return arguments


def stages(command, run_dir, candidate, manifest=None, targets=None, options=None, root=None, lease_context=None):
    root = root or ROOT
    options = options or {"configuration": "local-client", "build_mode": "debug", "ios_target": "simulator", "entrypoint": "lib/main.dart", "device": None}
    python = sys.executable
    define = f"--dart-define=OCEAN_MODE={options['configuration']}"
    check = ("repository", [python, "harness/run.py", "_check"], root)
    tooling = ("tooling-tests", [python, "-m", "unittest", "discover", "-s", "harness/tests", "-v"], root)
    sdk = ("sdk", [python, "harness/run.py", "_sdk"], root)
    pub = ("pub", ["flutter", "pub", "get", "--enforce-lockfile"], root / "app")
    format_paths = ["lib", "test"] + (["integration_test"] if (root / "app/integration_test").exists() else [])
    quality = [check, tooling, sdk, pub,
               ("format", ["dart", "format", "--output=none", "--set-exit-if-changed", *format_paths], root / "app"),
               ("analyze", ["flutter", "analyze", "--no-pub"], root / "app"),
               ("flutter-tests", ["flutter", "test", "--no-pub", "--reporter", "expanded", define, "--file-reporter", f"json:{run_dir / 'flutter-tests.events.jsonl'}"], root / "app")]
    if command == "test":
        return [sdk, pub, ("flutter-tests", ["flutter", "test", "--no-pub", "--reporter", "expanded", define, *(targets or [])], root / "app")]
    if command == "integration":
        return [sdk, pub, ("integration-tests", ["flutter", "test", "--no-pub", "--reporter", "expanded", define, "--device-id", options["device"], *(targets or [])], root / "app")]
    if command == "pub":
        return [sdk, pub]
    if command == "preflight":
        return [sdk, ("doctor", ["flutter", "doctor", "-v"], root / "app")]
    if command == "check":
        return [check, tooling]
    if command == "quality":
        return quality
    if command == "build":
        return [sdk, pub, ("ios-build", build_arguments(options), root / "app")]
    if command == "native":
        scope = options.get("scope", "probe")
        entrypoint = NATIVE_ENTRIES[scope]
        probe_options = {**options, "entrypoint": entrypoint, "tile_url": STARTUP_TILES if scope == "startup" else None}
        native_arguments = [python, "harness/native.py", "--output", str(run_dir / "native"), "--candidate", candidate, "--configuration", options["configuration"], "--scope", scope, "--lease-context", json.dumps(lease_context or {})]
        for name in ("runtime", "device_type"):
            if options.get(name):
                native_arguments += ["--" + name.replace("_", "-"), options[name]]
        if scope == "workbench":
            for name in ("scenario", "content_size", "initial_tiles", "cold_fixture"):
                if options.get(name):
                    native_arguments += ["--" + name.replace("_", "-"), options[name]]
            for name in ("reduce_motion", "migration_fault"):
                if options.get(name):
                    native_arguments += ["--" + name.replace("_", "-")]
            native_arguments += ["--driver-target", options.get("driver_target") or native_workbench.DRIVER]
            if options.get("fixture"):
                native_arguments += ["--fixture", options["fixture"]]
        return [sdk, pub,
                ({"probe": "probe-build", "startup": "startup-build", "workbench": "workbench-build"}[scope], build_arguments(probe_options), root / "app"),
                ({"probe": "process-restart", "startup": "startup-smoke", "workbench": "workbench-smoke"}[scope], native_arguments, root)]
    if command in {"gate", "local-gate", "f1-gate"}:
        private = {"gate": "_gate", "local-gate": "_local_gate", "f1-gate": "_f1_gate"}[command]
        stage_id = {"gate": "production-gate", "local-gate": "local-evidence-gate", "f1-gate": "f1-evidence-gate"}[command]
        return [(stage_id, [python, "harness/run.py", private, "--manifest", str(manifest)], ROOT)]
    raise ValueError(command)


def require_lease_context(context, root=None, required=("app-workspace",)):
    """Require the actual inherited flock descriptions, never an env claim.

    A fresh descriptor cannot impersonate another holder: it must refer to the
    canonical lock inode, a separate open must find it locked, and this inherited
    descriptor must already be able to take the same flock without a conflict.
    """
    root = (root or ROOT).resolve()
    marker = root / ".harness-isolation.json"
    origin = Path(json.loads(marker.read_text())["source_root"]).resolve() if marker.exists() else root
    lock_root = origin / "harness/runs/locks"
    if not isinstance(context, dict) or Path(context.get("lock_root", "")).resolve() != lock_root:
        raise ValueError("canonical Harness lease context is required; use harness/run.py")
    resources = context.get("resources", [])
    descriptors = context.get("lock_fds", [])
    if not set(required).issubset(resources) or len(descriptors) != len(resources):
        raise ValueError("workspace/device inherited lease descriptors are missing")
    for resource, descriptor in zip(resources, descriptors):
        if not isinstance(descriptor, int) or isinstance(descriptor, bool):
            raise ValueError("lease descriptor must be an integer")
        path = lock_root / (hashlib.sha256(resource.encode()).hexdigest() + ".lock")
        try:
            actual, expected = os.fstat(descriptor), path.stat()
            if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
                raise ValueError("inherited lease descriptor does not match the lock inode")
            with path.open("a+") as separate:
                try:
                    fcntl.flock(separate.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    fcntl.flock(separate.fileno(), fcntl.LOCK_UN)
                    raise ValueError("inherited lease is not held")
            # Re-locking the same open description is harmless. A fresh open
            # while someone else holds the resource fails here.
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError) as error:
            raise ValueError(f"invalid inherited lease for {resource}: {error}") from error
    return descriptors


@contextmanager
def isolated_workspace(source_root, fingerprint, report=None, evidence_dir=None):
    """Copy only source, verify it, and delete only this task's temporary root."""
    source_root = Path(source_root).resolve()
    with tempfile.TemporaryDirectory(prefix="ocean-harness-") as directory:
        destination = Path(directory).resolve()
        if report is not None:
            report.update(source_root=str(source_root), execution_root=str(destination), isolation={"requested": True, "verified_fingerprint": fingerprint, "task_owned": True, "cleaned": False})
        try:
            names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=source_root, stderr=subprocess.DEVNULL).decode().split("\0")
            files = {source_root / name for name in names if name}
        except subprocess.CalledProcessError:
            files = {path for path in source_root.rglob("*") if path.is_file()}
        files.update(checks.source_files(source_root))
        snapshot_outputs = [prefix for prefix in checks.OUTPUT_ROOTS if prefix.parts[0] == "app" or prefix.as_posix() in {"harness/runs", "harness/history", "harness/evidence"}]
        for path in sorted(files):
            relative = path.relative_to(source_root)
            if (not path.is_file() or {".git", "__pycache__", "node_modules"}.intersection(relative.parts)
                    or any(relative.is_relative_to(prefix) for prefix in snapshot_outputs)
                    or relative.as_posix() in checks.GENERATED - {"harness/project/work.json", "harness/project/next-phase/work.json", "harness/project/next-phase/execution.json"}):
                continue
            if not path.resolve().is_relative_to(source_root):
                raise ValueError(f"source snapshot refuses external symlink: {relative}")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        if checks.fingerprint(destination) != fingerprint or checks.fingerprint(source_root) != fingerprint:
            raise ValueError("source changed while creating isolated snapshot")
        marker = {"source_root": str(source_root), "source_fingerprint": fingerprint}
        source_proof = checks.next_phase.snapshot_source_archive(source_root, fingerprint)
        if source_proof is not None:
            archive = destination / checks.next_phase.SOURCE_ARCHIVE
            archive.write_bytes(source_proof)
            marker["source_objects"] = {"path": archive.name, "sha256": sha(archive)}
            if report is not None:
                if evidence_dir is None:
                    raise ValueError("isolated source proof requires an original attempt directory")
                retained = Path(evidence_dir) / "source-objects.json"
                with retained.open("xb") as output:
                    output.write(source_proof)
                report["source_objects"] = {"path": str(retained), "sha256": sha(retained), "kind": "next-phase-git-source-objects"}
        if checks.fingerprint(source_root) != fingerprint:
            raise ValueError("source changed while preserving approved Git objects")
        save(destination / ".harness-isolation.json", marker)
        try:
            yield destination
        finally:
            if report is not None:
                report["execution_candidate_after"] = {"source_fingerprint": checks.fingerprint(destination)}


def stage_spec(stages_list, root, run_dir):
    def normalized(value):
        if str(value).startswith("json:"):
            return str(value).replace(str(run_dir), "@run").replace(str(root), "@workspace")
        return str(value).replace(str(root), "@workspace").replace(str(run_dir), "@run")
    result = []
    for name, argv, cwd in stages_list:
        arguments = list(argv)
        if "--lease-context" in arguments:
            index = arguments.index("--lease-context")
            arguments[index + 1] = "@inherited-lease"
        result.append({"id": name, "command": [normalized(value) for value in arguments], "cwd": normalized(cwd)})
    return result


def preserve_artifact(execution_root, run_dir, stage_id, options, expected_fingerprint=None):
    execution_fingerprint = checks.fingerprint(execution_root)
    if expected_fingerprint and execution_fingerprint != expected_fingerprint:
        raise ValueError("executed source changed before artifact preservation")
    target = "iphoneos" if options["ios_target"] == "device" else "iphonesimulator"
    application = execution_root / f"app/build/ios/{target}/Runner.app"
    directory = run_dir / f"artifact-{stage_id}"
    directory.mkdir(exist_ok=True)
    retained = directory / "Runner.app"
    if retained.exists():
        shutil.rmtree(retained)
    shutil.copytree(application, retained, symlinks=True)
    files = []
    for path in sorted(retained.rglob("*")):
        if path.is_symlink():
            files.append({"path": path.relative_to(retained).as_posix(), "symlink": os.readlink(path)})
        elif path.is_file():
            files.append({"path": path.relative_to(retained).as_posix(), "sha256": sha(path), "bytes": path.stat().st_size})
    archive = Path(shutil.make_archive(str(directory / "Runner"), "gztar", directory, "Runner.app"))
    value = {"path": str(archive), "sha256": sha(archive), "candidate": {"source_fingerprint": execution_fingerprint}, "files": files, "configuration": options["configuration"], "build_mode": options["build_mode"], "ios_target": options["ios_target"], "entrypoint": options["entrypoint"], "driver_target": options.get("driver_target"), "fixture": options.get("fixture"), "tile_url": options.get("tile_url"), "native_options": {key: options.get(key) for key in NATIVE_OPTION_KEYS}, "signed_for_production": False}
    save(directory / "manifest.json", value)
    return {key: value[key] for key in ("path", "sha256", "candidate", "configuration", "build_mode", "ios_target", "entrypoint", "driver_target", "fixture", "tile_url", "native_options", "signed_for_production")}


def cleanup_previous_isolation(report, source_root):
    if not report.get("isolation", {}).get("task_owned"):
        return
    path = Path(report["execution_root"]).resolve()
    if not path.exists():
        return
    if path.parent != Path(tempfile.gettempdir()).resolve() or not path.name.startswith("ocean-harness-"):
        raise ValueError("refusing cleanup of non-task isolation path")
    marker = json.loads((path / ".harness-isolation.json").read_text())
    if marker != {"source_root": str(source_root.resolve()), "source_fingerprint": report["candidate"]["source_fingerprint"]}:
        raise ValueError("isolation ownership/candidate marker mismatch")
    shutil.rmtree(path)


def subprocess_stage(argv, cwd, log, timeout, lock_fds, on_spawn, lease_context=None, *, on_finish=None, cleanup_grace=5):
    if isinstance(cleanup_grace, bool) or not isinstance(cleanup_grace, (int, float)) or not math.isfinite(cleanup_grace) or not 0 < cleanup_grace <= 150:
        raise ValueError("cleanup grace must be finite in (0, 150] seconds")
    env = os.environ.copy()
    for key in ("NO_PROXY", "no_proxy"):
        current = env.get(key, "")
        env[key] = ",".join(filter(None, [current, "localhost", "127.0.0.1", "::1"]))
    process, primary = None, None
    receipt = {"spawned": False, "wrapper_reaped": False, "returncode": None, "cleanup_grace_seconds": cleanup_grace, "cleanup_errors": []}
    try:
        with log.open("x") as output:
            wrapper = [sys.executable, str(ROOT / "harness/run.py"), "_stage", "--stage-argv", json.dumps(argv)]
            if lease_context:
                wrapper += ["--lease-context", json.dumps(lease_context)]
            process = subprocess.Popen(wrapper, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True, pass_fds=tuple(lock_fds))
            receipt.update(spawned=True, wrapper_pid=process.pid, process_group=process.pid)
            on_spawn(process.pid)
            return process.wait(timeout=timeout)
    except BaseException as error:
        primary = error
        receipt["cause"] = type(error).__name__
        raise
    finally:
        cleanup_started = time.monotonic()
        if process is not None:
            def group_state():
                # This group was created by our own Popen(start_new_session).
                # A zero wrapper exit does not mean all descendants exited.
                process.poll()
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    return False
                except PermissionError:
                    return True
                except OSError as error:
                    receipt["cleanup_errors"].append({"type": type(error).__name__, "message": str(error)})
                    return None
                return True

            def wait_group(deadline):
                while True:
                    alive = group_state()
                    if alive is None or alive is False and process.returncode is not None:
                        return alive
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return alive
                    time.sleep(min(0.02, remaining))

            def signal_group(kind, field):
                try:
                    os.killpg(process.pid, kind)
                    receipt[field] = True
                except ProcessLookupError:
                    receipt[field] = False

            try:
                if process.poll() is None:
                    receipt["termination_requested_at"] = datetime.now(timezone.utc).isoformat()
                    signal_group(signal.SIGTERM, "term_sent")
                    alive = wait_group(cleanup_started + cleanup_grace)
                    if alive is True or process.poll() is None:
                        signal_group(signal.SIGKILL, "kill_sent")
                        wait_group(time.monotonic() + 5)
                else:
                    # The wrapper can exit slightly before a detached analyzer
                    # descendant. Permit natural quiescence, then clean only
                    # our group. Normal exits get at most five seconds total,
                    # even when a native cancellation has a 150-second grace.
                    budget = min(cleanup_grace, 5)
                    deadline = cleanup_started + budget
                    receipt["post_exit_cleanup_budget_seconds"] = budget
                    receipt["group_alive_after_wrapper_exit"] = group_state()
                    quiet_started = time.monotonic()
                    alive = wait_group(min(deadline, quiet_started + min(1, budget * 0.4)))
                    receipt["natural_quiet_wait_seconds"] = round(time.monotonic() - quiet_started, 3)
                    if alive is True:
                        receipt["termination_requested_at"] = datetime.now(timezone.utc).isoformat()
                        signal_group(signal.SIGTERM, "term_sent")
                        alive = wait_group(deadline - min(1, budget * 0.2))
                        if alive is True:
                            signal_group(signal.SIGKILL, "kill_sent")
                            wait_group(deadline)
            except (OSError, subprocess.TimeoutExpired, InterruptedError, KeyboardInterrupt) as error:
                receipt["cleanup_errors"].append({"type": type(error).__name__, "message": str(error)})
            receipt.update(returncode=process.poll(), wrapper_reaped=process.returncode is not None)
            receipt["group_alive"] = group_state()
        receipt["finished_at"] = datetime.now(timezone.utc).isoformat()
        receipt["cleanup_elapsed_seconds"] = round(time.monotonic() - cleanup_started, 3)
        if on_finish is not None:
            try:
                on_finish(receipt)
            except BaseException:
                if primary is None:
                    raise
        if primary is None and (receipt["cleanup_errors"] or not receipt["wrapper_reaped"] or receipt.get("group_alive") is not False):
            raise RuntimeError("stage cleanup/reap is incomplete; inspect completion receipt")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["preflight", "check", "pub", "quality", "test", "integration", "build", "native", "gate", "local-gate", "f1-gate", "_check", "_sdk", "_gate", "_local_gate", "_f1_gate", "_stage"])
    parser.add_argument("--target", action="append", default=[], help="Existing app/test path (test) or app/integration_test path (integration); repeat")
    parser.add_argument("--configuration", choices=["demo", "local-client"], default="local-client", help="Explicit OCEAN_MODE; demo data is separate from local-client")
    parser.add_argument("--build-mode", choices=["debug", "profile", "release"], default="debug", help="iOS build mode; simulator supports debug only")
    parser.add_argument("--ios-target", choices=["simulator", "device"], default="simulator", help="Device builds are unsigned local artifacts; no installation")
    parser.add_argument("--entrypoint", default="lib/main.dart", help="Existing Dart entrypoint under app/lib (build only)")
    parser.add_argument("--device", help="Explicit leased device ID for integration; no automatic device selection")
    parser.add_argument("--scope", choices=["probe", "startup", "workbench"], default="probe", help="native: reliability probe, formal-entry startup or private workbench tooling smoke; independent product acceptance remains separate")
    parser.add_argument("--driver-target", help="native workbench only: existing integration_test Dart driver; defaults to tooling smoke")
    parser.add_argument("--fixture", choices=[native_workbench.LEGACY], help="native workbench only: genuine v1 fixture seeded before first launch")
    parser.add_argument("--runtime", help="native only: explicit available CoreSimulator runtime ID")
    parser.add_argument("--device-type", help="native only: explicit available CoreSimulator device type ID")
    parser.add_argument("--scenario", choices=[f"N{i}" for i in range(1, 8)], help="independent workbench acceptance driver only; not tooling smoke")
    parser.add_argument("--content-size", choices=["large", "accessibility-extra-extra-extra-large"], help="task-only system text size; actual MediaQuery is the evidence")
    parser.add_argument("--reduce-motion", action="store_true", help="task-only OS setting attempt; actual disableAnimations must be observed")
    parser.add_argument("--initial-tiles", choices=["normal", "503"], default="normal", help="controlled tiles before first App mount")
    parser.add_argument("--cold-fixture", choices=["none", "viewport-corrupt", "viewport-nonfinite"], default="none", help="N5 task settings-only fault after first PID exits")
    parser.add_argument("--migration-fault", action="store_true", help="N6 genuine v1 migration rollback fixture; no data clearing")
    parser.add_argument("--isolated", action="store_true", help="Execute a fingerprint-verified clean source copy with locked pub preparation")
    parser.add_argument("--stage-argv", help=argparse.SUPPRESS)
    parser.add_argument("--lease-context", help=argparse.SUPPRESS)
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
        context = json.loads(args.lease_context) if args.lease_context else None
        descriptors = require_lease_context(context, required=()) if context else []
        return subprocess.call(json.loads(args.stage_argv), pass_fds=tuple(descriptors))
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
    if args.command in {"_gate", "_local_gate", "_f1_gate"}:
        if not args.manifest:
            parser.error("--manifest is required for evidence gate")
        try:
            manifest = read_manifest(args.manifest)
            if args.command == "_f1_gate":
                result = f1.evaluate(manifest, checks.fingerprint(), ROOT)
                result["evidence_manifest"] = {"path": str(args.manifest.resolve()), "sha256": sha(args.manifest), "kind": "f1-manifest"}
                print(json.dumps(result, ensure_ascii=False, indent=2))
                return int(not result["feature_allowed"])
            local = args.command == "_local_gate"
            evaluate = gate.evaluate_local if local else gate.evaluate
            result = evaluate(manifest, checks.fingerprint(), args.manifest.resolve().parent)
        except (OSError, ValueError, TypeError, UnicodeError, RecursionError) as error:
            if args.command == "_f1_gate":
                print(json.dumps({"feature": "F1", "feature_allowed": False, "publish_allowed": False, "reasons": [str(error)]}, ensure_ascii=False, indent=2))
                return 1
            result = {"reasons": [str(error)], "local_allowed": False, "publish_allowed": False} if args.command == "_local_gate" else {"allowed": False, "reasons": [str(error)]}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return int(not result["local_allowed" if args.command == "_local_gate" else "allowed"])
    if args.command in {"gate", "local-gate", "f1-gate"} and not args.manifest:
        parser.error("--manifest is required for evidence gate")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.target and args.command not in {"test", "integration"}:
        parser.error("--target applies to test/integration only")
    if args.entrypoint != "lib/main.dart" and args.command != "build":
        parser.error("--entrypoint applies to build only; native keeps its separate probe")
    entrypoint = (ROOT / "app" / args.entrypoint).resolve()
    if not entrypoint.is_relative_to(ROOT / "app/lib") or not entrypoint.is_file() or entrypoint.suffix != ".dart":
        parser.error("entrypoint must be an existing Dart file under app/lib")
    args.entrypoint = entrypoint.relative_to(ROOT / "app").as_posix()
    if args.command != "build" and (args.build_mode != "debug" or args.ios_target != "simulator"):
        parser.error("--build-mode and --ios-target apply to build only")
    if args.command == "build" and args.ios_target == "simulator" and args.build_mode != "debug":
        parser.error("iOS simulator supports debug only; profile/release require --ios-target device (unsigned)")
    if args.device and args.command != "integration":
        parser.error("--device applies to integration only")
    if args.scope != "probe" and args.command != "native":
        parser.error("--scope applies to native only")
    if (args.driver_target or args.fixture) and (args.command != "native" or args.scope != "workbench"):
        parser.error("--driver-target/--fixture apply only to native --scope workbench")
    if (args.runtime or args.device_type) and args.command != "native":
        parser.error("--runtime/--device-type apply to native only")
    for key, prefix in (("runtime", "com.apple.CoreSimulator.SimRuntime."), ("device_type", "com.apple.CoreSimulator.SimDeviceType.")):
        value = getattr(args, key)
        if value is not None and (not value.startswith(prefix) or not re.fullmatch(r"[A-Za-z0-9.-]+", value)):
            parser.error(f"--{key.replace('_', '-')} must be a CoreSimulator ID")
    advanced_native = args.scenario or args.content_size or args.reduce_motion or args.initial_tiles != "normal" or args.cold_fixture != "none" or args.migration_fault
    if advanced_native and (args.command != "native" or args.scope != "workbench"):
        parser.error("native acceptance options require --scope workbench")
    if args.command == "native" and args.scope == "workbench":
        try:
            args.driver_target = native_workbench.driver_target(ROOT, args.driver_target)
            if args.fixture and args.driver_target == native_workbench.DRIVER:
                raise ValueError("legacy fixture requires an explicit independent driver; default smoke assumes a fresh dataset")
            if advanced_native and (args.driver_target == native_workbench.DRIVER or not args.scenario):
                raise ValueError("acceptance options require an explicit independent driver and --scenario")
            if args.migration_fault and (args.scenario != "N6" or args.fixture != native_workbench.LEGACY):
                raise ValueError("migration fault requires N6 and the genuine legacy fixture")
            if args.cold_fixture != "none" and args.scenario != "N5":
                raise ValueError("cold viewport fixture applies to N5 only")
            entry = (ROOT / "app" / native_workbench.ENTRY).resolve()
            if not entry.is_relative_to(ROOT / "app/integration_test") or not entry.is_file():
                raise ValueError("private workbench entry must exist inside app/integration_test")
        except ValueError as error:
            parser.error(str(error))
    if args.command == "integration" and (not args.device or not args.target):
        parser.error("integration requires explicit --device and --target integration_test/<file.dart>")
    if args.device and (args.device.startswith("-") or not args.device.strip() or any(c.isspace() for c in args.device)):
        parser.error("--device must be an explicit device ID without spaces")
    if args.isolated and args.command in {"gate", "local-gate", "f1-gate"}:
        parser.error("evidence gate evaluates the current workspace; --isolated does not apply")
    test_root = ROOT / ("app/integration_test" if args.command == "integration" else "app/test")
    for target in args.target:
        path = (ROOT / "app" / target).resolve()
        if not path.is_relative_to(test_root) or not path.exists() or args.command == "integration" and (not path.is_file() or path.suffix != ".dart"):
            parser.error(f"test target must exist under {test_root.relative_to(ROOT)}: {target}")
    effective_entrypoint = NATIVE_ENTRIES[args.scope] if args.command == "native" else args.entrypoint
    options = {"configuration": args.configuration, "build_mode": args.build_mode, "ios_target": args.ios_target, "entrypoint": effective_entrypoint, "tile_url": STARTUP_TILES if args.command == "native" and args.scope == "startup" else None, "device": args.device, "scope": args.scope, "driver_target": args.driver_target, "fixture": args.fixture, "targets": args.target, "isolated": args.isolated, "timeout": args.timeout, "manifest": str(args.manifest.resolve()) if args.manifest else None}
    options.update({key: getattr(args, key) for key in NATIVE_OPTION_KEYS})
    if args.command == "native":
        options["runtime"] = args.runtime or "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        options["device_type"] = args.device_type or "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
    RUNS.mkdir(exist_ok=True)
    candidate = {"source_fingerprint": checks.fingerprint(ROOT)}
    prior, prior_path, attempt = None, None, None
    mirror = "report.json"
    if args.resume:
        run_dir = args.resume.absolute()
        try:
            prior, prior_path, mirror = resume_report(run_dir)
            validation = state.validate_resume(prior, candidate)
            if prior.get("command") != args.command:
                validation["reasons"].append("resume command differs from saved command")
            if prior.get("options") != options:
                validation["reasons"].append("resume configuration/targets/stage options differ from saved run")
            if validation["reasons"]:
                raise ValueError("; ".join(validation["reasons"]))
            native_resume_ready(prior, prior_path.parent)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"Cannot resume: {error}")
            return 1
    else:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        run_dir = RUNS / f"{stamp}-{args.command}"
        run_dir.mkdir()
    report = {"command": args.command, "candidate": candidate, "options": options, "started_at": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"), "resume_count": prior.get("resume_count", 0) + 1 if prior else 0, "stages": [], "inputs": {"flutter": json.loads((ROOT / "app/.fvmrc").read_text())["flutter"], "lock_sha256": sha(ROOT / "app/pubspec.lock"), "asset_sha256": sha(ROOT / "app/assets/deliveries.csv"), "entrypoint": effective_entrypoint, "driver_target": args.driver_target, "fixture": args.fixture, "tile_url": options["tile_url"], "native_options": {key: options.get(key) for key in NATIVE_OPTION_KEYS}}}
    parent_hash = sha(prior_path) if prior_path else None
    resources = ["app-workspace" if args.command in {"quality", "test", "integration", "pub", "build", "native", "preflight"} else "repository-checks"]
    if args.command == "native":
        resources.append("device:ios-task-simulator")
    elif args.command == "integration":
        resources.append(f"device:{args.device}")
    print(f"Run: {run_dir}", flush=True)
    report["job"] = {"pid": os.getpid(), "status": "running"}
    def interrupted(signum, frame):
        raise InterruptedError(f"received signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    status = "failed"
    lease_dir = run_dir / "leases" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    try:
        with state.lease(resources, lease_dir, RUNS / "locks") as metadata:
            if args.resume:
                current_prior, current_path, _ = resume_report(run_dir)
                if current_path != prior_path or sha(current_path) != parent_hash:
                    raise ValueError("latest attempt changed before atomic lease acquisition")
                native_resume_ready(current_prior, current_path.parent)
                cleanup_previous_isolation(prior, ROOT)
            attempt = attempt_directory(run_dir)
            report["latest_attempt_report"] = (attempt / "report.json").relative_to(run_dir).as_posix()
            if prior_path:
                report["parent_attempt"] = {"path": str(prior_path), "sha256": parent_hash}
            print(f"Attempt report: {attempt / 'report.json'}", flush=True)
            report["lease"] = {key: value for key, value in metadata.items() if key != "lock_fds"}
            save_attempt(run_dir, attempt, report, mirror)
            from contextlib import nullcontext
            workspace = isolated_workspace(ROOT, candidate["source_fingerprint"], report, attempt) if args.isolated else nullcontext(ROOT)
            with workspace as execution_root:
                plan = stages(args.command, attempt, candidate["source_fingerprint"], args.manifest.resolve() if args.manifest else None, args.target, options, execution_root, metadata)
                spec = stage_spec(plan, execution_root, attempt)
                if args.resume and prior.get("stage_spec") != spec:
                    raise ValueError("resume stage plan differs from saved run")
                previous_root = Path(prior.get("execution_root", str(execution_root))) if prior else execution_root
                report.update(stage_spec=spec, source_root=str(ROOT), execution_root=str(execution_root), isolation={"requested": args.isolated, "verified_fingerprint": candidate["source_fingerprint"], "task_owned": args.isolated, "cleaned": False})
                save_attempt(run_dir, attempt, report, mirror)
                for stage_id, argv, cwd in plan:
                    old = next((item for item in prior["stages"] if item["id"] == stage_id), None) if prior else None
                    current_spec = stage_spec([(stage_id, argv, cwd)], execution_root, attempt)
                    old_spec = stage_spec([(stage_id, old["command"], old["cwd"])], previous_root, prior_path.parent) if old else None
                    retained_outputs = {"ios-build", "probe-build", "startup-build", "workbench-build", "process-restart", "startup-smoke", "workbench-smoke", "integration-tests"}
                    if args.command == "quality":
                        retained_outputs.add("flutter-tests")  # retain each attempt's original machine stream
                    if args.command not in {"gate", "local-gate", "f1-gate"} and stage_id not in {"pub", *retained_outputs} and not args.isolated and old and old["status"] == "passed" and type(old.get("exit_code")) is int and old["exit_code"] == 0 and old_spec == current_spec:
                        previous_log = Path(old["log_path"])
                        if not previous_log.is_relative_to(run_dir) or previous_log.resolve() != previous_log or not previous_log.is_file() or sha(previous_log) != old["sha256"]:
                            raise ValueError(f"{stage_id}: saved log missing or changed; completed stage cannot be reused")
                        record = {**old, "reused_from": {"report": str(prior_path), "report_sha256": parent_hash, "stage_id": stage_id}}
                        report["stages"].append(record)
                        save_attempt(run_dir, attempt, report, mirror)
                        print(f"{stage_id}: reused verified stage", flush=True)
                        continue
                    record = {"id": stage_id, "command": argv, "cwd": str(cwd), "status": "running", "log_path": str(attempt / f"{stage_id}.log")}
                    report["stages"].append(record)
                    save_attempt(run_dir, attempt, report, mirror)
                    started = time.monotonic()
                    def on_spawn(pid):
                        record["job_pid"] = pid
                        save_attempt(run_dir, attempt, report, mirror)
                    def on_finish(receipt):
                        record["completion"] = receipt
                    code, failure = None, None
                    try:
                        code = subprocess_stage(argv, cwd, Path(record["log_path"]), args.timeout, metadata["lock_fds"], on_spawn, metadata, on_finish=on_finish, cleanup_grace=cleanup_grace(stage_id))
                    except BaseException as error:
                        failure = error
                        raise
                    finally:
                        completion = record.get("completion", {})
                        observed = completion.get("returncode", code)
                        completed = type(observed) is int and observed == 0 and completion.get("wrapper_reaped") is True and completion.get("group_alive") is False and not completion.get("cleanup_errors")
                        terminal = "timed_out" if isinstance(failure, subprocess.TimeoutExpired) else "interrupted" if isinstance(failure, (KeyboardInterrupt, InterruptedError)) else "failed" if failure or not completed else "passed"
                        record.update(status=terminal, exit_code=observed, elapsed_seconds=round(time.monotonic() - started, 3))
                        if failure:
                            record["error"] = {"type": type(failure).__name__, "message": str(failure)}
                        log = Path(record["log_path"])
                        if log.is_file():
                            record.update(sha256=sha(log), log_bytes=log.stat().st_size)
                        if stage_id == "flutter-tests" and args.command == "quality":
                            machine = attempt / "flutter-tests.events.jsonl"
                            if machine.is_file() and machine.resolve() == machine:
                                record["machine_report"] = {"path": str(machine), "sha256": sha(machine), "kind": "flutter-machine-events"}
                        save_attempt(run_dir, attempt, report, mirror)
                    if record["status"] == "passed" and stage_id in {"ios-build", "probe-build", "startup-build", "workbench-build"}:
                        record["artifact"] = preserve_artifact(execution_root, attempt, stage_id, options, candidate["source_fingerprint"])
                    save_attempt(run_dir, attempt, report, mirror)
                    print(f"{stage_id}: {record['status']} ({record['elapsed_seconds']}s); {record['log_path']}", flush=True)
                    if record["status"] != "passed":
                        print(Path(record["log_path"]).read_text()[-6000:])
                        break
                else:
                    status = "passed"
    except (KeyboardInterrupt, InterruptedError):
        status = "interrupted"
        print("Interrupted; inspect recorded process cleanup and actual OS leases before resume.")
    except (OSError, ValueError, RuntimeError, state.BusyError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(f"Cannot complete run: {error}")
    finally:
        current = checks.fingerprint(ROOT)
        report["candidate_after"] = {"source_fingerprint": current}
        report.setdefault("execution_candidate_after", {"source_fingerprint": current})
        if current != candidate["source_fingerprint"] or report["execution_candidate_after"] != candidate:
            status = "stale"
            print("Source or isolated execution source changed during run; retain diagnostics and rerun the final candidate.")
        report["job"]["status"] = status
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["lease"] = json.loads((lease_dir / "lease.json").read_text()) if (lease_dir / "lease.json").exists() else {}
        if report.get("isolation", {}).get("requested"):
            report["isolation"]["cleaned"] = not Path(report["execution_root"]).exists()
        if attempt is not None:
            save_attempt(run_dir, attempt, report, mirror)
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
