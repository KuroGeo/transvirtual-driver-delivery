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
                    subprocess_stage([sys.executable, "-c", "import time; time.sleep(60)"], REPO, self.root / "spawn.log", 10, [], on_spawn)
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


if __name__ == "__main__":
    unittest.main()
