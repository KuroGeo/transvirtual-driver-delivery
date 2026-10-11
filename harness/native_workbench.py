"""Private, leased native UI tooling smoke; never signs product acceptance."""
from contextlib import closing
import csv
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import struct
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlparse
import zlib

ENTRY = "integration_test/workbench_entry.dart"
DRIVER = "integration_test/workbench_driver.dart"
JOURNAL = "native-workbench-journal.jsonl"
LAUNCH_CONFIG = "native-workbench-launch.json"
PHASES = ("saved", "recovered", "confirmed")
LEGACY = "legacy-v1-identity-seq"
MIGRATION_TRIGGER = "ocean_native_fault_migration_backfill"
SCENARIOS = tuple(f"N{number}" for number in range(1, 8))
CONTENT_SIZES = ("large", "accessibility-extra-extra-extra-large")
COLD_FIXTURES = ("none", "viewport-corrupt", "viewport-nonfinite")
# Every full readonly sample is retained, including UI bounds and both model
# and persisted stop rows. Accessibility reading adds samples, not UI actions.
DRIVER_ACTION_JOURNAL_MAX_BYTES = 8 * 1024 * 1024
DRIVER_OBSERVATION_JOURNAL_MAX_BYTES = 16 * 1024 * 1024
# A deterministic, valid one-pixel PNG served through the real HTTP tile path.
def png_chunk(kind, value):
    return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value))


TILE = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"\x00\x90\xc0\xd0\xff")) + png_chunk(b"IEND", b""))
IDENTITY = ("operationId", "datasetId", "stopId")
TRIGGERS = {
    "submit": ("BEFORE INSERT ON outbox",),
    "ack": ("BEFORE DELETE ON outbox",),
    "settings": ("BEFORE INSERT ON delivery_settings", "BEFORE UPDATE ON delivery_settings"),
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def driver_target(root, target=None):
    """Only an existing private Dart source; never an arbitrary host command."""
    root = Path(root).resolve()
    target = target or DRIVER
    path = (root / "app" / target).resolve()
    if not path.is_relative_to(root / "app/integration_test") or not path.is_file() or path.suffix != ".dart":
        raise ValueError("driver target must be an existing Dart file under app/integration_test")
    return path.relative_to(root / "app").as_posix()


def device_identifiers(runtime, device_type):
    if not isinstance(runtime, str) or not isinstance(device_type, str) or not re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-\d{1,2}-\d{1,2}(?:-\d{1,2})?", runtime) or not re.fullmatch(r"com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]{1,96}", device_type):
        raise ValueError("native runtime/device-type must be explicit CoreSimulator iOS identifiers")


def available_device(runtime, device_type, runtimes, types):
    device_identifiers(runtime, device_type)
    if not isinstance(runtimes, dict) or not isinstance(types, dict) or not isinstance(runtimes.get("runtimes"), list) or not isinstance(types.get("devicetypes"), list) or not any(row.get("identifier") == runtime and row.get("isAvailable") is True for row in runtimes["runtimes"] if isinstance(row, dict)) or not any(row.get("identifier") == device_type for row in types["devicetypes"] if isinstance(row, dict)):
        raise ValueError("requested task runtime/device-type is absent or unavailable in actual inventory")


def workbench_options(args, driver):
    defaults = {"scenario": None, "content_size": "large", "reduce_motion": False, "initial_tiles": "normal", "cold_fixture": "none", "migration_fault": False}
    values = {key: getattr(args, key, default) for key, default in defaults.items()}
    if values["scenario"] is not None and values["scenario"] not in SCENARIOS or values["content_size"] not in CONTENT_SIZES or values["initial_tiles"] not in {"normal", "503"} or values["cold_fixture"] not in COLD_FIXTURES or any(type(values[key]) is not bool for key in ("reduce_motion", "migration_fault")):
        raise ValueError("native acceptance options outside the frozen enums/types")
    if (values != defaults) and (values["scenario"] is None or driver == DRIVER):
        raise ValueError("native acceptance controls require an explicit scenario and independent driver")
    if values["migration_fault"] and (values["scenario"] != "N6" or args.fixture != LEGACY):
        raise ValueError("migration fault requires N6 and the genuine v1 fixture")
    if values["cold_fixture"] != "none" and values["scenario"] != "N5":
        raise ValueError("cold viewport fixture requires N5")
    return values


def owned_container(path, udid):
    path = Path(path)
    resolved = path.resolve(strict=True)
    if path != resolved or not resolved.is_dir():
        raise ValueError("task app container must be a canonical directory")
    parts = resolved.parts
    suffix = ("Devices", udid, "data", "Containers", "Data", "Application")
    if not any(parts[index:index + len(suffix)] == suffix and index + len(suffix) + 1 == len(parts) for index in range(len(parts))):
        raise ValueError("app container does not belong to the newly created task simulator")
    return resolved


def installed_bundle(path, udid, application, executable):
    """Bind VM publication to the exact installed app on the new task device."""
    path = Path(path)
    resolved = path.resolve(strict=True)
    suffix = ("Devices", udid, "data", "Containers", "Bundle", "Application")
    parts = resolved.parts
    binary = resolved / executable
    if path != resolved or not resolved.is_dir() or resolved.name != application or not any(parts[index:index + len(suffix)] == suffix and index + len(suffix) + 2 == len(parts) for index in range(len(parts))) or not binary.is_file() or binary.resolve() != binary:
        raise ValueError("VM publication requires the exact canonical installed bundle on the task simulator")
    return resolved


def database_path(container, configuration, exists=True):
    if configuration not in {"demo", "local-client"}:
        raise ValueError("unsupported native database configuration")
    name = "ocean_delivery-demo.sqlite" if configuration == "demo" else "ocean_delivery.sqlite"
    path = Path(container) / "Documents" / name
    resolved = path.resolve(strict=exists)
    if resolved != path or not resolved.is_relative_to(Path(container)) or exists and not resolved.is_file():
        raise ValueError("database must be the exact configuration file inside the task container")
    return resolved


def launch_config_path(container, udid, create=False):
    container = owned_container(container, udid)
    directory = container / "Documents"
    if directory.is_symlink() or directory.resolve() != directory or directory.exists() and not directory.is_dir():
        raise ValueError("launch Documents must be a canonical task-owned directory")
    if create:
        directory.mkdir(mode=0o700, exist_ok=True)
    if not directory.is_dir():
        raise ValueError("launch Documents directory is absent")
    path = directory / LAUNCH_CONFIG
    if path.is_symlink() or path.resolve() != path or path.exists() and not path.is_file():
        raise ValueError("launch configuration must be the fixed task-owned regular file")
    return path


def validate_launch_config(value, mode, candidate, session):
    keys = {"schema", "mode", "candidate", "session", "tileUrl", "syncUrl"}
    if not isinstance(value, dict) or set(value) != keys or type(value.get("schema")) is not int or value["schema"] != 1:
        raise ValueError("launch configuration schema/fields differ from the fixed protocol")
    expected = {"mode": mode, "candidate": candidate, "session": session}
    if mode not in {"demo", "local-client"} or not isinstance(candidate, str) or not re.fullmatch(r"[0-9a-f]{64}", candidate) or not isinstance(session, str) or not re.fullmatch(r"[0-9a-f]{48}", session) or any(type(value.get(key)) is not str or value[key] != want for key, want in expected.items()):
        raise ValueError("launch configuration contains stale/invalid mode/candidate/session")
    def loopback(raw, path):
        if not isinstance(raw, str):
            raise ValueError("launch fixture URL must be a string")
        uri = urlparse(raw)
        try:
            valid_port = uri.port is not None and 0 < uri.port <= 65535
        except ValueError:
            valid_port = False
        if uri.scheme != "http" or uri.hostname not in {"127.0.0.1", "localhost"} or not valid_port or uri.username or uri.password or uri.fragment or uri.path != path:
            raise ValueError("launch fixture URL is not the exact task-loopback endpoint")
        return uri
    tile = loopback(value["tileUrl"], "/tiles/{z}/{x}/{y}.png")
    if tile.query:
        raise ValueError("launch tile URL cannot contain a query")
    if mode == "local-client":
        if value["syncUrl"] is not None:
            raise ValueError("local-client cannot override unavailable transport")
    else:
        sync = loopback(value["syncUrl"], "/sync")
        if sync.netloc != tile.netloc or not re.fullmatch(r"token=[0-9a-f]{48}", sync.query):
            raise ValueError("demo sync URL must use the same task fixture and token")


