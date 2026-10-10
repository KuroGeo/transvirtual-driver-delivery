"""Fail-closed evidence validation. A synthetic pass proves only this schema.

Production always requires H01-H08/G0-G6. Local inspection never authorizes
publication. References retain original bytes and are confined to base_dir.
"""

from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import struct
import zlib

CAPABILITIES = tuple(f"H{i:02d}" for i in range(1, 9))
GATES = tuple(f"G{i}" for i in range(7))
QUALITY_STAGES = ("repository", "tooling-tests", "sdk", "pub", "format", "analyze", "flutter-tests")
SOURCE_ROOT = Path(__file__).resolve().parents[1]
NATIVE_CONTRACT = SOURCE_ROOT / "harness/project/native-acceptance-contract.json"
NATIVE_REVISION = 6
HASH = re.compile(r"[0-9a-f]{64}\Z")
MAX_RAW = 128 * 1024 * 1024
MAX_RECORDS = 50000
NATIVE_PHASES = ("saved", "recovered", "confirmed")
NATIVE_EMPTY_DIAGNOSTICS = frozenset(("process.stdout.log", "process.stderr.log", "unified.stream.stderr.log"))
NATIVE_DIAGNOSTIC_KINDS = frozenset(("driver-raw-evidence", "raw-native-diagnostics"))


class EvidenceError(ValueError):
    """Invalid or inconsistent evidence, with a reviewable reason."""


def _object(value, label):
    if not isinstance(value, dict):
        raise EvidenceError(f"{label}: expected a JSON object")
    return value


def _list(value, label, nonempty=True):
    if not isinstance(value, list) or len(value) > MAX_RECORDS or (nonempty and not value):
        raise EvidenceError(f"{label}: expected a bounded {'nonempty ' if nonempty else ''}array")
    return value


def _integer(value, label, minimum=0):
    if type(value) is not int or value < minimum:
        raise EvidenceError(f"{label}: expected integer >= {minimum}; booleans are not integers")
    return value


def _number(value, label, minimum=None):
    if type(value) not in (int, float) or not math.isfinite(value) or (minimum is not None and value < minimum):
        raise EvidenceError(f"{label}: expected finite number")
    return value


def _text(value, label):
    if not isinstance(value, str) or not value.strip() or len(value) > 16384:
        raise EvidenceError(f"{label}: expected nonempty string")
    return value


def _hash(value, label):
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise EvidenceError(f"{label}: expected lowercase SHA-256")
    return value


