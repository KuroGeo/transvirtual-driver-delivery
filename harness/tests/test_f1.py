"""Synthetic evidence evaluates F1 rejection rules, never live acceptance."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from harness import checks, f1, gate, run
from harness.tests import test_gate as fixtures
from harness.tests.test_gate_native import png


def overlay():
    return {"schema_version": 1, "mode": "execute", "contract_revision": 4,
            "authorized_features": ["F1"], "production_eligible": False,
            "authorization": {"date": "2026-10-12", "source": "human request", "scope": "F1 implementation"},
            "source_main": "53c2089", "planning_sha": "5" * 40,
            "contract": f"{f1.PACKAGE}/f1-execution.md",
            "slices": {name: {"status": "planned", "owner_agent_id": None, "candidate": None, "evidence": [],
                              "functional_depends_on": list(f1.DEPENDENCIES[name]),
                              "interface_dependencies": ["NP03 AccountScope", "NP04 sessionGeneration"] if name in ("NP05", "NP06") else []}
                       for name in sorted(f1.SLICES)}}


class F1ProtocolTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.package = self.root / f1.PACKAGE
        self.package.mkdir(parents=True)
        self.registry = overlay()
        self.contract = self.package / "f1-execution.md"
        self.contract.write_text("# F1 execution contract 4 — synthetic policy\n")
        self.inputs = {self.contract.relative_to(self.root).as_posix()}
        self.save()

    def save(self):
        (self.package / "execution.json").write_text(json.dumps(self.registry))

    def errors(self):
        self.save()
        return f1.validate_execution(self.root, self.inputs)

    def test_navigation_overlay_preserves_separate_prepare_history(self):
        self.assertEqual(self.errors(), [])
        self.assertEqual(self.registry["slices"]["NP05"]["functional_depends_on"], ["NP00", "NP01"])

    def test_overlay_and_result_reports_do_not_change_candidate_but_contract_does(self):
        before = checks.fingerprint(self.root)
        self.registry["slices"]["NP01"]["status"] = "blocked"
        self.save()
        result = self.package / "results/NP01-F1.md"
        result.parent.mkdir()
        result.write_text("Mutable execution evidence index")
        self.assertEqual(checks.fingerprint(self.root), before)
        self.contract.write_text(self.contract.read_text() + "New policy")
        self.assertNotEqual(checks.fingerprint(self.root), before)

    def test_f2_f3_and_production_execution_are_rejected(self):
        for change in (lambda value: value.update(authorized_features=["F1", "F2"]),
                       lambda value: value.update(production_eligible=True),
                       lambda value: value["slices"].update(NP04=value["slices"]["NP05"])):
            with self.subTest(change=change):
                self.registry = overlay()
                change(self.registry)
                self.assertTrue(self.errors())

    def test_login_cannot_be_reintroduced_as_navigation_functional_dependency(self):
        self.registry["slices"]["NP05"]["functional_depends_on"].append("NP04")
        self.assertTrue(any("functional dependencies" in error for error in self.errors()))

    def test_account_interface_is_required_without_accepting_login(self):
        self.registry["slices"]["NP06"]["interface_dependencies"] = []
        self.assertTrue(any("interface dependencies" in error for error in self.errors()))

    def test_missing_symlinked_or_unfingerprinted_contract_fails(self):
        self.assertTrue(f1.validate_execution(self.root, set()))
        self.contract.unlink()
        self.contract.symlink_to(self.package / "execution.json")
        self.assertTrue(self.errors())

    def test_accepted_slice_requires_candidate_and_original_hashed_evidence(self):
        value = self.registry["slices"]["NP01"]
        value.update(status="accepted", owner_agent_id="harness", candidate={"source_fingerprint": "a" * 64})
        self.assertTrue(self.errors())
        value["evidence"] = [{"path": self.contract.relative_to(self.root).as_posix(), "kind": "contract", "sha256": hashlib.sha256(self.contract.read_bytes()).hexdigest()}]
        self.assertTrue(any("never documents alone" in error for error in self.errors()))
        self.contract.write_text("# F1 execution contract 4 — edited original\n")
        self.assertTrue(any("mismatched original" in error for error in self.errors()))

    def test_route_boundary_rejects_own_backend_and_delivery_mutation(self):
        path = self.root / "app/lib/data/routes/route.dart"
        path.parent.mkdir(parents=True)
        path.write_text("import 'package:http/http.dart'; void run() { enqueue(); }")
        errors = f1.boundaries(self.root, checks.directives)
        self.assertTrue(any("HTTP/backend" in error for error in errors))
        self.assertTrue(any("mutation" in error for error in errors))
        (self.root / "service/routes").mkdir(parents=True)
        self.assertTrue(any("own routes/matrix" in error for error in f1.boundaries(self.root, checks.directives)))

    def test_public_cli_f1_gate_uses_reread_private_gate(self):
        stages = run.stages("f1-gate", self.root, "a" * 64, self.root / "manifest.json")
        self.assertEqual(stages[0][0], "f1-evidence-gate")
        self.assertIn("_f1_gate", stages[0][1])

    def test_isolated_workspace_preserves_overlay_without_fingerprinting_mutable_board(self):
        with run.isolated_workspace(self.root, checks.fingerprint(self.root)) as isolated:
            self.assertEqual(_read_registry(isolated), self.registry)
            self.assertEqual(f1.validate_execution(isolated, self.inputs), [])

    def test_sensitive_supplier_fields_and_fixture_default_are_mechanically_rejected(self):
        path = self.root / "app/lib/data/routes/third_party_route_port.dart"
        path.parent.mkdir(parents=True)
        path.write_text("class ThirdPartyRouteRequest { final Coordinate origin; final Coordinate destination; final DateTime departureAt; final Mode mode; final String workspaceId; } class ThirdPartyRouteResponse {}")
        repository = path.parent / "route_repository.dart"
        repository.write_text("class RouteRepository { RouteRepository({this.port = const FixtureRoadPort()}); }")
        errors = f1.boundaries(self.root, checks.directives)
        self.assertTrue(any("supplier request" in error for error in errors))
        self.assertTrue(any("default road port" in error for error in errors))


class F1EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GateTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.root, self.fp = self.fixture.root, self.fixture.fingerprint
        for name in ("app/.fvmrc", "app/pubspec.lock", "app/assets/deliveries.csv"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(gate.SOURCE_ROOT / name, path)
        self.package = self.root / f1.PACKAGE
        self.package.mkdir(parents=True)
        (self.package / "execution.json").write_text(json.dumps(overlay()))
        (self.package / "f1-execution.md").write_text("# F1 execution contract 4 — fixture\n")
        source = self.root / "app/test/next_phase/f1_test.dart"
        source.parent.mkdir(parents=True)
        names = {check: f"synthetic {check} test" for check in f1.HOST_CHECKS}
        source.write_text("\n".join("test('" + name + "', () {});" for name in names.values()))
        self.host = {"schema": 1, "feature": "F1", "level": "host", "candidate": self.fp, "status": "passed",
                     "checks": [{"id": check, "status": "passed", "source": "app/test/next_phase/f1_test.dart", "test": names[check]} for check in sorted(names)]}
        text = "\n".join(f"00:00 +{index}: test/next_phase/f1_test.dart: {name}" for index, name in enumerate(names.values())) + "\n00:01 +11: All tests passed!\n"
        reference = self.fixture.evidence("quality-flutter-tests.log", "raw-log", text)
        stage = self.fixture.quality["stages"][-1]
        stage.update(log_path=reference["path"], sha256=reference["sha256"])
        self.events = [{"type": "start", "protocolVersion": "0.1.1"},
                       {"type": "suite", "suite": {"id": 0, "path": self.fixture.quality["execution_root"] + "/app/test/next_phase/f1_test.dart"}}]
        for tid, name in enumerate(names.values(), 1):
            self.events.extend([{"type": "testStart", "test": {"id": tid, "name": name, "suiteID": 0}},
                                {"type": "testDone", "testID": tid, "result": "success", "skipped": False, "hidden": False}])
        self.events.append({"type": "done", "success": True})
        self.machine_path = self.root / "flutter-tests.events.jsonl"
        stage["command"].extend(["--file-reporter", "json:" + str(self.machine_path)])
        self.fixture.quality["stage_spec"][-1]["command"] = [argument.replace(self.fixture.quality["execution_root"], "@workspace").replace(str(self.root), "@run") for argument in stage["command"]]
        self.manifest = {"schema": 1, "feature": "F1", "level": "host", "publish_allowed": False,
                         "external_unverified": list(f1.EXTERNAL), "candidate": {"source_fingerprint": self.fp}}
        self.refresh()

    def refresh(self):
        self.machine_path.write_text("".join(json.dumps(row) + "\n" for row in self.events))
        self.fixture.quality["stages"][-1]["machine_report"] = {"path": str(self.machine_path), "sha256": hashlib.sha256(self.machine_path.read_bytes()).hexdigest(), "kind": "flutter-machine-events"}
        self.manifest["host"] = self.fixture.evidence("host.json", "f1-host-coverage", json.dumps(self.host))
        self.manifest["quality"] = self.fixture.evidence("quality.json", "quality-run", json.dumps(self.fixture.quality))

    def evaluate(self):
        with patch.object(gate, "SOURCE_ROOT", self.root):
            return f1.evaluate(self.manifest, self.fp, self.root)

    def test_synthetic_host_positive_only_attests_schema_and_never_publish(self):
        result = self.evaluate()
        self.assertTrue(result["feature_allowed"], result["reasons"])
        self.assertFalse(result["publish_allowed"])
        self.assertIn("real-road", result["external_unverified"])

    def test_fixture_cannot_attest_live_native_device_or_production(self):
        for level in ("live", "native", "device-performance", "production"):
            with self.subTest(level=level):
                self.manifest["level"] = level
                self.assertFalse(self.evaluate()["feature_allowed"])
        self.manifest["level"] = "host"
        self.manifest["external_unverified"].remove("real-road")
        self.assertFalse(self.evaluate()["feature_allowed"])

    def test_f2_or_production_manifest_is_rejected(self):
        for field, value in (("feature", "F2"), ("publish_allowed", True)):
            original = self.manifest[field]
            self.manifest[field] = value
            self.assertFalse(self.evaluate()["feature_allowed"])
            self.manifest[field] = original

    def test_missing_native_pid_artifact_evidence_fails(self):
        self.manifest["level"] = "native-fixture"
        self.manifest["native"] = {"artifacts": {}}
        self.assertFalse(self.evaluate()["feature_allowed"])

    def test_stale_candidate_or_raw_hash_tampering_fails(self):
        self.manifest["candidate"]["source_fingerprint"] = "b" * 64
        self.assertFalse(self.evaluate()["feature_allowed"])
        self.manifest["candidate"]["source_fingerprint"] = self.fp
        (self.root / "quality-flutter-tests.log").write_text("tampered original\n")
        self.assertFalse(self.evaluate()["feature_allowed"])

    def test_missing_skip_failed_or_stale_feature_check_fails(self):
        for field, value in (("status", "skipped"), ("status", "failed"), ("candidate", "b" * 64)):
            original = self.host[field]
            self.host[field] = value
            self.refresh()
            self.assertFalse(self.evaluate()["feature_allowed"])
            self.host[field] = original
        self.host["checks"].pop()
        self.refresh()
        self.assertFalse(self.evaluate()["feature_allowed"])

    def test_aggregate_pass_without_named_feature_tests_is_rejected(self):
        reference = self.fixture.evidence("quality-flutter-tests.log", "raw-log", "00:01 +11: All tests passed!\n")
        self.fixture.quality["stages"][-1]["sha256"] = reference["sha256"]
        self.refresh()
        self.events = self.events[:2] + [self.events[-1]]
        self.refresh()
        self.assertFalse(self.evaluate()["feature_allowed"])

    def test_parallel_console_can_hide_names_when_machine_events_prove_each_test(self):
        reference = self.fixture.evidence("quality-flutter-tests.log", "raw-log", "00:01 +11: All tests passed!\n")
        self.fixture.quality["stages"][-1]["sha256"] = reference["sha256"]
        self.refresh()
        self.assertTrue(self.evaluate()["feature_allowed"])

    def test_machine_missing_failed_skipped_hidden_and_wrong_suite_are_rejected(self):
        original = copy.deepcopy(self.events)
        for mutate in (lambda rows: rows[3].update(result="failure"),
                       lambda rows: rows[3].update(skipped=True),
                       lambda rows: rows[3].update(hidden=True),
                       lambda rows: rows[1]["suite"].update(path="test/another.dart"),
                       lambda rows: rows.pop(3),
                       lambda rows: rows.append({"type": "done", "success": True}),
                       lambda rows: rows[-1].update(success=False)):
            self.events = copy.deepcopy(original)
            mutate(self.events)
            self.refresh()
            with self.subTest(mutate=mutate):
                self.assertFalse(self.evaluate()["feature_allowed"])

    def test_machine_raw_tampering_missing_tail_and_unbound_destination_are_rejected(self):
        self.machine_path.write_text(self.machine_path.read_text() + "tampered")
        self.assertFalse(self.evaluate()["feature_allowed"])
        self.refresh()
        self.machine_path.write_text(self.machine_path.read_text().rstrip("\n"))
        self.fixture.quality["stages"][-1]["machine_report"]["sha256"] = hashlib.sha256(self.machine_path.read_bytes()).hexdigest()
        self.manifest["quality"] = self.fixture.evidence("quality.json", "quality-run", json.dumps(self.fixture.quality))
        self.assertFalse(self.evaluate()["feature_allowed"])
        self.refresh()
        self.fixture.quality["stages"][-1]["command"][-1] = "json:/foreign/path/events.jsonl"
        self.manifest["quality"] = self.fixture.evidence("quality.json", "quality-run", json.dumps(self.fixture.quality))
        self.assertFalse(self.evaluate()["feature_allowed"])

    def test_symlink_evidence_is_rejected_and_original_bytes_remain_valid(self):
        original = self.manifest["host"]
        (self.root / "host-link.json").symlink_to(self.root / "host.json")
        self.manifest["host"] = {**original, "path": "host-link.json"}
        self.assertFalse(self.evaluate()["feature_allowed"])
        self.manifest["host"] = original
        self.assertTrue(self.evaluate()["feature_allowed"])

    def prepare_collection(self):
        mapping = {"schema": 1, "feature": "F1", "checks": [{key: value for key, value in check.items() if key != "status"} for check in self.host["checks"]]}
        (self.root / "app/test/next_phase/f1_coverage.json").write_text(json.dumps(mapping))
        fingerprint = checks.fingerprint(self.root)
        for key in ("candidate", "candidate_after", "execution_candidate_after"):
            self.fixture.quality[key] = {"source_fingerprint": fingerprint}
        for stage in self.fixture.quality["stages"]:
            stage["log_path"] = str(self.root / stage["log_path"])
        self.fixture.quality["isolation"]["verified_fingerprint"] = fingerprint
        report = self.root / "harness/runs/20261012T000000Z-quality/attempts/000001/report.json"
        report.parent.mkdir(parents=True)
        machine = report.parent / "flutter-tests.events.jsonl"
        shutil.copyfile(self.machine_path, machine)
        stage = self.fixture.quality["stages"][-1]
        stage["command"][-1] = "json:" + str(machine)
        stage["machine_report"]["path"] = str(machine)
        report.write_text(json.dumps(self.fixture.quality))
        return report

    def test_collector_binds_current_source_raw_quality_and_never_overwrites_attempt(self):
        report = self.prepare_collection()
        with patch.object(gate, "SOURCE_ROOT", self.root):
            result = f1.collect_host(self.root)
            self.assertTrue(result["feature_allowed"], result["reasons"])
            files = list((report.parent / "f1-host").glob("*.json"))
            self.assertEqual(len(files), 3)
            hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in files}
            with self.assertRaises(FileExistsError):
                f1.collect_host(self.root, report)
            self.assertEqual(hashes, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in files})

    def test_collector_rejects_missing_current_quality_and_foreign_original_paths(self):
        with self.assertRaisesRegex(gate.EvidenceError, "current-candidate quality"):
            f1.collect_host(self.root)
        report = self.prepare_collection()
        (self.root / "app/test/next_phase/f1_test.dart").write_text("changed candidate")
        with self.assertRaisesRegex(gate.EvidenceError, "current-candidate quality"):
            f1.collect_host(self.root)
        with self.assertRaisesRegex(gate.EvidenceError, "original canonical evidence"):
            f1.collect_host(self.root, self.root / "quality.json")

    def test_actual_repository_and_feature_callers_reject_stale_accepted_candidate(self):
        value = overlay()
        value["slices"]["NP01"].update(status="accepted", owner_agent_id="harness", candidate={"source_fingerprint": "b" * 64}, evidence=[self.manifest["quality"]])
        (self.package / "execution.json").write_text(json.dumps(value))
        self.assertTrue(any("accepted candidate" in error for error in checks.repository(self.root)))
        result = self.evaluate()
        self.assertFalse(result["feature_allowed"])
        self.assertTrue(any("accepted candidate" in error for error in result["reasons"]))

    def test_np12_cannot_be_accepted_with_host_fixture_or_documents(self):
        value = overlay()
        value["slices"]["NP12"].update(status="accepted", owner_agent_id="tester", candidate={"source_fingerprint": self.fp}, evidence=[self.manifest["quality"]])
        (self.package / "execution.json").write_text(json.dumps(value))
        self.assertFalse(self.evaluate()["feature_allowed"])


class F1NativePhaseTests(unittest.TestCase):
    """Synthetic phase graphs test predicates after OS provenance validation.

    They never replace native_run or represent an actual simulator run.
    """
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.fp = "a" * 64
        self.validator = f1.F1Validator({"candidate": {"source_fingerprint": self.fp}, "service_mode": "local-client"}, self.fp, self.root)
        self.run = {"configuration": "local-client", "_evidence_owner": self.root, "_verified_artifacts": {},
                    "launches": [{"phase": phase, "processId": 100 + index, "session": phase + "-session"} for index, phase in enumerate(("saved", "recovered", "confirmed"))]}
        self.records = {}
        for launch in self.run["launches"]:
            phase = launch["phase"]
            directory = self.root / phase
            directory.mkdir()
            identity = {"candidate": self.fp, "processId": launch["processId"], "session": launch["session"], "configuration": "local-client"}
            initial = {**identity, "stops": [{"id": "one", "status": "pending"}], "outbox": [],
                       "model": {"initialized": True, "panel": "detail", "selected": {"id": "one"}, "selectedOrigin": "list", "query": {"search": "Silver"}},
                       "camera": {"latitude": -33.8, "longitude": 151.2, "zoom": 12}, "bounds": {}}
            snapshots = {"initial-snapshot.json": initial, "snapshot.json": copy.deepcopy(initial)}
            ids = sorted(f1.NATIVE_CHECKS - {"F1.cold-recovery"}) if phase == "saved" else ["F1.cold-recovery"] if phase == "recovered" else []
            claims = []
            for check_id in ids:
                slug = check_id.removeprefix("F1.")
                before, after = copy.deepcopy(initial), copy.deepcopy(initial)
                claim = {"id": check_id, "status": "passed", "actions": ["tap:navigation-return"],
                         "before": slug + "-before.json", "after": slug + "-after.json"}
                if check_id == "F1.route-preview":
                    after["bounds"] = {"navigation-preview": [{"width": 390}]}
                    after["navigation"] = {"gatewaySource": "controlled-navigation-fixture", "isValid": True, "targetStopId": "one", "previewStatus": "unavailable", "routeProvider": None}
                elif check_id.startswith("F1.return-"):
                    origin = {"F1.return-query": "list", "F1.return-list": "list", "F1.return-map": "map", "F1.return-nearest": "nearest"}[check_id]
                    for value in (before, after):
                        value["model"]["selectedOrigin"] = origin
                    returned = copy.deepcopy(after)
                    returned["model"]["panel"] = "list" if origin == "list" else "map"
                    claim["sourceReturned"] = slug + "-source.json"
                    snapshots[claim["sourceReturned"]] = returned
                    preview = copy.deepcopy(after)
                    preview["navigation"] = {"gatewaySource": "controlled-navigation-fixture", "isValid": True, "targetStopId": "one", "previewStatus": "unavailable", "routeProvider": None}
                    handoff = copy.deepcopy(preview)
                    handoff["navigation"]["handoffStatus"] = "handoffRequested"
                    claim.update(preview=slug + "-preview.json", handoff=slug + "-handoff.json")
                    snapshots[claim["preview"]] = preview
                    snapshots[claim["handoff"]] = handoff
                snapshots[claim["before"]] = before
                snapshots[claim["after"]] = after
                claims.append(claim)
            result = {**identity, "vmProcessId": launch["processId"], "phase": phase, "scope": "f1-native-navigation-fixture", "status": "passed", "f1Checks": claims}
            actions = [{**identity, "sequence": 1, "action": "tap:navigation-return", "stage": stage} for stage in ("started", "completed")]
            self.records[phase] = {"snapshots": snapshots, "result": result, "actions": actions, "observations": list(snapshots.values())}
            database = directory / "phase-final.sqlite"
            with gate.closing(sqlite3.connect(database)) as connection:
                connection.executescript("""PRAGMA user_version=2;
                    CREATE TABLE datasets(id TEXT); INSERT INTO datasets VALUES('dataset');
                    CREATE TABLE stops(id TEXT, status TEXT); INSERT INTO stops VALUES('one','pending');
                    CREATE TABLE outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT,dataset_id TEXT,stop_id TEXT);
                    CREATE TABLE delivery_settings(dataset_id TEXT);""")
            self.retain(database)
            image = directory / "phase-final.png"
            image.write_bytes(png(390, 844))
            self.retain(image)
            self.flush(phase)

    def retain(self, path):
        self.run["_verified_artifacts"][str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()

    def flush(self, phase):
        directory = self.root / phase
        record = self.records[phase]
        values = {**record["snapshots"], "result.json": record["result"]}
        for name, value in values.items():
            path = directory / name
            path.write_text(json.dumps(value))
            self.retain(path)
        for name in ("actions", "observations"):
            path = directory / (name + ".jsonl")
            path.write_text("".join(json.dumps(value) + "\n" for value in record[name]))
            self.retain(path)

    def evaluate(self):
        return self.validator.navigation_phases(self.run)

    def test_synthetic_phase_graph_checks_predicates_only(self):
        self.assertEqual(self.evaluate(), self.run)

    def test_native_receipt_cannot_invent_preview_or_source_return(self):
        preview = self.records["saved"]["snapshots"]["route-preview-after.json"]
        preview["bounds"] = {}
        self.flush("saved")
        with self.assertRaisesRegex(gate.EvidenceError, "route-preview UI"):
            self.evaluate()

    def test_native_wrong_source_and_camera_are_rejected(self):
        source = self.records["saved"]["snapshots"]["return-map-source.json"]
        source["camera"]["zoom"] = 14
        self.flush("saved")
        with self.assertRaisesRegex(gate.EvidenceError, "map viewport"):
            self.evaluate()

    def test_native_fake_identity_and_forged_actions_are_rejected(self):
        self.records["saved"]["result"]["f1Checks"][0]["actions"] = ["fake-tap"]
        self.flush("saved")
        with self.assertRaisesRegex(gate.EvidenceError, "absent from original"):
            self.evaluate()

    def test_native_late_pid_and_missing_original_are_rejected(self):
        self.records["saved"]["result"]["vmProcessId"] = 999
        self.flush("saved")
        with self.assertRaisesRegex(gate.EvidenceError, "vmProcessId"):
            self.evaluate()
        self.records["saved"]["result"]["vmProcessId"] = 100
        self.flush("saved")
        del self.run["_verified_artifacts"][str(self.root / "saved/phase-final.png")]
        with self.assertRaisesRegex(gate.EvidenceError, "missing original inventoried"):
            self.evaluate()

    def test_native_changed_outbox_and_sqlite_disagreement_are_rejected(self):
        self.records["saved"]["snapshots"]["return-query-after.json"]["outbox"] = [{"seq": 1}]
        self.flush("saved")
        with self.assertRaisesRegex(gate.EvidenceError, "intermediate navigation"):
            self.evaluate()

    def test_native_fixture_gateway_cannot_be_relabelled_live(self):
        self.records["saved"]["snapshots"]["route-preview-after.json"]["navigation"]["gatewaySource"] = "real-external-maps"
        self.flush("saved")
        with self.assertRaisesRegex(gate.EvidenceError, "fixture provenance"):
            self.evaluate()

    def test_native_stale_target_fake_route_and_unrelated_handoff_are_rejected(self):
        handoff = self.records["saved"]["snapshots"]["return-list-handoff.json"]["navigation"]
        for key, value, message in (("targetStopId", "different-stop", "destination binding"),
                                    ("isValid", False, "current navigation target"),
                                    ("routeProvider", "fixture-road", "licensed road provenance"),
                                    ("previewStatus", "ready", "unavailable road supplier"),
                                    ("handoffStatus", "arrived", "handoff requested")):
            original = handoff[key]
            handoff[key] = value
            self.flush("saved")
            with self.subTest(key=key), self.assertRaisesRegex(gate.EvidenceError, message):
                self.evaluate()
            handoff[key] = original


def _read_registry(root):
    return json.loads((root / f1.PACKAGE / "execution.json").read_text())


if __name__ == "__main__":
    unittest.main()