def read_launch_config(container, udid, mode, candidate, session):
    path = launch_config_path(container, udid)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(16 * 1024 + 1)
    if not raw or len(raw) > 16 * 1024:
        raise ValueError("launch configuration is empty or exceeds 16KiB")
    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("launch configuration contains duplicate fields")
            result[key] = value
        return result
    value = json.loads(raw, object_pairs_hook=unique_fields)
    validate_launch_config(value, mode, candidate, session)
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(), "byte_length": len(raw),
            "schema": 1, "mode": mode, "candidate": candidate, "session": session}


def verify_launch_config(container, udid, receipt):
    actual = read_launch_config(container, udid, receipt["mode"], receipt["candidate"], receipt["session"])
    if actual != receipt:
        raise ValueError("task launch configuration changed after its immutable receipt")
    return actual


def write_launch_config(container, udid, mode, candidate, session, fixture, previous=None):
    path = launch_config_path(container, udid, create=True)
    if previous is None:
        if path.exists():
            raise ValueError("new task launch cannot adopt an existing unowned configuration")
    else:
        verify_launch_config(container, udid, previous)
        if previous["mode"] != mode or previous["candidate"] != candidate or previous["session"] == session:
            raise ValueError("relaunch requires the same candidate/mode and a fresh session")
    value = {"schema": 1, "mode": mode, "candidate": candidate, "session": session,
             "tileUrl": fixture.url + "/tiles/{z}/{x}/{y}.png",
             "syncUrl": fixture.url + "/sync?token=" + fixture.token if mode == "demo" else None}
    validate_launch_config(value, mode, candidate, session)
    raw = (json.dumps(value, separators=(",", ":")) + "\n").encode()
    temporary = path.with_name("." + LAUNCH_CONFIG + "." + secrets.token_hex(12) + ".tmp")
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        # Recheck the fixed destination immediately before the atomic replacement.
        launch_config_path(container, udid)
        if previous is None and path.exists():
            raise ValueError("launch configuration appeared before exclusive task write")
        if previous is not None:
            verify_launch_config(container, udid, previous)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return read_launch_config(container, udid, mode, candidate, session)


def seed_legacy(container, udid, configuration, source, output, fixture=LEGACY):
    """Exact approved v1 fixture, only an absent DB in a newly-owned container."""
    if fixture != LEGACY:
        raise ValueError("unsupported prelaunch native fixture")
    container = owned_container(container, udid)
    path = database_path(container, configuration, exists=False)
    if not path.parent.is_dir() or path.exists() or any(Path(str(path) + suffix).exists() for suffix in ("-wal", "-shm", "-journal")):
        raise ValueError("legacy fixture requires an absent mode database before first launch")
    source = Path(source)
    rows = list(csv.reader(source.read_text().splitlines()))
    if not rows or rows[0] != ["reference", "customer_name", "address", "latitude", "longitude", "status", "time_window"] or len(rows) != 31 or any(len(row) != 7 for row in rows[1:]):
        raise ValueError("legacy fixture requires the approved 30-stop source columns")
    rows = rows[1:]
    # Create exclusively so an existing database is never overwritten, even on a race.
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    schema = """
        PRAGMA foreign_keys=ON;
        CREATE TABLE datasets (id TEXT PRIMARY KEY NOT NULL);
        CREATE TABLE stops (
          id TEXT PRIMARY KEY NOT NULL, dataset_id TEXT NOT NULL REFERENCES datasets(id),
          reference TEXT NOT NULL, customer_name TEXT NOT NULL, address TEXT NOT NULL,
          latitude REAL NOT NULL, longitude REAL NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'failed')),
          reason TEXT, operation_id TEXT UNIQUE, acknowledged_at INTEGER,
          UNIQUE (dataset_id, reference), UNIQUE (dataset_id, id));
        CREATE TABLE outbox (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE,
          dataset_id TEXT NOT NULL, stop_id TEXT NOT NULL,
          status TEXT NOT NULL CHECK (status IN ('completed', 'failed')), reason TEXT,
          FOREIGN KEY (dataset_id, stop_id) REFERENCES stops(dataset_id, id));
    """
    with closing(sqlite3.connect(path, timeout=2)) as connection, connection:
        connection.executescript(schema)
        connection.execute("INSERT INTO datasets VALUES('legacy-dataset')")
        for row in rows:
            connection.execute("INSERT INTO stops(id,dataset_id,reference,customer_name,address,latitude,longitude,status) VALUES(?,?,?,?,?,?,?,?)",
                ("legacy-" + row[0], "legacy-dataset", row[0], row[1], row[2], float(row[3]), float(row[4]), row[5]))
        for index in range(2):
            stop, operation = "legacy-" + rows[index][0], f"legacy-operation-{index}"
            status, reason = ("completed", None) if index == 0 else ("failed", "  Historical reason  ")
            connection.execute("UPDATE stops SET status=?,reason=?,operation_id=? WHERE id=?", (status, reason, operation, stop))
            connection.execute("INSERT INTO outbox(seq,operation_id,dataset_id,stop_id,status,reason) VALUES(?,?,?,?,?,?)", (7 if index == 0 else 11, operation, "legacy-dataset", stop, status, reason))
        acknowledged = "legacy-" + rows[2][0]
        connection.execute("UPDATE stops SET status='completed',operation_id='historically-acknowledged',acknowledged_at=1700000000000 WHERE id=?", (acknowledged,))
        connection.execute("INSERT INTO outbox(seq,operation_id,dataset_id,stop_id,status) VALUES(22,'previously-deleted','legacy-dataset',?,'completed')", (acknowledged,))
        connection.execute("DELETE FROM outbox WHERE seq=22")
        connection.execute("PRAGMA user_version=1")
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "legacy-schema.sql").write_text(schema)
    backup_path = output / "legacy-before-launch.sqlite"
    with closing(sqlite3.connect(path)) as connection, closing(sqlite3.connect(backup_path)) as backup:
        deadline = time.monotonic() + 5
        def progress(status, remaining, total):
            if time.monotonic() >= deadline:
                raise TimeoutError("legacy SQLite backup deadline exceeded")
        connection.backup(backup, pages=64, progress=progress, sleep=0.01)
    receipt = {"fixture": LEGACY, "configuration": configuration, "task_udid": udid, "database": str(path), "user_version": 1,
        "asset_sha256": digest(source), "schema_sha256": digest(output / "legacy-schema.sql"), "backup_sha256": digest(backup_path),
        "operation_ids": ["legacy-operation-0", "legacy-operation-1"], "outbox_sequence": [7, 11], "sqlite_sequence": 22,
        "historical_acknowledged_at": 1700000000000, "unknown_legacy_fields": ["note", "recorded_at", "time_window"]}
    write_json(output / "legacy-fixture.json", receipt)
    return receipt


