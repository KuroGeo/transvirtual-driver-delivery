"""Small OS-backed resource leases and interrupted-run validation.

Lease files are diagnostics; flock is the authority. A killed process can leave
an ``active`` JSON file while the kernel has already released all its locks.
``job`` describes a local process, never the state of a model agent.
"""

from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import tempfile


class BusyError(RuntimeError):
    """Another process currently owns a resource's OS lock."""

    def __init__(self, resource, owner=None):
        self.resource = resource
        self.owner = owner or {}
        super().__init__(
            f"resource {resource!r} is busy; owner_pid={self.owner.get('owner_pid', 'unknown')} "
            f"run_dir={self.owner.get('run_dir', 'unknown')}"
        )


def _lock_path(lock_root, resource):
    name = hashlib.sha256(resource.encode("utf-8")).hexdigest()
    return Path(lock_root) / f"{name}.lock"


def _read_owner(handle):
    try:
        handle.seek(0)
        return json.load(handle)
    except (ValueError, OSError):
        return {}


def _write_json(path, value):
    """Replace run metadata atomically, without replacing lock-file inodes."""
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        json.dump(value, out, sort_keys=True, indent=2)
        out.write("\n")
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def lease(resources, run_dir, lock_root):
    """Hold exclusive nonblocking locks until exit or process death.

    Resources are acquired in sorted order. A conflict releases any locks
    acquired earlier in the same call; no lock is deleted during cleanup.
    Yielded lock_fds are ephemeral descriptors for subprocess pass_fds. They
    are deliberately excluded from the on-disk lease metadata.
    """
    resources = sorted(set(resources))
    if not resources or any(not isinstance(item, str) or not item for item in resources):
        raise ValueError("lease requires nonempty resource names")
    run_dir, lock_root = Path(run_dir).resolve(), Path(lock_root).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    lock_root.mkdir(parents=True, exist_ok=True)
    metadata = {
        "owner_pid": os.getpid(),
        "run_dir": str(run_dir),
        "lock_root": str(lock_root),
        "resources": resources,
        "acquired_at": datetime.now(timezone.utc).isoformat(),
        "status": "active",
    }
    acquired = []
    try:
        for resource in resources:
            handle = _lock_path(lock_root, resource).open("a+", encoding="utf-8")
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                owner = _read_owner(handle)
                handle.close()
                raise BusyError(resource, owner) from None
            acquired.append(handle)
            handle.seek(0)
            handle.truncate()
            json.dump({**metadata, "resource": resource}, handle, sort_keys=True)
            handle.flush()
        _write_json(run_dir / "lease.json", metadata)
        yield {**metadata, "lock_fds": [handle.fileno() for handle in acquired]}
    finally:
        if len(acquired) == len(resources):
            metadata["status"] = "released"
            metadata["released_at"] = datetime.now(timezone.utc).isoformat()
            try:
                _write_json(run_dir / "lease.json", metadata)
            finally:
                for handle in reversed(acquired):
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                    handle.close()
        else:
            for handle in reversed(acquired):
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
                handle.close()


def _fingerprint(candidate):
    return candidate.get("source_fingerprint") if isinstance(candidate, dict) else candidate


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def validate_resume(report, candidate):
    """Check saved work before reusing stages, then let the caller reacquire.

    ``report`` contains candidate.source_fingerprint, job.{pid,status}, and
    lease.{resources,lock_root}. Agent status is deliberately not consulted.
    This check is advisory until the caller acquires its own lease; the lease
    acquisition itself is the atomic protection against concurrent execution.
    """
    reasons = []
    previous, current = _fingerprint(report.get("candidate")), _fingerprint(candidate)
    if not previous or not current:
        reasons.append("candidate.source_fingerprint is missing; cannot reuse completed stages")
    elif previous != current:
        reasons.append("candidate.source_fingerprint changed; rerun completed stages for this source")
    job = report.get("job", {})
    pid = job.get("pid")
    if pid is not None:
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            reasons.append("job.pid must be a positive process ID or null")
        elif _pid_alive(pid):
            reasons.append(f"job.pid {pid} is still alive; stop/reap the prior job before resume")
    elif job.get("status") == "running":
        reasons.append("job is running but job.pid is missing; process exit cannot be verified")
    if not job.get("status"):
        reasons.append("job.status is missing; agent completion is not a process status")
    for stage in report.get("stages", []):
        pid = stage.get("job_pid")
        if stage.get("status") != "running" or pid is None:
            continue
        if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
            reasons.append(f"stage {stage.get('id', 'unknown')}: job_pid must be a positive process ID")
        elif _pid_alive(pid):
            reasons.append(f"stage {stage.get('id', 'unknown')}: job_pid {pid} is still alive; stop/reap the prior stage")
    lease_record = report.get("lease", {}) or {}
    resources, lock_root = lease_record.get("resources", []), lease_record.get("lock_root")
    if resources and not lock_root:
        reasons.append("lease.lock_root is missing for recorded resources")
    elif resources:
        for resource in sorted(set(resources)):
            path = _lock_path(lock_root, resource)
            if not path.exists():
                continue
            with path.open("a+", encoding="utf-8") as handle:
                try:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    owner = _read_owner(handle)
                    reasons.append(
                        f"lease resource {resource!r} is still locked by pid "
                        f"{owner.get('owner_pid', 'unknown')}"
                    )
                else:
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    return {"allowed": not reasons, "reasons": reasons}
