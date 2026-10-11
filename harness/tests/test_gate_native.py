"""Tiny synthetic raw graphs exercise validation only; no native acceptance."""

import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import struct
import unittest
import zlib

from harness import gate
from harness.tests import test_gate as fixtures


def png(width, height):
    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\0" * width * 4) * height)) + chunk(b"IEND", b""))


class NativeGateTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GateTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        self.fp = self.fixture.fingerprint
        self.validator = gate.Validator(self.fixture.manifest, self.fp, self.root)
        self.contract = json.loads(gate.NATIVE_CONTRACT.read_bytes())
        self.contract_ref = self.fixture.evidence("contract.json", "native-contract", gate.NATIVE_CONTRACT.read_bytes())

    def tearDown(self):
        self.fixture.tearDown()

    def artifact(self, name, kind, value):
        if isinstance(value, (dict, list)):
            value = json.dumps(value)
        return self.validator.raw(self.fixture.evidence(name, kind, value))

    def collector(self, references, candidate=None, **changes):
        value = {"schema": 1, "candidate": candidate or self.fp, "configuration": "demo", "platform": "ios",
                 "scope": "workbench-tooling-smoke", "business_acceptance": False,
                 "entrypoint": "integration_test/workbench_entry.dart", "status": "failed", "artifacts": references, **changes}
        reference = self.fixture.evidence("collector.json", "raw-native-collector", json.dumps(value))
        return self.validator.raw(reference)

    def empty_reference(self, name, kind="driver-raw-evidence", candidate=None):
        (self.root / name).parent.mkdir(parents=True, exist_ok=True)
        return {**self.fixture.evidence(name, kind, b""), "candidate": candidate or self.fp}

    def test_retained_actual_x02_empty_diagnostic_records_have_reader_compatibility(self):
        # Exact zero-byte records physically verified in accepted X02
        # 20261010T175309967471Z-native. This copied reader-only fixture is
        # historical producer compatibility, not current full G2 acceptance.
        historical = "e888779d6b48c5a3aecd002b20f0a21362134594fbb19680562bd535a7cc769b"
        names = ("saved/process.stdout.log", "recovered/process.stderr.log", "recovered/process.stdout.log", "confirmed/process.stderr.log", "confirmed/process.stdout.log")
        refs = [self.empty_reference(name, candidate=historical) for name in names]
        for reference in refs:
            self.assertEqual(reference["sha256"], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        item = self.collector(refs, candidate=historical, status="passed")
        validator = gate.Validator({"candidate": {"source_fingerprint": historical}, "service_mode": "local-client"}, historical, self.root)
        read = validator.native_inventory(item)
        self.assertEqual(set(read), {str(self.root / name) for name in names})
        self.assertTrue(all(value["raw"] == b"" for value in read.values()))
        for reference in refs:
            with self.assertRaises(gate.EvidenceError):
                validator.raw(reference)  # general evidence never gains waiver

    def test_failed_current_collector_empty_diagnostic_is_not_native_acceptance(self):
        # Matches the actual failed184820 producer path/kind. Reader accepts
        # authentic empty diagnostics; failed VM discovery still blocks G2.
        ref = self.empty_reference("saved/process.stdout.log", "raw-native-diagnostics")
        collector = self.collector([ref])
        self.assertEqual(self.validator.native_inventory(collector)[str(self.root / ref["path"])]["raw"], b"")
        report = self.acceptance()
        report["artifacts"] = {"collector": {key: collector[key] for key in ("path", "kind", "sha256")}, "diagnostic": ref}
        report["runs"] = [{"id": "failed-real-shape", "report": "collector"}]
        self.rejected_acceptance(report, "status must be 'passed'")

    def test_native_empty_reader_refuses_wrong_name_phase_kind_source_and_hash(self):
        cases = (("saved/process.stdout.log", "raw-log"), ("saved/process.stdout.log", "sqlite-backup"),
                 ("saved/driver.log", "external-driver-log"), ("saved/driver.stdout.log", "driver-raw-evidence"),
                 ("saved/driver.stderr.log", "raw-native-diagnostics"), ("saved/actions.jsonl", "driver-raw-evidence"),
                 ("saved/snapshot.json", "raw-native-diagnostics"), ("saved/state.sqlite", "driver-raw-evidence"),
                 ("saved/os.png", "raw-native-diagnostics"), ("other/process.stdout.log", "driver-raw-evidence"),
                 ("process.stderr.log", "driver-raw-evidence"), ("saved/nested/process.stderr.log", "raw-native-diagnostics"))
        for name, kind in cases:
            with self.subTest(name=name, kind=kind):
                ref = self.empty_reference(name, kind)
                with self.assertRaises(gate.EvidenceError):
                    self.validator.native_inventory(self.collector([ref]))
        ref = self.empty_reference("saved/process.stderr.log")
        for reference in ({**ref, "sha256": "0" * 64}, {**ref, "candidate": "b" * 64}):
            with self.subTest(reference=reference), self.assertRaises(gate.EvidenceError):
                self.validator.native_inventory(self.collector([reference]))
        for changes in ({"entrypoint": "lib/main.dart"}, {"scope": "fake-fixture"}, {"business_acceptance": True}, {"schema": True}):
            with self.subTest(changes=changes), self.assertRaises(gate.EvidenceError):
                self.validator.native_inventory(self.collector([ref], **changes))
        with self.assertRaises(gate.EvidenceError):
            self.validator.native_inventory(self.collector([ref, ref]))

    def test_native_inventory_does_not_waive_empty_unlisted_or_relabelled_aggregate_artifacts(self):
        ref = self.empty_reference("saved/process.stdout.log")
        collector = self.collector([ref])
        for extra, message in (({**ref, "kind": "raw-log"}, "exact original empty diagnostic kind"),
                               (self.empty_reference("recovered/process.stdout.log"), "empty or oversized")):
            report = self.acceptance()
            report["artifacts"] = {"collector": {key: collector[key] for key in ("path", "kind", "sha256")}, "diagnostic": extra}
            report["runs"] = [{"id": "failed-real-shape", "report": "collector"}]
            self.rejected_acceptance(report, message)
        report = self.acceptance()
        report["artifacts"] = {"collector": {key: collector[key] for key in ("path", "kind", "sha256")}}
        report["runs"] = [{"id": "failed-real-shape", "report": "collector"}]
        self.rejected_acceptance(report, "retain full original collector inventory")

    def test_current_producer_empty_unified_stderr_requires_original_inventory_context(self):
        for phase in ("saved", "recovered", "confirmed"):
            for kind in ("driver-raw-evidence", "raw-native-diagnostics"):
                with self.subTest(phase=phase, kind=kind):
                    ref = self.empty_reference(phase + "/unified.stream.stderr.log", kind)
                    self.assertEqual(self.validator.native_inventory(self.collector([ref]))[str(self.root / ref["path"])]["raw"], b"")
                    with self.assertRaises(gate.EvidenceError):
                        self.validator.raw(ref)

    def ios_motion_observation(self):
        return {"check": {"id": "N7.reduced-motion-semantics", "configuration": "demo", "transport": "controlled-http-simulated"},
                "before": {}, "after": {"model": {}, "mediaQuery": {"disableAnimations": False},
                                           "platformAccessibility": {"platform": "ios", "reduceMotion": True},
                                           "bounds": {"online-toggle": [{"centerHit": True}]}},
                "run": {"platform": "ios", "commands": [
                    {"argv": ["xcrun", "simctl", "spawn", "owned-device", "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled", "-bool", "YES"], "exit_code": 0},
                    {"argv": ["xcrun", "simctl", "spawn", "owned-device", "defaults", "read", "com.apple.Accessibility", "ReduceMotionEnabled"], "exit_code": 0, "stdout": "1\n"}]},
                "journal": [], "actions": ["semantics-probe:zoom-in"],
                "action_records": [{"action": "semantics-probe:zoom-in", "stage": "completed", "response": 7}]}

    def test_ios_actual_reduce_motion_flag_accepts_and_preserves_false_mediaquery(self):
        value = self.ios_motion_observation()
        self.validator.native_minimum(value)
        self.assertIs(value["after"]["mediaQuery"]["disableAnimations"], False)
        # Typed raw predicates consume the actual platform observation and the
        # unchanged Flutter value, rather than synthesizing disableAnimations.
        artifacts = {"after": self.artifact("motion.json", "ui-snapshot", value["after"])}
        for pointer, expected in (("/platformAccessibility/platform", "ios"), ("/platformAccessibility/reduceMotion", True), ("/mediaQuery/disableAnimations", False)):
            self.validator.assertion({"artifact": "after", "pointer": pointer, "op": "eq", "value": expected}, artifacts)

    def test_ios_missing_false_or_wrong_platform_flag_cannot_be_waived_by_mediaquery_true(self):
        for change in (
            lambda after: after["platformAccessibility"].update(reduceMotion=False),
            lambda after: after["platformAccessibility"].pop("reduceMotion"),
            lambda after: after["platformAccessibility"].update(reduceMotion=1),
            lambda after: after["platformAccessibility"].update(platform="android"),
            lambda after: after["platformAccessibility"].pop("platform"),
            lambda after: after.pop("platformAccessibility"),
        ):
            value = self.ios_motion_observation()
            value["after"]["mediaQuery"]["disableAnimations"] = True
            change(value["after"])
            with self.subTest(after=value["after"]), self.assertRaises(gate.EvidenceError):
                self.validator.native_minimum(value)

    def test_actual_ios_motion_still_requires_os_receipts_and_typed_semantics_responses(self):
        for mutation in (
            lambda value: value["run"].update(commands=[]),
            lambda value: value["run"]["commands"].pop(0),
            lambda value: value["run"]["commands"].pop(1),
            lambda value: value["run"]["commands"][1].update(stdout="0\n"),
            lambda value: value.update(actions=[]),
            lambda value: value.update(action_records=[]),
            lambda value: value["action_records"][0].update(response=True),
            lambda value: value["action_records"][0].pop("response"),
            lambda value: value["action_records"][0].update(response=-1),
        ):
            value = self.ios_motion_observation()
            mutation(value)
            with self.subTest(value=value), self.assertRaises(gate.EvidenceError):
                self.validator.native_minimum(value)

    def test_android_motion_cannot_substitute_ios_flag_for_actual_disable_animations(self):
        value = self.ios_motion_observation()
        value["run"]["platform"] = "android"
        value["after"]["platformAccessibility"]["platform"] = "android"
        with self.assertRaises(gate.EvidenceError) as caught:
            self.validator.native_minimum(value)
        self.assertIn("actual Android disableAnimations", str(caught.exception))

    def test_native_protocol5_aggregate_and_raw_phase_receipt_are_rejected(self):
        report = self.acceptance()
        report["revision"] = 5
        self.rejected_acceptance(report, "native acceptance revision")
        check, runs, artifacts = self.first_import_graph()
        old = gate._json(artifacts["receipt"]["raw"], "phase receipt")
        old["revision"] = 5
        artifacts["receipt"] = self.artifact("receipt.json", "e08-phase-receipt", old)
        runs["run"]["_verified_artifacts"][str(artifacts["receipt"]["path_object"])] = artifacts["receipt"]["sha256"]
        with self.assertRaises(gate.EvidenceError) as caught:
            self.validator.native_check(check, runs, artifacts)
        self.assertIn("phase receipt revision", str(caught.exception))

    def acceptance(self):
        return {
            "schema": 1, "revision": 6, "candidate": self.fp, "status": "passed",
            "scope": "full-native-functional", "platform": "ios", "process_restart": True,
            "independent_review": {"task": "synthetic-independent", "reviewer": "synthetic-reviewer", "product_author": False},
            "contract": self.contract_ref, "artifacts": {}, "runs": [],
            "cases": {case: {"status": "passed", "checks": [{"id": key, "status": "passed"} for key in ids]} for case, ids in self.contract["cases"].items()},
            "requirements": copy.deepcopy(self.contract["requirements"]),
        }

    def rejected_acceptance(self, report, text):
        item = self.artifact("acceptance.json", "native-acceptance", report)
        with self.assertRaises(gate.EvidenceError) as caught:
            self.validator.native(report, item)
        self.assertIn(text, str(caught.exception))

    def test_all_34_checks_and_all_14_requirement_bindings_are_mandatory(self):
        self.assertEqual(sum(len(ids) for ids in self.contract["cases"].values()), 34)
        self.assertEqual(set(self.contract["requirements"]), {f"R{i:02d}" for i in range(1, 15)})
        for case, ids in self.contract["cases"].items():
            for key in ids:
                with self.subTest(key=key):
                    report = self.acceptance()
                    report["cases"][case]["checks"] = [value for value in report["cases"][case]["checks"] if value["id"] != key]
                    self.rejected_acceptance(report, case + " exact checks")
        for requirement in self.contract["requirements"]:
            with self.subTest(requirement=requirement):
                report = self.acceptance()
                report["requirements"][requirement] = []
                self.rejected_acceptance(report, "exact R01-R14")

    def test_partial_check_duplicate_check_and_self_authored_review_reject(self):
        for status in ("blocked", "not_run", "failed", "not_applicable", True):
            report = self.acceptance()
            report["cases"]["N7"]["checks"][1]["status"] = status
            self.rejected_acceptance(report, "N7.os-keyboard status")
        report = self.acceptance()
        report["cases"]["N1"]["checks"].append(copy.deepcopy(report["cases"]["N1"]["checks"][0]))
        self.rejected_acceptance(report, "N1 exact checks")
        report = self.acceptance()
        report["independent_review"]["product_author"] = True
        self.rejected_acceptance(report, "product_author")

    def test_current_authoritative_contract_cannot_be_reduced_or_renamed(self):
        altered = copy.deepcopy(self.contract)
        altered["cases"]["N7"] = []
        ref = self.fixture.evidence("contract.json", "native-contract", json.dumps(altered))
        report = self.acceptance()
        report["contract"] = ref
        self.rejected_acceptance(report, "authoritative current source")

    def test_complete_status_graph_without_raw_runs_is_not_acceptance(self):
        self.rejected_acceptance(self.acceptance(), "native runs")

    def test_canonical_paths_reject_traversal_symlinks_and_outside_even_with_correct_hash(self):
        item = self.fixture.evidence("raw.json", "raw-json", "{}")
        for path in ("../raw.json", str(self.root.parent / "raw.json")):
            with self.subTest(path=path), self.assertRaises(gate.EvidenceError):
                self.validator.raw({**item, "path": path})
        (self.root / "link.json").symlink_to(self.root / "raw.json")
        with self.assertRaises(gate.EvidenceError):
            self.validator.raw({**item, "path": "link.json"})
        (self.root / "link-dir").symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(gate.EvidenceError):
            self.validator.raw({**item, "path": "link-dir/raw.json"})

    def test_duplicate_json_keys_nonfinite_values_and_truncated_jsonl_reject(self):
        for raw in ('{"candidate":"one","candidate":"two"}', '{"x":NaN}', '{"x":Infinity}', '{"x":1e309}', '{"x":'):
            with self.subTest(raw=raw), self.assertRaises(gate.EvidenceError):
                gate._json(raw, "raw")
        with self.assertRaises(gate.EvidenceError):
            self.validator.jsonl(self.artifact("actions.jsonl", "ui-actions", '{"sequence":1}'))
        with self.assertRaises(gate.EvidenceError):
            self.validator.jsonl(self.artifact("actions.jsonl", "ui-actions", '{"sequence":1}\n{'))

    def test_hash_edit_and_hash_valid_png_truncation_or_wrong_dimensions_reject(self):
        ref = self.fixture.evidence("os.png", "os-screenshot", png(10, 20))
        self.assertEqual(self.validator.png(self.validator.raw(ref)), (10, 20))
        (self.root / "os.png").write_bytes(png(10, 21))
        with self.assertRaises(gate.EvidenceError):
            self.validator.raw(ref)
        for raw in (png(10, 20)[:-1], png(10, 20) + b"suffix", b"fake PNG"):
            with self.subTest(length=len(raw)), self.assertRaises((gate.EvidenceError, struct.error)):
                self.validator.png(self.artifact("bad.png", "os-screenshot", raw))

    def test_typed_pointer_assertions_join_raw_artifacts_and_reject_bool_numeric_confusion(self):
        artifacts = {"before": self.artifact("before.json", "ui-snapshot", {"operation": "op-a", "count": 2}),
                     "after": self.artifact("after.json", "ui-snapshot", {"operation": "op-a", "count": 3})}
        self.validator.assertion({"artifact": "after", "pointer": "/operation", "op": "eq", "right": {"artifact": "before", "pointer": "/operation"}}, artifacts)
        self.validator.assertion({"artifact": "after", "pointer": "/count", "op": "gte", "right": {"artifact": "before", "pointer": "/count"}}, artifacts)
        for assertion in (
            {"artifact": "after", "pointer": "/count", "op": "eq", "value": True},
            {"artifact": "after", "pointer": "/count", "op": "gte", "value": True},
            {"artifact": "after", "pointer": "/missing", "op": "eq", "value": None},
            {"artifact": "after", "pointer": "/operation", "op": "eq", "value": "op-a", "right": {"artifact": "before", "pointer": "/operation"}},
        ):
            with self.subTest(assertion=assertion), self.assertRaises(gate.EvidenceError):
                self.validator.assertion(assertion, artifacts)

    def test_held_out_hash_valid_cross_mode_pid_session_graph_is_rejected(self):
        expected = {"candidate": self.fp, "processId": 10, "vmProcessId": 10, "configuration": "demo", "session": "session-demo"}
        # All three files have correct hashes; identity joins still reject them.
        for name, changes in (("mode", {"configuration": "local-client"}), ("pid", {"processId": 20, "vmProcessId": 20}), ("session", {"session": "session-other"})):
            item = self.artifact(name + ".json", "raw-native", {**expected, **changes})
            raw = gate._json(item["raw"], name)
            with self.subTest(name=name), self.assertRaises(gate.EvidenceError):
                self.validator.identity(raw, expected, vm=True)
        for field in ("processId", "vmProcessId"):
            with self.subTest(field=field), self.assertRaises(gate.EvidenceError):
                self.validator.identity({**expected, field: True}, expected, vm=True)

    def sqlite_file(self, name, version=2):
        path = self.root / name
        with sqlite3.connect(path) as connection:
            connection.executescript('CREATE TABLE datasets(id TEXT PRIMARY KEY); CREATE TABLE stops(id TEXT PRIMARY KEY,status TEXT); CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT);')
            if version == 2:
                connection.execute('CREATE TABLE delivery_settings(dataset_id TEXT PRIMARY KEY,online INTEGER)')
            connection.execute('INSERT INTO datasets VALUES(?)', ("dataset",))
            connection.execute('INSERT INTO stops VALUES(?,?)', ("stop", "completed"))
            connection.execute('INSERT INTO outbox VALUES(?,?)', (22, "deleted-highest"))
            connection.execute('DELETE FROM outbox')
            connection.execute(f'PRAGMA user_version={version}')
        return self.validator.raw({"path": name, "kind": "sqlite-backup", "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})

    def test_readonly_actual_sqlite_preserves_deleted_high_water_and_rejects_fake_json_backup(self):
        for version in (1, 2):
            raw = self.sqlite_file(f"v{version}.sqlite", version)
            before = raw["path_object"].read_bytes()
            parsed = self.validator.database(raw)
            self.assertEqual(parsed["version"], version)
            self.assertEqual(parsed["sequences"]["outbox"], 22)
            self.assertEqual(raw["path_object"].read_bytes(), before)
            self.assertNotIn("delivery_settings", parsed["tables"] if version == 1 else {})
        with self.assertRaises(gate.EvidenceError):
            self.validator.database(self.artifact("fake.sqlite", "sqlite-backup", {"user_version": 2, "tables": {}}))

    def first_import_graph(self):
        import csv
        with (gate.SOURCE_ROOT / "app/assets/deliveries.csv").open() as source:
            rows = list(csv.DictReader(source))
        database_path = self.root / "native.sqlite"
        with sqlite3.connect(database_path) as connection:
            connection.executescript("""
                CREATE TABLE datasets(id TEXT PRIMARY KEY);
                CREATE TABLE stops(id TEXT PRIMARY KEY,dataset_id TEXT,reference TEXT,customer_name TEXT,address TEXT,latitude REAL,longitude REAL,status TEXT,reason TEXT,time_window TEXT,note TEXT,recorded_at INTEGER,operation_id TEXT,acknowledged_at INTEGER);
                CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT,dataset_id TEXT,stop_id TEXT,status TEXT,reason TEXT,note TEXT,recorded_at INTEGER);
                CREATE TABLE delivery_settings(dataset_id TEXT PRIMARY KEY,online INTEGER,viewport_latitude REAL,viewport_longitude REAL,viewport_zoom REAL);
                INSERT INTO datasets VALUES('dataset');
                INSERT INTO delivery_settings VALUES('dataset',1,NULL,NULL,NULL);
                PRAGMA user_version=2;
            """)
            for index, row in enumerate(rows):
                connection.execute('INSERT INTO stops VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)', (f"stop-{index}", "dataset", row["reference"], row["customer_name"], row["address"], float(row["latitude"]), float(row["longitude"]), row["status"], None, row["time_window"], None, None, None, None))
        db_ref = {"path": "native.sqlite", "kind": "sqlite-backup", "sha256": hashlib.sha256(database_path.read_bytes()).hexdigest()}
        database = self.validator.database(self.validator.raw(db_ref))
        identity = {"candidate": self.fp, "processId": 123, "configuration": "demo", "session": "actual-synthetic-session"}
        snapshot = {"schema": 1, **identity, "mode": "demo", "transport": "controlled-http-simulated", "databasePath": "/same-install/Documents/ocean_delivery-demo.sqlite", "observedAt": "2026-10-10T10:00:00+00:00", "outbox": [], "persistedSettings": {"datasetId": "dataset", "online": True, "viewport": None}, "model": {"initialized": True, "queueCount": 0, "pendingCount": sum(row["status"] == "pending" for row in rows), "online": True, "panel": "map", "selected": None}, "mediaQuery": {"width": 10, "height": 20, "devicePixelRatio": 1.0}, "persistedStops": []}
        for index, row in enumerate(rows):
            snapshot["persistedStops"].append({"id": f"stop-{index}", "reference": row["reference"], "customerName": row["customer_name"], "address": row["address"], "latitude": float(row["latitude"]), "longitude": float(row["longitude"]), "status": row["status"], "reason": None, "timeWindow": row["time_window"], "note": None, "recordedAt": None, "operationId": None, "acknowledgedAt": None})
        check = {"id": "N1.first-import", "status": "passed", **identity, "vmProcessId": 123, "run": "run", "phase": "saved", "transport": snapshot["transport"], "receipt": "receipt", "actions": "actions", "action_sequences": [1], "observations": "observations", "before": "before", "after": "after", "capture": {"png": "png", "sqlite": "sqlite", "projection": "projection", "journal": "journal"}, "assertions": [{"artifact": "after", "pointer": "/persistedStops", "op": "length", "value": 30}]}
        artifacts = {"sqlite": self.validator.raw(db_ref)}
        artifacts["before"] = self.artifact("before.json", "ui-snapshot", snapshot)
        artifacts["after"] = self.artifact("after.json", "ui-snapshot", snapshot)
        artifacts["png"] = self.artifact("os.png", "os-screenshot", png(10, 20))
        artifacts["projection"] = self.artifact("projection.json", "sqlite-projection", {"path": "native.sqlite", "sha256": db_ref["sha256"], "user_version": 2, "schema": database["schema"], "tables": database["tables"], "triggers": [], "sqlite_sequence": []})
        event = {**identity, "source": "repository", "stage": "import_committed", "observedAt": snapshot["observedAt"]}
        artifacts["journal"] = self.artifact("journal.jsonl", "repository-coordinator-journal", json.dumps(event) + "\n")
        actions = [{**identity, "vmProcessId": 123, "sequence": 1, "action": "snapshot", "stage": stage} for stage in ("started", "completed")]
        artifacts["actions"] = self.artifact("actions.jsonl", "ui-actions", "".join(json.dumps(value) + "\n" for value in actions))
        artifacts["observations"] = self.artifact("observations.jsonl", "ui-observations", json.dumps(snapshot) + "\n")
        receipt = {"schema": 1, "revision": 6, **identity, "vmProcessId": 123, "checks": [{"id": check["id"], "status": "passed", "before": "before.json", "after": "after.json", "actionSequenceStart": 1, "actionSequenceEnd": 1, "capture": {"png": "os.png", "sqlite": "native.sqlite", "projection": "projection.json", "journal": "journal.jsonl"}, "assertions": [{"artifact": "after.json", "pointer": "/persistedStops", "op": "length", "value": 30}]}]}
        artifacts["receipt"] = self.artifact("receipt.json", "e08-phase-receipt", receipt)
        run = {"configuration": "demo", "data_container": "/same-install", "launches": [{"phase": "saved", **identity}], "_evidence_owner": self.root, "_verified_artifacts": {str(item["path_object"]): item["sha256"] for item in artifacts.values()}}
        return check, {"run": run}, artifacts

    def test_complete_first_import_raw_subgraph_passes_without_claiming_full_acceptance(self):
        check, runs, artifacts = self.first_import_graph()
        accepted = self.validator.native_check(check, runs, artifacts)
        self.assertEqual(accepted["check"]["id"], "N1.first-import")
        # This single check cannot satisfy G2's other33 native requirements.
        self.rejected_acceptance(self.acceptance(), "native runs")

    def test_hash_valid_projection_action_and_capture_mutations_reject_raw_subgraph(self):
        for mutation, text in (("projection", "actual SQLite"), ("actions", "completed exactly once"), ("png", "PNG dimensions"), ("pid", "identity"), ("receipt", "raw phase check status")):
            with self.subTest(mutation=mutation):
                # Each mutation starts from a fresh fixture/file set.
                (self.root / "native.sqlite").unlink(missing_ok=True)
                check, runs, artifacts = self.first_import_graph()
                if mutation == "projection":
                    value = gate._json(artifacts["projection"]["raw"], "projection")
                    value["tables"]["outbox"] = [{"seq": 9}]
                    artifacts["projection"] = self.artifact("projection.json", "sqlite-projection", value)
                elif mutation == "actions":
                    value = self.validator.jsonl(artifacts["actions"])
                    artifacts["actions"] = self.artifact("actions.jsonl", "ui-actions", json.dumps(value[0]) + "\n")
                elif mutation == "png":
                    artifacts["png"] = self.artifact("os.png", "os-screenshot", png(10, 25))
                elif mutation == "pid":
                    value = gate._json(artifacts["after"]["raw"], "snapshot")
                    value["processId"] = 321
                    artifacts["after"] = self.artifact("after.json", "ui-snapshot", value)
                else:
                    value = gate._json(artifacts["receipt"]["raw"], "receipt")
                    value["checks"][0]["status"] = "blocked"
                    artifacts["receipt"] = self.artifact("receipt.json", "e08-phase-receipt", value)
                # All rewritten references and collector hashes match. Raw
                # semantic inconsistency must still reject, not only old SHA.
                runs["run"]["_verified_artifacts"] = {str(item["path_object"]): item["sha256"] for item in artifacts.values()}
                with self.assertRaises(gate.EvidenceError) as caught:
                    self.validator.native_check(check, runs, artifacts)
                self.assertIn(text, str(caught.exception))

    def test_owned_log_stream_term_receipts_do_not_waive_nonzero_business_commands(self):
        stream = {"argv": ["xcrun", "simctl", "spawn", "device", "log", "stream", "--style", "json", "--process", "Runner", "--predicate", "task app"], "phase": "saved", "reader_pid": 500, "reaped": True, "exit_code": 143}
        self.validator.native_command(stream)
        self.validator.native_command({**stream, "exit_code": -15})
        for command in ({**stream, "reaped": False}, {**stream, "exit_code": 1}, {**stream, "reader_pid": True}, {**stream, "argv": ["dart", "run", "driver.dart"], "exit_code": 143}, {"argv": ["xcrun", "simctl", "launch"], "exit_code": False}):
            with self.subTest(command=command), self.assertRaises(gate.EvidenceError):
                self.validator.native_command(command)

    def test_raw_capture_substitution_and_omitted_independent_assertions_do_not_pass(self):
        check, runs, artifacts = self.first_import_graph()
        # Both same-size PNGs have valid bytes and current collector inventory;
        # the raw independent check named the original capture only.
        artifacts["other-png"] = self.artifact("other.png", "os-screenshot", png(10, 20))
        runs["run"]["_verified_artifacts"][str(artifacts["other-png"]["path_object"])] = artifacts["other-png"]["sha256"]
        check["capture"]["png"] = "other-png"
        with self.assertRaises(gate.EvidenceError) as caught:
            self.validator.native_check(check, runs, artifacts)
        self.assertIn("raw phase exact capture", str(caught.exception))
        check["capture"]["png"] = "png"
        raw = gate._json(artifacts["receipt"]["raw"], "receipt")
        raw["checks"][0]["assertions"] = [{"artifact": "after.json", "pointer": "/model/online", "op": "eq", "value": False}]
        artifacts["receipt"] = self.artifact("receipt.json", "e08-phase-receipt", raw)
        runs["run"]["_verified_artifacts"][str(artifacts["receipt"]["path_object"])] = artifacts["receipt"]["sha256"]
        # Aggregate has only a true assertion; raw declared false still rejects.
        check["assertions"] = [{"artifact": "after", "pointer": "/model/online", "op": "eq", "value": True}]
        with self.assertRaises(gate.EvidenceError) as caught:
            self.validator.native_check(check, runs, artifacts)
        self.assertIn("assertion /model/online", str(caught.exception))

    def test_arbitrary_true_assertion_cannot_waive_owned_keyboard_predicate(self):
        value = {"check": {"id": "N7.os-keyboard", "configuration": "demo", "transport": "controlled-http-simulated"},
                 "before": {}, "after": {"model": {}, "mediaQuery": {"viewInsets": {"bottom": 0}}}, "journal": [], "actions": ["tap:failure-save"]}
        with self.assertRaises((gate.EvidenceError, KeyError)):
            self.validator.native_minimum(value)


if __name__ == "__main__":
    unittest.main()
