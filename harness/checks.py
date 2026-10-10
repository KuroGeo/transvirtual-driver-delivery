"""Repository facts and Dart dependency directions, with actionable errors."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOTS = tuple(Path(name) for name in (
    "app/.dart_tool", "app/.idea", "app/build", "app/android/.gradle",
    "app/android/.cxx", "app/android/app/.cxx", "app/ios/Pods",
    "app/ios/.symlinks", "app/ios/.generated", "app/ios/Flutter/ephemeral",
    "harness/runs", "harness/history", "harness/evidence", "harness/archive",
    "harness/reports",
))
GENERATED = {
    "app/ios/Flutter/Generated.xcconfig", "app/ios/Flutter/flutter_export_environment.sh",
    "app/ios/Flutter/.last_build_id", "app/ios/Flutter/Flutter.podspec",
    "app/ios/Runner/GeneratedPluginRegistrant.h", "app/ios/Runner/GeneratedPluginRegistrant.m",
    "app/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
    "app/android/local.properties", "app/.flutter-plugins-dependencies",
    "app/android/gradlew", "app/android/gradlew.bat", "app/android/gradle/wrapper/gradle-wrapper.jar",
    "harness/project/work.json",
}


def source_files(root=ROOT):
    roots = [root / "app", root / "harness", root / ".agents" / "skills", root / ".github"]
    files = [root / name for name in ("AGENTS.md", "README.md", "docs/solution-design.md", "docs/assignment/brief.en.txt", "docs/assignment/deliveries.csv", "prototype/README.md", "prototype/direct-sync-design.md", "prototype/origin-return-design.md", "prototype/assets/map-config.json") if (root / name).exists()]
    for directory in roots:
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            relative = path.relative_to(root)
            if (not path.is_file() or {".git", "__pycache__"}.intersection(relative.parts)
                    or any(relative.is_relative_to(prefix) for prefix in OUTPUT_ROOTS)
                    or relative.as_posix() in GENERATED or path.suffix == ".iml"):
                continue
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def fingerprint(root=ROOT):
    digest = hashlib.sha256()
    for path in source_files(root):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


# Tokenization skips comments while retaining string tokens; only directive URIs
# count. Strings in executable code and commented imports are not dependencies.
TOKENS = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/|(?:r)?(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')|[A-Za-z_]\w*|[^\s]", re.MULTILINE)


def directives(source):
    tokens = [match.group() for match in TOKENS.finditer(source) if not match.group().startswith(("//", "/*"))]
    for index, token in enumerate(tokens):
        if token not in {"import", "export"}:
            continue
        for value in tokens[index + 1:]:
            if value == ";":
                break
            if value.startswith(("'", '"', "r'", 'r\"')):
                value = value[1:] if value.startswith("r") else value
                yield value[1:-1]


def architecture(root=ROOT):
    root = Path(root).resolve()
    errors = []
    lib = root / "app" / "lib"
    paths = sorted(lib.rglob("*.dart"))
    dependencies = {}
    for path in paths:
        dependencies[path] = []
        for uri in directives(path.read_text()):
            target = None
            if uri.startswith("package:ocean_delivery/"):
                target = (lib / uri.removeprefix("package:ocean_delivery/")).resolve()
            elif ":" not in uri:
                target = (path.parent / uri).resolve()
            if target and not target.is_relative_to(lib):
                errors.append(f"{path.relative_to(root)}: dependency {uri} escapes app/lib")
            dependencies[path].append((uri, target))
    for path in paths:
        layer = path.relative_to(lib).parts[0]
        if layer not in {"models", "data", "ui"}:
            continue
        visited = set()
        def inspect(current, via):
            if current in visited:
                return
            visited.add(current)
            for uri, target in dependencies.get(current, []):
                parts = target.relative_to(lib).parts if target and target.is_relative_to(lib) else ()
                violation = None
                if layer == "models" and (target and parts and parts[0] != "models" or ":" in uri and not uri.startswith("dart:")):
                    violation = "models use pure Dart and other models only"
                elif layer == "models" and uri in {"dart:ui", "dart:io", "dart:html"}:
                    violation = "models must remain platform independent"
                elif layer == "data" and (parts and parts[0] in {"ui", "app"} or uri.startswith("package:flutter/")):
                    violation = "data depends on models/contracts, never UI or Flutter"
                elif layer == "ui" and (uri.startswith(("package:sqflite", "package:csv/")) or target and target.name == "sqlite_delivery_repository.dart"):
                    violation = "UI uses DeliveryRepository; move SQLite/CSV wiring into app assembly"
                if violation:
                    errors.append(f"{path.relative_to(root)}: {via + uri}: {violation}")
                elif target:
                    inspect(target, via + uri + " -> ")
        inspect(path, "")
    return errors


def repository(root=ROOT):
    errors = architecture(root)
    files = [root / "AGENTS.md", root / "README.md"]
    files += [path for path in (root / "harness").rglob("*.md") if not {"runs", "archive"}.intersection(path.relative_to(root / "harness").parts)]
    files += list((root / ".agents" / "skills").rglob("*.md"))
    for path in files:
        if not path.exists():
            errors.append(f"missing entry point {path.relative_to(root)}")
            continue
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", path.read_text()):
            target = target.strip("<>").split("#")[0]
            if not target or "://" in target or target.startswith("mailto:"):
                continue
            if not (path.parent / target).exists():
                errors.append(f"{path.relative_to(root)}: broken local link {target}")
    for path in (root / ".agents" / "skills").glob("*/SKILL.md"):
        content = path.read_text()
        name = re.search(r"^name: (.+)$", content, re.MULTILINE)
        description = re.search(r"^description: (.+)$", content, re.MULTILINE)
        if not content.startswith("---\n") or not name or name[1] != path.parent.name or not description:
            errors.append(f"{path.relative_to(root)}: skill metadata name/description missing or mismatched")
    backlog_path = root / "harness" / "project" / "backlog.json"
    if backlog_path.exists():
        tasks = json.loads(backlog_path.read_text())["tasks"]
        by_id = {task["id"]: task for task in tasks}
        if len(tasks) != len(by_id):
            errors.append("backlog.json: duplicate task IDs")
        visited, active = set(), set()
        def visit(task_id):
            if task_id in active:
                errors.append(f"backlog.json: cyclic dependency at {task_id}")
                return
            if task_id in visited:
                return
            active.add(task_id)
            task = by_id[task_id]
            for dependency in task["depends_on"]:
                if dependency not in by_id:
                    errors.append(f"backlog.json: {task_id} missing dependency {dependency}")
                else:
                    visit(dependency)
            active.remove(task_id)
            visited.add(task_id)
            if not task.get("write_scope") or not task.get("done_when") or not task.get("requirements"):
                errors.append(f"backlog.json: {task_id} lacks scope, acceptance or requirement IDs")
        for task_id in by_id:
            visit(task_id)
        required = set(re.findall(r"\| (R\d+) \|", (root / "harness" / "project" / "mission.md").read_text()))
        covered = {requirement for task in tasks for requirement in task["requirements"]}
        if required - covered:
            errors.append(f"backlog.json: uncovered requirements {sorted(required - covered)}")
    else:
        errors.append("missing harness/project/backlog.json")
    return errors
