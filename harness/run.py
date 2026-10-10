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
    from . import checks, gate, state, native_workbench
except ImportError:  # CLI script entrypoint
    import checks
    import gate
    import state
    import native_workbench

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
               ("flutter-tests", ["flutter", "test", "--no-pub", "--reporter", "expanded", define], root / "app")]
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
    if command in {"gate", "local-gate"}:
        private = "_gate" if command == "gate" else "_local_gate"
        stage_id = "production-gate" if command == "gate" else "local-evidence-gate"
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
def isolated_workspace(source_root, fingerprint, report=None):
    """Copy only source, verify it, and delete only this task's temporary root."""
    source_root = Path(source_root).resolve()
    with tempfile.TemporaryDirectory(prefix="ocean-harness-") as directory:
        destination = Path(directory).resolve()
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
                    or relative.as_posix() in checks.GENERATED - {"harness/project/work.json"}):
                continue
            if not path.resolve().is_relative_to(source_root):
                raise ValueError(f"source snapshot refuses external symlink: {relative}")
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        if checks.fingerprint(destination) != fingerprint or checks.fingerprint(source_root) != fingerprint:
            raise ValueError("source changed while creating isolated snapshot")
        save(destination / ".harness-isolation.json", {"source_root": str(source_root), "source_fingerprint": fingerprint})
        try:
            yield destination
        finally:
            if report is not None:
                report["execution_candidate_after"] = {"source_fingerprint": checks.fingerprint(destination)}


def stage_spec(stages_list, root, run_dir):
    def normalized(value):
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


def subprocess_stage(argv, cwd, log, timeout, lock_fds, on_spawn, lease_context=None):
    env = os.environ.copy()
    for key in ("NO_PROXY", "no_proxy"):
        current = env.get(key, "")
        env[key] = ",".join(filter(None, [current, "localhost", "127.0.0.1", "::1"]))
    with log.open("w") as output:
        wrapper = [sys.executable, str(ROOT / "harness/run.py"), "_stage", "--stage-argv", json.dumps(argv)]
        if lease_context:
            wrapper += ["--lease-context", json.dumps(lease_context)]
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
    parser.add_argument("command", choices=["preflight", "check", "pub", "quality", "test", "integration", "build", "native", "gate", "local-gate", "_check", "_sdk", "_gate", "_local_gate", "_stage"])
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
    if args.command in {"_gate", "_local_gate"}:
        if not args.manifest:
            parser.error("--manifest is required for evidence gate")
        try:
            manifest = read_manifest(args.manifest)
            local = args.command == "_local_gate"
            evaluate = gate.evaluate_local if local else gate.evaluate
            result = evaluate(manifest, checks.fingerprint(), args.manifest.resolve().parent)
        except (OSError, ValueError, TypeError, UnicodeError, RecursionError) as error:
            result = {"reasons": [str(error)], "local_allowed": False, "publish_allowed": False} if args.command == "_local_gate" else {"allowed": False, "reasons": [str(error)]}
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return int(not result["local_allowed" if args.command == "_local_gate" else "allowed"])
    if args.command in {"gate", "local-gate"} and not args.manifest:
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
    if args.isolated and args.command in {"gate", "local-gate"}:
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
    if args.resume:
        run_dir = args.resume.resolve()
        report = json.loads((run_dir / "report.json").read_text())
        validation = state.validate_resume(report, candidate)
        if report.get("command") != args.command:
            validation["reasons"].append("resume command differs from saved command")
        if report.get("options") != options:
            validation["reasons"].append("resume configuration/targets/stage options differ from saved run")
        if validation["reasons"]:
            print(json.dumps(validation, ensure_ascii=False, indent=2))
            return 1
        report["resume_count"] = report.get("resume_count", 0) + 1
    else:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        run_dir = RUNS / f"{stamp}-{args.command}"
        run_dir.mkdir()
        report = {"command": args.command, "candidate": candidate, "options": options, "started_at": stamp, "stages": [], "inputs": {"flutter": json.loads((ROOT / "app/.fvmrc").read_text())["flutter"], "lock_sha256": sha(ROOT / "app/pubspec.lock"), "asset_sha256": sha(ROOT / "app/assets/deliveries.csv"), "entrypoint": effective_entrypoint, "driver_target": args.driver_target, "fixture": args.fixture, "tile_url": options["tile_url"], "native_options": {key: options.get(key) for key in NATIVE_OPTION_KEYS}}}
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
    try:
        with state.lease(resources, run_dir, RUNS / "locks") as metadata:
            if args.resume:
                cleanup_previous_isolation(report, ROOT)
            report["lease"] = {key: value for key, value in metadata.items() if key != "lock_fds"}
            save(run_dir / "report.json", report)
            from contextlib import nullcontext
            workspace = isolated_workspace(ROOT, candidate["source_fingerprint"], report) if args.isolated else nullcontext(ROOT)
            with workspace as execution_root:
                plan = stages(args.command, run_dir, candidate["source_fingerprint"], args.manifest.resolve() if args.manifest else None, args.target, options, execution_root, metadata)
                spec = stage_spec(plan, execution_root, run_dir)
                if args.resume and report.get("stage_spec") != spec:
                    raise ValueError("resume stage plan differs from saved run")
                previous_root = Path(report.get("execution_root", str(execution_root)))
                report.update(stage_spec=spec, source_root=str(ROOT), execution_root=str(execution_root), isolation={"requested": args.isolated, "verified_fingerprint": candidate["source_fingerprint"], "task_owned": args.isolated, "cleaned": False})
                save(run_dir / "report.json", report)
                for stage_id, argv, cwd in plan:
                    prior = next((item for item in report["stages"] if item["id"] == stage_id), None)
                    current_spec = stage_spec([(stage_id, argv, cwd)], execution_root, run_dir)
                    old_spec = stage_spec([(stage_id, prior["command"], prior["cwd"])], previous_root, run_dir) if prior else None
                    if args.command not in {"gate", "local-gate"} and stage_id != "pub" and not (args.isolated and args.command in {"build", "native", "integration"}) and prior and prior["status"] == "passed" and old_spec == current_spec:
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
                    code = subprocess_stage(argv, cwd, Path(record["log_path"]), args.timeout, metadata["lock_fds"], on_spawn, metadata)
                    record.update(status="passed" if code == 0 else "failed", exit_code=code, elapsed_seconds=round(time.monotonic() - started, 3), sha256=sha(record["log_path"]))
                    if code == 0 and stage_id in {"ios-build", "probe-build", "startup-build", "workbench-build"}:
                        record["artifact"] = preserve_artifact(execution_root, run_dir, stage_id, options, candidate["source_fingerprint"])
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
        current = checks.fingerprint(ROOT)
        report["candidate_after"] = {"source_fingerprint": current}
        report.setdefault("execution_candidate_after", {"source_fingerprint": current})
        if current != candidate["source_fingerprint"] or report["execution_candidate_after"] != candidate:
            status = "stale"
            print("Source or isolated execution source changed during run; retain diagnostics and rerun the final candidate.")
        report["job"]["status"] = status
        report["finished_at"] = datetime.now(timezone.utc).isoformat()
        report["lease"] = json.loads((run_dir / "lease.json").read_text()) if (run_dir / "lease.json").exists() else {}
        if report.get("isolation", {}).get("requested"):
            report["isolation"]["cleaned"] = not Path(report["execution_root"]).exists()
        save(run_dir / "report.json", report)
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