def _equal(left, right):
    # JSON bool != int, including nested values.
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(_equal(left[key], right[key]) for key in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(_equal(a, b) for a, b in zip(left, right))
    return left == right


def _expect(value, expected, label):
    if not _equal(value, expected):
        raise EvidenceError(f"{label} must be {expected!r}; got {value!r}")


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _json(raw, label):
    if not isinstance(raw, (str, bytes)) or len(raw) > 8 * 1024 * 1024:
        raise EvidenceError(f"{label}: JSON exceeds8MiB or is not text")
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise EvidenceError("nonfinite decoded JSON float")
        return number
    try:
        return json.loads(raw, object_pairs_hook=_pairs, parse_float=finite_float,
                          parse_constant=lambda value: (_ for _ in ()).throw(EvidenceError(f"nonfinite JSON {value}")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise EvidenceError(f"{label}: expected a raw JSON report: {error}") from error


class Validator:
    def __init__(self, manifest, fingerprint, base_dir):
        self.manifest = _object(manifest, "manifest")
        self.fingerprint = _hash(fingerprint, "current source fingerprint")
        self.base = Path(base_dir).absolute()
        if self.base.resolve() != self.base or not self.base.is_dir():
            raise EvidenceError("evidence base must be an existing canonical directory without symlinks")
        self.reasons = []
        self.checked = {}
        self.native_hashes = set()
        self.native_artifacts = {}
        candidate = _object(manifest.get("candidate"), "candidate")
        _expect(candidate.get("source_fingerprint"), fingerprint, "candidate.source_fingerprint is missing or stale")
        self.mode = manifest.get("service_mode")
        if self.mode not in ("connected", "local-client"):
            raise EvidenceError("service_mode must explicitly be connected or local-client")

    def attempt(self, function, *args):
        try:
            return function(*args)
        except (EvidenceError, OSError, sqlite3.Error, KeyError, TypeError, ValueError, UnicodeError, RecursionError, IndexError, AttributeError, OverflowError, struct.error, zlib.error) as error:
            self.reasons.append(str(error))
            return None

    def path(self, name, owner=None):
        _text(name, "evidence path")
        relative = Path(name)
        if ".." in relative.parts:
            raise EvidenceError(f"evidence path traversal forbidden: {name}")
        path = relative if relative.is_absolute() else (owner or self.base) / relative
        path = path.absolute()
        if not path.is_relative_to(self.base) or path.resolve() != path:
            raise EvidenceError(f"evidence path outside base or symlink forbidden: {name}")
        if not path.is_file():
            raise EvidenceError(f"cannot read {name}: missing regular file")
        return path

    def raw(self, reference, owner=None):
        return self._raw(reference, owner, allow_empty=False)

    def _raw(self, reference, owner=None, *, allow_empty=False):
        reference = _object(reference, "evidence reference requires path, sha256 and kind")
        if not all(key in reference for key in ("path", "sha256", "kind")):
            raise EvidenceError("evidence reference requires path, sha256 and kind")
        _text(reference["kind"], "evidence kind")
        expected = _hash(reference["sha256"], "evidence sha256")
        path = self.path(reference["path"], owner)
        minimum = 0 if allow_empty else 1
        if not minimum <= path.stat().st_size <= MAX_RAW:
            raise EvidenceError(f"{path}: empty or oversized evidence")
        raw = path.read_bytes()
        if not minimum <= len(raw) <= MAX_RAW:
            raise EvidenceError(f"{path}: evidence size changed or is outside bounds")
        if hashlib.sha256(raw).hexdigest() != expected:
            raise EvidenceError(f"sha256 mismatch for {reference['path']}")
        return {**reference, "path_object": path, "raw": raw}

    def native_inventory(self, collector_item):
        """Read original native inventory, narrowly allowing empty diagnostics.

        This reader requires a retained hashed collector document. A caller's
        kind/path declaration alone cannot make a general empty file valid.
        Failed collectors may be inspected, but native_run independently
        requires passed full-run evidence before any G2 acceptance.
        """
        collector_item = self.raw({"path": str(collector_item["path_object"]), "sha256": collector_item["sha256"], "kind": collector_item["kind"]})
        collector = _object(_json(collector_item["raw"], "original native collector inventory"), "native collector")
        _expect(collector.get("schema"), 1, "original collector schema")
        _expect(collector.get("candidate"), self.fingerprint, "original collector candidate")
        _expect(collector.get("entrypoint"), "integration_test/workbench_entry.dart", "original workbench collector entry")
        _expect(collector.get("scope"), "workbench-tooling-smoke", "original workbench collector scope")
        _expect(collector.get("business_acceptance"), False, "original collector does not self-sign business acceptance")
        if collector.get("platform") not in ("ios", "android") or collector.get("configuration") not in ("demo", "local-client"):
            raise EvidenceError("native inventory lacks actual platform/configuration context")
        owner = collector_item["path_object"].parent
        result = {}
        for reference in _list(collector.get("artifacts"), "raw native collector artifacts"):
            _object(reference, "original native inventory reference")
            _expect(reference.get("candidate"), self.fingerprint, "collector artifact candidate")
            path = self.path(reference.get("path"), owner)
            name = str(path)
            if name in result:
                raise EvidenceError("duplicate raw collector artifact path")
            parts = path.relative_to(owner).parts if path.is_relative_to(owner) else ()
            empty_allowed = (len(parts) == 2 and parts[0] in NATIVE_PHASES and parts[1] in NATIVE_EMPTY_DIAGNOSTICS and reference.get("kind") in NATIVE_DIAGNOSTIC_KINDS)
            result[name] = self._raw(reference, owner, allow_empty=empty_allowed)
        return result

    def report(self, item, expected=None):
        report = _object(_json(item["raw"], str(item["path_object"])), "report")
        for key, value in {"candidate": self.fingerprint, "status": "passed", **(expected or {})}.items():
            _expect(report.get(key), value, key)
        return report

    def entries(self, production):
        groups = (("harness", CAPABILITIES, "demonstrated"), ("gates", GATES, "passed")) if production else (("gates", ("G1", "G2", "G4"), "passed"),)
        for group, ids, status in groups:
            entries = self.attempt(_object, self.manifest.get(group), group) or {}
            for entry_id in ids:
                label = f"{group}.{entry_id}"
                self.checked[entry_id] = []
                entry = entries.get(entry_id)
                if not isinstance(entry, dict):
                    self.reasons.append(f"{label} is missing")
                    continue
                self.attempt(_expect, entry.get("status"), status, f"{label}.status")
                self.attempt(_expect, entry.get("candidate"), self.fingerprint, f"{label}.candidate")
                references = self.attempt(_list, entry.get("evidence"), f"{label}.evidence is missing") or []
                seen = set()
                for reference in references:
                    item = self.attempt(self.raw, reference)
                    if item:
                        key = str(item["path_object"])
                        if key in seen:
                            self.reasons.append(f"{label}: duplicate evidence path {key}")
                        seen.add(key)
                        self.checked[entry_id].append(item)

    def specialized(self, entry_id, kind, function, expected=None):
        matches = [item for item in self.checked.get(entry_id, []) if item["kind"] == kind]
        if not matches:
            self.reasons.append(f"{entry_id} requires valid {kind} evidence")
        result = []
        for item in matches:
            report = self.attempt(self.report, item, expected)
            if report is not None:
                value = self.attempt(function, report, item)
                if value is not None:
                    result.append(value)
        return result

    def nested(self, reference, owner):
        return self.raw(reference, owner["path_object"].parent)

    def current_inputs(self, inputs, expected):
        inputs = _object(inputs, "current input hashes")
        for name, path in expected.items():
            if inputs.get(name) != hashlib.sha256(path.read_bytes()).hexdigest():
                raise EvidenceError(f"current source input mismatch: {name}")

    def runner(self, report, item, command):
        _expect(report.get("command"), command, "command")
        for field in ("candidate", "candidate_after", "execution_candidate_after"):
            _expect(report.get(field), {"source_fingerprint": self.fingerprint}, f"{field} is missing or stale")
        _expect(_object(report.get("job"), "job").get("status"), "passed", "job.status")
        _text(report.get("started_at"), "started_at")
        _text(report.get("finished_at"), "finished_at")
        isolation = _object(report.get("isolation"), "isolation")
        _expect(isolation.get("verified_fingerprint"), self.fingerprint, "isolation.verified_fingerprint")
        if isolation.get("requested") is True:
            _expect(isolation.get("task_owned"), True, "isolation.task_owned")
            _expect(isolation.get("cleaned"), True, "isolation.cleaned")
        _expect(_object(report.get("lease"), "lease").get("status"), "released", "lease.status")
        inputs = _object(report.get("inputs"), "inputs")
        _expect(inputs.get("flutter"), _json((SOURCE_ROOT / "app/.fvmrc").read_bytes(), "SDK pin")["flutter"], "inputs.flutter")
        self.current_inputs(inputs, {"lock_sha256": SOURCE_ROOT / "app/pubspec.lock", "asset_sha256": SOURCE_ROOT / "app/assets/deliveries.csv"})
        stages = _list(report.get("stages"), "stages")
        specs = _list(report.get("stage_spec"), "stage_spec")
        if len({stage.get("id") for stage in stages if isinstance(stage, dict)}) != len(stages):
            raise EvidenceError("required quality stages are missing or duplicated")
        if len(specs) != len(stages):
            raise EvidenceError("stage_spec missing or duplicated")
        logs = {}
        for stage, spec in zip(stages, specs):
            _object(stage, "stage")
            _object(spec, "stage_spec")
            _expect(stage.get("status"), "passed", "stage status")
            _integer(stage.get("exit_code"), "stage exit_code")
            _expect(stage["exit_code"], 0, "status/exit_code")
            _integer(stage.get("job_pid"), "stage job_pid", 1)
            argv = _list(stage.get("command"), "stage command")
            if any(not isinstance(argument, str) for argument in argv):
                raise EvidenceError("stage command arguments must be strings")
            normalized = [argument.replace(report["execution_root"], "@workspace").replace(str(item["path_object"].parent), "@run") for argument in argv]
            if "--lease-context" in normalized:
                normalized[normalized.index("--lease-context") + 1] = "@inherited-lease"
            _expect(spec.get("id"), stage.get("id"), "stage_spec.id")
            _expect(spec.get("command"), normalized, "stage_spec.command")
            _expect(spec.get("cwd"), stage.get("cwd", "").replace(report["execution_root"], "@workspace"), "stage_spec.cwd")
            logs[stage["id"]] = self.nested({"path": stage.get("log_path"), "sha256": stage.get("sha256"), "kind": "raw-log"}, item)
        return stages, logs

    def quality(self, report, item):
        # Runner candidate is an object; unlike specialized receipts.
        if isinstance(report.get("stages"), list) and tuple(stage.get("id") for stage in report["stages"] if isinstance(stage, dict)) != QUALITY_STAGES:
            raise EvidenceError("required quality stages are missing or duplicated (including pub)")
        stages, logs = self.runner(report, item, "quality")
        if tuple(stage["id"] for stage in stages) != QUALITY_STAGES:
            raise EvidenceError("required quality stages are missing or duplicated (including pub)")
        options = _object(report.get("options"), "quality options")
        _expect(options.get("targets"), [], "quality full-suite targets")
        mode = options.get("configuration")
        if mode not in ("demo", "local-client"):
            raise EvidenceError("quality configuration must be demo or local-client")
        expected = {
            "repository": ["harness/run.py", "_check"],
            "tooling-tests": ["-m", "unittest", "discover", "-s", "harness/tests", "-v"],
            "sdk": ["harness/run.py", "_sdk"],
            "pub": ["pub", "get", "--enforce-lockfile"],
            "format": ["format", "--output=none", "--set-exit-if-changed", "lib", "test", "integration_test"],
            "analyze": ["analyze", "--no-pub"],
            "flutter-tests": ["test", "--no-pub", "--reporter", "expanded", f"--dart-define=OCEAN_MODE={mode}"],
        }
        for stage in stages:
            _expect(stage["command"][1:], expected[stage["id"]], "full quality stage command")
            if stage["id"] in ("pub", "analyze", "flutter-tests"):
                _expect(Path(stage["command"][0]).name, "flutter", "quality executable")
            if stage["id"] == "format":
                _expect(Path(stage["command"][0]).name, "dart", "quality executable")
        tooling = logs["tooling-tests"]["raw"].decode("utf-8")
        flutter = logs["flutter-tests"]["raw"].decode("utf-8")
        if not re.search(r"Ran [1-9][0-9]* tests in .*\n\s*\nOK\s*\Z", tooling) or "Exception in thread" in tooling:
            raise EvidenceError("tooling-tests raw log lacks final successful completion")
        if not re.search(r"\+[1-9][0-9]*: All tests passed!\s*\Z", flutter) or re.search(r"\+[0-9]+ -[1-9]|Some tests failed|unhandled exception", flutter, re.I):
            raise EvidenceError("flutter-tests raw log lacks full successful completion")
        return report

    def quality_items(self):
        items = [item for item in self.checked.get("G1", []) if item["kind"] == "quality-run"]
        if not items:
            self.reasons.append("G1 requires valid quality-run evidence")
        for item in items:
            report = self.attempt(_json, item["raw"], "quality-run")
            if report is not None:
                self.attempt(self.quality, _object(report, "quality-run"), item)

    def jsonl(self, item):
        raw = item["raw"]
        if not raw.endswith(b"\n"):
            raise EvidenceError(f"{item['path']}: truncated JSONL (missing final newline)")
        lines = raw.splitlines()
        _list(lines, "JSONL records")
        return [_object(_json(line, item["path"]), "JSONL record") for line in lines]

    def png(self, item):
        raw = item["raw"]
        if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
            raise EvidenceError("OS screenshot is not PNG")
        offset, chunks, ended, dimensions = 8, [], False, None
        while offset < len(raw):
            size = struct.unpack(">I", raw[offset:offset + 4])[0]
            kind = raw[offset + 4:offset + 8]
            end = offset + 12 + size
            if end > len(raw):
                raise EvidenceError("truncated PNG chunk")
            data = raw[offset + 8:offset + 8 + size]
            crc = struct.unpack(">I", raw[end - 4:end])[0]
            if zlib.crc32(kind + data) & 0xffffffff != crc:
                raise EvidenceError("PNG chunk CRC mismatch")
            if dimensions is None:
                if kind != b"IHDR" or size != 13:
                    raise EvidenceError("PNG lacks first IHDR")
                width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", data)
                if not 0 < width <= 8192 or not 0 < height <= 8192 or compression != 0 or filtering != 0 or interlace != 0 or depth != 8 or color not in (0, 2, 4, 6):
                    raise EvidenceError("unsupported or invalid OS PNG dimensions/encoding")
                dimensions = width, height
                expected = height * (1 + width * {0: 1, 2: 3, 4: 2, 6: 4}[color])
            elif kind == b"IHDR":
                raise EvidenceError("duplicate PNG IHDR")
            if kind == b"IDAT":
                chunks.append(data)
            if kind == b"IEND":
                if size != 0 or end != len(raw):
                    raise EvidenceError("PNG has trailing or invalid terminal bytes")
                ended = True
            offset = end
        if not ended or not chunks:
            raise EvidenceError("PNG missing IDAT/IEND")
        decompressor = zlib.decompressobj()
        pixels = decompressor.decompress(b"".join(chunks), expected + 1)
        if len(pixels) != expected or not decompressor.eof or decompressor.unused_data or decompressor.unconsumed_tail:
            raise EvidenceError("PNG truncated or oversized pixel stream")
        return dimensions

    def database(self, item):
        if not item["raw"].startswith(b"SQLite format 3\x00"):
            raise EvidenceError("native durable capture is not SQLite")
        with closing(sqlite3.connect(item["path_object"].as_uri() + "?mode=ro&immutable=1", uri=True, timeout=1)) as connection:
            connection.execute("PRAGMA query_only=ON")
            calls = [0]
            def bounded():
                calls[0] += 1
                return calls[0] > 1000
            connection.set_progress_handler(bounded, 1000)
            connection.row_factory = sqlite3.Row
            _expect(connection.execute("PRAGMA integrity_check").fetchone()[0], "ok", "SQLite integrity_check")
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version not in (1, 2):
                raise EvidenceError("SQLite backup must be genuine schema v1 or v2")
            tables, schema = {}, {}
            triggers = [dict(row) for row in connection.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger' ORDER BY name")]
            for table, order in (("datasets", "id"), ("stops", "id"), ("outbox", "seq")) + ((("delivery_settings", "dataset_id"),) if version == 2 else ()):
                rows = connection.execute(f'SELECT * FROM "{table}" ORDER BY "{order}" LIMIT {MAX_RECORDS + 1}').fetchall()
                if len(rows) > MAX_RECORDS:
                    raise EvidenceError("SQLite row bound exceeded")
                tables[table] = [{key: {"sqlite_nonfinite": str(actual)} if type(actual) is float and not math.isfinite(actual) else actual for key, actual in dict(row).items()} for row in rows]
                schema[table] = [dict(row) for row in connection.execute(f'PRAGMA table_info("{table}")')]
            sequences = {row["name"]: row["seq"] for row in connection.execute("SELECT name,seq FROM sqlite_sequence")}
        return {"version": version, "tables": tables, "schema": schema, "triggers": triggers, "sequences": sequences}

    def identity(self, record, check, vm=False):
        _object(record, "native identity record")
        fields = ("processId", "candidate", "configuration", "session") + (("vmProcessId",) if vm else ())
        for field in fields:
            _expect(record.get(field), check.get(field), f"native {field} identity")
        _integer(record.get("processId"), "native processId", 1)
        if vm:
            _integer(record.get("vmProcessId"), "native vmProcessId", 1)
            _expect(record["vmProcessId"], record["processId"], "native connected VM PID")

    def assertion(self, assertion, artifacts):
        assertion = _object(assertion, "native assertion")
        item = artifacts[assertion["artifact"]]
        value = _json(item["raw"], "assertion raw JSON") if not item["path"].endswith(".jsonl") else self.jsonl(item)
        pointer = assertion.get("pointer")
        if not isinstance(pointer, str) or (pointer and not pointer.startswith("/")):
            raise EvidenceError("assertion must use JSON pointer")
        missing = False
        for part in pointer.split("/")[1:] if pointer else []:
            part = part.replace("~1", "/").replace("~0", "~")
            if isinstance(value, dict) and part in value:
                value = value[part]
            elif isinstance(value, list) and part.isdigit() and int(part) < len(value):
                value = value[int(part)]
            else:
                missing = True
                break
        operation = assertion.get("op")
        if operation == "absent":
            _expect(missing, True, "assertion absent")
            return
        if missing:
            raise EvidenceError(f"assertion pointer does not exist: {pointer}")
        if ("value" in assertion) == ("right" in assertion):
            raise EvidenceError("assertion requires exactly one typed value or right reference")
        expected = assertion.get("value")
        if "right" in assertion:
            operand = _object(assertion["right"], "assertion right")
            right_item = artifacts[operand["artifact"]]
            expected = _json(right_item["raw"], "assertion right raw JSON") if not right_item["path"].endswith(".jsonl") else self.jsonl(right_item)
            right_pointer = operand.get("pointer")
            if not isinstance(right_pointer, str) or (right_pointer and not right_pointer.startswith("/")):
                raise EvidenceError("assertion right must use JSON pointer")
            for part in right_pointer.split("/")[1:] if right_pointer else []:
                part = part.replace("~1", "/").replace("~0", "~")
                if isinstance(expected, dict) and part in expected:
                    expected = expected[part]
                elif isinstance(expected, list) and part.isdigit() and int(part) < len(expected):
                    expected = expected[int(part)]
                else:
                    raise EvidenceError("assertion right pointer does not exist")
        if operation == "eq":
            _expect(value, expected, f"assertion {pointer}")
        elif operation == "length":
            _integer(expected, "assertion length")
            if not isinstance(value, (list, dict, str)) or len(value) != expected:
                raise EvidenceError(f"assertion length failed: {pointer}")
        elif operation in ("gte", "lte"):
            _number(value, "assertion actual")
            _number(expected, "assertion expected")
            if (operation == "gte" and value < expected) or (operation == "lte" and value > expected):
                raise EvidenceError(f"assertion {operation} failed: {pointer}")
        else:
            raise EvidenceError("unsupported assertion operation")

    def native_run(self, run, artifacts):
        report_item = artifacts[run["report"]]
        report = self.report(report_item, {"schema": 1, "process_restart": True, "entrypoint": "integration_test/workbench_entry.dart"})
        if report.get("platform") not in ("ios", "android"):
            raise EvidenceError("platform must be android or ios; browser/host evidence is insufficient")
        driver = _text(report.get("driver_target"), "independent native driver")
        if driver == "integration_test/workbench_driver.dart":
            raise EvidenceError("default tooling smoke driver cannot satisfy full G2")
        inputs = _object(report.get("inputs"), "native source inputs")
        required = ("harness/native.py", "harness/native_workbench.py", "harness/run.py", "app/integration_test/workbench_entry.dart", "app/" + driver,
                    "app/integration_test/support/native_workbench_bridge.dart", "app/integration_test/support/native_driver_support.dart", "app/integration_test/support/native_gesture_command.dart", "app/integration_test/support/native_gesture_extension.dart", "app/integration_test/support/native_acceptance_support.dart", "app/pubspec.lock", "app/assets/deliveries.csv")
        if not driver.startswith("integration_test/") or ".." in Path(driver).parts:
            raise EvidenceError("native independent driver outside approved source scope")
        self.current_inputs(inputs, {name: SOURCE_ROOT / name for name in required})
        mode = report.get("configuration")
        if mode not in ("demo", "local-client"):
            raise EvidenceError("native configuration must be demo or local-client")
        _expect(report.get("transport"), "simulated-http-demo" if mode == "demo" else "unavailable", "native transport")
        device = _object(report.get("device"), "native device")
        _expect(device.get("task_owned"), True, "native task device ownership")
        _text(device.get("udid"), "native device.udid")
        container = _text(report.get("data_container"), "native data_container")
        launches = _list(report.get("launches"), "native launches")
        phases = _list(report.get("phases"), "native phases")
        if [phase.get("phase") for phase in phases] != ["saved", "recovered", "confirmed"] or len(launches) != 3:
            raise EvidenceError("native recovery requires saved/recovered/confirmed three phases")
        pids, sessions = [], []
        for launch, phase in zip(launches, phases):
            pid = _integer(launch.get("processId"), "launch processId", 1)
            _expect(phase.get("pid"), pid, "phase PID")
            _expect(phase.get("vm_process_id"), pid, "phase actual VM PID")
            _expect(phase.get("terminated"), True, "phase terminated")
            _expect(phase.get("status"), "passed", "phase status")
            _expect(launch.get("candidate"), self.fingerprint, "launch candidate")
            _expect(launch.get("configuration"), mode, "launch configuration")
            session = _text(launch.get("session"), "launch session")
            _expect(phase.get("session"), session, "phase session")
            _hash(launch.get("vm_uri_sha256"), "launch VM URI hash")
            config = _object(launch.get("launch_config"), "actual launch config")
            _expect(config.get("candidate"), self.fingerprint, "launch config candidate")
            _expect(config.get("mode"), mode, "launch config mode")
            _expect(config.get("session"), session, "launch config session")
            _expect(config.get("schema"), 1, "launch config schema")
            _hash(config.get("sha256"), "launch config SHA")
            _integer(config.get("byte_length"), "launch config byte_length", 1)
            if not config.get("path", "").startswith(container + "/"):
                raise EvidenceError("launch config outside same installation data container")
            pids.append(pid)
            sessions.append(session)
        if len(set(pids)) != 3 or len(set(sessions)) != 3:
            raise EvidenceError("actual three distinct PID/session same-install recovery required")
        _expect(report.get("process_ids"), pids, "actual process_ids")
        commands = _list(report.get("commands"), "native actual commands")
        simctl = [command for command in commands if command.get("argv", [])[:2] == ["xcrun", "simctl"]]
        launch_commands = [command for command in simctl if command["argv"][2:3] == ["launch"]]
        if len(launch_commands) != 3:
            raise EvidenceError("three actual simctl launch receipts required")
        for command, pid in zip(launch_commands, pids):
            if not re.search(r":\s*" + str(pid) + r"\s*\Z", command.get("stdout", "")):
                raise EvidenceError("actual simctl launch stdout PID mismatch")
        if not any(command["argv"][2:3] == ["get_app_container"] and command.get("stdout", "").strip() == container for command in simctl):
            raise EvidenceError("actual same-install data container receipt missing")
        installs = [command for command in simctl if command["argv"][2:3] == ["install"]]
        if len(installs) != 1:
            raise EvidenceError("native same install requires exactly one actual install")
        for command in commands:
            self.native_command(command)
        driver_commands = [command for command in commands if command.get("argv", [])[:3] == ["dart", "run", driver]]
        if len(driver_commands) != 3:
            raise EvidenceError("actual independent driver commands for all three phases required")
        for command, launch in zip(driver_commands, launches):
            argv = command["argv"]
            for flag, expected in (("--phase", launch["phase"]), ("--pid", str(launch["processId"])), ("--candidate", self.fingerprint), ("--session", launch["session"]), ("--configuration", mode)):
                if flag not in argv or argv[argv.index(flag) + 1] != expected:
                    raise EvidenceError("actual driver command identity mismatch: " + flag)
            self.nested(command.get("log"), report_item)
        if commands.index(installs[0]) > commands.index(launch_commands[0]):
            raise EvidenceError("same-install app install must precede first launch")
        if any(command["argv"][2:3] in (["erase"], ["uninstall"]) for command in simctl):
            raise EvidenceError("native recovery cannot erase or reinstall data")
        # Bind compiled entry, driver and preserved artifact to the actual full runner.
        runner_item = artifacts[run["runner_report"]]
        runner = _object(_json(runner_item["raw"], "native runner"), "native runner")
        native_stages, _ = self.runner(runner, runner_item, "native")
        if [stage["id"] for stage in native_stages] != ["sdk", "pub", "workbench-build", "workbench-smoke"]:
            raise EvidenceError("full native workbench build/execute stages missing")
        compiled = native_stages[2]["command"]
        if "--target" not in compiled or compiled[compiled.index("--target") + 1] != report["entrypoint"] or f"--dart-define=OCEAN_MODE={mode}" not in compiled:
            raise EvidenceError("actual build command does not compile matching workbench entry/mode")
        options = _object(runner.get("options"), "native runner options")
        for key, expected in {"scope": "workbench", "configuration": mode, "entrypoint": report["entrypoint"], "driver_target": driver, "targets": []}.items():
            _expect(options.get(key), expected, "native compiled " + key)
        manifest_item = artifacts[run["artifact_manifest"]]
        manifest = _object(_json(manifest_item["raw"], "compiled artifact manifest"), "compiled artifact manifest")
        for key in ("configuration", "entrypoint", "driver_target"):
            _expect(manifest.get(key), options.get(key), "compiled artifact " + key)
        _expect(manifest.get("candidate"), {"source_fingerprint": self.fingerprint}, "compiled artifact candidate")
        archive = self.nested({"path": manifest.get("path"), "sha256": manifest.get("sha256"), "kind": "compiled-native-archive"}, manifest_item)
        self.compiled_archive(archive, manifest)
        verified = {}
        for key, actual in self.native_inventory(report_item).items():
            verified[key] = actual["sha256"]
            self.native_artifacts[key] = (actual["sha256"], report)
        report["_verified_artifacts"] = verified
        return {**report, "_evidence_owner": report_item["path_object"].parent}

    def native_command(self, command):
        command = _object(command, "native actual command")
        argv = _list(command.get("argv"), "native actual argv")
        code = command.get("exit_code")
        if type(code) is not int:
            raise EvidenceError("native command exit_code must be actual integer")
        log_stream = len(argv) >= 8 and argv[:3] == ["xcrun", "simctl", "spawn"] and argv[4:6] == ["log", "stream"] and "--process" in argv and "--predicate" in argv
        if log_stream:
            _expect(command.get("reaped"), True, "owned log-stream reaped")
            _integer(command.get("reader_pid"), "owned log-stream reader_pid", 1)
            if command.get("phase") not in ("saved", "recovered", "confirmed") or code not in (0, -15, 143):
                raise EvidenceError("owned log-stream cleanup is not expected TERM/success")
        elif code != 0:
            raise EvidenceError("ordinary native command must succeed with exit_code0")

    def compiled_archive(self, item, manifest):
        import io
        import tarfile
        expected = {}
        for entry in _list(manifest.get("files"), "compiled artifact file inventory"):
            name = _text(entry.get("path"), "compiled file path")
            if Path(name).is_absolute() or ".." in Path(name).parts or name in expected:
                raise EvidenceError("compiled archive unsafe/duplicate inventory path")
            expected[name] = entry
        total = 0
        seen = set()
        try:
            with tarfile.open(fileobj=io.BytesIO(item["raw"]), mode="r:gz") as archive:
                for member in archive:
                    if not member.name.startswith("Runner.app/") and member.name != "Runner.app":
                        raise EvidenceError("compiled archive outside Runner.app")
                    name = member.name.removeprefix("Runner.app/")
                    if Path(member.name).is_absolute() or ".." in Path(member.name).parts:
                        raise EvidenceError("compiled archive path traversal")
                    if member.isdir():
                        continue
                    if name in seen or name not in expected:
                        raise EvidenceError("compiled archive duplicate/uninventoried file")
                    seen.add(name)
                    entry = expected[name]
                    if member.issym():
                        _expect(member.linkname, entry.get("symlink"), "compiled archive symlink target")
                        import posixpath
                        target = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
                        if Path(member.linkname).is_absolute() or not target.startswith("Runner.app/"):
                            raise EvidenceError("compiled archive escaping symlink")
                    elif member.isfile():
                        total += member.size
                        if member.size > MAX_RAW or total > 512 * 1024 * 1024:
                            raise EvidenceError("compiled archive expansion exceeds bound")
                        _expect(member.size, entry.get("bytes"), "compiled archive file size")
                        stream = archive.extractfile(member)
                        _expect(hashlib.sha256(stream.read()).hexdigest(), entry.get("sha256"), "compiled archive file SHA")
                    else:
                        raise EvidenceError("compiled archive unsupported member")
        except tarfile.TarError as error:
            raise EvidenceError("compiled archive is malformed") from error
        _expect(seen, set(expected), "compiled archive full inventory")

    def native(self, report, item):
        if report.get("platform") not in ("ios", "android"):
            raise EvidenceError("platform must be android or ios; browser/host evidence is insufficient")
        for key, expected in {"schema": 1, "revision": NATIVE_REVISION, "scope": "full-native-functional", "process_restart": True}.items():
            _expect(report.get(key), expected, "native acceptance " + key)
        review = _object(report.get("independent_review"), "native independent_review")
        _expect(review.get("product_author"), False, "native independent product_author")
        _text(review.get("task"), "native independent task")
        _text(review.get("reviewer"), "native independent reviewer")
        contract_item = self.nested(report.get("contract"), item)
        if contract_item["raw"] != NATIVE_CONTRACT.read_bytes():
            raise EvidenceError("native contract differs from authoritative current source")
        contract = _json(contract_item["raw"], "native contract")
        _expect(contract.get("revision"), NATIVE_REVISION, "authoritative native evidence protocol revision")
        cases = _object(report.get("cases"), "native cases")
        _expect(set(cases), set(contract["cases"]), "native exact case IDs")
        _expect(report.get("requirements"), contract["requirements"], "native exact R01-R14 bindings")
        for case_id, check_ids in contract["cases"].items():
            case = _object(cases[case_id], "native " + case_id)
            _expect(case.get("status"), "passed", case_id + " status")
            checks = _list(case.get("checks"), case_id + " checks")
            _expect([check.get("id") for check in checks if isinstance(check, dict)], check_ids, case_id + " exact checks")
            for check in checks:
                _expect(check.get("status"), "passed", check["id"] + " status")
        # Inventory context must be known before the initial aggregate registry
        # sees an empty file. General raw() remains nonempty, including entries
        # that merely claim a diagnostic kind without original membership.
        raw_runs = _list(report.get("runs"), "native runs")
        references = _object(report.get("artifacts"), "native artifact table")
        inventory = {}
        for run in raw_runs:
            _object(run, "native run reference")
            collector_item = self.nested(references[run["report"]], item)
            for path, artifact in self.native_inventory(collector_item).items():
                if path in inventory:
                    raise EvidenceError("duplicate artifact path across original native inventories")
                inventory[path] = artifact
        artifacts = {}
        seen_paths = set()
        for artifact_id, ref in references.items():
            _text(artifact_id, "artifact ID")
            path = self.path(_object(ref, "aggregate artifact reference").get("path"), item["path_object"].parent)
            original = inventory.get(str(path))
            if original is not None and not original["raw"]:
                for field in ("kind", "sha256"):
                    _expect(ref.get(field), original[field], "exact original empty diagnostic " + field)
                artifact = {**ref, "path_object": path, "raw": original["raw"]}
            else:
                artifact = self.nested(ref, item)
            path = str(artifact["path_object"])
            if path in seen_paths:
                raise EvidenceError("native artifact table duplicates one path under multiple IDs")
            seen_paths.add(path)
            artifacts[artifact_id] = artifact
        _expect(set(inventory).issubset(seen_paths), True, "native artifact table must retain full original collector inventory")
        runs = {}
        for run in raw_runs:
            _object(run, "native run reference")
            run_id = _text(run.get("id"), "native run ID")
            if run_id in runs:
                raise EvidenceError("duplicate native run ID")
            runs[run_id] = self.native_run(run, artifacts)
        modes = {run["configuration"] for run in runs.values()}
        _expect(modes, {"demo", "local-client"}, "native both actual configurations")
        cases = _object(report.get("cases"), "native cases")
        _expect(set(cases), set(contract["cases"]), "native exact case IDs")
        _expect(report.get("requirements"), contract["requirements"], "native exact R01-R14 bindings")
        checked = {}
        for case_id, ids in contract["cases"].items():
            case = _object(cases[case_id], "native " + case_id)
            _expect(case.get("status"), "passed", case_id + " status")
            checks = _list(case.get("checks"), case_id + " checks")
            _expect([check.get("id") for check in checks if isinstance(check, dict)], ids, case_id + " exact checks")
            for check in checks:
                check_id = check["id"]
                try:
                    checked[check_id] = self.native_check(check, runs, artifacts)
                except (EvidenceError, KeyError, TypeError, sqlite3.Error, OSError) as error:
                    raise EvidenceError(f"{check_id}: {error}") from error
        self.native_cross_checks(checked)
        self.native_hashes.add(item["sha256"])
        return report

    def native_check(self, check, runs, artifacts):
        _expect(check.get("status"), "passed", "check status")
        _integer(check.get("processId"), "check processId", 1)
        _integer(check.get("vmProcessId"), "check vmProcessId", 1)
        _expect(check["vmProcessId"], check["processId"], "check VM PID")
        run = runs[check["run"]]
        _expect(check.get("configuration"), run["configuration"], "check configuration")
        _expect(check.get("candidate"), self.fingerprint, "check candidate")
        launch = next((value for value in run["launches"] if value["phase"] == check.get("phase")), None)
        if launch is None:
            raise EvidenceError("check references missing native launch")
        for field in ("processId", "session", "configuration", "candidate"):
            _expect(check.get(field), launch.get(field), "check launch " + field)
        reference_ids = [check.get(key) for key in ("receipt", "actions", "observations", "before", "after")]
        reference_ids.extend(_object(check.get("capture"), "native raw capture refs").values())
        for artifact_id in reference_ids:
            artifact = artifacts[artifact_id]
            if run["_verified_artifacts"].get(str(artifact["path_object"])) != artifact["sha256"]:
                raise EvidenceError("check artifact not bound to original raw collector inventory")
        # The raw phase receipt was written by the actual independent driver;
        # aggregation cannot create a passed check absent from that receipt.
        receipt_item = artifacts[check["receipt"]]
        receipt = _object(_json(receipt_item["raw"], "raw E08 phase receipt"), "raw E08 phase receipt")
        _expect(receipt.get("schema"), 1, "phase receipt schema")
        _expect(receipt.get("revision"), NATIVE_REVISION, "phase receipt revision")
        self.identity(receipt, check, vm=True)
        raw_checks = _list(receipt.get("checks"), "raw phase checks")
        matches = [value for value in raw_checks if value.get("id") == check["id"]]
        if len(matches) != 1:
            raise EvidenceError("raw phase receipt missing or duplicate check")
        raw_check = matches[0]
        _expect(raw_check.get("status"), "passed", "raw phase check status")
        declared_samples = _list(raw_check.get("samples", []), "raw check samples", nonempty=False)
        sample_paths = [self.path(name, run["_evidence_owner"]) for name in declared_samples]
        aggregate_paths = [artifacts[key]["path_object"] for key in _list(check.get("samples", []), "aggregate samples", nonempty=False)]
        if check["id"] == "N7.two-sizes-safearea":
            if not all(name in aggregate_paths for name in sample_paths):
                raise EvidenceError("aggregate omitted authentic raw size sample")
        else:
            _expect(aggregate_paths, sample_paths, "exact raw independent samples")
        for key in ("before", "after"):
            raw_path = self.path(raw_check.get(key), run["_evidence_owner"])
            _expect(raw_path, artifacts[check[key]]["path_object"], "phase raw " + key + " path")
        raw_capture = _object(raw_check.get("capture"), "raw check capture")
        for key in ("png", "sqlite", "projection", "journal"):
            _expect(self.path(raw_capture.get(key), run["_evidence_owner"]), artifacts[check["capture"][key]]["path_object"], "raw phase exact capture " + key)
        for key in ("gesture", "keyboard_snapshot", "legacy_before_sqlite", "rollback_sqlite", "rollback_snapshot", "list_before"):
            if key in check:
                _expect(self.path(raw_check.get(key), run["_evidence_owner"]), artifacts[check[key]]["path_object"], "raw phase exact metadata " + key)
        for capture_name in ("keyboard_capture", "rollback_capture"):
            if capture_name in check:
                declared_capture = _object(raw_check.get(capture_name), "raw " + capture_name)
                for key in ("png", "sqlite", "projection", "journal"):
                    _expect(self.path(declared_capture.get(key), run["_evidence_owner"]), artifacts[check[capture_name][key]]["path_object"], "raw phase exact " + capture_name + " " + key)
        before = _object(_json(artifacts[check["before"]]["raw"], "native before snapshot"), "native before")
        after = _object(_json(artifacts[check["after"]]["raw"], "native after snapshot"), "native after")
        observations = self.jsonl(artifacts[check["observations"]])
        for snapshot in (before, after):
            self.identity(snapshot, check)
            _expect(snapshot.get("schema"), 1, "snapshot schema")
            _expect(snapshot.get("mode"), check["configuration"], "snapshot mode")
            _expect(snapshot.get("transport"), check.get("transport"), "snapshot transport")
            if not any(_equal(snapshot, observation) for observation in observations):
                raise EvidenceError("raw snapshot not present in immutable observations journal")
            expected_db = run["data_container"] + "/Documents/" + ("ocean_delivery-demo.sqlite" if check["configuration"] == "demo" else "ocean_delivery.sqlite")
            _expect(snapshot.get("databasePath"), expected_db, "same-install mode database path")
        for observation in observations:
            self.identity(observation, check)
        actions = self.jsonl(artifacts[check["actions"]])
        grouped = {}
        for action in actions:
            self.identity(action, check, vm=True)
            sequence = _integer(action.get("sequence"), "action sequence", 1)
            grouped.setdefault(sequence, []).append(action)
        sequences = _list(check.get("action_sequences"), "check action sequences")
        if len(set(sequences)) != len(sequences):
            raise EvidenceError("duplicate selected action sequence")
        names = []
        for sequence in sequences:
            _integer(sequence, "selected action sequence", 1)
            pair = grouped.get(sequence, [])
            if len(pair) != 2 or [event.get("stage") for event in pair] != ["started", "completed"] or pair[0].get("action") != pair[1].get("action"):
                raise EvidenceError("actual selected UI action not completed exactly once")
            names.append(_text(pair[0].get("action"), "actual UI action"))
        first, last = min(sequences), max(sequences)
        raw_start = _integer(raw_check.get("actionSequenceStart"), "raw action range start", 1)
        raw_end = _integer(raw_check.get("actionSequenceEnd"), "raw action range end", raw_start)
        if first < raw_start or last > raw_end:
            raise EvidenceError("aggregate actions outside raw check action range")
        lifecycle = {"N1.first-import", "N1.cold-preservation", "N1.no-resend", "N5.valid-viewport-cold", "N5.invalid-viewport-fallback", "N6.genuine-v1-upgrade", "N6.migration-rollback-retry", "N7.two-sizes-safearea"}
        if check["id"] not in lifecycle and not any(name.startswith(("tap:", "scroll:", "emulated-text:", "os-")) for name in names):
            raise EvidenceError("check lacks actual typed UI action; observations are not business actions")
        capture = _object(check.get("capture"), "native capture")
        dimensions = self.png(artifacts[capture["png"]])
        database = self.database(artifacts[capture["sqlite"]])
        projection = _object(_json(artifacts[capture["projection"]]["raw"], "SQLite projection"), "SQLite projection")
        _expect(projection.get("sha256"), artifacts[capture["sqlite"]]["sha256"], "projection SQLite hash")
        _expect(projection.get("tables"), database["tables"], "actual SQLite vs JSON projection")
        for field, actual in (("user_version", database["version"]), ("schema", database["schema"]), ("triggers", database["triggers"]), ("sqlite_sequence", [{"name": name, "seq": seq} for name, seq in sorted(database["sequences"].items())])):
            _expect(projection.get(field), actual, "actual SQLite projection " + field)
        self.snapshot_database(after, database)
        journal = self.jsonl(artifacts[capture["journal"]])
        current = [event for event in journal if event.get("session") == check["session"]]
        if not current or not any(event.get("source") == "repository" for event in current):
            raise EvidenceError("native repository journal missing actual current session")
        for event in current:
            self.identity(event, check)
        actual_model = _object(after.get("model"), "native rendered model")
        _expect(actual_model.get("initialized"), True, "actual rendered initialized model")
        _expect(actual_model.get("queueCount"), len(database["tables"]["outbox"]), "actual rendered queue count vs SQL")
        _expect(actual_model.get("pendingCount"), sum(row["status"] == "pending" for row in database["tables"]["stops"]), "actual rendered pending count vs SQL")
        media = _object(after.get("mediaQuery"), "native mediaQuery")
        width = _number(media.get("width"), "actual viewport width", 1)
        height = _number(media.get("height"), "actual viewport height", 1)
        ratio = _number(media.get("devicePixelRatio"), "actual pixel ratio", 0.1)
        if abs(dimensions[0] - width * ratio) > 2 or abs(dimensions[1] - height * ratio) > 2:
            raise EvidenceError("actual PNG dimensions do not match native viewport/pixel ratio")
        # Independently emitted raw assertions remain mandatory even if an
        # aggregator substitutes or omits a meaningful assertion in its copy.
        raw_assertions = _list(raw_check.get("assertions"), "raw independent check assertions")
        by_path = {str(artifact["path_object"]): artifact_id for artifact_id, artifact in artifacts.items()}
        for raw_assertion in raw_assertions:
            normalized = dict(_object(raw_assertion, "raw assertion"))
            normalized["artifact"] = by_path[str(self.path(raw_assertion.get("artifact"), run["_evidence_owner"]))]
            if "right" in raw_assertion:
                operand = _object(raw_assertion["right"], "raw assertion right")
                normalized["right"] = {**operand, "artifact": by_path[str(self.path(operand.get("artifact"), run["_evidence_owner"]))]}
            self.assertion(normalized, artifacts)
        assertions = _list(check.get("assertions"), "native check assertions")
        for assertion in assertions:
            self.assertion(assertion, artifacts)
        from datetime import datetime
        start = datetime.fromisoformat(_text(before.get("observedAt"), "before observedAt").replace("Z", "+00:00"))
        finish = datetime.fromisoformat(_text(after.get("observedAt"), "after observedAt").replace("Z", "+00:00"))
        if finish < start:
            raise EvidenceError("native snapshot time window reversed")
        window = [event for event in current if start <= datetime.fromisoformat(event["observedAt"].replace("Z", "+00:00")) <= finish]
        result = {"check": check, "run": run, "before": before, "after": after, "database": database, "journal": current if check["id"] in lifecycle else window, "actions": names, "action_records": [grouped[sequence][1] for sequence in sequences], "artifacts": artifacts, "dimensions": dimensions}
        self.native_minimum(result)
        return result

    def snapshot_database(self, snapshot, database):
        from datetime import datetime, timezone
        def time_value(value):
            if value is None:
                return None
            return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        tables = database["tables"]
        if database["version"] != 2:
            raise EvidenceError("post-action durable state must be schema v2")
        aliases = {"dataset_id": "datasetId", "stop_id": "stopId", "operation_id": "operationId", "recorded_at": "recordedAt"}
        expected = [{aliases.get(key, key): time_value(value) if key == "recorded_at" else value for key, value in row.items()} for row in tables["outbox"]]
        _expect(snapshot.get("outbox"), expected, "snapshot outbox vs actual SQL immutable rows")
        persisted = _list(snapshot.get("persistedStops"), "persisted native stops")
        if len(persisted) != len(tables["stops"]):
            raise EvidenceError("snapshot durable stop count differs from SQLite")
        lookup = {stop["id"]: stop for stop in persisted}
        for row in tables["stops"]:
            stop = lookup[row["id"]]
            for key in ("status", "reason", "note", "operation_id", "recorded_at", "acknowledged_at", "time_window"):
                alias = {**aliases, "acknowledged_at": "acknowledgedAt", "time_window": "timeWindow"}.get(key, key)
                _expect(stop.get(alias), time_value(row.get(key)) if key.endswith("_at") else row.get(key), "snapshot stop " + key)
        settings = tables["delivery_settings"]
        if len(settings) != 1:
            raise EvidenceError("expected one persisted dataset settings row")
        row = settings[0]
        expected_settings = {"datasetId": row["dataset_id"], "online": row["online"] == 1, "viewport": None}
        valid_viewport = all(type(row[key]) in (int, float) and math.isfinite(row[key]) for key in ("viewport_latitude", "viewport_longitude", "viewport_zoom")) and -90 <= row["viewport_latitude"] <= 90 and -180 <= row["viewport_longitude"] <= 180 and 0 <= row["viewport_zoom"] <= 22
        if valid_viewport:
            expected_settings["viewport"] = {"datasetId": row["dataset_id"], "latitude": row["viewport_latitude"], "longitude": row["viewport_longitude"], "zoom": row["viewport_zoom"]}
        _expect(snapshot.get("persistedSettings"), expected_settings, "persisted settings vs actual SQLite")

    def native_minimum(self, value):
        check, before, after = value["check"], value["before"], value["after"]
        check_id, actions, journal = check["id"], value["actions"], value["journal"]
        model = _object(after.get("model"), "actual after model")
        selected = model.get("selected")
        def require(condition, message):
            if not condition:
                raise EvidenceError("required raw predicate: " + message)
        def tapped(key):
            require("tap:" + key in actions, "actual UI tap " + key)
        def stage(name):
            require(any(event.get("stage") == name for event in journal), "actual journal " + name)
        def same(field):
            _expect(after.get(field), before.get(field), "preserved " + field)
        if check_id.startswith("N1.") or check_id.startswith("N3."):
            _expect(check["configuration"], "demo", "HTTP acceptance demo configuration")
        if check_id.startswith("N2."):
            _expect(check["configuration"], "local-client", "unavailable default local-client configuration")
            _expect(after.get("transport"), "unavailable-local-client", "default local transport unavailable")
        actual_transport = "controlled-http-simulated" if check["configuration"] == "demo" else "unavailable-local-client"
        _expect(check.get("transport"), actual_transport, "truthful native configuration transport")
        if check_id == "N1.first-import":
            require(len(after["persistedStops"]) == 30, "actual approved 30-stop first import")
            require(all(stop.get("timeWindow") for stop in after["persistedStops"]), "seven-column time windows")
            stage("import_committed")
            import csv
            with (SOURCE_ROOT / "app/assets/deliveries.csv").open() as source:
                approved = list(csv.DictReader(source))
            observed = {stop["reference"]: stop for stop in after["persistedStops"]}
            require(set(observed) == {row["reference"] for row in approved}, "approved CSV exact references")
            for row in approved:
                actual = observed[row["reference"]]
                for column, field in (("customer_name", "customerName"), ("address", "address"), ("time_window", "timeWindow"), ("status", "status")):
                    _expect(actual.get(field), row[column], "approved CSV " + field)
                for column in ("latitude", "longitude"):
                    _expect(actual.get(column), float(row[column]), "original unmodified CSV coordinate")
        elif check_id == "N1.offline-two-results":
            _expect(model.get("online"), False, "offline after save")
            require(len(after["outbox"]) == 2 and {row["status"] for row in after["outbox"]} == {"completed", "failed"}, "two actual immutable complete/failure rows")
            failure = next(row for row in after["outbox"] if row["status"] == "failed")
            _text(failure.get("reason"), "actual saved failure reason")
            if failure.get("note") is not None:
                _expect(failure["note"], failure["note"].strip(), "actual failure note trimmed")
            tapped("detail-complete")
            require(any(name.startswith("tap:failure-reason-") for name in actions), "actual failure choice UI action")
            tapped("failure-save")
            stage("submit_committed")
        elif check_id == "N1.cold-preservation":
            require(len(after["outbox"]) == 2, "two rows survived actual cold launch")
            _expect(model.get("online"), False, "persisted offline cold launch")
            stage("database_reopened")
        elif check_id in ("N1.serial-confirmation", "N1.no-resend"):
            require(not after["outbox"], "actual acknowledged queue empty")
            if check_id.endswith("serial-confirmation"):
                tapped("online-toggle")
                stage("ack_committed")
            else:
                require(not any(event.get("stage") in ("sync_sending", "ack_committed") for event in journal), "third-process no acknowledged resend")
        elif check_id == "N2.unavailable":
            require(after["outbox"], "local unavailable retains saved results")
            require(not any(event.get("stage") == "ack_committed" for event in journal), "no unavailable acknowledgement")
            same("outbox")
        elif check_id == "N2.failure-options":
            for slug in ("recipient-unavailable", "business-closed", "address-not-found"):
                tapped("failure-reason-" + slug)
            require(any(row["status"] == "failed" and row.get("note") for row in after["outbox"]), "preset optional trimmed note persisted")
        elif check_id == "N2.other-validation":
            tapped("failure-reason-other")
            tapped("failure-save")
            require(any(row["status"] == "failed" and row.get("reason") and row.get("reason") == row["reason"].strip() and row.get("note") is None for row in after["outbox"]), "trimmed nonblank Other result with null note")
            samples = self.native_samples(check, value["artifacts"])
            require(any("failure-sheet" in sample.get("bounds", {}) and sample.get("outbox") == before.get("outbox") for sample in samples), "blank Other attempt retained modal and unchanged queue")
        elif check_id == "N2.imported-unknown":
            require(isinstance(selected, dict) and selected.get("status") == "failed", "actual imported failed detail")
            for key in ("reason", "note", "recordedAt", "acknowledgedAt", "operationId"):
                _expect(selected.get(key), None, "imported unknown " + key)
        elif check_id == "N2.submit-rollback-retry":
            tapped("failure-save")
            stage("submit_failed")
            stage("submit_committed")
            require(len(after["outbox"]) == len(before["outbox"]) + 1, "single event after rollback retry")
            samples = self.native_samples(check, value["artifacts"])
            require(any(sample.get("outbox") == before["outbox"] and sample.get("model", {}).get("saveError") and "failure-sheet" in sample.get("bounds", {}) for sample in samples), "actual failed SQL write retained modal draft and queue")
            capture = _object(check.get("rollback_capture"), "actual intermediate rollback capture")
            for artifact_id in capture.values():
                artifact = value["artifacts"][artifact_id]
                require(value["run"]["_verified_artifacts"].get(str(artifact["path_object"])) == artifact["sha256"], "rollback raw collector binding")
            self.png(value["artifacts"][capture["png"]])
            rollback_db = self.database(value["artifacts"][capture["sqlite"]])
            rollback_projection = _object(_json(value["artifacts"][capture["projection"]]["raw"], "actual rollback projection"), "rollback projection")
            _expect(rollback_projection.get("sha256"), value["artifacts"][capture["sqlite"]]["sha256"], "rollback SQLite hash")
            _expect(rollback_projection.get("tables"), rollback_db["tables"], "rollback actual SQLite vs projection")
            failed = next(sample for sample in samples if sample.get("model", {}).get("saveError") and "failure-sheet" in sample.get("bounds", {}))
            self.snapshot_database(failed, rollback_db)
            _expect(failed.get("outbox"), before.get("outbox"), "rollback actual SQL preserves original immutable queue")
            require(any(event.get("stage") == "submit_failed" and event.get("session") == check["session"] for event in self.jsonl(value["artifacts"][capture["journal"]])), "actual intermediate SQL failure journal")
        elif check_id == "N2.terminal-double-tap":
            tapped("double-complete")
            require(len(after["outbox"]) == len(before["outbox"]) + 1, "two pending Complete gestures create exactly one immutable result")
            require(selected and selected.get("status") == "completed", "completed terminal detail remains visible")
            require(model.get("panel") == "detail", "save remains terminal detail")
            require(sum(row["stopId"] == selected["id"] for row in after["outbox"]) == 1, "one selected stop operation")
            gesture_item = value["artifacts"][check["gesture"]]
            require(value["run"]["_verified_artifacts"].get(str(gesture_item["path_object"])) == gesture_item["sha256"], "actual UI gesture raw collector binding")
            gesture = _object(_json(gesture_item["raw"], "actual double Complete gesture"), "gesture")
            require(any(event.get("action") == "tap:double-complete" and _equal(event.get("response"), gesture) for event in value["action_records"]), "actual completed DoubleComplete response equals raw gesture proof")
            _expect(gesture.get("completedTaps"), 2, "actual completed pointer taps")
            _expect(gesture.get("key"), "detail-complete", "actual pointer target")
            first = _integer(gesture.get("firstCompletedMicros"), "actual first completed gesture micros")
            elapsed = _integer(gesture.get("elapsedMicros"), "actual gesture elapsed micros")
            require(first <= elapsed <= 1000000, "two actual completed gestures within one second")
        elif check_id == "N2.settings-retry":
            tapped("retry-settings")
            samples = self.native_samples(check, value["artifacts"])
            require(any(sample.get("model", {}).get("settingsError") and sample.get("persistedSettings", {}).get("online") == before["persistedSettings"]["online"] for sample in samples), "failed Online retains original durable flag/error")
            require(model.get("settingsError") is None, "settings actual retry cleared own error")
            require(after["persistedSettings"]["online"] != before["persistedSettings"]["online"], "actual settings retry changed durable Online flag")
            require(any(sample.get("model", {}).get("settingsError") and sample.get("persistedSettings", {}).get("viewport") != before.get("persistedSettings", {}).get("viewport") for sample in samples), "unrelated committed viewport did not clear Online retry")
            fixture_item = value["artifacts"][check["fixture"]]
            require(value["run"]["_verified_artifacts"].get(str(fixture_item["path_object"])) == fixture_item["sha256"], "actual settings fixture collector binding")
            controls = self.jsonl(fixture_item)
            require(any(event.get("kind") == "control" and event.get("state", {}).get("sqlFault") == "settings" for event in controls), "actual named settings SQL fault")
            require(any(event.get("kind") == "control" and event.get("state", {}).get("sqlFault") == "none" for event in controls), "actual named settings fault removed for Retry")
        elif check_id in ("N3.wrong-ack", "N3.send-timeout", "N3.ack-rollback"):
            fixture_item = value["artifacts"][check["fixture"]]
            require(value["run"]["_verified_artifacts"].get(str(fixture_item["path_object"])) == fixture_item["sha256"], "actual raw fault fixture collector binding")
            fixture = self.jsonl(fixture_item)
            mode = {"N3.wrong-ack": "wrong", "N3.send-timeout": "never", "N3.ack-rollback": "match"}[check_id]
            from datetime import datetime
            started = datetime.fromisoformat(before["observedAt"].replace("Z", "+00:00"))
            finished = datetime.fromisoformat(after["observedAt"].replace("Z", "+00:00"))
            identities = {(row["operationId"], row["datasetId"], row["stopId"]) for row in before["outbox"]}
            request = next((event for event in fixture if event.get("kind") == "sync" and event.get("mode") == mode and (event.get("body", {}).get("operationId"), event.get("body", {}).get("datasetId"), event.get("body", {}).get("stopId")) in identities and started <= datetime.fromisoformat(event["at"].replace("Z", "+00:00")) <= finished), None)
            require(request is not None, "actual selected fault request mode " + mode)
            response = next((event for event in fixture if event.get("kind") == "sync-response" and event.get("requestSeq") == request["seq"]), None)
            if check_id == "N3.wrong-ack":
                require(response is not None and response.get("emitted") is True, "actual emitted wrong ACK")
                require(any(response.get("ack", {}).get(key) != request["body"].get(key) for key in ("operationId", "datasetId", "stopId")), "actual ACK identity mismatch")
            if check_id == "N3.send-timeout":
                require(response is None or response.get("emitted") is False, "never fixture delivered no ACK")
            if check_id == "N3.ack-rollback":
                require(response is not None and response.get("emitted") is True, "actual emitted matching ACK before SQL failure")
                for key in ("operationId", "datasetId", "stopId"):
                    _expect(response.get("ack", {}).get(key), request["body"].get(key), "actual rollback matching ACK")
            same("outbox")
            stage("sync_failed")
            require(not any(event.get("stage") == "sync_acknowledged" for event in journal), "failure never increases confirmed count")
            if check_id == "N3.ack-rollback":
                stage("ack_failed")
            if check_id == "N3.send-timeout":
                from datetime import datetime
                events = [event for event in journal if event.get("stage") in ("sync_sending", "sync_failed")]
                require(len(events) >= 2, "actual timeout sending/failure sequence")
                elapsed = (datetime.fromisoformat(events[-1]["observedAt"].replace("Z", "+00:00")) - datetime.fromisoformat(events[0]["observedAt"].replace("Z", "+00:00"))).total_seconds()
                require(elapsed >= 5, "actual product five-second deadline")
        elif check_id == "N3.pause-inflight":
            _expect(model.get("online"), False, "pause persisted offline")
            stage("ack_committed")
            require(len(after["outbox"]) == len(before["outbox"]) - 1, "one in-flight commit; tail retained")
        elif check_id == "N3.tail-enqueue":
            samples = self.native_samples(check, value["artifacts"])
            require(any(sample.get("model", {}).get("isSyncing") is True and len(sample.get("outbox", [])) == len(before["outbox"]) + 1 and sample["outbox"][:-1] == before["outbox"] for sample in samples), "actual held-owner immutable tail enqueue checkpoint")
            stage("submit_committed")
            stage("sync_acknowledged")
            require(not after["outbox"], "enqueued tail drained by same serial owner")
        elif check_id == "N3.single-owner":
            require(actions.count("tap:list-sync") >= 2, "two actual manual triggers join automatic owner")
            samples = self.native_samples(check, value["artifacts"])
            require(any(sample.get("model", {}).get("isSyncing") is True and sample.get("model", {}).get("syncProgress", {}).get("stage") == "sending" for sample in samples), "actual joined in-flight owner snapshot")
            depth = maximum = 0
            for event in journal:
                if event.get("stage") == "sync_started":
                    depth += 1
                    maximum = max(maximum, depth)
                if event.get("stage") == "sync_finished":
                    depth -= 1
                require(0 <= depth <= 1, "one actual coordinator logical owner")
            require(maximum == 1 and depth == 0, "one completed actual drain (HTTP handler count not owner count)")
        elif check_id == "N4.map-controls":
            for key in ("zoom-in", "zoom-out", "fit-stops", "locate-reference"):
                tapped(key)
            require(any(name.startswith("tap:map-stop-") or name.startswith("tap:map-cluster-") for name in actions), "actual marker/cluster tap")
            require(after.get("mapReady") is True and after.get("camera"), "actual native map ready/camera")
        elif check_id == "N4.query-intersection-empty":
            samples = self.native_samples(check, value["artifacts"])
            require(any(sample.get("result", {}).get("matchedCount") == 0 and sample.get("result", {}).get("totalQueueCount", 0) > 0 for sample in samples), "empty match distinguished from global queue")
            require(any(sample.get("model", {}).get("query", {}).get("search") and sample["model"]["query"].get("status") and sample["model"]["query"].get("waitingOnly") is True for sample in samples), "actual combined query intersection")
        elif check_id == "N4.reference-nearest":
            tapped("nearest-stop")
            require(selected and model.get("selectedOrigin") == "nearest", "nearest typed origin selected")
            eligible = self.native_samples(check, value["artifacts"])[0]
            require(selected.get("id") == eligible.get("result", {}).get("nearestId"), "nearest UI from actual current eligible shared result")
        elif check_id == "N4.typed-returns":
            samples = self.native_samples(check, value["artifacts"])
            origins = {sample.get("model", {}).get("selectedOrigin") for sample in samples}
            require({"list", "map", "nearest"} <= origins, "actual list/map/nearest typed detail origins")
            tapped("detail-return")
            _expect(model.get("panel"), "list", "typed return restored deep list source")
            list_before = _object(_json(value["artifacts"][check["list_before"]]["raw"], "actual deep list before"), "deep list before")
            self.identity(list_before, check)
            require(any(_equal(sample, list_before) for sample in samples), "actual deep list snapshot sample binding")
            offset = _number(list_before.get("model", {}).get("listSession", {}).get("scrollOffset"), "actual deep list offset")
            require(offset > 400, "actual nonzero deep lazy-list scroll")
            _expect(model.get("listSession", {}).get("scrollOffset"), offset, "actual list Return preserves offset")
            _expect(after.get("focusedWidget"), "Stop TV-300024", "actual restored row focus")
            _expect(model.get("query", {}).get("search"), "", "actual empty-query list Return")
        elif check_id == "N4.notice-context":
            for key in ("query", "selected", "selectedOrigin", "listSession"):
                _expect(model.get(key), before.get("model", {}).get(key), "notice preserved " + key)
            same("camera")
            require(model.get("notice"), "actual visible notice")
        elif check_id == "N5.tile-degraded-retry":
            tapped("retry-map")
            require(before.get("tileStatus") in ("degraded", "error") and after.get("tileStatus") == "ready", "actual degraded tile to retry ready")
            require(after["outbox"] or any(event.get("stage") == "submit_committed" for event in journal), "business works while tiles unavailable")
        elif check_id == "N5.cache-only-clear":
            tapped("clear-map-cache")
            samples = self.native_samples(check, value["artifacts"])
            preclear = samples[-1]
            for field in ("outbox", "persistedStops", "persistedSettings"):
                _expect(after.get(field), preclear.get(field), "actual cache-only preservation " + field)
        elif check_id == "N5.valid-viewport-cold":
            viewport = after["persistedSettings"].get("viewport")
            require(viewport is not None, "persisted actual valid viewport")
            for field in ("latitude", "longitude", "zoom"):
                require(abs(after["camera"][field] - viewport[field]) < 1e-6, "actual cold camera matches viewport " + field)
        elif check_id == "N5.invalid-viewport-fallback":
            camera = _object(after.get("camera"), "fallback camera")
            for field in ("latitude", "longitude", "zoom"):
                _number(camera.get(field), "valid fallback " + field)
            require(0 <= camera["zoom"] <= 22, "finite bounded fallback zoom")
            same("outbox")
            cold = _object(value["run"].get("cold_fixture"), "actual invalid cold fixture")
            receipt = _object(cold.get("after"), "actual cold-after projection")
            ref = {"path": receipt.get("path"), "sha256": receipt.get("sha256"), "kind": "sqlite-backup"}
            raw = self.raw(ref, value["run"]["_evidence_owner"])
            require(value["run"]["_verified_artifacts"].get(str(raw["path_object"])) == raw["sha256"], "actual invalid cold SQLite backup collector binding")
            invalid = self.database(raw)["tables"]["delivery_settings"][0]
            valid = all(type(invalid[key]) in (int, float) and math.isfinite(invalid[key]) for key in ("viewport_latitude", "viewport_longitude", "viewport_zoom")) and -90 <= invalid["viewport_latitude"] <= 90 and -180 <= invalid["viewport_longitude"] <= 180 and 0 <= invalid["viewport_zoom"] <= 22
            require(not valid, "cold source viewport actually invalid, not a scope label")
            _expect(after["persistedSettings"].get("viewport"), None, "invalid persisted viewport omitted from active settings")
        elif check_id in ("N6.genuine-v1-upgrade", "N6.migration-rollback-retry"):
            legacy = self.database(value["artifacts"][check["legacy_before_sqlite"]])
            _expect(legacy["version"], 1, "genuine prelaunch schema1")
            require("note" not in legacy["tables"]["stops"][0] and "time_window" not in legacy["tables"]["stops"][0], "real v1 columns not v2 relabeled")
            require(legacy["sequences"].get("outbox") == 22, "deleted-highest AUTOINCREMENT22")
            durable = value["database"]
            require(durable["sequences"].get("outbox", 0) >= 22, "upgrade preserves sequence high-water")
            _expect(durable["tables"]["datasets"], legacy["tables"]["datasets"], "upgrade same dataset IDs")
            new_stops = {row["id"]: row for row in durable["tables"]["stops"]}
            require(set(new_stops) == {row["id"] for row in legacy["tables"]["stops"]}, "upgrade preserves all original stop IDs")
            import csv
            with (SOURCE_ROOT / "app/assets/deliveries.csv").open() as source:
                csv_rows = {row["reference"]: row for row in csv.DictReader(source)}
            for old in legacy["tables"]["stops"]:
                new = new_stops[old["id"]]
                for key in ("dataset_id", "reference", "customer_name", "address", "latitude", "longitude"):
                    _expect(new.get(key), old.get(key), "upgrade original identity/coordinates " + key)
                if old["status"] != "pending":
                    for key in ("status", "reason", "operation_id", "acknowledged_at"):
                        _expect(new.get(key), old.get(key), "upgrade historical terminal " + key)
                    _expect(new.get("note"), None, "historical unknown note")
                    _expect(new.get("recorded_at"), None, "historical unknown recorded time")
                csv_row = csv_rows.get(old["reference"])
                exact = csv_row is not None and all(old[key] == csv_row[key] for key in ("customer_name", "address")) and all(old[key] == float(csv_row[key]) for key in ("latitude", "longitude"))
                _expect(new.get("time_window"), csv_row["time_window"] if exact else None, "safe exact-source time-window backfill")
            if check_id == "N6.genuine-v1-upgrade":
                require(any(row["seq"] > 22 for row in durable["tables"]["outbox"]), "actual post-upgrade UI save preserves deleted-highest seq and appends above22")
            for row in legacy["tables"]["outbox"]:
                matches = [new for new in durable["tables"]["outbox"] if new["operation_id"] == row["operation_id"]]
                require(len(matches) == 1, "legacy queued operation retained")
                for key, actual in row.items():
                    _expect(matches[0].get(key), actual, "legacy immutable " + key)
            if check_id.endswith("rollback-retry"):
                rollback = self.database(value["artifacts"][check["rollback_sqlite"]])
                for key in ("version", "tables", "schema", "sequences"):
                    _expect(rollback[key], legacy[key], "failed native migration rollback preserves v1 " + key)
                failed = _object(_json(value["artifacts"][check["rollback_snapshot"]]["raw"], "migration failure snapshot"), "migration failure snapshot")
                self.identity(failed, check)
                require(failed.get("model") is None or failed["model"].get("initialized") is False, "failed initialization unavailable")
                tapped("retry-bootstrap")
                stage("initialize_failed")
        elif check_id == "N7.two-sizes-safearea":
            samples = self.native_samples(check, value["artifacts"], same_identity=False)
            sizes = {(sample["mediaQuery"]["width"], sample["mediaQuery"]["height"]) for sample in samples}
            require(len(sizes) >= 2, "two actual device viewport sizes")
            require(all(sample["mediaQuery"].get("viewPadding") for sample in samples), "actual safe-area observations")
        elif check_id == "N7.os-keyboard":
            keyboard_item = value["artifacts"][check["keyboard_snapshot"]]
            require(value["run"]["_verified_artifacts"].get(str(keyboard_item["path_object"])) == keyboard_item["sha256"], "actual keyboard snapshot collector binding")
            keyboard = _object(_json(keyboard_item["raw"], "actual OS keyboard snapshot"), "keyboard")
            self.identity(keyboard, check)
            capture = _object(check.get("keyboard_capture"), "actual keyboard capture")
            for artifact_id in capture.values():
                artifact = value["artifacts"][artifact_id]
                require(value["run"]["_verified_artifacts"].get(str(artifact["path_object"])) == artifact["sha256"], "actual keyboard capture collector binding")
            media = _object(keyboard.get("mediaQuery"), "actual keyboard mediaQuery")
            inset = _number(media["viewInsets"].get("bottom"), "actual OS keyboard inset", 1)
            require("text-entry-emulation:false" in actions, "driver emulation disabled before actual OS keyboard observation")
            rects = keyboard.get("bounds", {}).get("failure-save", [])
            require(len(rects) == 1, "actual Save geometry")
            rect = rects[0]
            require(rect.get("centerHit") is True and rect["top"] >= 0 and rect["bottom"] <= media["height"] - inset + 0.5 and rect["left"] >= 0 and rect["right"] <= media["width"] + 0.5 and rect["width"] >= 44 and rect["height"] >= 44, "full Save bounds above OS keyboard, usable hit target")
            dimensions = self.png(value["artifacts"][capture["png"]])
            require(abs(dimensions[0] - media["width"] * media["devicePixelRatio"]) <= 2 and abs(dimensions[1] - media["height"] * media["devicePixelRatio"]) <= 2, "actual OS keyboard PNG dimensions")
            keyboard_db = self.database(value["artifacts"][capture["sqlite"]])
            self.snapshot_database(keyboard, keyboard_db)
            projection = _json(value["artifacts"][capture["projection"]]["raw"], "keyboard SQL projection")
            _expect(projection.get("tables"), keyboard_db["tables"], "keyboard actual SQL/projection")
            _expect(projection.get("sha256"), value["artifacts"][capture["sqlite"]]["sha256"], "keyboard SQLite hash")
            tapped("failure-save")
            require(selected and selected.get("status") == "failed" and model.get("panel") == "detail", "OS keyboard Save committed terminal detail")
        elif check_id == "N7.text-scale":
            require(after["mediaQuery"].get("textScaleAt16", 0) >= 2, "actual system 2x text scale")
            self.native_os_settings(value, "content_size")
        elif check_id == "N7.reduced-motion-semantics":
            accessibility = _object(after.get("platformAccessibility"), "actual platform accessibility observation")
            platform = value["run"].get("platform")
            _expect(accessibility.get("platform"), platform, "actual accessibility platform matches collector")
            media = _object(after.get("mediaQuery"), "actual reduced-motion MediaQuery")
            if type(media.get("disableAnimations")) is not bool:
                raise EvidenceError("actual observed disableAnimations must be boolean")
            if platform == "ios":
                # Pinned Flutter's iOS Reduce Motion flag is distinct from its
                # Disable Animations flag. Preserve the actual MediaQuery value.
                _expect(accessibility.get("reduceMotion"), True, "actual iOS UIAccessibility Reduce Motion")
            elif platform == "android":
                _expect(media["disableAnimations"], True, "actual Android disableAnimations")
            else:
                raise EvidenceError("unsupported actual reduced-motion platform")
            self.native_os_settings(value, "reduce_motion")
            require(after.get("bounds", {}).get("detail-close") or after.get("bounds", {}).get("online-toggle"), "usable actual controls")
            require(any(name.startswith("semantics-probe:") for name in actions), "actual driver semantics response probe")
            probes = [event for event in value.get("action_records", []) if event.get("action", "").startswith("semantics-probe:")]
            require(probes, "actual completed native semantics responses")
            for event in probes:
                _integer(event.get("response"), "actual native semantics response ID")
        elif check_id == "N7.platform-back":
            require(any(name in actions for name in ("tap:failure-close", "tap:detail-return", "tap:detail-close", "os-system-back")), "actual modal/typed/system return")
        else:
            raise EvidenceError("unknown native check cannot waive predicates")

    def native_samples(self, check, artifacts, same_identity=True):
        samples = []
        for key in _list(check.get("samples"), "required additional raw samples"):
            artifact = artifacts[key]
            membership = self.native_artifacts.get(str(artifact["path_object"]))
            if membership is None or membership[0] != artifact["sha256"]:
                raise EvidenceError("additional snapshot not bound to actual collector inventory")
            sample = _object(_json(artifact["raw"], "native sample"), "native sample")
            run = membership[1]
            if not any(all(sample.get(field) == launch.get(field) for field in ("processId", "candidate", "configuration", "session")) for launch in run["launches"]):
                raise EvidenceError("additional sample PID/session/mode does not match actual launch")
            if same_identity:
                self.identity(sample, check)
            else:
                _expect(sample.get("candidate"), self.fingerprint, "actual device sample candidate")
                _integer(sample.get("processId"), "actual device sample PID", 1)
            samples.append(sample)
        return samples

    def native_os_settings(self, value, setting):
        commands = value["run"]["commands"]
        if setting == "content_size":
            matching = [command for command in commands if "content_size" in command.get("argv", []) and command.get("exit_code") == 0]
            if not any("accessibility-extra-extra-extra-large" in command["argv"] for command in matching) or not any("accessibility-extra-extra-extra-large" in command.get("stdout", "") for command in matching):
                raise EvidenceError("actual OS text-size write/read receipt missing")
        else:
            matching = [command for command in commands if "ReduceMotionEnabled" in command.get("argv", []) and command.get("exit_code") == 0]
            if not any("write" in command["argv"] and "YES" in command["argv"] for command in matching) or not any("read" in command["argv"] and command.get("stdout", "").strip() == "1" for command in matching):
                raise EvidenceError("actual OS reduced-motion write/read receipt missing")

    def native_cross_checks(self, checked):
        saved = checked["N1.offline-two-results"]["after"]
        recovered = checked["N1.cold-preservation"]["after"]
        for field in ("outbox", "persistedStops", "persistedSettings"):
            _expect(recovered.get(field), saved.get(field), "actual cold preserved " + field)
        nearest = checked["N4.reference-nearest"]
        observations = self.jsonl(nearest["artifacts"][nearest["check"]["observations"]])
        # Source return occurs after this check and before subsequent typed-return
        # checks; original observation journal retains the actual intermediate UI.
        from datetime import datetime
        selected_at = datetime.fromisoformat(nearest["after"]["observedAt"].replace("Z", "+00:00"))
        if not any(observation.get("model", {}).get("panel") == "map" and observation.get("model", {}).get("selected") is None and datetime.fromisoformat(observation["observedAt"].replace("Z", "+00:00")) > selected_at for observation in observations):
            raise EvidenceError("actual nearest-origin return to map observation missing")
        all_actions = self.jsonl(nearest["artifacts"][nearest["check"]["actions"]])
        if not any(event.get("action") in ("tap:detail-return", "tap:detail-close") and event.get("stage") == "completed" and datetime.fromisoformat(event["observedAt"].replace("Z", "+00:00")) > selected_at for event in all_actions):
            raise EvidenceError("actual nearest typed close/return UI action missing")
        first = checked["N1.first-import"]["run"]
        for key in ("N1.offline-two-results", "N1.cold-preservation", "N1.serial-confirmation", "N1.no-resend"):
            _expect(checked[key]["run"], first, "N1 same actual installation/run")
        confirmation = checked["N1.serial-confirmation"]
        raw = confirmation["artifacts"][confirmation["check"]["fixture"]]
        if confirmation["run"]["_verified_artifacts"].get(str(raw["path_object"])) != raw["sha256"]:
            raise EvidenceError("HTTP receipt not bound to actual native collector")
        requests = self.jsonl(raw)
        for row in saved["outbox"]:
            operation = row["operationId"]
            request = next((event for event in requests if event.get("kind") == "sync" and event.get("body", {}).get("operationId") == operation), None)
            if request is None:
                raise EvidenceError("actual immutable HTTP body missing for saved operation")
            for key in ("operationId", "datasetId", "stopId", "status", "reason", "note", "recordedAt"):
                _expect(request["body"].get(key), row.get(key), "actual raw HTTP body " + key)
            response = next((event for event in requests if event.get("kind") == "sync-response" and event.get("requestSeq") == request["seq"]), None)
            if response is None or response.get("emitted") is not True:
                raise EvidenceError("actual emitted matching ACK response missing")
            for key in ("operationId", "datasetId", "stopId"):
                _expect(response.get("ack", {}).get(key), row[key], "actual raw ACK " + key)
            if not any(event.get("stage") == "ack_committed" and event.get("operationId") == operation for event in confirmation["journal"]):
                raise EvidenceError("confirmation lacks persisted matching ACK commit")

    def performance(self, report, item):
        from datetime import datetime
        for key, expected in {"device_type": "real", "build_mode": "profile"}.items():
            _expect(report.get(key), expected, key)
        device = _object(report.get("device"), "physical device")
        for key in ("model", "os", "identifier"):
            _text(device.get(key), "physical device " + key)
        _number(device.get("refresh_hz"), "physical refresh_hz", 1)
        _text(report.get("configuration"), "profile configuration")
        _expect(report.get("trace_format"), "ocean-physical-profile-v1", "typed raw trace format")
        workload = _object(report.get("workload"), "profile workload")
        _integer(workload.get("stops"), "profile workload stops", 30)
        _integer(workload.get("outbox"), "profile workload outbox", 1)
        self.nested(workload.get("source"), item)
        budget_item = self.nested(report.get("budget"), item)
        budget = _object(_json(budget_item["raw"], "frozen performance budget"), "performance budget")
        _expect(budget.get("candidate"), self.fingerprint, "budget candidate")
        if datetime.fromisoformat(budget["frozen_at"].replace("Z", "+00:00")) >= datetime.fromisoformat(report["started_at"].replace("Z", "+00:00")):
            raise EvidenceError("performance budget must be frozen before actual measurements")
        trace_item = self.nested(report.get("trace"), item)
        trace = self.report(trace_item, {"device_type": "real", "build_mode": "profile"})
        _expect(trace.get("device"), device, "raw trace physical device")
        _expect(trace.get("configuration"), report["configuration"], "raw trace configuration")
        _expect(trace.get("workload"), workload, "raw trace workload")
        metrics = _object(trace.get("metrics"), "raw profile metrics")
        if set(metrics) != set(budget.get("metrics", {})) or not metrics:
            raise EvidenceError("performance metrics must match the frozen typed budgets")
        for name, rule in budget["metrics"].items():
            _object(rule, "typed performance budget")
            _text(rule.get("unit"), "budget unit")
            _text(rule.get("sample_definition"), "budget sample definition")
            samples = _list(metrics[name].get("samples"), "actual raw metric samples")
            _integer(rule.get("minimum_samples"), "minimum performance samples", 1)
            if len(samples) < rule["minimum_samples"]:
                raise EvidenceError("insufficient physical profile samples")
            for sample in samples:
                _number(sample, "profile sample", 0)
            if rule.get("statistic") == "p95":
                measured = sorted(samples)[math.ceil(len(samples) * 0.95) - 1]
            elif rule.get("statistic") == "max":
                measured = max(samples)
            else:
                raise EvidenceError("profile budget statistic must be p95 or max")
            _number(rule.get("limit"), "performance budget limit", 0)
            if measured > rule["limit"]:
                raise EvidenceError(f"physical profile budget exceeded: {name}")
            _expect(metrics[name].get("unit"), rule["unit"], "raw metric unit")
        recheck_item = self.nested(report.get("release_recheck"), item)
        recheck = self.report(recheck_item, {"device_type": "real", "build_mode": "release"})
        _expect(recheck.get("device"), device, "release experience actual device")
        self.nested(recheck.get("raw_log"), recheck_item)
        return report

    def resources(self, report, item, production):
        _expect(report.get("schema"), 1, "resource evidence schema")
        _expect(report.get("revision"), 5, "resource evidence revision")
        _expect(report.get("service_mode"), self.mode, "resource service_mode")
        acceptance = self.nested(report.get("native_acceptance"), item)
        if acceptance["sha256"] not in self.native_hashes:
            raise EvidenceError("G4 local proof does not bind previously validated full current G2")
        local = _object(report.get("local"), "G4 local")
        _expect(local.get("status"), "passed", "G4 local status")
        for name in ("transactions", "recovery", "upgrade"):
            reference = self.nested(local.get(name), item)
            receipt = self.report(reference)
            _expect(receipt.get("revision"), 5, "G4 local proof revision")
            _expect(receipt.get("native_check"), {"transactions": "N2.submit-rollback-retry", "recovery": "N1.cold-preservation", "upgrade": "N6.genuine-v1-upgrade"}[name], "G4 required native proof check")
            _expect(receipt.get("native_acceptance_sha256"), acceptance["sha256"], "G4 current full acceptance identity")
        approved = self.nested(report.get("approved_source"), item)
        _expect(approved["sha256"], hashlib.sha256((SOURCE_ROOT / "app/assets/deliveries.csv").read_bytes()).hexdigest(), "G4 approved current CSV source")
        rights = _object(report.get("rights"), "G4 resource rights")
        for name in ("business_data", "dependencies", "fonts_icons", "map_data", "tile_service", "offline_cache"):
            right_item = self.nested(rights.get(name), item)
            right = self.report(right_item)
            _expect(right.get("approved"), True, "G4 applicable resource approval")
            _text(right.get("license"), "G4 resource license")
            _text(right.get("attribution"), "G4 resource attribution")
            if production and name in ("tile_service", "offline_cache"):
                _expect(right.get("production_use"), True, "G4 production resource use")
            self.nested(right.get("source"), right_item)
        unavailable = _object(report.get("unavailable"), "G4 unavailable boundary")
        if self.mode == "local-client":
            _expect(unavailable.get("transport"), "unavailable", "G4 local-client unavailable transport")
            _expect(unavailable.get("claims_uploaded"), False, "G4 local-client truthful upload boundary")
            self.nested(unavailable.get("native_receipt"), item)
        return report

    def production(self):
        _expect(self.manifest.get("enforcement_deployed"), True, "enforcement_deployed; CI/release enforcement is not demonstrated")
        self.entries(True)
        self.quality_items()
        self.specialized("G2", "native-acceptance", self.native, {"process_restart": True})
        self.specialized("G3", "performance", self.performance, {"device_type": "real", "build_mode": "profile"})
        self.specialized("G4", "resource-evidence", lambda report, item: self.resources(report, item, True))
        for kind in ("ci-enforcement", "release-enforcement"):
            self.specialized("H06", kind, lambda report, item: self.enforcement(report, item), {"enforced": True})
        if self.mode == "connected":
            self.specialized("G4", "connected-service", self.connected, {"transport": "connected"})
        artifacts = [item for item in self.checked.get("G5", []) if item["kind"] == "release-artifact"]
        hashes = {item["sha256"] for item in artifacts}
        if not hashes:
            self.reasons.append("G5 requires a hashed release-artifact")
        signatures = self.specialized("G5", "release-signature", lambda report, item: report,
                                      {"build_mode": "release", "signed": True, "signing_kind": "production"})
        signed = set()
        for signature in signatures:
            if signature.get("artifact_sha256") not in hashes:
                self.reasons.append("G5 release-signature: artifact_sha256 does not match a hashed release-artifact")
            else:
                signed.add(signature["artifact_sha256"])
        for artifact in artifacts:
            if artifact["sha256"] not in signed:
                self.reasons.append(f"G5 release-artifact ({artifact['path']}): no matching production signature")
        authorizations = self.specialized("G6", "authorization-receipt", lambda report, item: report, {"authorized": True})
        destinations = set()
        for authorization in authorizations:
            destination = self.attempt(_text, authorization.get("destination"), "G6 authorization destination")
            if destination:
                destinations.add(destination)
        deliveries = self.specialized("G6", "delivery-receipt", lambda report, item: report, {"delivered": True})
        for delivery in deliveries:
            if delivery.get("destination") not in destinations:
                self.reasons.append("G6 delivery-receipt: destination has no matching authorization")
            if delivery.get("artifact_sha256") not in signed:
                self.reasons.append("G6 delivery-receipt: artifact_sha256 does not match a signed release-artifact")

    def enforcement(self, report, item):
        _text(report.get("workflow"), "actual enforcement workflow")
        _text(report.get("run_id"), "actual enforced run_id")
        self.nested(report.get("raw_log"), item)
        _expect(report.get("bypass_rejected"), True, "actual enforcement bypass_rejected")
        return report

    def connected(self, report, item):
        _text(report.get("endpoint"), "actual connected endpoint")
        _expect(report.get("simulated"), False, "actual connected simulated")
        for name in ("authorization", "idempotent_acceptance", "raw_request", "raw_response"):
            self.nested(report.get(name), item)
        return report


def _evaluate(manifest, current_fingerprint, base_dir, local):
    reasons = []
    try:
        validator = Validator(manifest, current_fingerprint, base_dir)
        if local:
            validator.entries(False)
            validator.quality_items()
            validator.specialized("G2", "native-acceptance", validator.native, {"process_restart": True})
            validator.specialized("G4", "resource-evidence", lambda report, item: validator.resources(report, item, False))
        else:
            validator.attempt(validator.production)
        reasons = validator.reasons
    except (EvidenceError, OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, RecursionError, UnicodeError) as error:
        reasons.append(str(error))
    if local:
        return {"local_allowed": not reasons, "publish_allowed": False, "reasons": reasons}
    return {"allowed": not reasons, "reasons": reasons}


def evaluate(manifest, current_fingerprint, base_dir):
    """Production H01-H08/G0-G6, all mandatory regardless of scope labels."""
    return _evaluate(manifest, current_fingerprint, base_dir, False)


def evaluate_local(manifest, current_fingerprint, base_dir):
    """Inspect current full G1/G2/local-resource G4; never permit publication."""
    return _evaluate(manifest, current_fingerprint, base_dir, True)
