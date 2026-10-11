"""Repository facts and Dart dependency directions, with actionable errors."""
import hashlib
import json
from pathlib import Path
import re
try:
    from . import next_phase
except ImportError:
    try:
        import next_phase
    except ImportError:
        from harness import next_phase

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
    "harness/project/next-phase/work.json",
}
ENTRY_INPUTS = (
    "AGENTS.md", "README.md", "docs/solution-design.md",
    "docs/next-phase-solution-design.md",
    "prototype/index.html", "prototype/README.md", "prototype/map-design.md",
    "prototype/direct-sync-design.md", "prototype/origin-return-design.md",
    "prototype/feedback-design.md",
)
LEVELS = {f"G{number}" for number in range(7)} | {f"H{number:02}" for number in range(1, 9)}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def source_files(root=ROOT):
    root = Path(root).resolve()
    roots = [root / name for name in ("app", "harness", ".agents/skills", ".github", "prototype/assets", "prototype/vendor", "prototype/next-phase")]
    # Live prototype code/assets are acceptance inputs; archives and screenshots
    # stay outside these roots. Do not change isolated-copy output exclusions.
    files = [root / name for name in ENTRY_INPUTS if (root / name).is_file() and (root / name).resolve().is_relative_to(root)]
    for directory in roots:
        if not directory.exists():
            continue
        for path in directory.rglob("*"):
            relative = path.relative_to(root)
            if (not path.is_file() or not path.resolve().is_relative_to(root)
                    or {".git", "__pycache__"}.intersection(relative.parts)
                    or any(relative.is_relative_to(prefix) for prefix in OUTPUT_ROOTS)
                    or relative.is_relative_to(Path("prototype/next-phase/evidence"))
                    or relative.as_posix() in GENERATED or path.suffix == ".iml"):
                continue
            files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def fingerprint(root=ROOT):
    root = Path(root).resolve()
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


def _json(root, relative, errors):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON field {key!r}")
            result[key] = value
        return result
    try:
        return json.loads((root / relative).read_text(), object_pairs_hook=unique_keys)
    except (OSError, ValueError, UnicodeError) as error:
        errors.append(f"{relative}: cannot read JSON: {error}")
        return None


def _object(value, fields, label, errors, exact=False):
    if not isinstance(value, dict):
        errors.append(f"{label}: expected an object")
        return False
    missing = set(fields) - value.keys()
    if missing:
        errors.append(f"{label}: missing fields {sorted(missing)}")
    if exact and value.keys() - set(fields):
        errors.append(f"{label}: unknown fields {sorted(value.keys() - set(fields))}")
    return True


def _strings(value, label, errors, nonempty=True):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        errors.append(f"{label}: expected a list of nonempty strings")
        return []
    if nonempty and not value:
        errors.append(f"{label}: must not be empty")
    if len(value) != len(set(value)):
        errors.append(f"{label}: duplicate entries")
    return value


def _path(root, value, label, errors, file=False):
    if (not isinstance(value, str) or not value or ":" in value or "\\" in value or "\0" in value
            or value.startswith("/") or any(part in {"", ".", ".."} for part in value.split("/"))):
        errors.append(f"{label}: use a canonical repository-relative path")
        return None
    path = root / value
    try:
        inside = path.resolve().is_relative_to(root)
    except (OSError, RuntimeError) as error:
        errors.append(f"{label}: cannot resolve path: {error}")
        return None
    if not inside:
        errors.append(f"{label}: path escapes the repository")
        return None
    if file and not path.is_file():
        errors.append(f"{label}: file does not exist; implement it or mark the test planned")
        return None
    return path


def _positive(value):
    return type(value) is int and value > 0


