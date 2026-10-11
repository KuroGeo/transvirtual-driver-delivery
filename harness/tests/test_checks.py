import importlib.util
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("checks", Path(__file__).parents[1] / "checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, value):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value)

    def test_semantic_directives_ignore_comment_and_executable_strings(self):
        self.write("app/lib/ui/page.dart", "// import 'package:sqflite/sqflite.dart';\n/* import '../data/sqlite_delivery_repository.dart'; */\nconst text = \"import 'package:sqflite/sqflite.dart';\";\nimport '../data/delivery/delivery_repository.dart';")
        self.assertEqual(checks.architecture(self.root), [])

    def test_relative_package_export_and_conditional_violation(self):
        for directive in ["import '../data/delivery/sqlite_delivery_repository.dart';", "export 'package:ocean_delivery/data/delivery/sqlite_delivery_repository.dart';", "import 'clean.dart' if (dart.library.io) '../data/delivery/sqlite_delivery_repository.dart';"]:
            with self.subTest(directive=directive):
                self.write("app/lib/ui/page.dart", directive)
                self.assertEqual(len(checks.architecture(self.root)), 1)

    def test_barrel_cannot_hide_concrete_storage(self):
        self.write("app/lib/ui/page.dart", "import '../shared.dart';")
        self.write("app/lib/shared.dart", "export 'data/delivery/sqlite_delivery_repository.dart';")
        self.assertTrue(checks.architecture(self.root))

    def test_data_and_model_forbidden_dependencies(self):
        self.write("app/lib/data/delivery/repository.dart", "import '../../ui/page.dart';")
        self.write("app/lib/models/stop.dart", "import 'dart:io';\nimport 'package:flutter/widgets.dart';")
        self.assertEqual(len(checks.architecture(self.root)), 3)

    def test_generated_outputs_do_not_invalidate_source_but_untracked_source_does(self):
        self.write("app/lib/main.dart", "void main() {}")
        original = checks.fingerprint(self.root)
        self.write("app/build/output.txt", "build")
        self.write("harness/runs/log.txt", "run")
        self.write("app/.idea/workspace.xml", "IDE state")
        self.write("app/ocean_delivery.iml", "IDE module")
        self.write("app/android/gradlew", "generated wrapper")
        self.write("app/android/gradlew.bat", "generated Windows wrapper")
        self.write("app/android/gradle/wrapper/gradle-wrapper.jar", "generated wrapper jar")
        self.write("harness/archive/rehearsal.tar.gz", "historical evidence")
        self.write("harness/reports/status.json", "current validation output")
        self.assertEqual(checks.fingerprint(self.root), original)
        self.write("app/lib/new.dart", "class Feature {}")
        self.assertNotEqual(checks.fingerprint(self.root), original)

    def test_output_names_inside_business_source_remain_candidate_inputs(self):
        for name in ("reports", "build", "evidence", "archive", "runs"):
            with self.subTest(directory=name):
                before = checks.fingerprint(self.root)
                self.write(f"app/lib/{name}/feature.dart", "class Feature {}")
                self.assertNotEqual(checks.fingerprint(self.root), before)
        before = checks.fingerprint(self.root)
        self.write("app/assets/status.json", '{"status": "pending"}')
        self.assertNotEqual(checks.fingerprint(self.root), before)

    def test_active_prototype_contract_inputs_invalidate_candidate(self):
        for name in (
            "prototype/index.html", "prototype/assets/app.js", "prototype/assets/map.js",
            "prototype/assets/icons.json", "prototype/assets/refined.css",
            "prototype/map-design.md", "prototype/feedback-design.md",
            "prototype/assets/app-icon-design.md", "prototype/vendor/leaflet/leaflet.js",
        ):
            with self.subTest(path=name):
                self.write(name, "original")
                before = checks.fingerprint(self.root)
                self.write(name, "changed contract")
                self.assertNotEqual(checks.fingerprint(self.root), before)
        before = checks.fingerprint(self.root)
        self.write("prototype/evidence/report.json", "new screenshot evidence")
        self.write("prototype/archive/round2/assets/app.js", "historical input")
        self.assertEqual(checks.fingerprint(self.root), before)

    def test_symlink_root_fingerprint_matches_resolved_root_and_tracks_edits(self):
        self.write("app/lib/main.dart", "void main() {}")
        before = checks.fingerprint(self.root.resolve())
        alias_directory = tempfile.TemporaryDirectory()
        self.addCleanup(alias_directory.cleanup)
        alias = Path(alias_directory.name) / "repository"
        alias.symlink_to(self.root.resolve(), target_is_directory=True)
        self.assertEqual(checks.fingerprint(alias), before)
        (alias / "app/lib/main.dart").write_text("void main() { /* new candidate */ }")
        after = checks.fingerprint(self.root.resolve())
        self.assertNotEqual(after, before)
        self.assertEqual(checks.fingerprint(alias), after)
        self.assertEqual(checks.fingerprint(str(alias)), after)

    def test_new_product_layers_keep_existing_semantic_boundaries(self):
        for name, source in (
            ("app/lib/data/services/demo_transport.dart", "import '../../ui/map.dart';"),
            ("app/lib/models/workbench.dart", "import 'package:flutter/foundation.dart';"),
            ("app/lib/ui/delivery/map/map.dart", "export 'package:csv/csv.dart';"),
        ):
            with self.subTest(path=name):
                self.write(name, source)
                self.assertTrue(any(name in error for error in checks.architecture(self.root)))


class Traceability(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.write("AGENTS.md", "Entry point\n")
        self.write("README.md", "Project\n")
        self.write("harness/project/mission.md", "| R01 | durable update |\n| R02 | stable identity |\n")
        self.write("prototype/assets/app.js", "const contract = 'active';\n")
        self.write("app/test/example_test.dart", "test('durable acknowledgement', () {});\n")
        self.write(".agents/skills/test-skill/SKILL.md", "---\nname: test-skill\ndescription: Fixture skill\n---\n")
        epic = self.write("harness/project/issues/EPIC.md", "<!-- ocean-delivery-epic:FLUTTER-PARITY; contract:5 -->\nFixture epic\n")
        self.backlog = {
            "schema_version": 1, "contract_revision": 5,
            "github_parent": {"number": 14, "issue_id": 114,
                "url": "https://github.com/KuroGeo/transvirtual-driver-delivery/issues/14",
                "body_sha256": hashlib.sha256(epic.read_bytes()).hexdigest()},
            "tasks": [self.task("E00", 15, []), self.task("E01", 16, ["E00"])],
        }
        self.matrix = {"schema_version": 1, "contract_revision": 5,
            "requirements": [self.row("R01"), self.row("R02")]}
        self.publish(self.backlog, self.matrix)

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def task(self, task_id, number, dependencies):
        body = f"<!-- ocean-delivery-task:{task_id}; contract:5 -->\n[Parent](https://github.com/KuroGeo/transvirtual-driver-delivery/issues/14)\n"
        self.write(f"harness/project/issues/{task_id}.md", body)
        return {"id": task_id, "requirements": ["R01", "R02"],
            "depends_on": dependencies, "skills": ["test-skill"],
            "write_scope": ["app/lib/data"], "acceptance": ["Durable identities"],
            "done_when": "Durable identities",
            "github": {"number": number, "issue_id": number + 100,
                "url": f"https://github.com/KuroGeo/transvirtual-driver-delivery/issues/{number}",
                "parent_number": 14, "blocked_by_numbers": [15] if dependencies else [],
                "body_sha256": hashlib.sha256(body.encode()).hexdigest()}}

    def row(self, requirement):
        return {"id": requirement, "sources": ["prototype/assets/app.js"],
            "tasks": ["E00", "E01"],
            "tests": [{"task": "E01", "path": "app/test/example_test.dart",
                "state": "implemented", "level": "G1", "cases": ["durable acknowledgement"],
                "evidence": []}],
            "gaps": [{"task": "E01", "level": "G2", "reason": "OS process acceptance not run"}]}

    def publish(self, backlog, matrix):
        self.write("harness/project/backlog.json", json.dumps(backlog))
        self.write("harness/project/requirement-matrix.json", json.dumps(matrix))

    def errors(self):
        return "\n".join(checks.traceability(self.root))

    def test_valid_graph_shared_test_honest_gaps_and_planned_paths(self):
        self.assertEqual(checks.traceability(self.root), [])
        self.assertEqual(checks.repository(self.root), [])
        self.matrix["requirements"][0]["tests"][0].update(
            state="planned", path="app/integration_test/future_test.dart", level="G2")
        self.publish(self.backlog, self.matrix)
        self.assertEqual(checks.traceability(self.root), [])
        self.matrix["requirements"][0]["tests"] = []
        self.publish(self.backlog, self.matrix)
        self.assertEqual(checks.traceability(self.root), [])

    def test_missing_graph_fields_and_wrong_types_report_locations(self):
        for field, value, expected in (
            ("requirements", None, "requirements"), ("depends_on", "E00", "depends_on"),
            ("skills", [], "skills"), ("skills", [None], "skills"),
            ("write_scope", [], "write_scope"), ("acceptance", [], "acceptance"),
            ("done_when", None, "done_when"), ("github", None, "github"),
            ("id", [], ".id"),
        ):
            with self.subTest(field=field, value=value):
                backlog = copy.deepcopy(self.backlog)
                backlog["tasks"][1][field] = value
                self.publish(backlog, self.matrix)
                self.assertIn(expected, self.errors())
        for field in ("requirements", "skills", "write_scope", "acceptance", "done_when", "github"):
            with self.subTest(missing=field):
                backlog = copy.deepcopy(self.backlog)
                del backlog["tasks"][1][field]
                self.publish(backlog, self.matrix)
                self.assertIn("missing fields", self.errors())
        for field, value in (("tasks", {}), ("schema_version", True), ("contract_revision", "5")):
            with self.subTest(top_field=field):
                backlog = copy.deepcopy(self.backlog)
                backlog[field] = value
                self.publish(backlog, self.matrix)
                self.assertIn(field, self.errors())

    def test_duplicate_and_dangling_graph_identity_is_not_collapsed(self):
        for field in ("number", "issue_id", "url"):
            with self.subTest(field=field):
                backlog = copy.deepcopy(self.backlog)
                backlog["tasks"][1]["github"][field] = backlog["tasks"][0]["github"][field]
                self.publish(backlog, self.matrix)
                self.assertIn("duplicate Issue identity", self.errors())
        for change, expected in (
            (lambda b: b["tasks"].append(copy.deepcopy(b["tasks"][0])), "duplicate task ID"),
            (lambda b: b["tasks"][1].update(depends_on=["X99"]), "missing dependency X99"),
            (lambda b: b["tasks"][1].update(depends_on=["E00", "E00"]), "duplicate entries"),
            (lambda b: b["tasks"][1]["github"].update(parent_number=99), "parent_number"),
            (lambda b: b["tasks"][1]["github"].update(blocked_by_numbers=[]), "blocked_by_numbers"),
            (lambda b: b["tasks"][1]["github"].update(blocked_by_numbers=[15, 15]), "blocked_by_numbers"),
            (lambda b: b["tasks"][1]["github"].update(number=True), "positive integer"),
            (lambda b: b["tasks"][1]["github"].update(blocked_by_numbers=[True]), "positive integers"),
            (lambda b: b["tasks"][1]["github"].update(url="https://github.com/Elsewhere/other/issues/16"), "parent repository"),
            (lambda b: b["tasks"][1]["github"].update(url="https://github.com/KuroGeo/transvirtual-driver-delivery/issues/16?x=1"), "canonical Issue URL"),
        ):
            with self.subTest(expected=expected):
                backlog = copy.deepcopy(self.backlog)
                change(backlog)
                self.publish(backlog, self.matrix)
                self.assertIn(expected, self.errors())

    def test_cycles_show_the_actual_chain_including_self_edge(self):
        for target, expected in (("E01", "E00 -> E01 -> E00"), ("E00", "E00 -> E00")):
            with self.subTest(target=target):
                backlog = copy.deepcopy(self.backlog)
                backlog["tasks"][0]["depends_on"] = [target]
                self.publish(backlog, self.matrix)
                self.assertIn(expected, self.errors())

    def test_issue_body_hash_marker_and_parent_link_are_checked(self):
        path = "harness/project/issues/E01.md"
        original = (self.root / path).read_text()
        self.write(path, original + "Unexpected edited body\n")
        self.assertIn("body differs", self.errors())
        for body, expected in (
            (original.replace("task:E01", "task:E99"), "marker"),
            (original.replace("issues/14", "issues/99"), "parent Issue link"),
        ):
            with self.subTest(expected=expected):
                backlog = copy.deepcopy(self.backlog)
                backlog["tasks"][1]["github"]["body_sha256"] = hashlib.sha256(body.encode()).hexdigest()
                self.write(path, body)
                self.publish(backlog, self.matrix)
                self.assertIn(expected, self.errors())

    def test_parent_epic_receipt_hash_and_contract_marker_are_checked(self):
        path = "harness/project/issues/EPIC.md"
        original = (self.root / path).read_text()
        self.write(path, original + "Receipt drift\n")
        self.assertIn("local EPIC body differs", self.errors())
        body = original.replace("contract:5", "contract:4")
        self.backlog["github_parent"]["body_sha256"] = hashlib.sha256(body.encode()).hexdigest()
        self.write(path, body)
        self.publish(self.backlog, self.matrix)
        self.assertIn("epic/contract marker", self.errors())

    def test_actual_skill_file_metadata_and_scope_paths_are_required(self):
        for skill, expected in (("missing-skill", "file does not exist"), ("../outside", "invalid skill name")):
            with self.subTest(skill=skill):
                backlog = copy.deepcopy(self.backlog)
                backlog["tasks"][1]["skills"] = [skill]
                self.publish(backlog, self.matrix)
                self.assertIn(expected, self.errors())
        self.publish(self.backlog, self.matrix)
        self.write(".agents/skills/test-skill/SKILL.md", "---\nname: other\ndescription: wrong\n---\n")
        self.assertIn("metadata", self.errors())
        self.backlog["tasks"][1]["write_scope"] = ["../outside"]
        self.publish(self.backlog, self.matrix)
        self.assertIn("write_scope: use a canonical", self.errors())

    def test_malformed_and_duplicate_json_fields_fail_without_exception(self):
        for path in ("harness/project/backlog.json", "harness/project/requirement-matrix.json"):
            for invalid in ("{", '{"schema_version": 1, "schema_version": 2}', "null", "[]"):
                with self.subTest(path=path, invalid=invalid):
                    self.publish(self.backlog, self.matrix)
                    self.write(path, invalid)
                    self.assertIn(path.rsplit("/", 1)[-1], self.errors())

    def test_requirement_rows_and_field_names_join_the_complete_backlog(self):
        for change, expected in (
            (lambda m: m["requirements"].pop(), "missing requirements"),
            (lambda m: m["requirements"].append(copy.deepcopy(m["requirements"][0])), "duplicate requirement"),
            (lambda m: m["requirements"][0].update(id="R99"), "unknown requirement"),
            (lambda m: m["requirements"][0].update(tasks=["E00"]), "missing=['E01']"),
            (lambda m: m["requirements"][0].update(tasks=["E00", "E01", "X99"]), "unexpected=['X99']"),
            (lambda m: m["requirements"][0].update(sources=[]), "sources: must not be empty"),
            (lambda m: m["requirements"][0].update(tests=[], gaps=[]), "missing test mapping"),
            (lambda m: m.update(schema_version=2), "schema_version"),
            (lambda m: m.update(contract_revision=6), "contract_revision"),
            (lambda m: m["requirements"][0].update(testz=[]), "unknown fields"),
            (lambda m: m["requirements"][0].pop("sources"), "missing fields"),
        ):
            with self.subTest(expected=expected):
                matrix = copy.deepcopy(self.matrix)
                change(matrix)
                self.publish(self.backlog, matrix)
                self.assertIn(expected, self.errors())

    def test_test_state_binding_cases_and_gap_shapes_are_strict(self):
        for field, value, expected in (
            ("task", "X99", "accountable backlog task"), ("state", "passed", "planned/implemented"),
            ("state", "implementd", "planned/implemented"), ("path", "app/test/missing_test.dart", "file does not exist"),
            ("path", "app/test", "file does not exist"), ("level", "G2", "matching host/native level"),
            ("level", [], "recognized verification level"), ("cases", [], "cases: must not be empty"),
            ("cases", ["case", "case"], "duplicate entries"), ("evidence", {}, "evidence: expected a list"),
        ):
            with self.subTest(field=field, value=value):
                matrix = copy.deepcopy(self.matrix)
                matrix["requirements"][0]["tests"][0][field] = value
                self.publish(self.backlog, matrix)
                self.assertIn(expected, self.errors())
        matrix = copy.deepcopy(self.matrix)
        matrix["requirements"][0]["tests"].append(copy.deepcopy(matrix["requirements"][0]["tests"][0]))
        self.publish(self.backlog, matrix)
        self.assertIn("duplicate test binding", self.errors())
        for field, value in (("task", "X99"), ("level", "G99"), ("reason", "")):
            with self.subTest(gap=field):
                matrix = copy.deepcopy(self.matrix)
                matrix["requirements"][0]["gaps"][0][field] = value
                self.publish(self.backlog, matrix)
                self.assertIn("gaps[0]", self.errors())

    def test_planned_paths_cannot_escape_or_claim_existing_run_evidence(self):
        for path in ("../outside.dart", "/tmp/outside.dart", "app//test/example.dart",
                     "app/test/./example.dart", "app\\test\\example.dart", "https://example.test/a.dart", "app/test/\0.dart"):
            with self.subTest(path=path):
                matrix = copy.deepcopy(self.matrix)
                matrix["requirements"][0]["tests"][0].update(state="planned", path=path)
                self.publish(self.backlog, matrix)
                self.assertIn("canonical repository-relative path", self.errors())
        matrix = copy.deepcopy(self.matrix)
        matrix["requirements"][0]["tests"][0].update(state="planned", evidence=[{"usage": "passed"}])
        self.publish(self.backlog, matrix)
        self.assertIn("planned tests cannot claim", self.errors())
        for path in ("app/test/future.py", "harness/tests/test_future.dart", "app/lib/harness_probe.dart"):
            with self.subTest(unsupported_path=path):
                matrix = copy.deepcopy(self.matrix)
                matrix["requirements"][0]["tests"][0].update(state="planned", path=path)
                self.publish(self.backlog, matrix)
                self.assertIn("supported test root", self.errors())

    def test_sources_must_exist_be_fingerprinted_and_stay_in_repository(self):
        self.write("not-a-contract.txt", "unfingerprinted")
        for source, expected in (("prototype/missing.md", "file does not exist"),
                                 ("not-a-contract.txt", "outside candidate fingerprint")):
            with self.subTest(source=source):
                matrix = copy.deepcopy(self.matrix)
                matrix["requirements"][0]["sources"] = [source]
                self.publish(self.backlog, matrix)
                self.assertIn(expected, self.errors())
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        target = Path(outside.name) / "outside.dart"
        target.write_text("task-owned external fixture")
        (self.root / "app/test/escaped.dart").symlink_to(target)
        matrix = copy.deepcopy(self.matrix)
        matrix["requirements"][0]["tests"][0]["path"] = "app/test/escaped.dart"
        self.publish(self.backlog, matrix)
        self.assertIn("path escapes the repository", self.errors())

    def history(self, report_change=None, evidence_change=None):
        log = self.write("harness/runs/history/flutter-tests.log", "fixture completed\n")
        report = {"candidate": {"source_fingerprint": "b" * 64},
            "candidate_after": {"source_fingerprint": "b" * 64},
            "job": {"status": "passed"}, "stages": [{"id": "flutter-tests", "status": "passed",
                "exit_code": 0, "log_path": log.name, "sha256": hashlib.sha256(log.read_bytes()).hexdigest()}]}
        if report_change:
            report_change(report)
        path = self.write("harness/runs/history/report.json", json.dumps(report))
        evidence = {"report": path.relative_to(self.root).as_posix(),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "stage": "flutter-tests", "usage": "historical"}
        if evidence_change:
            evidence_change(evidence)
        matrix = copy.deepcopy(self.matrix)
        matrix["requirements"][0]["tests"][0]["evidence"] = [evidence]
        self.publish(self.backlog, matrix)

    def test_historical_stage_log_is_verifiable_without_current_pass_claim(self):
        self.history()
        self.assertEqual(checks.traceability(self.root), [])
        self.assertNotEqual(checks.fingerprint(self.root), "b" * 64)

    def test_historical_evidence_rejects_false_status_candidate_and_log_identity(self):
        for change, expected in (
            (lambda r: r["job"].update(status="interrupted"), "completed successfully"),
            (lambda r: r["candidate_after"].update(source_fingerprint="c" * 64), "changed during execution"),
            (lambda r: r["stages"].append(copy.deepcopy(r["stages"][0])), "one matching actual stage"),
            (lambda r: r["stages"][0].update(status="running"), "never running/skipped/interrupted"),
            (lambda r: r["stages"][0].update(exit_code=1), "exit_code 0"),
            (lambda r: r["stages"][0].update(exit_code=False), "exit_code 0"),
            (lambda r: r["stages"][0].update(sha256="c" * 64), "raw log path/hash"),
            (lambda r: r["stages"][0].update(log_path="/outside/log.txt"), "raw log path/hash"),
        ):
            with self.subTest(expected=expected):
                self.history(report_change=change)
                self.assertIn(expected, self.errors())
        for change, expected in (
            (lambda e: e.update(sha256="c" * 64), "report hash"),
            (lambda e: e.update(report="harness/runs/missing.json"), "file does not exist"),
            (lambda e: e.update(usage="current"), "generated manifests"),
            (lambda e: e.update(stage="missing-stage"), "one matching actual stage"),
        ):
            with self.subTest(expected=expected):
                self.history(evidence_change=change)
                self.assertIn(expected, self.errors())


if __name__ == "__main__":
    unittest.main()