def sql_connection(path, writable=False, versions=(2,)):
    connection = sqlite3.connect(Path(path).as_uri() + ("?mode=rw" if writable else "?mode=ro"), uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    if connection.execute("PRAGMA user_version").fetchone()[0] not in versions:
        connection.close()
        raise ValueError("fault/snapshot schema version is outside the explicitly allowed versions")
    return connection


def migration_fault(container, udid, configuration, install=False):
    container = owned_container(container, udid)
    path = database_path(container, configuration)
    with closing(sql_connection(path, writable=True, versions=(1,) if install else (1, 2))) as connection, connection:
        connection.execute(f'DROP TRIGGER IF EXISTS "{MIGRATION_TRIGGER}"')
        if install:
            identity = connection.execute("SELECT stop_id FROM outbox WHERE seq=11 AND operation_id='legacy-operation-1' AND dataset_id='legacy-dataset'").fetchone()
            if not identity:
                raise ValueError("migration fault requires the exact genuine legacy operation fixture")
            connection.execute(f'''CREATE TRIGGER "{MIGRATION_TRIGGER}" BEFORE UPDATE ON stops
                WHEN NEW.id=(SELECT stop_id FROM outbox WHERE seq=11 AND operation_id='legacy-operation-1')
                BEGIN SELECT RAISE(ABORT, 'task-owned migration backfill failure'); END''')
    return {"trigger": MIGRATION_TRIGGER, "installed": install, "database": str(path)}


def cold_settings_fixture(container, udid, configuration, name):
    if name not in COLD_FIXTURES[1:]:
        raise ValueError("unsupported cold viewport fixture")
    container = owned_container(container, udid)
    path = database_path(container, configuration)
    with closing(sql_connection(path, writable=True)) as connection, connection:
        datasets = connection.execute("SELECT DISTINCT dataset_id FROM stops").fetchall()
        if len(datasets) != 1:
            raise ValueError("cold fixture requires the actual single imported dataset")
        dataset = datasets[0][0]
        if not connection.execute("SELECT dataset_id FROM delivery_settings WHERE dataset_id=?", (dataset,)).fetchone():
            raise ValueError("cold fixture requires a persisted current settings row")
        latitude = "bad" if name == "viewport-corrupt" else float("inf")
        connection.execute("UPDATE delivery_settings SET viewport_latitude=?,viewport_longitude=0,viewport_zoom=12 WHERE dataset_id=?", (latitude, dataset))
    return {"fixture": name, "dataset_id": dataset, "scope": "three viewport columns only; online and delivery identities retained"}


def sql_fault(container, configuration, fault):
    if fault not in {"none", *TRIGGERS}:
        raise ValueError("unsupported task SQL fault")
    path = database_path(container, configuration)
    with closing(sql_connection(path, writable=True)) as connection, connection:
        for name, statements in TRIGGERS.items():
            for index in range(len(statements)):
                connection.execute(f'DROP TRIGGER IF EXISTS "ocean_native_fault_{name}_{index}"')
        for index, statement in enumerate(TRIGGERS.get(fault, ())):
            connection.execute(f'CREATE TRIGGER "ocean_native_fault_{fault}_{index}" {statement} BEGIN SELECT RAISE(ABORT, \'task-owned native fixture\'); END')
    return {"fault": fault, "database": str(path)}


def sqlite_snapshot(container, configuration, output, legacy=False):
    """SQLite backup handles WAL consistently; bounded progress rejects lock hangs."""
    path = database_path(container, configuration)
    destination = Path(output)
    deadline = time.monotonic() + 5
    def progress(status, remaining, total):
        if time.monotonic() >= deadline:
            raise TimeoutError("SQLite backup deadline exceeded")
    versions = (1,) if legacy else (2,)
    with closing(sql_connection(path, versions=versions)) as source, closing(sqlite3.connect(destination)) as target:
        source.backup(target, pages=64, progress=progress, sleep=0.01)
    with closing(sql_connection(destination, versions=versions)) as backup:
        def scalar(value):
            return {"sqlite_nonfinite": str(value)} if isinstance(value, float) and not math.isfinite(value) else value
        names = (("datasets", "id"), ("stops", "id"), ("outbox", "seq")) + (() if legacy else (("delivery_settings", "dataset_id"),))
        tables = {table: [{key: scalar(value) for key, value in dict(row).items()} for row in backup.execute(f'SELECT * FROM "{table}" ORDER BY {order}')]
                  for table, order in names}
        schema = {table: [dict(row) for row in backup.execute(f'PRAGMA table_info("{table}")')] for table, _ in names}
        version = backup.execute("PRAGMA user_version").fetchone()[0]
        triggers = [dict(row) for row in backup.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' ORDER BY name")]
        sequence = [dict(row) for row in backup.execute("SELECT name,seq FROM sqlite_sequence ORDER BY name")] if backup.execute("SELECT name FROM sqlite_master WHERE name='sqlite_sequence'").fetchone() else []
        if legacy and backup.execute("SELECT name FROM sqlite_master WHERE name='delivery_settings'").fetchone():
            raise ValueError("legacy rollback backup unexpectedly contains v2 settings")
        if backup.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("native SQLite backup failed integrity check")
    return {"path": destination.name, "sha256": digest(destination), "user_version": version, "schema": schema, "triggers": triggers, "sqlite_sequence": sequence, "tables": tables}


def outbox_identities(rows, snapshot=False):
    names = ("seq", *IDENTITY) if snapshot else ("seq", "operation_id", "dataset_id", "stop_id")
    return [tuple(row[name] for name in names) for row in rows]


def unified_vm_uri(text, pid, executable="Runner", process_path=None):
    """Decode complete log-stream/show JSON objects, never arbitrary stdout URLs."""
    decoder, offset, candidates = json.JSONDecoder(), 0, set()
    while True:
        offset = text.find("{", offset)
        if offset < 0:
            break
        try:
            event, end = decoder.raw_decode(text, offset)
        except json.JSONDecodeError:
            break  # Do not treat a nested object in an incomplete event as a log record.
        offset = end
        if not isinstance(event, dict) or type(event.get("processID")) is not int or event["processID"] != pid:
            continue
        if not str(event.get("processImagePath", "")).endswith("/" + executable) or not str(event.get("senderImagePath", "")).endswith("/Flutter"):
            continue
        if process_path is not None and (event.get("processImagePath") != str(process_path) or event.get("senderImagePath") != str(Path(process_path).parent / "Frameworks/Flutter.framework/Flutter")):
            continue
        message = event.get("eventMessage")
        if not isinstance(message, str):
            continue
        match = re.fullmatch(r"(?:flutter: )?The Dart VM service is listening on (http://\S+)\s*", message.strip())
        if not match:
            continue
        uri = urlparse(match[1])
        try:
            valid_port = uri.port is not None and 0 < uri.port <= 65535
        except ValueError:
            continue
        if uri.scheme != "http" or uri.hostname not in {"127.0.0.1", "localhost"} or not valid_port or uri.username or uri.password or uri.query or uri.fragment or not re.fullmatch(r"/[A-Za-z0-9_-]{8,128}={0,2}/", uri.path):
            continue
        candidates.add(match[1])
    if len(candidates) > 1:
        raise ValueError("current native PID published conflicting VM service identities")
    return next(iter(candidates), None)


def persisted_vm_uri(text, pid, executable, process_path):
    """Persisted log show must be a complete native JSON array, unlike a stream."""
    try:
        events = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(events, list) or not all(isinstance(event, dict) for event in events):
        return None
    return unified_vm_uri(text, pid, executable, process_path)


def validate_driver_result(directory, phase, pid, candidate, configuration, session, container, launch_config, scenario=None):
    directory = Path(directory)
    result = json.loads((directory / "result.json").read_text())
    snapshot = json.loads((directory / "snapshot.json").read_text())
    expected = {"schema": 1, "processId": pid, "candidate": candidate, "configuration": configuration, "session": session,
                "launchConfigPath": launch_config["path"], "launchConfigByteLength": launch_config["byte_length"], "launchConfigSchema": 1}
    for label, value in (("driver receipt", result), ("readonly snapshot", snapshot)):
        if not isinstance(value, dict) or any(type(value.get(key)) is not type(want) or value.get(key) != want for key, want in expected.items()):
            raise ValueError(f"{label} candidate/configuration/native PID identity mismatch")
    if result.get("status") != "passed" or result.get("phase") != phase or type(result.get("vmProcessId")) is not int or result["vmProcessId"] != pid:
        raise ValueError("driver failed, wrong phase, or VM PID differs from actual launched process")
    if scenario is not None and (result.get("scope") != "e08-native-functional-acceptance" or result.get("scenario") != scenario):
        raise ValueError("independent acceptance result scope/scenario differs from frozen host options")
    if snapshot.get("mode") != configuration or snapshot.get("transport") != ("controlled-http-simulated" if configuration == "demo" else "unavailable-local-client"):
        raise ValueError("readonly snapshot mode/transport differs from native launch")
    if Path(snapshot.get("databasePath", "")).resolve() != database_path(container, configuration):
        raise ValueError("readonly snapshot database path differs from task native database")
    if not isinstance(snapshot.get("outbox"), list):
        raise ValueError("readonly snapshot lacks actual outbox membership")
    identity = {key: expected[key] for key in ("processId", "candidate", "configuration", "session")}
    for name, limit in (("actions.jsonl", DRIVER_ACTION_JOURNAL_MAX_BYTES),
                        ("observations.jsonl", DRIVER_OBSERVATION_JOURNAL_MAX_BYTES)):
        path = directory / name
        if not path.is_file() or not path.stat().st_size or path.stat().st_size > limit:
            raise ValueError("driver action/observation journal missing, empty or outside bounds")
        for line in path.read_text().splitlines():
            row = json.loads(line)
            if not isinstance(row, dict) or any(type(row.get(key)) is not type(want) or row.get(key) != want for key, want in identity.items()):
                raise ValueError("raw driver journal contains stale PID/candidate/mode/session")
            if name == "actions.jsonl" and row.get("vmProcessId") != pid or name == "observations.jsonl" and (row.get("mode") != configuration or any(type(row.get(key)) is not type(expected[key]) or row.get(key) != expected[key] for key in ("launchConfigPath", "launchConfigByteLength", "launchConfigSchema"))):
                raise ValueError("raw VM/action observation identity mismatch")
    initial = json.loads((directory / "initial-snapshot.json").read_text())
    if any(type(initial.get(key)) is not type(want) or initial.get(key) != want for key, want in expected.items()) or initial.get("mode") != configuration:
        raise ValueError("initial readonly observation belongs to another process/session")
    return result, snapshot


class FixtureHTTPServer(ThreadingHTTPServer):
    """Task-only capacity for the native map's parallel initial tile burst."""
    request_queue_size = 64


class Fixture:
    """Task-local HTTP fixture. Controls change fixtures, never product/UI state."""
    def __init__(self, output, capture, fault, migration=None):
        self.output, self.capture, self.fault = Path(output), capture, fault
        self.migration = migration
        self.token = secrets.token_hex(24)
        self.state = {"tiles": "normal", "sync": "match", "delayMs": 720, "sqlFault": "none", "migrationFault": "armed" if migration else "none"}
        self.requests = []
        self.sync_received = threading.Event()
        self.stopping = threading.Event()
        self.lock = threading.RLock()
        self.handlers, self.connections = set(), set()
        self.active_sync = self.max_active_sync = 0
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(5)
                with owner.lock:
                    owner.handlers.add(threading.current_thread())
                    owner.connections.add(self.connection)

            def finish(self):
                try:
                    super().finish()
                finally:
                    with owner.lock:
                        owner.handlers.discard(threading.current_thread())
                        owner.connections.discard(self.connection)

            def log_message(self, *args):
                pass

            def reply(self, code, value, content_type="application/json"):
                raw = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.response_status, self.response_emitted = code, False
                try:
                    self.send_response(code)
                    self.send_header("Content-Type", content_type)
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                    self.wfile.flush()
                    self.response_emitted = True
                    return True
                except OSError:
                    return False

            def authorized(self):
                return secrets.compare_digest(self.headers.get("X-Ocean-Task", ""), owner.token)

            def do_GET(self):
                path = urlparse(self.path).path
                if re.fullmatch(r"/tiles/\d+/\d+/\d+\.png", path):
                    with owner.lock:
                        status = 503 if owner.state["tiles"] == "503" else 200
                        owner.record({"kind": "tile", "path": path, "status": status})
                    self.reply(status, TILE if status == 200 else b"task tile fixture unavailable", "image/png" if status == 200 else "text/plain")
                elif path == "/state" and self.authorized():
                    with owner.lock:
                        self.reply(200, {"state": owner.state.copy(), "requests": list(owner.requests),
                            "activeSync": owner.active_sync, "maxActiveSync": owner.max_active_sync})
                else:
                    self.reply(403 if path == "/state" else 404, {"error": "unsupported/unauthorized fixture request"})

            def do_POST(self):
                parsed = urlparse(self.path)
                sync_id, completion = None, "closed_without_ack"
                self.response_status, self.response_emitted = None, False
                error_receipt, capture_name = None, None
                lengths = self.headers.get_all("Content-Length", [])
                transfers = self.headers.get_all("Transfer-Encoding", [])
                with owner.lock:
                    request_id = owner.record({"kind": "fixture-request", "method": "POST",
                        "path": owner.safe_text(parsed.path, 128),
                        "contentLength": [owner.safe_text(value, 128) for value in lengths[:3]],
                        "transferEncoding": [owner.safe_text(value, 128) for value in transfers[:3]],
                        "hostAuthorized": self.authorized()})["seq"]
                try:
                    # Private callers send exact UTF-8 bytes and length. Reject
                    # ambiguous/chunked framing rather than reading unbounded input.
                    if transfers or len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,10}", lengths[0]):
                        raise ValueError("fixture POST requires one Content-Length and no Transfer-Encoding")
                    length = int(lengths[0])
                    if not 0 < length <= 65536:
                        raise ValueError("fixture body size outside bounds")
                    self.connection.settimeout(5)
                    raw = self.rfile.read(length)
                    if len(raw) != length:
                        raise ValueError("fixture body ended before its declared Content-Length")
                    value = json.loads(raw)
                    if not isinstance(value, dict):
                        raise ValueError("fixture body must be an object")
                    if parsed.path == "/sync":
                        token = parse_qs(parsed.query).get("token", [""])[0]
                        if not secrets.compare_digest(token, owner.token):
                            self.reply(403, {"error": "unauthorized sync fixture"})
                            return
                        if any(not isinstance(value.get(key), str) or not value[key] for key in IDENTITY):
                            raise ValueError("sync fixture requires actual operation identity")
                        with owner.lock:
                            state = owner.state.copy()
                            owner.active_sync += 1
                            owner.max_active_sync = max(owner.max_active_sync, owner.active_sync)
                            sync_id = owner.record({"kind": "sync", "body": value.copy(), "mode": state["sync"],
                                "activeSync": owner.active_sync, "maxActiveSync": owner.max_active_sync})["seq"]
                        if state["sync"] == "never":
                            owner.stopping.wait()
                            completion = "cleanup_closed_without_ack"
                            return  # Cleanup closes the held request without inventing an ACK.
                        if state["sync"] == "hold":
                            deadline = time.monotonic() + 15
                            while not owner.stopping.wait(0.05):
                                with owner.lock:
                                    mode = owner.state["sync"]
                                if mode != "hold":
                                    state["sync"] = mode
                                    break
                                if time.monotonic() >= deadline:
                                    completion = "hold_deadline_closed_without_ack"
                                    return
                            else:
                                completion = "cleanup_closed_without_ack"
                                return
                            if state["sync"] not in {"match", "wrong", "delayed"}:
                                return
                        if owner.stopping.wait(state["delayMs"] / 1000):
                            completion = "cleanup_closed_without_ack"
                            return
                        ack = {key: value[key] for key in IDENTITY}
                        if state["sync"] == "wrong":
                            ack["operationId"] = "wrong-" + ack["operationId"]
                        emitted = self.reply(200, ack)
                        completion = "response_emitted" if emitted else "client_closed_before_response"
                        with owner.lock:
                            owner.record({"kind": "sync-response", "requestSeq": sync_id, "ack": ack, "emitted": emitted})
                    elif parsed.path in {"/control", "/capture"}:
                        if not self.authorized():
                            self.reply(403, {"error": "unauthorized host fixture control"})
                            return
                        if parsed.path == "/control":
                            self.reply(200, owner.control(value))
                        else:
                            if set(value) != {"name"} or not isinstance(value["name"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", value["name"]):
                                raise ValueError("capture needs one safe task artifact name")
                            capture_name = value["name"]
                            self.reply(200, owner.capture(value["name"]))
                    else:
                        self.reply(404, {"error": "unsupported fixture request"})
                except (OSError, ValueError, KeyError, sqlite3.Error, TimeoutError, RuntimeError, subprocess.TimeoutExpired) as error:
                    completion = "handler_error"
                    error_receipt = {"type": type(error).__name__, "message": owner.safe_text(error, 1024)}
                    self.reply(400, {"error": error_receipt["message"]})
                finally:
                    with owner.lock:
                        owner.record({"kind": "fixture-response", "requestSeq": request_id,
                            "status": self.response_status, "emitted": self.response_emitted,
                            "captureName": capture_name, "error": error_receipt})
                    if sync_id is not None:
                        with owner.lock:
                            owner.active_sync -= 1
                            owner.record({"kind": "sync-finished", "requestSeq": sync_id, "completion": completion,
                                "activeSync": owner.active_sync, "maxActiveSync": owner.max_active_sync})
        self.server = FixtureHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def safe_text(self, value, limit):
        text = str(value).replace(self.token, "@task-secret")
        text = re.sub(r"(?i)(token=)[^&\s\"'<>]+", r"\1@task-secret", text)
        return text[:limit]

    def record(self, value):
        value = {"seq": len(self.requests) + 1, "at": datetime.now(timezone.utc).isoformat(), **value}
        self.requests.append(value)
        if value.get("kind") == "sync":
            self.sync_received.set()
        with (self.output / "fixture-requests.jsonl").open("a") as stream:
            stream.write(json.dumps(value) + "\n")
        return value

    def control(self, value):
        if not value or set(value) - set(self.state):
            raise ValueError("unknown/empty fixture control")
        with self.lock:
            proposed = {**self.state, **value}
            if any(type(proposed[key]) is not str for key in ("tiles", "sync", "sqlFault")) or proposed["tiles"] not in {"normal", "503"} or proposed["sync"] not in {"match", "wrong", "hold", "never", "delayed"} or type(proposed["delayMs"]) is not int or not 0 <= proposed["delayMs"] <= 15000 or proposed["sqlFault"] not in {"none", *TRIGGERS}:
                raise ValueError("fixture control outside allowed bounds")
            if "sqlFault" in value:
                self.fault(proposed["sqlFault"])
            if "migrationFault" in value:
                if value["migrationFault"] != "none" or self.migration is None or self.state["migrationFault"] != "armed":
                    raise ValueError("only an armed, proof-captured migration fixture can be dropped")
                self.migration()
            self.state = proposed
            self.record({"kind": "control", "state": proposed.copy()})
            return proposed.copy()

    def __enter__(self):
        with self.lock:
            self.record({"kind": "fixture-server", "listenBacklog": self.server.request_queue_size,
                "bind": "task-loopback", "port": self.server.server_port})
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stopping.set()
        self.server.shutdown()
        with self.lock:
            connections, handlers = list(self.connections), list(self.handlers)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.server.server_close()
        self.thread.join(timeout=2)
        deadline = time.monotonic() + 6
        for handler in handlers:
            handler.join(timeout=max(0, deadline - time.monotonic()))
        with self.lock:
            cleaned = not self.thread.is_alive() and not any(handler.is_alive() for handler in self.handlers) and self.active_sync == 0
            self.record({"kind": "fixture-cleanup", "handlersCleaned": cleaned, "activeSync": self.active_sync, "maxActiveSync": self.max_active_sync})
        if not cleaned:
            raise TimeoutError("task HTTP handlers/server did not stop within cleanup deadline")


class Workbench:
    def __init__(self, args, root, lease_fds):
        self.args, self.root, self.fds = args, Path(root), tuple(lease_fds)
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.driver = driver_target(root, args.driver_target)
        self.options = workbench_options(args, self.driver)
        device_identifiers(args.runtime, args.device_type)
        self.device = self.container = self.active_phase = self.driver_process = self.session = self.pid = None
        self.log_reader = None
        self.log_streams = []
        self.log_started = self.log_record = None
        self.launch_config = None
        self.native_executable = None
        self.sql_fault_ever_installed = False
        self.migration_armed = self.boot_failure_captured = False
        self.legacy_baseline = None
        self.command_lock = threading.RLock()
        self.report = {"schema": 1, "candidate": args.candidate, "configuration": args.configuration,
                       "platform": "ios", "device_type": "simulator", "build_mode": "debug",
                       "scope": "workbench-tooling-smoke", "business_acceptance": False,
                       "transport": "simulated-http-demo" if args.configuration == "demo" else "unavailable",
                       "tile_source": "task-loopback-http-fixture", "status": "failed", "process_restart": False,
                       "entrypoint": ENTRY, "driver_target": self.driver, "fixture_name": args.fixture,
                       "acceptance_options": self.options,
                       "commands": [], "phases": [], "artifacts": []}
        self.application = self.root / "app/build/ios/iphonesimulator/Runner.app"
        import plistlib
        info = plistlib.loads((self.application / "Info.plist").read_bytes())
        self.bundle = info["CFBundleIdentifier"]
        self.executable = info.get("CFBundleExecutable", "Runner")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.executable):
            raise ValueError("task app executable cannot be used safely in an OS log predicate")
        self.report["inputs"] = {name: digest(self.root / name) for name in (
            "harness/native.py", "harness/native_workbench.py", "harness/run.py", "app/" + ENTRY,
            "app/" + self.driver, "app/integration_test/support/native_workbench_bridge.dart",
            "app/integration_test/support/native_driver_support.dart", "app/integration_test/support/native_gesture_command.dart",
            "app/integration_test/support/native_gesture_extension.dart", "app/pubspec.lock", "app/assets/deliveries.csv")}
        if self.options["scenario"]:
            name = "app/integration_test/support/native_acceptance_support.dart"
            self.report["inputs"][name] = digest(self.root / name)

    def save(self):
        write_json(self.output / "result.json", self.report)

    def command(self, *arguments, timeout=120, env=None):
        with self.command_lock:
            argv = ["xcrun", "simctl", *arguments]
            record = {"argv": argv, "at": datetime.now(timezone.utc).isoformat()}
            started = time.monotonic()
            try:
                result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout, pass_fds=self.fds, env=env)
                record.update(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
                if result.returncode:
                    raise RuntimeError(f"simctl {arguments[0]} failed: {result.stderr or result.stdout}")
                return result.stdout.strip()
            except (OSError, subprocess.TimeoutExpired, RuntimeError) as error:
                record["error"] = str(error)
                raise
            finally:
                record["elapsed_seconds"] = round(time.monotonic() - started, 3)
                self.report["commands"].append(record)
                self.save()

    def artifact(self, path, kind):
        path = Path(path)
        value = {"path": path.relative_to(self.output).as_posix(), "sha256": digest(path), "kind": kind, "candidate": self.args.candidate}
        self.report["artifacts"].append(value)
        return value

    def capture(self, name):
        with self.command_lock:
            if not self.active_phase or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", name):
                raise ValueError("capture outside active task phase")
            verify_launch_config(self.container, self.device, self.launch_config)
            legacy = name == "migration-rollback"
            observation = self.failed_boot_observation() if legacy else None
            target = self.output / self.active_phase / name
            if target.with_suffix(".png").exists() or target.with_suffix(".sqlite").exists():
                raise ValueError("task capture name already used")
            self.command("io", self.device, "screenshot", str(target.with_suffix(".png")), timeout=30)
            database = sqlite_snapshot(self.container, self.args.configuration, target.with_suffix(".sqlite"), legacy=legacy)
            if legacy and (self.legacy_baseline is None or any(database[key] != self.legacy_baseline[key] for key in ("tables", "schema", "sqlite_sequence")) or not any(row["name"] == MIGRATION_TRIGGER for row in database["triggers"])):
                raise ValueError("actual v1 migration failure changed original rows/schema/sequence or lost the armed trigger")
            write_json(target.with_suffix(".sqlite.json"), database)
            records = [self.artifact(target.with_suffix(suffix), kind) for suffix, kind in ((".png", "os-screenshot"), (".sqlite", "sqlite-backup"), (".sqlite.json", "sqlite-projection"))]
            journal = database_path(self.container, self.args.configuration).parent / JOURNAL
            if not journal.is_file() or journal.resolve() != journal:
                raise ValueError("actual task event journal missing or outside mode DB directory")
            destination = target.with_suffix(".journal.jsonl")
            destination.write_bytes(journal.read_bytes())
            events = [json.loads(line) for line in destination.read_text().splitlines()]
            current = [event for event in events if event.get("session") == self.session]
            if not current or not any(event.get("source") == "repository" and (not legacy or event.get("stage") == "initialize_failed") for event in current) or any(event.get("processId") != self.pid or event.get("candidate") != self.args.candidate or event.get("configuration") != self.args.configuration for event in current):
                raise ValueError("native journal lacks current PID/candidate/configuration/session events")
            records.append(self.artifact(destination, "repository-coordinator-journal"))
            if legacy:
                records.append(self.artifact(self.output / self.active_phase / "migration-rollback-snapshot.json", "actual-failed-boot-readonly-observation"))
                self.boot_failure_captured = True
                self.report["migration_rollback"] = {"phase": self.active_phase, "processId": self.pid, "session": self.session,
                    "user_version": database["user_version"], "preserved_v1_rows_schema_sequence": True, "artifacts": records}
            self.save()
            return {"artifacts": records, "database": database, **({"failed_boot_observation": observation} if legacy else {})}

    def failed_boot_observation(self):
        if not self.options["migration_fault"] or self.options["scenario"] != "N6" or not self.migration_armed or self.active_phase != "saved":
            raise ValueError("v1 capture requires the explicit armed N6 first-launch migration fixture")
        path = self.output / self.active_phase / "migration-rollback-snapshot.json"
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError("migration capture requires the fixed bounded readonly failed-boot snapshot")
        value = json.loads(path.read_text())
        expected = {"schema": 1, "processId": self.pid, "candidate": self.args.candidate, "configuration": self.args.configuration,
            "mode": self.args.configuration, "session": self.session, "launchConfigPath": self.launch_config["path"],
            "launchConfigByteLength": self.launch_config["byte_length"], "launchConfigSchema": 1,
            "transport": "controlled-http-simulated" if self.args.configuration == "demo" else "unavailable-local-client"}
        if not isinstance(value, dict) or any(type(value.get(key)) is not type(want) or value[key] != want for key, want in expected.items()):
            raise ValueError("failed-boot observation contains a stale PID/candidate/mode/session/config identity")
        model = value.get("model")
        bounds = value.get("bounds")
        retry = bounds.get("reload-data", []) if isinstance(bounds, dict) else []
        if value.get("outbox") is not None or not isinstance(value.get("databasePath"), str) or Path(value["databasePath"]).resolve() != database_path(self.container, self.args.configuration) or model is not None and (not isinstance(model, dict) or model.get("initialized") is not False) or not isinstance(retry, list) or not any(isinstance(row, dict) and row.get("centerHit") is True for row in retry):
            raise ValueError("v1 capture requires actual uninitialized model and visible/hittable Retry UI")
        return {"path": path.relative_to(self.output).as_posix(), "sha256": digest(path), "processId": self.pid, "session": self.session}

    def clear_migration_fault(self):
        if not self.migration_armed or not self.boot_failure_captured:
            raise ValueError("migration trigger cannot be dropped before actual rollback capture")
        receipt = migration_fault(self.container, self.device, self.args.configuration)
        self.migration_armed = False
        write_json(self.output / "migration-trigger.json", {**receipt, "candidate": self.args.candidate, "processId": self.pid, "session": self.session})
        self.artifact(self.output / "migration-trigger.json", "named-migration-trigger-drop")
        self.save()

    def prepare_cold_fixture(self):
        if self.pid is None or self.alive(self.pid):
            raise ValueError("cold fixture requires the saved native process to have terminated")
        verify_launch_config(self.container, self.device, self.launch_config)
        before = sqlite_snapshot(self.container, self.args.configuration, self.output / "cold-before.sqlite")
        receipt = cold_settings_fixture(self.container, self.device, self.args.configuration, self.options["cold_fixture"])
        after = sqlite_snapshot(self.container, self.args.configuration, self.output / "cold-after.sqlite")
        if any(before["tables"][key] != after["tables"][key] for key in ("datasets", "stops", "outbox")) or before["sqlite_sequence"] != after["sqlite_sequence"]:
            raise ValueError("cold viewport fixture changed delivery/outbox identities")
        identity = lambda rows: [(row["dataset_id"], row["online"]) for row in rows]
        if identity(before["tables"]["delivery_settings"]) != identity(after["tables"]["delivery_settings"]):
            raise ValueError("cold viewport fixture changed dataset/online settings")
        write_json(self.output / "cold-before.sqlite.json", before)
        write_json(self.output / "cold-after.sqlite.json", after)
        self.report["cold_fixture"] = {**receipt, "after_terminated_pid": self.pid, "before": before, "after": after}
        for name in ("cold-before.sqlite", "cold-before.sqlite.json", "cold-after.sqlite", "cold-after.sqlite.json"):
            self.artifact(self.output / name, "task-cold-viewport-fixture")
        self.save()

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def terminate(self, pid):
        self.command("terminate", self.device, self.bundle, timeout=30)
        deadline = time.monotonic() + 10
        while self.alive(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        if self.alive(pid):
            raise TimeoutError("old native PID did not terminate; recovery cannot be claimed")

    def log_predicate(self):
        # SDK uses these actual unified-log fields. The stream starts before
        # launch; complete JSON records are additionally matched to its new PID.
        if self.native_executable is not None:
            return 'eventType = logEvent AND processImagePath == ' + json.dumps(str(self.native_executable))
        return f'eventType = logEvent AND processImagePath ENDSWITH "/{self.executable}"'

    def start_log_reader(self, directory):
        if self.log_reader is not None:
            raise ValueError("previous task log reader is still active")
        self.log_streams = [(directory / name).open("w") for name in ("unified.stream.json", "unified.stream.stderr.log")]
        argv = ["xcrun", "simctl", "spawn", self.device, "log", "stream", "--style", "json", "--level", "debug", "--process", self.executable, "--predicate", self.log_predicate()]
        self.log_started = time.monotonic()
        self.log_record = {"argv": argv, "phase": self.active_phase, "at": datetime.now(timezone.utc).isoformat()}
        try:
            self.log_reader = subprocess.Popen(argv, stdout=self.log_streams[0], stderr=self.log_streams[1], pass_fds=self.fds)
            self.log_record["reader_pid"] = self.log_reader.pid
        except OSError:
            for stream in self.log_streams:
                stream.close()
            self.log_streams = []
            raise

    def stop_log_reader(self):
        if self.log_reader is None:
            return
        process = self.log_reader
        try:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            self.log_record.update(exit_code=process.returncode, reaped=True, elapsed_seconds=round(time.monotonic() - self.log_started, 3))
        finally:
            exit_code = process.poll()
            self.log_record.update(exit_code=exit_code, reaped=exit_code is not None)
            for stream in self.log_streams:
                stream.close()
            self.log_streams = []
            self.report["commands"].append(self.log_record)
            self.log_reader = None if exit_code is not None else process
            self.save()

    def failure_diagnostics(self):
        """Retain OS facts before deletion even when Dart/SQLite never started."""
        if not self.device or self.pid is None:
            return
        directory = self.output / (self.active_phase or "failure")
        directory.mkdir(exist_ok=True)
        diagnostics = {"processId": self.pid, "session": self.session, "candidate": self.args.candidate}
        try:
            screenshot = directory / "failure-os.png"
            self.command("io", self.device, "screenshot", str(screenshot), timeout=15)
            diagnostics["screenshot"] = self.artifact(screenshot, "failed-native-os-screenshot")
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            diagnostics["screenshot_error"] = str(error)
        try:
            raw = self.command("spawn", self.device, "log", "show", "--style", "json", "--process", str(self.pid), "--last", "2m", "--info", "--debug", "--predicate", self.log_predicate(), timeout=15)
            path = directory / "failure-unified-show.json"
            path.write_text(raw + "\n")
            diagnostics["unified_log"] = self.artifact(path, "failed-native-unified-log")
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            diagnostics["unified_log_error"] = str(error)
        self.report["failure_diagnostics"] = diagnostics

    def set_sql_fault(self, value):
        result = sql_fault(self.container, self.args.configuration, value)
        if value != "none":
            self.sql_fault_ever_installed = True
        return result

    def launch(self, phase, fixture):
        if self.pid is not None and self.alive(self.pid):
            raise ValueError("previous native PID is still alive; launch configuration cannot be replaced")
        bundle = installed_bundle(self.command("get_app_container", self.device, self.bundle, "app", timeout=30), self.device, self.application.name, self.executable)
        executable = bundle / self.executable
        if self.native_executable is not None and executable != self.native_executable:
            raise ValueError("same-install relaunch changed the installed task app bundle")
        self.native_executable = executable
        self.report["installed_app_bundle"] = str(bundle)
        directory = self.output / phase
        directory.mkdir()
        self.session = secrets.token_hex(24)
        self.launch_config = write_launch_config(self.container, self.device, self.args.configuration,
            self.args.candidate, self.session, fixture, self.launch_config)
        self.report.setdefault("launch_inputs", []).append({"phase": phase, **self.launch_config})
        self.save()
        self.start_log_reader(directory)
        stdout, stderr = directory / "process.stdout.log", directory / "process.stderr.log"
        launch = self.command("launch", f"--stdout={stdout}", f"--stderr={stderr}", self.device, self.bundle,
                              "--enable-dart-profiling", "--enable-checked-mode", "--verify-entry-points")
        match = re.search(r": (\d+)\s*$", launch)
        if not match:
            raise ValueError("native launch did not return an actual process PID")
        pid = int(match[1])
        self.pid = pid
        self.report.setdefault("launches", []).append({"phase": phase, "processId": pid, "session": self.session,
            "candidate": self.args.candidate, "configuration": self.args.configuration, "launch_config": self.launch_config.copy()})
        started = time.monotonic()
        deadline, next_show, attempts = started + 45, started, 0
        while time.monotonic() < deadline:
            if not self.alive(pid):
                raise RuntimeError("native app exited before VM-service connection")
            if self.log_reader is None or self.log_reader.poll() is not None:
                raise RuntimeError("task unified-log reader exited before VM discovery")
            path = directory / "unified.stream.json"
            if path.stat().st_size > 8 * 1024 * 1024:
                raise ValueError("task unified-log stream exceeded bounded discovery size")
            uri = unified_vm_uri(path.read_text(errors="replace"), pid, self.executable, self.native_executable)
            source, evidence = "live-stream", None
            if not uri and time.monotonic() >= next_show:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                attempts += 1
                try:
                    raw = self.command("spawn", self.device, "log", "show", "--style", "json", "--process", str(pid), "--last", "2m", "--info", "--debug", "--predicate", self.log_predicate(), timeout=min(5, remaining))
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                    self.report["launches"][-1].setdefault("vm_discovery_errors", []).append({"attempt": attempts, "type": type(error).__name__})
                else:
                    retained = directory / f"discovery-show-{attempts:02d}.json"
                    retained.write_text(raw + "\n")
                    evidence = self.artifact(retained, "task-pid-persisted-vm-discovery")
                    if retained.stat().st_size > 8 * 1024 * 1024:
                        raise ValueError("task persisted unified log exceeded bounded discovery size")
                    uri = persisted_vm_uri(raw, pid, self.executable, self.native_executable)
                    source = "persisted-show"
                next_show = time.monotonic() + 2
            if time.monotonic() >= deadline:
                break
            if uri:
                if not self.alive(pid):
                    raise RuntimeError("native app exited during VM-service discovery")
                verify_launch_config(self.container, self.device, self.launch_config)
                self.report["launches"][-1]["vm_uri_sha256"] = hashlib.sha256(uri.encode()).hexdigest()
                self.report["launches"][-1]["vm_discovery_source"] = source
                self.report["launches"][-1]["vm_process_image_path"] = str(self.native_executable)
                if evidence is not None:
                    self.report["launches"][-1]["vm_discovery_artifact"] = evidence
                return pid, uri
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
        raise TimeoutError("actual launched process published no authenticated loopback VM URI")

    def drive(self, phase, pid, uri, fixture):
        verify_launch_config(self.container, self.device, self.launch_config)
        directory = self.output / phase
        argv = ["dart", "run", self.driver, "--vm-service-url", uri, "--output", str(directory), "--phase", phase,
                "--candidate", self.args.candidate, "--pid", str(pid), "--configuration", self.args.configuration,
                "--session", self.session, "--fixture-url", fixture.url, "--fixture-token", fixture.token]
        if phase != "saved":
            argv.extend(["--baseline", str(self.output / "saved/snapshot.json")])
        if self.args.fixture:
            argv.extend(["--fixture", self.args.fixture])
        if self.options["scenario"]:
            for key in ("scenario", "content_size", "initial_tiles", "cold_fixture"):
                argv.extend(["--" + key.replace("_", "-"), self.options[key]])
            for key in ("reduce_motion", "migration_fault"):
                if self.options[key]:
                    argv.append("--" + key.replace("_", "-"))
        log = directory / "driver.log"
        started = time.monotonic()
        with log.open("w") as stream:
            self.driver_process = subprocess.Popen(argv, cwd=self.root / "app", stdout=stream, stderr=subprocess.STDOUT, pass_fds=self.fds)
            try:
                code = self.driver_process.wait(timeout=330 if self.options["scenario"] else 180)
            finally:
                if self.driver_process.poll() is None:
                    self.driver_process.terminate()
                    try:
                        self.driver_process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.driver_process.kill()
                        self.driver_process.wait(timeout=5)
                recorded_argv = argv.copy()
                for flag in ("--vm-service-url", "--fixture-token"):
                    recorded_argv[recorded_argv.index(flag) + 1] = "@task-secret"
                self.report["commands"].append({"argv": recorded_argv, "phase": phase,
                    "exit_code": self.driver_process.returncode, "elapsed_seconds": round(time.monotonic() - started, 3),
                    "log": self.artifact(log, "external-driver-log")})
                self.driver_process = None
                self.save()
        if code:
            raise RuntimeError(f"external driver {phase} failed with exit {code}; inspect raw driver log")
        verify_launch_config(self.container, self.device, self.launch_config)
        return validate_driver_result(directory, phase, pid, self.args.candidate, self.args.configuration, self.session, self.container, self.launch_config, self.options["scenario"])

    def execute(self):
        pids, saved_ids, recovered_tables = [], None, None
        try:
            runtimes = json.loads(self.command("list", "runtimes", "--json"))
            types = json.loads(self.command("list", "devicetypes", "--json"))
            available_device(self.args.runtime, self.args.device_type, runtimes, types)
            created = self.command("create", "OceanDelivery-Workbench", self.args.device_type, self.args.runtime)
            if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", created):
                raise ValueError("simctl create returned an invalid task UDID")
            self.device = created
            self.report["device"] = {"udid": self.device, "runtime": self.args.runtime, "type": self.args.device_type, "task_owned": True}
            self.command("boot", self.device)
            self.command("bootstatus", self.device, "-b", timeout=240)
            self.command("install", self.device, str(self.application))
            self.container = owned_container(self.command("get_app_container", self.device, self.bundle, "data"), self.device)
            self.report["data_container"] = str(self.container)
            launch_config_path(self.container, self.device, create=True)
            if self.options["scenario"]:
                self.command("ui", self.device, "content_size", self.options["content_size"], timeout=30)
                content_receipt = self.command("ui", self.device, "content_size", timeout=30)
                self.report["os_controls"] = {"content_size": self.options["content_size"], "content_size_receipt": content_receipt,
                    "reduce_motion_requested": self.options["reduce_motion"], "actual_mediaquery_proof": "required from independent UI driver, not inferred from command success"}
                if self.options["reduce_motion"]:
                    self.command("spawn", self.device, "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "YES", timeout=30)
                    self.report["os_controls"]["reduce_motion_notification_receipt"] = self.command("spawn", self.device, "notifyutil", "-p", "com.apple.Accessibility.ReduceMotionStatusDidChange", timeout=30)
                    self.report["os_controls"]["reduce_motion_defaults_receipt"] = self.command("spawn", self.device, "defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled", timeout=30)
            if self.args.fixture:
                self.report["legacy_fixture"] = seed_legacy(self.container, self.device, self.args.configuration, self.root / "app/assets/deliveries.csv", self.output)
                self.report["legacy_fixture"]["reference_fixture"] = {"path": "app/test/data/legacy_repository_fixture.dart", "sha256": digest(self.root / "app/test/data/legacy_repository_fixture.dart")}
                write_json(self.output / "legacy-fixture.json", self.report["legacy_fixture"])
                for name in ("legacy-schema.sql", "legacy-before-launch.sqlite", "legacy-fixture.json"):
                    self.artifact(self.output / name, "genuine-v1-prelaunch-fixture")
                if self.options["migration_fault"]:
                    migration_fault(self.container, self.device, self.args.configuration, install=True)
                    self.migration_armed = True
                    self.legacy_baseline = sqlite_snapshot(self.container, self.args.configuration, self.output / "legacy-armed.sqlite", legacy=True)
                    write_json(self.output / "legacy-armed.sqlite.json", self.legacy_baseline)
                    for name in ("legacy-armed.sqlite", "legacy-armed.sqlite.json"):
                        self.artifact(self.output / name, "genuine-v1-armed-backfill-fixture")
            with Fixture(self.output, self.capture, self.set_sql_fault, self.clear_migration_fault if self.options["migration_fault"] else None) as fixture:
                fixture.control({"tiles": self.options["initial_tiles"]})
                if self.args.fixture and self.args.configuration == "demo":
                    fixture.control({"sync": "hold"})
                self.report["fixture"] = {"base_url": fixture.url, "tile_sha256": hashlib.sha256(TILE).hexdigest(), "task_owned": True,
                    "listen_backlog": fixture.server.request_queue_size,
                    "counter_semantics": "active HTTP handlers, including uncancellable requests after logical coordinator timeout; not coordinator owners"}
                for phase in PHASES:
                    self.active_phase = phase
                    if phase == "recovered" and self.options["cold_fixture"] != "none":
                        self.prepare_cold_fixture()
                    pid, uri = self.launch(phase, fixture)
                    pids.append(pid)
                    self.report["process_ids"] = pids.copy()
                    if len(set(pids)) != len(pids):
                        raise ValueError("native relaunch reused a PID; recovery identity ambiguous")
                    if phase != "saved":
                        before = sqlite_snapshot(self.container, self.args.configuration, self.output / phase / "before-driver.sqlite")
                        write_json(self.output / phase / "before-driver.sqlite.json", before)
                        for suffix in (".sqlite", ".sqlite.json"):
                            self.artifact(self.output / phase / ("before-driver" + suffix), "pre-driver-durable-state")
                        if phase == "recovered" and outbox_identities(before["tables"]["outbox"]) != saved_ids:
                            raise ValueError("actual cold restart lost or changed saved operation identities/sequence")
                        if phase == "confirmed" and before["tables"] != recovered_tables:
                            raise ValueError("third process changed the previously retained durable result")
                    result, snapshot = self.drive(phase, pid, uri, fixture)
                    capture = self.capture("phase-final")
                    tables = capture["database"]["tables"]
                    ids = outbox_identities(tables["outbox"])
                    if outbox_identities(snapshot["outbox"], snapshot=True) != ids:
                        raise ValueError("driver model outbox membership differs from actual SQLite backup")
                    if self.driver == DRIVER:
                        expected = 2 if phase == "saved" or self.args.configuration == "local-client" else 0
                        if len(ids) != expected:
                            raise ValueError("default tooling smoke queue count differs from phase/configuration")
                    if phase == "saved":
                        saved_ids = ids
                        if not tables["delivery_settings"] or any(row["online"] != 0 for row in tables["delivery_settings"]):
                            raise ValueError("saved phase did not persist offline before cold recovery")
                    if phase == "recovered":
                        recovered_tables = tables
                    if phase == "confirmed" and tables != recovered_tables:
                        raise ValueError("readonly confirmed phase mutated durable product data")
                    self.terminate(pid)
                    verify_launch_config(self.container, self.device, self.launch_config)
                    self.stop_log_reader()
                    known = {record["path"] for record in self.report["artifacts"]}
                    for path in sorted((self.output / phase).iterdir()):
                        if path.is_symlink():
                            raise ValueError("driver evidence must be task-owned files, not symlink references")
                        if path.is_file() and path.relative_to(self.output).as_posix() not in known:
                            self.artifact(path, "driver-raw-evidence")
                    self.report["phases"].append({"phase": phase, "pid": pid, "session": self.session, "vm_process_id": result["vmProcessId"], "queue_count": len(ids), "terminated": True, "status": "passed"})
                    self.save()
                self.report.update(status="passed", process_restart=True)
        except (OSError, ValueError, KeyError, RuntimeError, TimeoutError, sqlite3.Error, subprocess.TimeoutExpired, InterruptedError, KeyboardInterrupt) as error:
            self.report.update(status="failed", error=str(error))
        finally:
            if self.report["status"] != "passed":
                self.failure_diagnostics()
            try:
                self.stop_log_reader()
            except (OSError, subprocess.TimeoutExpired) as error:
                self.report.update(status="failed", log_reader_cleanup_error=str(error))
            self.active_phase = None
            if self.container:
                if self.migration_armed:
                    try:
                        self.report["migration_fault_cleanup"] = migration_fault(self.container, self.device, self.args.configuration)
                        self.migration_armed = False
                    except (OSError, ValueError, sqlite3.Error) as error:
                        self.report.update(status="failed", migration_fault_cleanup_error=str(error))
                try:
                    sql_fault(self.container, self.args.configuration, "none")
                    self.report["fault_cleanup"] = {"status": "completed", "scope": "named task triggers only"}
                except FileNotFoundError:
                    if self.sql_fault_ever_installed:
                        self.report.update(status="failed", fault_cleanup_error="mode DB disappeared after a task SQL fault was installed")
                    else:
                        self.report["fault_cleanup"] = {"status": "not_applicable", "database_present": False, "reason": "mode DB absent/uninitialized; no task SQL fault was installed"}
                except ValueError as error:
                    # A real failed v1 initialization cannot have installed a
                    # v2 delivery/settings fault. Retain that fact separately.
                    uninitialized = False
                    if self.options["migration_fault"] and not self.sql_fault_ever_installed:
                        try:
                            with closing(sql_connection(database_path(self.container, self.args.configuration), versions=(1, 2))) as connection:
                                uninitialized = connection.execute("PRAGMA user_version").fetchone()[0] == 1
                        except (OSError, ValueError, sqlite3.Error):
                            pass
                    if self.options["migration_fault"] and uninitialized and not self.sql_fault_ever_installed:
                        self.report["fault_cleanup"] = {"status": "not_applicable", "database_present": True, "user_version": 1,
                            "reason": "genuine v1 initialization failed; no v2 task SQL fault was installed"}
                    else:
                        self.report.update(status="failed", fault_cleanup_error=str(error))
                except (OSError, sqlite3.Error) as error:
                    self.report["fault_cleanup_error"] = str(error)
                    self.report["status"] = "failed"
            if self.device:
                try:
                    self.command("shutdown", self.device, timeout=30)
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                    self.report["shutdown_error"] = str(error)
                try:
                    self.command("delete", self.device, timeout=30)
                    self.report["device_cleaned"] = True
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                    self.report.update(status="failed", cleanup_error=str(error))
            fixture_log = self.output / "fixture-requests.jsonl"
            if fixture_log.exists():
                self.artifact(fixture_log, "host-fixture-request-journal")
            known = {record["path"]: record["sha256"] for record in self.report["artifacts"]}
            for path in sorted(self.output.rglob("*")):
                if path.is_symlink():
                    self.report.update(status="failed", evidence_error="driver evidence contains symlink")
                    continue
                if not path.is_file() or path == self.output / "result.json":
                    continue
                name = path.relative_to(self.output).as_posix()
                if name in known and digest(path) != known[name]:
                    self.report.update(status="failed", evidence_error=f"previously captured artifact changed: {name}")
                elif name not in known:
                    self.artifact(path, "raw-native-diagnostics")
            self.save()
        print(json.dumps({key: value for key, value in self.report.items() if key != "commands"}, ensure_ascii=False, indent=2))
        return 0 if self.report["status"] == "passed" else 1


def execute(args, root, lease_fds):
    return Workbench(args, root, lease_fds).execute()