def _issue(value, label, errors, base=None):
    if not _object(value, ("number", "url", "issue_id", "body_sha256"), label, errors):
        return None
    for field in ("number", "issue_id"):
        if not _positive(value.get(field)):
            errors.append(f"{label}.{field}: expected a positive integer")
    url = value.get("url")
    match = re.fullmatch(r"(https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/issues/)([1-9]\d*)", url) if isinstance(url, str) else None
    if not match or not _positive(value.get("number")) or int(match[2]) != value["number"] or base and match[1] != base:
        errors.append(f"{label}.url: expected the canonical Issue URL matching number and parent repository")
    if not isinstance(value.get("body_sha256"), str) or not SHA256.fullmatch(value["body_sha256"]):
        errors.append(f"{label}.body_sha256: expected a SHA-256 hex digest")
    return match[1] if match else None


def _backlog(root, value, required, errors):
    label = "backlog.json"
    if not _object(value, ("schema_version", "contract_revision", "github_parent", "tasks"), label, errors):
        return {}, None
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        errors.append(f"{label}.schema_version: expected 1")
    revision = value.get("contract_revision")
    if not _positive(revision):
        errors.append(f"{label}.contract_revision: expected a positive integer")
    parent = value.get("github_parent")
    base = _issue(parent, f"{label}.github_parent", errors)
    parent = parent if isinstance(parent, dict) else {}
    epic = _path(root, "harness/project/issues/EPIC.md", f"{label}.github_parent.issue", errors, file=True)
    if epic:
        body = epic.read_bytes()
        if f"<!-- ocean-delivery-epic:FLUTTER-PARITY; contract:{revision} -->" not in body.decode("utf-8", errors="replace"):
            errors.append(f"{label}.github_parent.issue: epic/contract marker is missing or mismatched")
        if hashlib.sha256(body).hexdigest() != parent.get("body_sha256"):
            errors.append(f"{label}.github_parent.body_sha256: local EPIC body differs from publication metadata")
    tasks = value.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        errors.append(f"{label}.tasks: expected a nonempty list")
        return {}, revision
    by_id, identities = {}, {key: set() for key in ("number", "issue_id", "url")}
    for key in identities:
        if isinstance(parent.get(key), (int, str)):
            identities[key].add(parent[key])
    for index, task in enumerate(tasks):
        location = f"{label}.tasks[{index}]"
        if not _object(task, ("id", "requirements", "depends_on", "skills", "write_scope", "acceptance", "done_when", "github"), location, errors):
            continue
        task_id = task.get("id")
        if not isinstance(task_id, str) or not re.fullmatch(r"[EX]\d{2}", task_id):
            errors.append(f"{location}.id: expected a stable E/X task ID")
            continue
        location += f" ({task_id})"
        if task_id in by_id:
            errors.append(f"{location}: duplicate task ID {task_id}")
            continue
        by_id[task_id] = task
        requirements = _strings(task.get("requirements"), f"{location}.requirements", errors)
        if set(requirements) - required:
            errors.append(f"{location}.requirements: unknown requirements {sorted(set(requirements) - required)}")
        _strings(task.get("depends_on"), f"{location}.depends_on", errors, nonempty=False)
        for scope in _strings(task.get("write_scope"), f"{location}.write_scope", errors):
            _path(root, scope, f"{location}.write_scope", errors)
        _strings(task.get("acceptance"), f"{location}.acceptance", errors)
        if not isinstance(task.get("done_when"), str) or not task["done_when"].strip():
            errors.append(f"{location}.done_when: nonempty acceptance is required")
        for skill in _strings(task.get("skills"), f"{location}.skills", errors):
            if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", skill):
                errors.append(f"{location}.skills: invalid skill name {skill!r}")
                continue
            path = _path(root, f".agents/skills/{skill}/SKILL.md", f"{location}.skills ({skill})", errors, file=True)
            if path:
                try:
                    content = path.read_text()
                except (OSError, UnicodeError) as error:
                    errors.append(f"{location}.skills: cannot read {path.relative_to(root)}: {error}")
                    continue
                if not content.startswith("---\n") or not re.search(rf"^name: {re.escape(skill)}$", content, re.MULTILINE) or not re.search(r"^description: \S", content, re.MULTILINE):
                    errors.append(f"{location}.skills: {path.relative_to(root)} metadata name/description missing or mismatched")
        github = task.get("github")
        _issue(github, f"{location}.github", errors, base)
        if not isinstance(github, dict):
            continue
        for key, seen in identities.items():
            identity = github.get(key)
            if isinstance(identity, (int, str)):
                if identity in seen:
                    errors.append(f"{location}.github.{key}: duplicate Issue identity {identity!r}")
                seen.add(identity)
        if not _positive(github.get("parent_number")) or github["parent_number"] != parent.get("number"):
            errors.append(f"{location}.github.parent_number: does not match the parent Issue")
        issue_path = _path(root, f"harness/project/issues/{task_id}.md", f"{location}.issue", errors, file=True)
        if issue_path:
            body = issue_path.read_bytes()
            text = body.decode("utf-8", errors="replace")
            if f"<!-- ocean-delivery-task:{task_id}; contract:{revision} -->" not in text:
                errors.append(f"{location}.issue: task/contract marker is missing or mismatched")
            if not isinstance(parent.get("url"), str) or parent["url"] not in text:
                errors.append(f"{location}.issue: parent Issue link is missing or mismatched")
            if hashlib.sha256(body).hexdigest() != github.get("body_sha256"):
                errors.append(f"{location}.github.body_sha256: local Issue body differs from publication metadata")
    dependencies = {task_id: task.get("depends_on", []) if isinstance(task.get("depends_on"), list) else [] for task_id, task in by_id.items()}
    for task_id, task in by_id.items():
        names = [name for name in dependencies[task_id] if isinstance(name, str)]
        for dependency in names:
            if dependency not in by_id:
                errors.append(f"{label}: {task_id} missing dependency {dependency}")
        github = task.get("github")
        if not isinstance(github, dict):
            continue
        numbers = github.get("blocked_by_numbers")
        if not isinstance(numbers, list) or any(not _positive(number) for number in numbers):
            errors.append(f"{label}: {task_id}.github.blocked_by_numbers must be a list of positive integers")
        else:
            expected = [by_id[name].get("github", {}).get("number") for name in names if name in by_id and isinstance(by_id[name].get("github"), dict)]
            if len(numbers) != len(set(numbers)) or sorted(numbers) != sorted(number for number in expected if _positive(number)):
                errors.append(f"{label}: {task_id}.github.blocked_by_numbers does not match depends_on Issue numbers")
    visited, active = set(), []
    def visit(task_id):
        if task_id in active:
            errors.append(f"{label}: cyclic dependency {' -> '.join(active[active.index(task_id):] + [task_id])}")
            return
        if task_id in visited:
            return
        active.append(task_id)
        for dependency in dependencies[task_id]:
            if isinstance(dependency, str) and dependency in by_id:
                visit(dependency)
        active.pop()
        visited.add(task_id)
    for task_id in by_id:
        visit(task_id)
    covered = {requirement for task in by_id.values() for requirement in (task["requirements"] if isinstance(task.get("requirements"), list) else []) if isinstance(requirement, str)}
    if required - covered:
        errors.append(f"{label}: uncovered requirements {sorted(required - covered)}")
    return by_id, revision


