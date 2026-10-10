import importlib.util
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


if __name__ == "__main__":
    unittest.main()
