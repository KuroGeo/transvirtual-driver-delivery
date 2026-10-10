import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from harness.gate import CAPABILITIES, EvidenceError, GATES, SOURCE_ROOT, Validator, evaluate, evaluate_local


class GateTests(unittest.TestCase):
    """Synthetic reports validate gate rejection logic, not product readiness."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.fingerprint = "a" * 64
        self.manifest = {
            "candidate": {"source_fingerprint": self.fingerprint},
            "enforcement_deployed": True,
            "service_mode": "connected",
            "harness": {}, "gates": {},
        }
        for group, ids, status in (
            ("harness", CAPABILITIES, "demonstrated"), ("gates", GATES, "passed"),
        ):
            for entry_id in ids:
                self.manifest[group][entry_id] = {
                    "status": status, "candidate": self.fingerprint,
                    "evidence": [self.evidence(f"{entry_id}.log", "raw-log", f"synthetic {entry_id} fixture\n")],
                }
        for entry_id, kind, fields in (
            ("H06", "ci-enforcement", {"enforced": True}),
            ("H06", "release-enforcement", {"enforced": True}),
            ("G2", "native-acceptance", {"platform": "ios", "process_restart": True}),
            ("G3", "performance", {"device_type": "real", "build_mode": "profile"}),
            ("G4", "connected-service", {"transport": "connected"}),
        ):
            self.add_report(entry_id, kind, fields)
        self.quality = {
            "command": "quality",
            "candidate": {"source_fingerprint": self.fingerprint},
            "candidate_after": {"source_fingerprint": self.fingerprint},
            "execution_candidate_after": {"source_fingerprint": self.fingerprint},
            "started_at": "2026-10-10T10:00:00+00:00",
            "finished_at": "2026-10-10T10:01:00+00:00",
            "execution_root": str(self.root / "execution"),
            "source_root": str(SOURCE_ROOT),
            "options": {"configuration": "local-client", "targets": []},
            "isolation": {"requested": True, "task_owned": True, "cleaned": True, "verified_fingerprint": self.fingerprint},
            "lease": {"status": "released"},
            "inputs": {"flutter": json.loads((SOURCE_ROOT / "app/.fvmrc").read_text())["flutter"], "lock_sha256": hashlib.sha256((SOURCE_ROOT / "app/pubspec.lock").read_bytes()).hexdigest(), "asset_sha256": hashlib.sha256((SOURCE_ROOT / "app/assets/deliveries.csv").read_bytes()).hexdigest()},
            "stage_spec": [],
            "job": {"status": "passed"},
            "stages": [],
        }
        commands = {
            "repository": ["python3", "harness/run.py", "_check"],
            "tooling-tests": ["python3", "-m", "unittest", "discover", "-s", "harness/tests", "-v"],
            "sdk": ["python3", "harness/run.py", "_sdk"],
            "pub": ["flutter", "pub", "get", "--enforce-lockfile"],
            "format": ["dart", "format", "--output=none", "--set-exit-if-changed", "lib", "test", "integration_test"],
            "analyze": ["flutter", "analyze", "--no-pub"],
            "flutter-tests": ["flutter", "test", "--no-pub", "--reporter", "expanded", "--dart-define=OCEAN_MODE=local-client"],
        }
        for stage_id, command in commands.items():
            text = "synthetic passed stage\n"
            if stage_id == "tooling-tests":
                text = "Ran 9 tests in 0.02s\n\nOK\n"
            if stage_id == "flutter-tests":
                text = "00:01 +9: All tests passed!\n"
            log = self.evidence(f"quality-{stage_id}.log", "raw-log", text)
            cwd = self.quality["execution_root"] + ("/app" if stage_id in ("pub", "format", "analyze", "flutter-tests") else "")
            self.quality["stages"].append({"id": stage_id, "status": "passed", "exit_code": 0, "job_pid": 99, "command": command, "cwd": cwd, "log_path": log["path"], "sha256": log["sha256"]})
            self.quality["stage_spec"].append({"id": stage_id, "command": command, "cwd": cwd.replace(self.quality["execution_root"], "@workspace")})
        self.entry("G1")["evidence"].append(self.evidence("quality.json", "quality-run", json.dumps(self.quality)))
        artifact = self.evidence("release.bin", "release-artifact", b"synthetic release artifact")
        self.manifest["gates"]["G5"]["evidence"].append(artifact)
        self.add_report("G5", "release-signature", {
            "build_mode": "release", "signed": True, "signing_kind": "production",
            "artifact_sha256": artifact["sha256"],
        })
        self.add_report("G6", "authorization-receipt", {"authorized": True, "destination": "synthetic://test"})
        self.add_report("G6", "delivery-receipt", {
            "delivered": True, "destination": "synthetic://test", "artifact_sha256": artifact["sha256"],
        })

    def tearDown(self):
        self.temp.cleanup()

    def evidence(self, name, kind, value):
        raw = value.encode() if isinstance(value, str) else value
        (self.root / name).write_bytes(raw)
        return {"path": name, "kind": kind, "sha256": hashlib.sha256(raw).hexdigest()}

    def entry(self, entry_id):
        group = "harness" if entry_id.startswith("H") else "gates"
        return self.manifest[group][entry_id]

    def add_report(self, entry_id, kind, fields):
        report = {"candidate": self.fingerprint, "status": "passed", **fields}
        item = self.evidence(f"{kind}.json", kind, json.dumps(report))
        self.entry(entry_id)["evidence"].append(item)

    def change_report(self, entry_id, kind, changes):
        item = next(value for value in self.entry(entry_id)["evidence"] if value["kind"] == kind)
        path = self.root / item["path"]
        report = json.loads(path.read_bytes())
        report.update(changes)
        raw = json.dumps(report).encode()
        path.write_bytes(raw)
        item["sha256"] = hashlib.sha256(raw).hexdigest()

    def assert_rejected(self, reason, manifest=None, fingerprint=None):
        result = evaluate(manifest or self.manifest, fingerprint or self.fingerprint, self.root)
        self.assertFalse(result["allowed"], result)
        self.assertTrue(any(reason in value for value in result["reasons"]), result)
        return result

    def settings_snapshot(self, name, rows=(), datasets=("dataset-fixture",)):
        """Read genuine SQLite through the immutable evidence reader."""
        path = self.root / (name + ".sqlite")
        with sqlite3.connect(path) as connection:
            connection.executescript("""
                PRAGMA user_version=2;
                CREATE TABLE datasets (id TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE stops (
                    id TEXT PRIMARY KEY NOT NULL,
                    dataset_id TEXT NOT NULL REFERENCES datasets(id),
                    reference TEXT NOT NULL, customer_name TEXT NOT NULL,
                    address TEXT NOT NULL, latitude REAL NOT NULL,
                    longitude REAL NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('pending','completed','failed')),
                    reason TEXT, time_window TEXT, note TEXT,
                    recorded_at INTEGER, operation_id TEXT UNIQUE,
                    acknowledged_at INTEGER,
                    UNIQUE(dataset_id,reference), UNIQUE(dataset_id,id)
                );
                CREATE TABLE outbox (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    operation_id TEXT NOT NULL UNIQUE, dataset_id TEXT NOT NULL,
                    stop_id TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('completed','failed')),
                    reason TEXT, note TEXT, recorded_at INTEGER,
                    FOREIGN KEY(dataset_id,stop_id) REFERENCES stops(dataset_id,id)
                );
                CREATE TABLE delivery_settings (
                    dataset_id TEXT PRIMARY KEY NOT NULL REFERENCES datasets(id),
                    online INTEGER NOT NULL DEFAULT 1 CHECK (online IN (0,1)),
                    viewport_latitude REAL, viewport_longitude REAL, viewport_zoom REAL
                );
            """)
            connection.executemany("INSERT INTO datasets VALUES (?)", [(value,) for value in datasets])
            connection.execute("""
                INSERT INTO stops (id,dataset_id,reference,customer_name,address,
                                   latitude,longitude,status,time_window)
                VALUES ('stop-fixture','dataset-fixture','fixture-ref','Fixture',
                        'Fixture address',-33.87,151.21,'pending','09:00–12:00')
            """)
            connection.executemany("INSERT INTO delivery_settings VALUES (?,?,?,?,?)", rows)
        raw = path.read_bytes()
        validator = Validator(self.manifest, self.fingerprint, self.root)
        item = validator.raw({"path": path.name, "kind": "sqlite-backup", "sha256": hashlib.sha256(raw).hexdigest()})
        database = validator.database(item)
        snapshot = {
            "outbox": [],
            "persistedStops": [{"id": "stop-fixture", "status": "pending", "reason": None,
                                "note": None, "operationId": None, "recordedAt": None,
                                "acknowledgedAt": None, "timeWindow": "09:00–12:00"}],
            "persistedSettings": {"datasetId": "dataset-fixture", "online": True, "viewport": None},
        }
        self.assertEqual(path.read_bytes(), raw)
        return validator, snapshot, database

    def test_empty_settings_accept_only_current_sql_dataset_canonical_defaults(self):
        validator, snapshot, database = self.settings_snapshot("default-settings")
        self.assertEqual(database["tables"]["delivery_settings"], [])
        validator.snapshot_database(snapshot, database)
        for field, value in (
            ("online", False), ("online", 1),
            ("datasetId", "forged-dataset"),
            ("viewport", {"datasetId": "dataset-fixture", "latitude": -33.87,
                          "longitude": 151.21, "zoom": 15.0}),
        ):
            with self.subTest(field=field, value=value):
                forged = copy.deepcopy(snapshot)
                forged["persistedSettings"][field] = value
                with self.assertRaisesRegex(EvidenceError, "persisted settings vs actual SQLite"):
                    validator.snapshot_database(forged, database)

    def test_settings_require_unambiguous_actual_dataset_and_at_most_one_row(self):
        for name, datasets, rows, message in (
            ("missing-dataset", (), (), "actual SQLite datasets"),
            ("multiple-datasets", ("dataset-fixture", "other"), (), "exactly one current SQLite dataset"),
            ("multiple-settings", ("dataset-fixture",),
             (("dataset-fixture", 1, None, None, None), ("other", 0, None, None, None)),
             "at most one persisted dataset settings row"),
            ("foreign-settings", ("dataset-fixture",), (("other", 1, None, None, None),),
             "persisted settings current SQLite dataset"),
        ):
            with self.subTest(name=name):
                validator, snapshot, database = self.settings_snapshot(name, rows, datasets)
                with self.assertRaisesRegex(EvidenceError, message):
                    validator.snapshot_database(snapshot, database)

    def test_persisted_settings_retain_online_and_validated_viewport_rules(self):
        for index, (online, coordinates, viewport) in enumerate((
            (0, (None, None, None), None),
            (1, (-33.87, 151.21, 15.0), {"datasetId": "dataset-fixture", "latitude": -33.87,
                                       "longitude": 151.21, "zoom": 15.0}),
            (0, (100.0, 151.21, 15.0), None),
            (1, (-33.87, 151.21, 23.0), None),
            (1, (-33.87, None, 15.0), None),
            (1, (float("inf"), 151.21, 15.0), None),
        )):
            with self.subTest(online=online, coordinates=coordinates):
                row = ("dataset-fixture", online, *coordinates)
                validator, snapshot, database = self.settings_snapshot("persisted-settings-" + str(index), (row,))
                snapshot["persistedSettings"].update(online=bool(online), viewport=viewport)
                validator.snapshot_database(snapshot, database)
                forged = copy.deepcopy(snapshot)
                forged["persistedSettings"]["online"] = not bool(online)
                with self.assertRaisesRegex(EvidenceError, "persisted settings vs actual SQLite"):
                    validator.snapshot_database(forged, database)
                forged["persistedSettings"]["online"] = bool(online)
                forged["persistedSettings"]["viewport"] = None if viewport is not None else {
                    "datasetId": "dataset-fixture", "latitude": -33.87,
                    "longitude": 151.21, "zoom": 15.0,
                }
                with self.assertRaisesRegex(EvidenceError, "persisted settings vs actual SQLite"):
                    validator.snapshot_database(forged, database)

    def test_complete_synthetic_fixture_only_validates_schema(self):
        # A complete full-quality schema can pass its own validator. The old
        # platform/restart-only native fixture remains insufficient for G2.
        validator = Validator(self.manifest, self.fingerprint, self.root)
        item = next(item for item in self.entry("G1")["evidence"] if item["kind"] == "quality-run")
        self.assertEqual(validator.quality(self.quality, validator.raw(item)), self.quality)
        self.assert_rejected("native acceptance schema")

    def test_every_required_capability_and_gate_rejects_missing_entry(self):
        for group, ids in (("harness", CAPABILITIES), ("gates", GATES)):
            for entry_id in ids:
                with self.subTest(entry_id=entry_id):
                    manifest = copy.deepcopy(self.manifest)
                    del manifest[group][entry_id]
                    self.assert_rejected(f"{group}.{entry_id} is missing", manifest)

    def test_every_required_status_rejects_unknown_failed_skipped_and_stale(self):
        for group, ids in (("harness", CAPABILITIES), ("gates", GATES)):
            for entry_id in ids:
                for status in ("unknown", "failed", "skipped", "stale", "partial", "not_applicable"):
                    with self.subTest(entry_id=entry_id, status=status):
                        manifest = copy.deepcopy(self.manifest)
                        manifest[group][entry_id]["status"] = status
                        self.assert_rejected(f"{group}.{entry_id}.status", manifest)

    def test_candidate_changes_invalidate_all_old_evidence(self):
        self.assert_rejected("candidate.source_fingerprint", fingerprint="b" * 64)
        for group, ids in (("harness", CAPABILITIES), ("gates", GATES)):
            for entry_id in ids:
                with self.subTest(entry_id=entry_id):
                    manifest = copy.deepcopy(self.manifest)
                    manifest[group][entry_id]["candidate"] = "old-source"
                    self.assert_rejected(f"{group}.{entry_id}.candidate", manifest)

    def test_missing_evidence_unknown_files_and_hash_mismatch_fail(self):
        for evidence, expected in (
            ([], "evidence is missing"),
            ([{"path": "gone.log", "kind": "raw-log", "sha256": "0"}], "SHA-256"),
            ([{"path": "H01.log", "kind": "raw-log", "sha256": "0"}], "SHA-256"),
            ([{"path": "H01.log", "sha256": "0"}], "requires path, sha256 and kind"),
        ):
            with self.subTest(expected=expected):
                manifest = copy.deepcopy(self.manifest)
                manifest["harness"]["H01"]["evidence"] = evidence
                self.assert_rejected(expected, manifest)

    def test_claimed_enforcement_does_not_override_missing_ci_or_release_proof(self):
        self.manifest["enforcement_deployed"] = False
        self.assert_rejected("enforcement_deployed")
        self.manifest["enforcement_deployed"] = True
        for kind in ("ci-enforcement", "release-enforcement"):
            with self.subTest(kind=kind):
                self.change_report("H06", kind, {"enforced": False})
                self.assert_rejected("enforced must be True")
                self.change_report("H06", kind, {"enforced": True})
        self.entry("H06")["evidence"] = [self.entry("H06")["evidence"][0]]
        self.assert_rejected("H06 requires valid ci-enforcement")

    def test_passed_envelope_cannot_override_failed_stale_or_incomplete_quality(self):
        item = next(value for value in self.entry("G1")["evidence"] if value["kind"] == "quality-run")
        for change, expected in (
            (lambda r: r.update(candidate={"source_fingerprint": "old-source"}), "candidate is missing or stale"),
            (lambda r: r.update(candidate_after={"source_fingerprint": "changed-source"}), "candidate_after is missing or stale"),
            (lambda r: r.update(job={"status": "failed"}), "job.status must be 'passed'"),
            (lambda r: r.update(command="test"), "command must be 'quality'"),
            (lambda r: r.update(stages=r["stages"][:-1]), "required quality stages"),
            (lambda r: r["stages"][4].update(status="failed", exit_code=1), "stage status"),
        ):
            with self.subTest(expected=expected):
                report = copy.deepcopy(self.quality)
                change(report)
                raw = json.dumps(report).encode()
                (self.root / item["path"]).write_bytes(raw)
                item["sha256"] = hashlib.sha256(raw).hexdigest()
                self.assert_rejected(expected)

    def test_quality_requires_original_stage_logs_and_quality_report_kind(self):
        log = self.root / self.quality["stages"][0]["log_path"]
        log.write_text("changed after the run")
        self.assert_rejected("sha256 mismatch")
        log.unlink()
        self.assert_rejected("cannot read")
        self.entry("G1")["evidence"] = [self.entry("G1")["evidence"][0]]
        self.assert_rejected("G1 requires valid quality-run")

    def test_browser_host_and_hot_restart_do_not_pass_native_gate(self):
        for changes, expected in (
            ({"platform": "browser"}, "platform must be android or ios"),
            ({"platform": "host"}, "platform must be android or ios"),
            ({"platform": "android", "process_restart": False}, "process_restart must be True"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G2", "native-acceptance", changes)
                self.assert_rejected(expected)

    def test_debug_emulator_and_simulator_cannot_pass_real_profile_gate(self):
        for changes, expected in (
            ({"build_mode": "debug"}, "build_mode must be 'profile'"),
            ({"build_mode": "release"}, "build_mode must be 'profile'"),
            ({"build_mode": "profile", "device_type": "emulator"}, "device_type must be 'real'"),
            ({"device_type": "simulator"}, "device_type must be 'real'"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G3", "performance", changes)
                self.assert_rejected(expected)

    def test_fake_sync_cannot_pass_connected_delivery(self):
        self.change_report("G4", "connected-service", {"transport": "fake"})
        self.assert_rejected("transport must be 'connected'")
        item = next(value for value in self.entry("G4")["evidence"] if value["kind"] == "connected-service")
        item["kind"] = "fake-sync"
        self.assert_rejected("G4 requires valid connected-service")

    def test_raw_specialized_report_candidate_and_status_are_checked(self):
        for changes, expected in (
            ({"candidate": "old-source"}, "candidate must be"),
            ({"candidate": self.fingerprint, "status": "failed"}, "status must be 'passed'"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G3", "performance", changes)
                self.assert_rejected(expected)

    def test_specialized_evidence_must_be_raw_json(self):
        item = next(value for value in self.entry("G3")["evidence"] if value["kind"] == "performance")
        (self.root / item["path"]).write_text("reported passed, raw report unavailable")
        item["sha256"] = hashlib.sha256((self.root / item["path"]).read_bytes()).hexdigest()
        self.assert_rejected("expected a raw JSON report")

    def test_release_requires_release_mode_production_signature_and_artifact_hash(self):
        for changes, expected in (
            ({"build_mode": "debug"}, "build_mode must be 'release'"),
            ({"build_mode": "release", "signed": False}, "signed must be True"),
            ({"signed": True, "signing_kind": "debug"}, "signing_kind must be 'production'"),
            ({"signing_kind": "production", "artifact_sha256": "wrong"}, "artifact_sha256 does not match"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G5", "release-signature", changes)
                self.assert_rejected(expected)

    def test_delivery_requires_authorization_matching_destination_and_artifact(self):
        self.change_report("G6", "authorization-receipt", {"authorized": False})
        self.assert_rejected("authorized must be True")
        self.change_report("G6", "authorization-receipt", {"authorized": True})
        for changes, expected in (
            ({"delivered": False}, "delivered must be True"),
            ({"delivered": True, "destination": "synthetic://unauthorized"}, "no matching authorization"),
            ({"destination": "synthetic://test", "artifact_sha256": "wrong"}, "artifact_sha256 does not match"),
        ):
            with self.subTest(changes=changes):
                self.change_report("G6", "delivery-receipt", changes)
                self.assert_rejected(expected)

    def test_delivery_cannot_select_an_unsigned_second_artifact(self):
        unsigned = self.evidence("unsigned.bin", "release-artifact", b"unsigned second fixture")
        self.entry("G5")["evidence"].append(unsigned)
        self.change_report("G6", "delivery-receipt", {"artifact_sha256": unsigned["sha256"]})
        self.assert_rejected("no matching production signature")

    def test_full_quality_rejects_bool_exit_targeted_command_old_inputs_and_incomplete_cleanup(self):
        item = next(value for value in self.entry("G1")["evidence"] if value["kind"] == "quality-run")
        mutations = (
            (lambda r: r["stages"][0].update(exit_code=False), "booleans"),
            (lambda r: r["options"].update(targets=["test/review/one.dart"]), "full-suite targets"),
            (lambda r: r["inputs"].update(lock_sha256="0" * 64), "current source input"),
            (lambda r: r["isolation"].update(cleaned=False), "isolation.cleaned"),
            (lambda r: r.update(execution_candidate_after={"source_fingerprint": "b" * 64}), "execution_candidate_after"),
            (lambda r: r["stages"][6]["command"].append("--plain-name=one"), "full quality stage command"),
        )
        for mutation, text in mutations:
            with self.subTest(text=text):
                report = copy.deepcopy(self.quality)
                mutation(report)
                raw = json.dumps(report).encode()
                (self.root / item["path"]).write_bytes(raw)
                item["sha256"] = hashlib.sha256(raw).hexdigest()
                self.assert_rejected(text)

    def test_hash_valid_late_flutter_failure_or_truncated_tooling_completion_rejects(self):
        item = next(value for value in self.entry("G1")["evidence"] if value["kind"] == "quality-run")
        for stage_id, text in (("flutter-tests", "00:01 +9: All tests passed!\nunhandled exception after completion\n"), ("tooling-tests", "Ran 9 tests in 0.02s\n")):
            with self.subTest(stage=stage_id):
                report = copy.deepcopy(self.quality)
                stage = next(stage for stage in report["stages"] if stage["id"] == stage_id)
                original_log = (self.root / stage["log_path"]).read_bytes()
                (self.root / stage["log_path"]).write_text(text)
                stage["sha256"] = hashlib.sha256(text.encode()).hexdigest()
                raw = json.dumps(report).encode()
                (self.root / item["path"]).write_bytes(raw)
                item["sha256"] = hashlib.sha256(raw).hexdigest()
                self.assert_rejected("successful completion")
                (self.root / stage["log_path"]).write_bytes(original_log)

    def test_local_evaluator_never_returns_a_production_allowed_field(self):
        self.manifest["delivery_scope"] = "local-demo"
        self.manifest["enforcement_deployed"] = False
        result = evaluate_local(self.manifest, self.fingerprint, self.root)
        self.assertEqual(set(result), {"local_allowed", "publish_allowed", "reasons"})
        self.assertIs(result["publish_allowed"], False)
        self.assertIs(result["local_allowed"], False)  # bare G2/tooling smoke
        self.assertTrue(any("native acceptance schema" in reason for reason in result["reasons"]))
        self.assert_rejected("enforcement_deployed")

    def test_malformed_top_level_types_return_structured_refusal(self):
        for manifest in (None, [], True, {"candidate": False}, {"candidate": {"source_fingerprint": self.fingerprint}, "service_mode": True}):
            with self.subTest(manifest=manifest):
                self.assertFalse(evaluate(manifest, self.fingerprint, self.root)["allowed"])
                local = evaluate_local(manifest, self.fingerprint, self.root)
                self.assertFalse(local["local_allowed"])
                self.assertIs(local["publish_allowed"], False)

    def test_scope_name_cannot_bypass_production_requirements(self):
        self.manifest["delivery_scope"] = "local-demo"
        self.manifest["gates"]["G3"]["status"] = "not_applicable"
        self.assert_rejected("gates.G3.status")


if __name__ == "__main__":
    unittest.main()