def _historical_evidence(root, value, label, errors):
    fields = ("report", "sha256", "stage", "usage")
    if not _object(value, fields, label, errors, exact=True):
        return
    if value.get("usage") != "historical":
        errors.append(f"{label}.usage: tracked matrix accepts historical references only; fresh passed results belong in generated manifests")
    if not isinstance(value.get("stage"), str) or not value["stage"].strip():
        errors.append(f"{label}.stage: expected a nonempty actual stage ID")
    path = _path(root, value.get("report"), f"{label}.report", errors, file=True)
    if not path:
        return
    if not isinstance(value.get("sha256"), str) or not SHA256.fullmatch(value["sha256"]) or hashlib.sha256(path.read_bytes()).hexdigest() != value["sha256"]:
        errors.append(f"{label}.sha256: report hash missing or mismatched")
    report = _json(root, value["report"], errors)
    if not isinstance(report, dict) or not isinstance(report.get("stages"), list):
        errors.append(f"{label}: expected a Harness run report with stages")
        return
    candidates = report.get("candidate"), report.get("candidate_after")
    if any(not isinstance(candidate, dict) or not isinstance(candidate.get("source_fingerprint"), str) or not SHA256.fullmatch(candidate["source_fingerprint"]) for candidate in candidates) or candidates[0] != candidates[1]:
        errors.append(f"{label}: report candidate is missing or changed during execution")
    if not isinstance(report.get("job"), dict) or report["job"].get("status") != "passed":
        errors.append(f"{label}: historical run must actually have completed successfully")
    stages = [stage for stage in report["stages"] if isinstance(stage, dict) and stage.get("id") == value.get("stage")]
    if len(stages) != 1:
        errors.append(f"{label}.stage: expected one matching actual stage")
        return
    stage = stages[0]
    if stage.get("status") != "passed" or type(stage.get("exit_code")) is not int or stage["exit_code"] != 0:
        errors.append(f"{label}.stage: must be passed with exit_code 0, never running/skipped/interrupted")
    log_value = stage.get("log_path")
    log = Path(log_value) if isinstance(log_value, str) and log_value and "\0" not in log_value else None
    if log is not None and not log.is_absolute():
        log = path.parent / log
    try:
        valid_log = (log is not None and log.resolve().is_relative_to(root) and log.is_file()
                     and isinstance(stage.get("sha256"), str)
                     and hashlib.sha256(log.read_bytes()).hexdigest() == stage["sha256"])
    except (OSError, ValueError, RuntimeError):
        valid_log = False
    if not valid_log:
        errors.append(f"{label}.stage: raw log path/hash missing, escaped or mismatched")


