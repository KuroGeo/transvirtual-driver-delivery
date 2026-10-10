import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from harness.state import BusyError, lease, validate_resume


REPO = Path(__file__).resolve().parents[2]
HOLDER = """
import json, sys, time
from harness.state import lease
with lease([sys.argv[1]], sys.argv[2], sys.argv[3]) as record:
    print(json.dumps(record), flush=True)
    time.sleep(60)
"""
PARENT_WITH_WRAPPER = """
import json, subprocess, sys, time
from harness.state import lease
with lease([sys.argv[1]], sys.argv[2], sys.argv[3]) as record:
    wrapper = subprocess.Popen(
        [sys.executable, '-c', 'import time; time.sleep(60)'],
        pass_fds=record['lock_fds'], start_new_session=True,
    )
    print(json.dumps({**record, 'job_pid': wrapper.pid}), flush=True)
    time.sleep(60)
"""

# A separate task worker owns Linux's subreaper flag. It reaps only the known
# orphan fixture PID, never subprocess_stage's wrapper; no host setting changes.
EXITED_WRAPPER_WORKER = r'''
import ctypes, json, os, signal, subprocess, sys, threading, time
from pathlib import Path
from harness.run import subprocess_stage
mode, directory = sys.argv[1], Path(sys.argv[2])
ready, done = directory / "orphan-ready.json", directory / "orphan-done.txt"
if sys.platform.startswith("linux"):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER, this worker only
        raise OSError(ctypes.get_errno(), "task subreaper setup failed")
child_source = r"""
import json, os, signal, sys, time
from pathlib import Path
mode, ready, done = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
if mode == "term":
    def stop(*args):
        done.write_text("term")
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
elif mode == "ignore":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
ready.write_text(json.dumps({"pid": os.getpid(), "group": os.getpgrp()}))
if mode in ("natural", "zombie"):
    # Begin the tail only after the actual wrapper PID has disappeared.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            os.kill(os.getpgrp(), 0)
        except ProcessLookupError:
            break
        time.sleep(0.01)
    time.sleep(0.25)
    done.write_text(mode)
else:
    time.sleep(60)
"""
parent_source = """
import subprocess, sys, time
from pathlib import Path
child = subprocess.Popen([sys.executable, '-u', '-c', sys.argv[1], *sys.argv[2:]])
ready = Path(sys.argv[3])
deadline = time.monotonic() + 5
while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
    time.sleep(0.01)
if not ready.exists():
    raise RuntimeError('owned orphan did not become ready')
print('zero-wrapper-parent-ready', flush=True)
"""
reaped = {}
allow_reap = threading.Event()
if mode != "zombie":
    allow_reap.set()
def reap_fixture():
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            identity = json.loads(ready.read_text())
        except (FileNotFoundError, ValueError):
            time.sleep(0.01)
            continue
        pid = identity["pid"]
        if not allow_reap.is_set():
            time.sleep(0.01)
            continue
        try:
            found, status = os.waitpid(pid, os.WNOHANG)
            if found == pid:
                reaped.update(identity, exited=True, wait_status=status)
                return
        except ChildProcessError:
            # macOS launchd adopts the orphan. Observe actual disappearance;
            # Linux waits until this worker becomes its reaping parent.
            if not sys.platform.startswith("linux"):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    reaped.update(identity, exited=True)
                    return
        time.sleep(0.01)
thread = threading.Thread(target=reap_fixture, daemon=True)
thread.start()
receipt, spawned, outcome = [], [], {}
sibling = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           start_new_session=True)
try:
    outcome["code"] = subprocess_stage(
        [sys.executable, '-u', '-c', parent_source, child_source, mode, str(ready), str(done)],
        Path.cwd(), directory / 'stage.log', 10, [], spawned.append,
        on_finish=receipt.append, cleanup_grace=1)
except BaseException as error:
    outcome["error"] = {"type": type(error).__name__, "message": str(error)}
finally:
    outcome["unrelated_task_group_survived"] = sibling.poll() is None
    # Cleanup is limited to this fixture's independently recorded Popen group,
    # so the old implementation fails the test without leaving a long orphan.
    for group in spawned:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    allow_reap.set()
    thread.join(timeout=5)
    sibling.terminate()
    sibling.wait(timeout=5)
outcome.update(receipt=receipt, fixture=reaped,
               done=done.read_text() if done.exists() else None,
               log=(directory / 'stage.log').read_text())
print(json.dumps(outcome))
'''


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.locks = self.root / "locks"
        self.candidate = {"source_fingerprint": "candidate-a"}
        self.report = {
            "candidate": self.candidate,
            "job": {"pid": None, "status": "interrupted"},
            "lease": {"resources": ["device:test"], "lock_root": str(self.locks)},
            "agent_status": "complete",
        }

    def tearDown(self):
        self.temp.cleanup()

    def start_holder(self, resource="device:test", code=HOLDER):
        child = subprocess.Popen(
            [sys.executable, "-u", "-c", code, resource, str(self.root / "child"), str(self.locks)],
            cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop_holder, child)
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=5):
                self.stop_holder(child)
                self.fail("lock holder did not become ready within 5 seconds")
            line = child.stdout.readline()
        if not line:
            self.fail(f"lock holder failed: {child.stderr.read()}")
        record = json.loads(line)
        self.assertEqual(record["owner_pid"], child.pid)
        return child, record

    @staticmethod
    def stop_holder(child):
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
        if child.stdout:
            child.stdout.close()
        if child.stderr:
            child.stderr.close()

    def test_normal_exit_releases_resource_and_preserves_diagnostics(self):
        with lease(["device:test", "device:test"], self.root / "one", self.locks) as record:
            self.assertEqual(record["resources"], ["device:test"])
            saved = json.loads((self.root / "one/lease.json").read_text())
            self.assertEqual(saved["status"], "active")
            self.assertNotIn("lock_fds", saved)
            self.assertEqual(len(record["lock_fds"]), 1)
            with self.assertRaises(BusyError) as conflict:
                with lease(["device:test"], self.root / "two", self.locks):
                    self.fail("entered a conflicting lease")
            self.assertEqual(conflict.exception.owner["owner_pid"], os.getpid())
        saved = json.loads((self.root / "one/lease.json").read_text())
        self.assertEqual(saved["status"], "released")
        with lease(["device:test"], self.root / "two", self.locks):
            pass

    def test_exception_in_body_releases_lock(self):
        with self.assertRaisesRegex(RuntimeError, "intentional failure"):
            with lease(["device:test"], self.root / "one", self.locks):
                raise RuntimeError("intentional failure")
        with lease(["device:test"], self.root / "two", self.locks):
            pass

    def test_graceful_parent_close_preserves_descendant_inherited_lock(self):
        with lease(["device:test"], self.root / "one", self.locks) as record:
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], pass_fds=record["lock_fds"])
            self.addCleanup(self.stop_holder, child)
        self.assertIsNone(child.poll())
        self.assertEqual(json.loads((self.root / "one/lease.json").read_text())["status"], "released")
        self.report["stages"] = [{"id": "descendant", "status": "running", "job_pid": child.pid}]
        blocked = validate_resume(self.report, self.candidate)
        self.assertTrue(any("still locked" in reason for reason in blocked["reasons"]), blocked)
        with self.assertRaises(BusyError):
            with lease(["device:test"], self.root / "contender", self.locks):
                self.fail("parent close must not unlock the inherited descriptor")
        child.terminate()
        child.wait(timeout=5)
        self.assertTrue(validate_resume(self.report, self.candidate)["allowed"])
        with lease(["device:test"], self.root / "after-child", self.locks):
            pass

    def test_real_timeout_preserves_completion_callback_and_forced_reap(self):
        from harness.run import subprocess_stage
        receipt = []
        log = self.root / "timeout.log"
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess_stage([sys.executable, "-u", "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"],
                             REPO, log, 1, [], lambda pid: None, on_finish=receipt.append, cleanup_grace=0.2)
        self.assertEqual(len(receipt), 1)
        self.assertTrue(receipt[0]["spawned"])
        self.assertTrue(receipt[0]["wrapper_reaped"])
        self.assertEqual(receipt[0]["returncode"], -signal.SIGKILL)
        self.assertTrue(receipt[0]["term_sent"])
        self.assertTrue(receipt[0]["kill_sent"])
        self.assertEqual(receipt[0]["cause"], "TimeoutExpired")
        self.assertIn("ready", log.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(receipt[0]["wrapper_pid"], 0)

    def test_native_grace_allows_cooperative_cleanup_longer_than_generic_five_seconds(self):
        from harness.run import cleanup_grace, subprocess_stage
        receipt = []
        code = "import signal,time,sys\ndef stop(*args):\n time.sleep(5.2)\n sys.exit(0)\nsignal.signal(signal.SIGTERM,stop)\nprint('ready',flush=True)\ntime.sleep(60)"
        with self.assertRaises(subprocess.TimeoutExpired):
            subprocess_stage([sys.executable, "-u", "-c", code], REPO, self.root / "cooperative.log", 1, [], lambda pid: None,
                             on_finish=receipt.append, cleanup_grace=cleanup_grace("workbench-smoke"))
        self.assertEqual(receipt[0]["cleanup_grace_seconds"], 150)
        self.assertGreater(receipt[0]["cleanup_elapsed_seconds"], 5)
        self.assertEqual(receipt[0]["returncode"], 0)
        self.assertTrue(receipt[0]["wrapper_reaped"])
        self.assertFalse(receipt[0].get("kill_sent", False))
        self.assertFalse(receipt[0]["group_alive"])

    def run_exited_wrapper_worker(self, mode):
        directory = self.root / mode
        directory.mkdir()
        result = subprocess.run([sys.executable, "-u", "-c", EXITED_WRAPPER_WORKER, mode, str(directory)],
                                cwd=REPO, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def exited_wrapper_case(self, mode):
        evidence = self.run_exited_wrapper_worker(mode)
        self.assertNotIn("error", evidence, evidence)
        self.assertEqual(evidence.get("code"), 0)
        self.assertEqual(len(evidence["receipt"]), 1)
        receipt = evidence["receipt"][0]
        self.assertEqual(receipt["returncode"], 0)
        self.assertTrue(receipt["wrapper_reaped"])
        self.assertTrue(receipt["group_alive_after_wrapper_exit"])
        self.assertFalse(receipt["group_alive"])
        self.assertFalse(receipt["cleanup_errors"])
        self.assertLess(receipt["cleanup_elapsed_seconds"], 1.5)
        self.assertTrue(evidence["fixture"].get("exited"), evidence)
        self.assertTrue(evidence["unrelated_task_group_survived"], evidence)
        self.assertEqual(evidence["fixture"]["group"], receipt["process_group"])
        self.assertIn("zero-wrapper-parent-ready", evidence["log"])
        return receipt, evidence

    def test_zero_wrapper_waits_for_actual_delayed_descendant_exit(self):
        receipt, evidence = self.exited_wrapper_case("natural")
        self.assertGreater(receipt["natural_quiet_wait_seconds"], 0)
        self.assertFalse(receipt.get("term_sent", False))
        self.assertFalse(receipt.get("kill_sent", False))
        self.assertEqual(evidence["done"], "natural")

    def test_zero_wrapper_terminates_only_its_actual_long_descendant(self):
        receipt, evidence = self.exited_wrapper_case("term")
        self.assertTrue(receipt["term_sent"])
        self.assertFalse(receipt.get("kill_sent", False))
        self.assertEqual(evidence["done"], "term")

    def test_zero_wrapper_forces_ignored_term_and_verifies_actual_group_exit(self):
        receipt, evidence = self.exited_wrapper_case("ignore")
        self.assertTrue(receipt["term_sent"])
        self.assertTrue(receipt["kill_sent"])
        self.assertIsNone(evidence["done"])
        if "wait_status" in evidence["fixture"]:
            self.assertEqual(os.waitstatus_to_exitcode(evidence["fixture"]["wait_status"]), -signal.SIGKILL)

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux task subreaper observes an actual unreaped orphan")
    def test_zero_wrapper_does_not_claim_unreaped_zombie_group_is_clean(self):
        evidence = self.run_exited_wrapper_worker("zombie")
        self.assertEqual(evidence["error"]["type"], "RuntimeError")
        receipt = evidence["receipt"][0]
        self.assertEqual(receipt["returncode"], 0)
        self.assertTrue(receipt["wrapper_reaped"])
        self.assertTrue(receipt["group_alive"])
        self.assertTrue(receipt["term_sent"])
        self.assertTrue(receipt["kill_sent"])
        self.assertLess(receipt["cleanup_elapsed_seconds"], 1.5)
        self.assertTrue(evidence["fixture"]["exited"])
        self.assertEqual(os.waitstatus_to_exitcode(evidence["fixture"]["wait_status"]), 0)
        self.assertTrue(evidence["unrelated_task_group_survived"])

    def test_spawn_record_failure_reaps_the_started_stage(self):
        with patch.object(sys, "path", [str(REPO / "harness"), *sys.path]):
            from harness.run import subprocess_stage
        for error in (InterruptedError("cancel while recording PID"), OSError("report write failed")):
            with self.subTest(error=type(error).__name__):
                started = []
                def on_spawn(pid):
                    started.append(pid)
                    raise error
                def cleanup():
                    for pid in started:
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        try:
                            os.waitpid(pid, 0)
                        except ChildProcessError:
                            pass
                self.addCleanup(cleanup)
                with self.assertRaises(type(error)):
                    subprocess_stage([sys.executable, "-c", "import time; time.sleep(60)"], REPO, self.root / (type(error).__name__ + "-spawn.log"), 10, [], on_spawn)
                self.assertEqual(len(started), 1)
                with self.assertRaises(ProcessLookupError):
                    os.kill(started[0], 0)

    def test_partial_acquisition_conflict_releases_earlier_resources(self):
        child, _ = self.start_holder("z:last")
        with self.assertRaises(BusyError):
            with lease(["a:first", "z:last"], self.root / "one", self.locks):
                pass
        with lease(["a:first"], self.root / "two", self.locks):
            pass
        self.assertIsNone(child.poll())

    def test_real_process_kill_releases_lease_and_resume_rechecks_candidate(self):
        child, record = self.start_holder()
        self.report["job"] = {"pid": child.pid, "status": "running"}
        self.report["lease"] = record
        with self.assertRaises(BusyError) as conflict:
            with lease(["device:test"], self.root / "contender", self.locks):
                pass
        blocked = validate_resume(self.report, self.candidate)
        self.assertFalse(blocked["allowed"])
        self.assertTrue(any("still alive" in reason for reason in blocked["reasons"]))
        self.assertTrue(any("still locked" in reason for reason in blocked["reasons"]))
        print(f"DRILL before-kill: pid={child.pid}, conflict={conflict.exception}, resume={blocked}", flush=True)
        os.kill(child.pid, signal.SIGKILL)
        exit_code = child.wait(timeout=5)
        self.assertEqual(exit_code, -signal.SIGKILL)
        stale_metadata = json.loads((self.root / "child/lease.json").read_text())
        self.assertEqual(stale_metadata["status"], "active")
        resumed = validate_resume(self.report, self.candidate)
        self.assertTrue(resumed["allowed"], resumed)
        with lease(["device:test"], self.root / "resumed", self.locks):
            pass
        changed = validate_resume(self.report, {"source_fingerprint": "candidate-b"})
        self.assertFalse(changed["allowed"])
        print(f"DRILL after-kill: exit_code={exit_code}, stale_metadata=active, resume={resumed}, changed_source={changed}", flush=True)

    def test_killed_parent_does_not_release_wrapper_inherited_lease(self):
        parent, record = self.start_holder(code=PARENT_WITH_WRAPPER)
        wrapper_pid = record["job_pid"]
        def stop_wrapper():
            try:
                os.killpg(wrapper_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.addCleanup(stop_wrapper)
        os.kill(parent.pid, signal.SIGKILL)
        parent_exit = parent.wait(timeout=5)
        self.assertEqual(parent_exit, -signal.SIGKILL)
        self.report["job"] = {"pid": parent.pid, "status": "running"}
        self.report["lease"] = record
        self.report["stages"] = [{"id": "long-job", "status": "running", "job_pid": wrapper_pid}]
        validation = validate_resume(self.report, self.candidate)
        self.assertFalse(validation["allowed"])
        self.assertTrue(any("still locked" in reason for reason in validation["reasons"]), validation)
        self.assertTrue(any("job_pid" in reason and "still alive" in reason for reason in validation["reasons"]), validation)
        with self.assertRaises(BusyError):
            with lease(["device:test"], self.root / "contender", self.locks):
                pass
        print(f"DRILL inherited-lease: parent_exit={parent_exit}, wrapper_pid={wrapper_pid}, resume={validation}", flush=True)
        stop_wrapper()
        deadline = time.monotonic() + 5
        while True:
            try:
                with lease(["device:test"], self.root / "after-wrapper", self.locks):
                    break
            except BusyError:
                if time.monotonic() > deadline:
                    self.fail("wrapper did not release inherited lock after termination")
                time.sleep(0.02)
        print("DRILL inherited-lease: wrapper terminated, OS lock reacquired", flush=True)

    def test_agent_complete_does_not_override_live_job(self):
        self.report["job"] = {"pid": os.getpid(), "status": "completed"}
        result = validate_resume(self.report, self.candidate)
        self.assertFalse(result["allowed"])
        self.assertIn("still alive", result["reasons"][0])

    def test_released_job_does_not_override_held_os_lock(self):
        with lease(["device:test"], self.root / "one", self.locks):
            result = validate_resume(self.report, self.candidate)
            self.assertFalse(result["allowed"])
            self.assertTrue(any("still locked" in reason for reason in result["reasons"]))

    def test_resume_missing_fingerprint_process_identity_and_lock_root(self):
        for edit, reason in (
            (lambda r: r.update(candidate={}), "source_fingerprint"),
            (lambda r: r.update(job={"status": "running", "pid": None}), "job.pid"),
            (lambda r: r.update(job={"pid": -1, "status": "interrupted"}), "job.pid"),
            (lambda r: r.update(job={}), "job.status"),
            (lambda r: r.update(lease={"resources": ["device:test"]}), "lock_root"),
        ):
            with self.subTest(reason=reason):
                report = json.loads(json.dumps(self.report))
                edit(report)
                result = validate_resume(report, self.candidate)
                self.assertFalse(result["allowed"])
                self.assertTrue(any(reason in value for value in result["reasons"]), result)

    def test_resume_rejects_malformed_nested_shapes_and_live_recorded_group(self):
        for edit in (lambda r: r.update(job=[]), lambda r: r.update(stages={}),
                     lambda r: r.update(stages=[None]), lambda r: r.update(stages=[{"completion": []}]),
                     lambda r: r.update(lease=[]), lambda r: r.update(lease={"resources": [1]})):
            report = json.loads(json.dumps(self.report))
            edit(report)
            self.assertFalse(validate_resume(report, self.candidate)["allowed"])
        self.report["stages"] = [{"id": "unfinished", "status": "failed", "job_pid": 123456789,
                                  "completion": {"wrapper_reaped": True, "process_group": 123456789}}]
        with patch("harness.state.os.killpg", return_value=None):
            result = validate_resume(self.report, self.candidate)
        self.assertTrue(any("process group" in reason for reason in result["reasons"]), result)


if __name__ == "__main__":
    unittest.main()
