"""Background-only, task-owned iOS simulator process-restart probe.

Never opens Simulator.app, clears an existing device, or uses a user's device.
This demonstrates SQLite/native process recovery with a fake test transport;
it is not full product acceptance or physical-device performance evidence.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import time

try:
    from . import run as runner
    from . import native_workbench
except ImportError:
    import run as runner
    import native_workbench

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--configuration", choices=["demo", "local-client"], default="local-client")
    parser.add_argument("--scope", choices=["probe", "startup", "workbench"], default="probe")
    parser.add_argument("--driver-target", help="workbench only: existing private integration_test Dart driver")
    parser.add_argument("--fixture", choices=[native_workbench.LEGACY], help="workbench only: absent-file genuine v1 prelaunch fixture")
    parser.add_argument("--lease-context", required=True, help="Inherited Harness flock context; use harness/run.py native")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-26-4")
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    args = parser.parse_args()
    try:
        descriptors = runner.require_lease_context(json.loads(args.lease_context), ROOT, ("app-workspace", "device:ios-task-simulator"))
        if runner.checks.fingerprint(ROOT) != args.candidate:
            raise ValueError("native candidate does not match the leased source snapshot")
        if (args.driver_target or args.fixture) and args.scope != "workbench":
            raise ValueError("driver/fixture applies only to workbench scope")
        if args.scope == "workbench":
            args.driver_target = native_workbench.driver_target(ROOT, args.driver_target)
            if args.fixture and args.driver_target == native_workbench.DRIVER:
                raise ValueError("legacy fixture requires an explicit independent driver")
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    if args.scope == "workbench":
        def interrupted_workbench(signum, frame):
            raise InterruptedError(f"received signal {signum}")
        signal.signal(signal.SIGTERM, interrupted_workbench)
        return native_workbench.execute(args, ROOT, descriptors)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    application = ROOT / "app/build/ios/iphonesimulator/Runner.app"
    bundle = plistlib.loads((application / "Info.plist").read_bytes())["CFBundleIdentifier"]
    report = {"candidate": args.candidate, "platform": "ios", "device_type": "simulator", "build_mode": "debug", "configuration": args.configuration, "transport": "fake-test-only" if args.scope == "probe" else "configured-formal-entry", "scope": "reliability-probe" if args.scope == "probe" else "startup-smoke", "status": "failed", "process_restart": False, "commands": [], "phases": []}
    report["tile_source"] = "task-loopback-unavailable" if args.scope == "startup" else "not_applicable"
    report["entrypoint"] = runner.NATIVE_ENTRIES[args.scope]
    device = None
    def interrupted(signum, frame):
        raise InterruptedError(f"received signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)

    def command(*argv, timeout=120):
        started = time.monotonic()
        result = subprocess.run(["xcrun", "simctl", *argv], text=True, capture_output=True, timeout=timeout)
        report["commands"].append({"argv": ["xcrun", "simctl", *argv], "exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr, "elapsed_seconds": round(time.monotonic() - started, 3), "at": datetime.now(timezone.utc).isoformat()})
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"simctl {' '.join(argv)}: {result.stderr or result.stdout}")
        return result.stdout.strip()

    try:
        device = command("create", "OceanDelivery-Harness", args.device_type, args.runtime)
        report["device"] = {"udid": device, "runtime": args.runtime, "type": args.device_type, "task_owned": True}
        command("boot", device)
        command("bootstatus", device, "-b", timeout=240)
        command("install", device, str(application))
        container = Path(command("get_app_container", device, bundle, "data"))
        report["data_container"] = str(container)
        if args.scope == "startup":
            launch = command("launch", f"--stdout={output / 'startup.stdout.log'}", f"--stderr={output / 'startup.stderr.log'}", device, bundle)
            match = re.search(r": (\d+)\s*$", launch)
            if not match:
                raise RuntimeError(f"No native process ID in startup receipt: {launch}")
            pid = int(match[1])
            # Allow initialization to settle; this is deliberately only an OS
            # launch/first-screen smoke, not a product-flow assertion.
            time.sleep(2)
            os.kill(pid, 0)
            screenshot = output / "startup.png"
            command("io", device, "screenshot", str(screenshot))
            report.update(status="passed", process_ids=[pid], screenshot={"path": "startup.png", "sha256": hashlib.sha256(screenshot.read_bytes()).hexdigest()})
            command("terminate", device, bundle)
        else:
            pids = []
            for number, phase in enumerate(("saved", "recovered", "confirmed"), 1):
                launch = command("launch", f"--stdout={output / f'process-{number}.stdout.log'}", f"--stderr={output / f'process-{number}.stderr.log'}", device, bundle)
                match = re.search(r": (\d+)\s*$", launch)
                if not match:
                    raise RuntimeError(f"No native process ID in launch receipt: {launch}")
                pid = int(match[1])
                pids.append(pid)
                deadline = time.monotonic() + 90
                value, raw = None, None
                while time.monotonic() < deadline:
                    paths = list(container.rglob("harness-probe.json"))
                    if paths:
                        raw = paths[0]
                        value = json.loads(raw.read_text())
                        if value.get("processId") == pid and value.get("phase") != "starting":
                            break
                    time.sleep(0.25)
                if not value or value.get("processId") != pid:
                    raise RuntimeError(f"No report from process {pid}; inspect process-{number}.stderr.log")
                shutil.copyfile(raw, output / f"{phase}.json")
                report["phases"].append({"phase": phase, "pid": pid, "path": f"{phase}.json", "sha256": hashlib.sha256(raw.read_bytes()).hexdigest()})
                if not value.get("pass") or value.get("phase") != phase:
                    raise RuntimeError(f"Probe {phase} failed: {value.get('error', value)}")
                if number == 1:
                    original_ids = value["operationIds"]
                    if value["queueCount"] != 2:
                        raise RuntimeError("Saved phase did not persist two updates")
                else:
                    if value["operationIds"] != original_ids or value["queueCount"] != 0:
                        raise RuntimeError("Reopened identity/ack queue does not match the saved phase")
                if phase == "recovered" and value["beforeQueueCount"] != 2:
                    raise RuntimeError("Restart did not retain both unacknowledged updates")
                if phase == "confirmed" and value["sentOperationIds"]:
                    raise RuntimeError("Already confirmed operations were sent again")
                command("terminate", device, bundle)
            if len(set(pids)) != 3:
                raise RuntimeError("Expected three distinct OS process IDs")
            for database in container.rglob("ocean_delivery_harness.sqlite*"):
                shutil.copyfile(database, output / database.name)
            report.update(status="passed", process_restart=True, process_ids=pids, original_operation_ids=original_ids)
    except (OSError, RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError, InterruptedError, KeyboardInterrupt) as error:
        report["error"] = str(error)
        report["status"] = "failed"
    finally:
        if device:
            # Only the UDID returned by our own create is eligible for cleanup.
            try:
                command("shutdown", device)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                report["shutdown_error"] = str(error)
            try:
                command("delete", device)
                report["device_cleaned"] = True
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                report["cleanup_error"] = str(error)
                report["status"] = "failed"
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "commands"}, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