def traceability(root=ROOT):
    """Validate the index, never infer business passes from file/title presence."""
    root = Path(root).resolve()
    errors = []
    try:
        mission = (root / "harness/project/mission.md").read_text()
        required = set(re.findall(r"\| (R\d+) \|", mission))
        if not required:
            errors.append("mission.md: requirement IDs are missing")
    except (OSError, UnicodeError) as error:
        required = set()
        errors.append(f"mission.md: cannot read requirements: {error}")
    tasks, revision = _backlog(root, _json(root, "harness/project/backlog.json", errors), required, errors)
    matrix = _json(root, "harness/project/requirement-matrix.json", errors)
    label = "requirement-matrix.json"
    if not _object(matrix, ("schema_version", "contract_revision", "requirements"), label, errors, exact=True):
        return errors
    if type(matrix.get("schema_version")) is not int or matrix["schema_version"] != 1:
        errors.append(f"{label}.schema_version: expected 1")
    if not _positive(matrix.get("contract_revision")) or matrix["contract_revision"] != revision:
        errors.append(f"{label}.contract_revision: must match backlog contract revision")
    rows = matrix.get("requirements")
    if not isinstance(rows, list):
        errors.append(f"{label}.requirements: expected a list")
        return errors
    input_paths = {path.resolve() for path in source_files(root)}
    seen = set()
    for index, row in enumerate(rows):
        location = f"{label}.requirements[{index}]"
        if not _object(row, ("id", "sources", "tasks", "tests", "gaps"), location, errors, exact=True):
            continue
        requirement = row.get("id")
        if not isinstance(requirement, str) or requirement not in required:
            errors.append(f"{location}.id: unknown requirement {requirement!r}")
            continue
        if requirement in seen:
            errors.append(f"{location}: duplicate requirement {requirement}")
        seen.add(requirement)
        for source in _strings(row.get("sources"), f"{location}.sources", errors):
            path = _path(root, source, f"{location}.sources ({source})", errors, file=True)
            if path and path.resolve() not in input_paths:
                errors.append(f"{location}.sources: {source} is outside candidate fingerprint inputs")
        mapped = _strings(row.get("tasks"), f"{location}.tasks", errors)
        expected = {task_id for task_id, task in tasks.items() if isinstance(task.get("requirements"), list) and requirement in task["requirements"]}
        if set(mapped) != expected:
            errors.append(f"{location}.tasks: must match declared backlog joins; missing={sorted(expected - set(mapped))}, unexpected={sorted(set(mapped) - expected)}")
        tests, gaps = row.get("tests"), row.get("gaps")
        if not isinstance(tests, list) or not isinstance(gaps, list):
            errors.append(f"{location}: tests and gaps must be lists")
            continue
        if not tests and not gaps:
            errors.append(f"{location}: missing test mapping or explicit gap")
        bindings = set()
        for test_index, test in enumerate(tests):
            test_label = f"{location}.tests[{test_index}]"
            if not _object(test, ("task", "path", "state", "level", "cases", "evidence"), test_label, errors, exact=True):
                continue
            if not isinstance(test.get("task"), str) or test["task"] not in mapped or test["task"] not in tasks:
                errors.append(f"{test_label}.task: must join an accountable backlog task in this row")
            if test.get("state") not in ("planned", "implemented"):
                errors.append(f"{test_label}.state: use planned/implemented; source presence is not passed execution")
            level = test.get("level")
            if not isinstance(level, str) or level not in LEVELS:
                errors.append(f"{test_label}.level: expected a recognized verification level")
            path = _path(root, test.get("path"), f"{test_label}.path", errors, file=test.get("state") == "implemented")
            if path:
                relative = path.relative_to(root)
                host_dart = relative.is_relative_to(Path("app/test"))
                host_python = relative.is_relative_to(Path("harness/tests"))
                host = host_dart or host_python
                native = any(relative.is_relative_to(prefix) for prefix in (Path("app/integration_test"), Path("app/test_driver")))
                suffix_matches = (host_dart or native) and relative.suffix == ".dart" or host_python and relative.suffix == ".py"
                if (not host and not native or not suffix_matches
                        or host and level != "G1" or native and (not isinstance(level, str) or level not in {"G2", "G3"})):
                    errors.append(f"{test_label}.path/level: use a supported test root and matching host/native level")
            _strings(test.get("cases"), f"{test_label}.cases", errors)
            binding = (test.get("task"), test.get("path"), test.get("level"))
            if all(isinstance(part, str) for part in binding):
                if binding in bindings:
                    errors.append(f"{test_label}: duplicate test binding")
                bindings.add(binding)
            evidence = test.get("evidence")
            if not isinstance(evidence, list):
                errors.append(f"{test_label}.evidence: expected a list")
            elif test.get("state") == "planned" and evidence:
                errors.append(f"{test_label}.evidence: planned tests cannot claim run evidence")
            else:
                for evidence_index, item in enumerate(evidence):
                    _historical_evidence(root, item, f"{test_label}.evidence[{evidence_index}]", errors)
        seen_gaps = set()
        for gap_index, gap in enumerate(gaps):
            gap_label = f"{location}.gaps[{gap_index}]"
            if not _object(gap, ("task", "level", "reason"), gap_label, errors, exact=True):
                continue
            if not isinstance(gap.get("task"), str) or gap["task"] not in mapped or gap["task"] not in tasks:
                errors.append(f"{gap_label}.task: must join a backlog task in this row")
            if not isinstance(gap.get("level"), str) or gap["level"] not in LEVELS or not isinstance(gap.get("reason"), str) or not gap["reason"].strip():
                errors.append(f"{gap_label}: recognized level and nonempty reason are required")
            binding = tuple(gap.get(key) for key in ("task", "level", "reason"))
            if all(isinstance(part, str) for part in binding):
                if binding in seen_gaps:
                    errors.append(f"{gap_label}: duplicate gap")
                seen_gaps.add(binding)
    if required - seen:
        errors.append(f"{label}: missing requirements {sorted(required - seen)}")
    return errors


def repository(root=ROOT):
    root = Path(root).resolve()
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
    errors.extend(traceability(root))
    errors.extend(next_phase.validate(root, {path.relative_to(root).as_posix() for path in source_files(root)}))
    return errors
