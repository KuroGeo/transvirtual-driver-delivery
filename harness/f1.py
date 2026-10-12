"""F1 execution overlay and local navigation evidence; never production approval.

The published prepare package remains immutable history. Its independent F1
overlay authorizes only navigation, and evidence gates reread original bytes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

try:
    from . import gate
except ImportError:
    import gate

PACKAGE = "harness/project/next-phase"
SLICES = frozenset(("NP00", "NP01", "NP05", "NP06", "NP10", "NP11", "NP12", "NP13"))
STATUSES = frozenset(("planned", "running", "review", "accepted", "blocked"))
HOST_CHECKS = frozenset((
    "F1.scope-late-result", "F1.input-revision", "F1.location-freshness",
    "F1.road-unavailable-failure", "F1.provider-provenance", "F1.third-party-privacy",
    "F1.launch-failure", "F1.resume-ordering", "F1.source-return", "F1.no-delivery-write",
    "F1.large-text",
))
NATIVE_CHECKS = frozenset(("F1.route-preview", "F1.return-map", "F1.return-list", "F1.return-query",
                           "F1.return-nearest", "F1.outbox-invariance", "F1.cold-recovery"))
EXTERNAL = ("real-external-maps", "real-gps", "real-road", "physical-device", "production")
DEPENDENCIES = {"NP00": [], "NP01": ["NP00"], "NP05": ["NP00", "NP01"],
                "NP06": ["NP00", "NP01", "NP05"], "NP10": ["NP06"],
                "NP11": ["NP10"], "NP12": ["NP11"], "NP13": ["NP12"]}


def _read(path):
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_file():
        raise gate.EvidenceError(f"F1: missing canonical regular file {path}")
    return gate._object(gate._json(path.read_bytes(), str(path)), str(path))


def validate_execution(root, candidate_inputs, fingerprint=None):
    """Validate the mutable F1 overlay separately from the prepare registry."""
    root = Path(root).resolve()
    path = root / PACKAGE / "execution.json"
    if not path.exists() and not path.is_symlink():
        return []
    try:
        value = _read(path)
        for key, expected in (("schema_version", 1), ("mode", "execute"),
                              ("authorized_features", ["F1"]), ("production_eligible", False)):
            gate._expect(value.get(key), expected, "F1 execution " + key)
        revision = gate._integer(value.get("contract_revision"), "F1 contract_revision", 4)
        contract_name = f"{PACKAGE}/f1-execution.md"
        gate._expect(value.get("contract"), contract_name, "F1 execution contract path")
        contract = root / contract_name
        if contract_name not in candidate_inputs or contract.resolve() != contract or not contract.is_file():
            raise gate.EvidenceError("F1 contract is missing, symlinked or outside candidate inputs")
        if not contract.read_text().startswith(f"# F1 execution contract {revision} "):
            raise gate.EvidenceError("F1 contract revision does not match frozen document")
        authorization = gate._object(value.get("authorization"), "F1 authorization")
        for key in ("date", "source", "scope"):
            gate._text(authorization.get(key), "F1 authorization " + key)
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", authorization["date"]):
            raise gate.EvidenceError("F1 authorization date must be explicit ISO date")
        if not re.fullmatch(r"[a-f0-9]{7,40}", value.get("source_main", "")) or not re.fullmatch(r"[a-f0-9]{40}", value.get("planning_sha", "")):
            raise gate.EvidenceError("F1 source main/planning identities missing")
        slices = gate._object(value.get("slices"), "F1 slices")
        if set(slices) != SLICES:
            raise gate.EvidenceError("F1 slices must be exactly NP00/01/05/06/10/11/12/13; F2/F3 execution forbidden")
        for name, entry in slices.items():
            gate._object(entry, "F1 slice " + name)
            if entry.get("status") not in STATUSES:
                raise gate.EvidenceError(f"F1 {name}: unknown status")
            gate._expect(entry.get("functional_depends_on"), DEPENDENCIES[name], f"F1 {name} navigation functional dependencies")
            gate._expect(entry.get("interface_dependencies"), ["NP03 AccountScope", "NP04 sessionGeneration"] if name in ("NP05", "NP06") else [], f"F1 {name} deferred account interface dependencies")
            evidence = gate._list(entry.get("evidence"), f"F1 {name} evidence", nonempty=False)
            if entry["status"] in ("running", "review", "accepted"):
                gate._text(entry.get("owner_agent_id"), f"F1 {name} owner")
            if entry["status"] == "planned" and (entry.get("candidate") is not None or evidence):
                raise gate.EvidenceError(f"F1 {name}: planned cannot attest execution evidence")
            if entry["status"] == "accepted":
                candidate = gate._object(entry.get("candidate"), f"F1 {name} candidate")
                if name == "NP00":
                    gate._expect(candidate.get("source_main"), value["source_main"], "F1 NP00 source main")
                    gate._expect(candidate.get("planning_sha"), value["planning_sha"], "F1 NP00 planning source")
                else:
                    gate._hash(candidate.get("source_fingerprint"), f"F1 {name} candidate fingerprint")
                    if fingerprint is not None:
                        gate._expect(candidate["source_fingerprint"], fingerprint, f"F1 {name} accepted candidate")
                if not evidence:
                    raise gate.EvidenceError(f"F1 {name}: acceptance requires retained evidence")
            for reference in evidence:
                gate._object(reference, f"F1 {name} evidence reference")
                gate._hash(reference.get("sha256"), f"F1 {name} evidence hash")
                gate._text(reference.get("path"), f"F1 {name} evidence path")
                gate._text(reference.get("kind"), f"F1 {name} evidence kind")
                target = root / reference["path"]
                if not target.is_relative_to(root) or target.resolve() != target or not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != reference["sha256"]:
                    raise gate.EvidenceError(f"F1 {name}: missing/unsafe/mismatched original evidence")
            if entry["status"] == "accepted" and name != "NP00":
                _accepted_slice(name, entry, root, fingerprint or entry["candidate"]["source_fingerprint"])
        return []
    except (gate.EvidenceError, OSError, ValueError, TypeError, UnicodeError, KeyError, IndexError, AttributeError, RecursionError, gate.sqlite3.Error) as error:
        return [str(error)]


def _accepted_slice(name, entry, root, fingerprint):
    """A board's accepted word cannot substitute for verified execution proof."""
    if name == "NP13":
        raise gate.EvidenceError("F1 NP13 cannot be accepted while real-road/external-service validation is unverified")
    validator = F1Validator({"candidate": {"source_fingerprint": fingerprint}, "service_mode": "local-client"}, fingerprint, root)
    valid = False
    for reference in entry["evidence"]:
        if reference["kind"] == "quality-run" and name == "NP01":
            item = validator.raw(reference)
            validator.quality(gate._object(gate._json(item["raw"], "accepted F1 quality"), "accepted F1 quality"), item)
            valid = True
        elif reference["kind"] == "f1-gate":
            item = validator.raw(reference)
            report = gate._object(gate._json(item["raw"], "accepted F1 gate"), "accepted F1 gate")
            gate._expect(report.get("candidate"), {"source_fingerprint": fingerprint}, "accepted F1 gate candidate")
            gate._expect(report.get("feature_allowed"), True, "accepted F1 gate verdict")
            gate._expect(report.get("publish_allowed"), False, "accepted F1 never publishes")
            manifest_item = validator.raw(report.get("evidence_manifest"))
            gate._expect(manifest_item["kind"], "f1-manifest", "accepted F1 original manifest kind")
            manifest = gate._object(gate._json(manifest_item["raw"], "accepted F1 manifest"), "accepted F1 manifest")
            result = evaluate(manifest, fingerprint, root, validate_registry=False)
            if not result["feature_allowed"]:
                raise gate.EvidenceError("accepted F1 evidence revalidation failed: " + "; ".join(result["reasons"]))
            gate._expect(report.get("level"), result["level"], "accepted F1 gate actual evidence level")
            if name == "NP12":
                gate._expect(result["level"], "native-fixture", "F1 NP12 requires native original evidence")
            valid = True
    if not valid:
        raise gate.EvidenceError(f"F1 {name}: accepted requires verified current quality/F1 gate, never documents alone")


def boundaries(root, directives):
    """Small mechanical policy; behavior and URI values remain tested in Dart."""
    root = Path(root).resolve()
    lib = root / "app/lib"
    errors = []
    modules = [lib / name for name in ("data/routes", "platform/navigation", "platform/location")]
    paths = [path for directory in modules if directory.exists() for path in directory.rglob("*.dart")]
    model = lib / "ui/navigation/navigation_view_model.dart"
    if model.exists():
        paths.append(model)
    for path in paths:
        relative = path.relative_to(root).as_posix()
        if path.resolve() != path or not path.is_file():
            errors.append(f"{relative}: F1 source must be a canonical regular candidate input")
            continue
        source = path.read_text()
        for uri in directives(source):
            if ("/data/delivery/" in uri or "sqlite_delivery_repository" in uri
                    or uri.startswith(("package:sqflite", "package:dio/", "package:http/"))
                    or "service/" in uri):
                errors.append(f"{relative}: F1 route/navigation boundary forbids delivery storage or own HTTP/backend transport: {uri}")
        # F1 must not mutate delivery terminal state or confirmation queue.
        for call in ("recordDelivery", "submitDelivery", "enqueue", "confirmDelivery", "markDelivered"):
            if re.search(r"\b" + call + r"\s*\(", source):
                errors.append(f"{relative}: F1 cannot call delivery/outbox mutation {call}")
    for directory in (root / "service/routes", root / "service/internal/routes", root / "service/matrix", root / "service/internal/matrix"):
        if directory.exists():
            errors.append(f"{directory.relative_to(root)}: F1 own routes/matrix backend forbidden")
    port = lib / "data/routes/third_party_route_port.dart"
    if port.exists():
        definition = port.read_text().split("class ThirdPartyRouteRequest", 1)
        fields = set(re.findall(r"\bfinal\s+\w+(?:<[^;]+>)?\s+(\w+)\s*;", definition[1].split("class ThirdPartyRouteResponse", 1)[0])) if len(definition) == 2 else set()
        if fields != {"origin", "destination", "departureAt", "mode"}:
            errors.append("app/lib/data/routes/third_party_route_port.dart: supplier request may contain only origin/destination/departureAt/mode; no scope/identity/notes/credentials")
    repository = lib / "data/routes/route_repository.dart"
    if repository.exists() and not re.search(r"this\.port\s*=\s*const\s+UnavailableThirdPartyRoutePort\(\)", repository.read_text()):
        errors.append("app/lib/data/routes/route_repository.dart: default road port must remain explicitly unavailable without licensed supplier configuration")
    return errors


class F1Validator(gate.Validator):
    def host(self, reference, quality):
        item = self.raw(reference)
        gate._expect(item["kind"], "f1-host-coverage", "F1 host evidence kind")
        report = gate._object(gate._json(item["raw"], "F1 host coverage"), "F1 host coverage")
        for key, expected in (("schema", 1), ("feature", "F1"), ("level", "host"),
                              ("candidate", self.fingerprint), ("status", "passed")):
            gate._expect(report.get(key), expected, "F1 host " + key)
        checks = gate._list(report.get("checks"), "F1 host checks")
        for check in checks:
            gate._object(check, "F1 host check")
        if len(checks) != len(HOST_CHECKS) or {check.get("id") for check in checks} != HOST_CHECKS:
            raise gate.EvidenceError("F1 host coverage requires every frozen feature check exactly once")
        flutter = next(stage for stage in quality["stages"] if stage["id"] == "flutter-tests")
        machine = self.raw(flutter.get("machine_report"))
        gate._expect(machine["kind"], "flutter-machine-events", "F1 original machine reporter kind")
        events = self.flutter_events(machine)
        seen = set()
        for check in checks:
            gate._expect(check.get("status"), "passed", "F1 host check status")
            source = gate._text(check.get("source"), "F1 host test source")
            name = gate._text(check.get("test"), "F1 host test name")
            if not source.startswith("app/test/") or not source.endswith(".dart") or ".." in Path(source).parts:
                raise gate.EvidenceError("F1 test must be a current app/test Dart source")
            path = gate.SOURCE_ROOT / source
            if path.resolve() != path or not path.is_file() or name not in path.read_text():
                raise gate.EvidenceError("F1 host test name missing from canonical current source")
            reporter_source = source.removeprefix("app/")
            expected_path = str(Path(quality["execution_root"]) / "app" / reporter_source)
            matches = [tid for tid, test in events["starts"].items()
                       if test["name"] == name and events["suites"][test["suiteID"]]["path"] in (expected_path, reporter_source)
                       and events["done"][tid]["hidden"] is False]
            if len(matches) != 1:
                raise gate.EvidenceError(f"F1 named test must complete once in its original machine suite: {name}")
            seen.add((source, name))
        if len(seen) < 7:
            raise gate.EvidenceError("F1 feature coverage cannot reuse one broad test for all checks")
        return report

    def native(self, evidence):
        """Reuse full PID/artifact/raw inventory checks, then F1 UI provenance."""
        evidence = gate._object(evidence, "F1 native evidence")
        artifacts = {name: self.raw(reference) for name, reference in gate._object(evidence.get("artifacts"), "F1 native artifacts").items()}
        # F1 uses the same collector but no historical N1–N7 scenario. Its
        # support source input is collected explicitly below by the producer.
        run = self.native_run({"report": "collector", "runner_report": "runner", "artifact_manifest": "compiled"}, artifacts)
        gate._expect(run.get("driver_target"), "integration_test/f1_navigation_driver.dart", "F1 independent driver")
        self.current_inputs(run.get("inputs"), {"app/integration_test/support/f1_navigation_fixture.dart": gate.SOURCE_ROOT / "app/integration_test/support/f1_navigation_fixture.dart"})
        gate._expect(run.get("acceptance_options", {}).get("scenario"), None, "F1 separate scenario")
        gate._expect(run.get("device_type"), "simulator", "F1 native local device")
        gate._expect(run.get("build_mode"), "debug", "F1 native local build")
        gate._expect(run.get("device_cleaned"), True, "F1 task device cleaned")
        return self.navigation_phases(run)

    def navigation_phases(self, run):
        """Validate original feature UI graph after native OS provenance checks."""
        all_checks = set()
        baseline = None
        durable = None
        for launch in run["launches"]:
            phase = launch["phase"]
            owner = run["_evidence_owner"] / phase
            inventory = run["_verified_artifacts"]
            def raw(name):
                path = owner / name
                digest = inventory.get(str(path))
                if not digest:
                    raise gate.EvidenceError(f"F1 native missing original inventoried {phase}/{name}")
                return self.raw({"path": str(path), "sha256": digest, "kind": "driver-raw-evidence"})
            result = gate._object(gate._json(raw("result.json")["raw"], "F1 driver result"), "F1 driver result")
            gate._expect(result.get("scope"), "f1-native-navigation-fixture", "F1 driver scope")
            gate._expect(result.get("status"), "passed", "F1 driver status")
            for key, expected in (("candidate", self.fingerprint), ("processId", launch["processId"]),
                                  ("vmProcessId", launch["processId"]), ("session", launch["session"]), ("phase", phase), ("configuration", run["configuration"])):
                gate._expect(result.get(key), expected, "F1 driver " + key)
            checks = gate._list(result.get("f1Checks"), "F1 independent UI checks", nonempty=False)
            for check in checks:
                gate._object(check, "F1 UI check")
                if check.get("id") not in NATIVE_CHECKS or check["id"] in all_checks:
                    raise gate.EvidenceError("F1 native unknown/duplicate feature UI check")
                gate._expect(check.get("status"), "passed", "F1 native UI status")
                all_checks.add(check["id"])
            actions = self.jsonl(raw("actions.jsonl"))
            observations = self.jsonl(raw("observations.jsonl"))
            initial = gate._object(gate._json(raw("initial-snapshot.json")["raw"], "F1 initial"), "F1 initial")
            final = gate._object(gate._json(raw("snapshot.json")["raw"], "F1 final"), "F1 final")
            gate._list(initial.get("stops"), "F1 ready baseline stops")
            gate._list(initial.get("outbox"), "F1 ready baseline outbox", nonempty=False)
            gate._expect(initial.get("model", {}).get("initialized"), True, "F1 ready baseline initialized")
            identity = {"candidate": self.fingerprint, "processId": launch["processId"], "session": launch["session"], "configuration": run["configuration"]}
            for row in [*actions, *observations, initial, final]:
                for key, expected in identity.items():
                    gate._expect(row.get(key), expected, "F1 raw UI identity " + key)
            for snapshot in (initial, final):
                if not any(gate._equal(snapshot, row) for row in observations):
                    raise gate.EvidenceError("F1 raw snapshots must occur in original observations")
                if snapshot.get("stops") != initial.get("stops") or snapshot.get("outbox") != initial.get("outbox"):
                    raise gate.EvidenceError("F1 navigation changed delivery terminal state/outbox")
            start = next(index for index, row in enumerate(observations) if gate._equal(row, initial))
            for snapshot in observations[start:]:
                if snapshot.get("stops") != initial["stops"] or snapshot.get("outbox") != initial["outbox"]:
                    raise gate.EvidenceError("F1 intermediate navigation observation changed delivery/outbox")
            if baseline is None:
                baseline = (initial.get("stops"), initial.get("outbox"))
            if baseline != (final.get("stops"), final.get("outbox")):
                raise gate.EvidenceError("F1 persisted delivery/outbox changed across relaunch")
            pairs = {}
            for action in actions:
                pairs.setdefault(action.get("sequence"), []).append(action)
            completed = []
            for pair in pairs.values():
                if len(pair) != 2 or [row.get("stage") for row in pair] != ["started", "completed"] or pair[0].get("action") != pair[1].get("action"):
                    raise gate.EvidenceError("F1 UI action must complete exactly once")
                completed.append(pair[0].get("action"))
            for check in checks:
                names = gate._list(check.get("actions"), "F1 claimed UI actions")
                if any(name not in completed for name in names):
                    raise gate.EvidenceError("F1 claimed UI actions absent from original driver journal")
                def observation(field):
                    name = gate._text(check.get(field), "F1 check " + field)
                    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.json", name):
                        raise gate.EvidenceError("F1 check snapshots must be exact phase files")
                    snapshot = gate._object(gate._json(raw(name)["raw"], "F1 check snapshot"), "F1 check snapshot")
                    if not any(gate._equal(snapshot, row) for row in observations):
                        raise gate.EvidenceError("F1 check snapshot absent from original observations")
                    return snapshot
                before, after = observation("before"), observation("after")
                if check["id"] == "F1.route-preview":
                    gate._expect(before.get("model", {}).get("panel"), "detail", "F1 preview starts at detail")
                    bounds = after.get("bounds", {}).get("navigation-preview")
                    if not isinstance(bounds, list) or not bounds:
                        raise gate.EvidenceError("F1 original observed route-preview UI missing")
                    gate._expect(after.get("navigation", {}).get("gatewaySource"), "controlled-navigation-fixture", "F1 navigation gateway original fixture provenance")
                    self.fixture_navigation(after, before)
                elif check["id"].startswith("F1.return-"):
                    origin = {"F1.return-query": "list", "F1.return-list": "list", "F1.return-map": "map", "F1.return-nearest": "nearest"}[check["id"]]
                    for snapshot in (before, after):
                        gate._expect(snapshot.get("model", {}).get("panel"), "detail", "F1 original/returned detail")
                        gate._expect(snapshot["model"].get("selectedOrigin"), origin, "F1 return original source")
                    for key in ("selected", "query"):
                        if before["model"].get(key) is None:
                            raise gate.EvidenceError("F1 return lacks actual selected stop/query")
                        gate._expect(after["model"].get(key), before["model"][key], "F1 return preserved " + key)
                    if check["id"] == "F1.return-query" and not before["model"]["query"].get("search"):
                        raise gate.EvidenceError("F1 query return requires actual nonempty filter")
                    preview = observation("preview")
                    handoff = observation("handoff")
                    self.fixture_navigation(preview, before)
                    self.fixture_navigation(handoff, before)
                    gate._expect(handoff["navigation"].get("handoffStatus"), "handoffRequested", "F1 actual fixture handoff requested")
                    returned = observation("sourceReturned")
                    gate._expect(returned.get("model", {}).get("panel"), "list" if origin == "list" else "map", "F1 source back panel")
                    gate._expect(returned["model"].get("query"), before["model"]["query"], "F1 source back query")
                    if origin in ("map", "nearest"):
                        gate._expect(returned.get("camera"), before.get("camera"), "F1 source back map viewport")
            # Original native SQLite backups must match the read-only bridge.
            sqlite_item = raw("phase-final.sqlite")
            database = self.database(sqlite_item)
            persisted = database["tables"]["outbox"]
            identities = [(row["seq"], row["operation_id"], row["dataset_id"], row["stop_id"]) for row in persisted]
            snapshot_ids = [(row["seq"], row["operationId"], row["datasetId"], row["stopId"]) for row in final.get("outbox", [])]
            if identities != snapshot_ids:
                raise gate.EvidenceError("F1 original SQLite backup disagrees with outbox snapshot")
            state = {key: database["tables"][key] for key in ("datasets", "stops", "outbox")}
            if durable is None:
                durable = state
            if state != durable:
                raise gate.EvidenceError("F1 durable delivery/outbox bytes changed across actual OS relaunch")
            self.png(raw("phase-final.png"))
        if all_checks != NATIVE_CHECKS:
            raise gate.EvidenceError("F1 native requires preview/map/list/query/nearest/invariance/recovery UI evidence")
        return run

    def fixture_navigation(self, snapshot, original_detail):
        navigation = gate._object(snapshot.get("navigation"), "F1 actual navigation snapshot")
        gate._expect(navigation.get("gatewaySource"), "controlled-navigation-fixture", "F1 original fixture gateway provenance")
        gate._expect(navigation.get("isValid"), True, "F1 current navigation target")
        gate._expect(navigation.get("targetStopId"), original_detail.get("model", {}).get("selected", {}).get("id"), "F1 selected destination binding")
        gate._text(navigation.get("targetStopId"), "F1 actual selected destination")
        gate._expect(navigation.get("previewStatus"), "unavailable", "F1 unavailable road supplier is honest")
        gate._expect(navigation.get("routeProvider"), None, "F1 absent licensed road provenance cannot become route/ETA")


def evaluate(manifest, fingerprint, base_dir, *, validate_registry=True):
    result = {"feature": "F1", "feature_allowed": False, "publish_allowed": False,
              "candidate": {"source_fingerprint": fingerprint}, "level": None, "external_unverified": list(EXTERNAL), "reasons": []}
    try:
        gate._object(manifest, "F1 manifest")
        for key, expected in (("schema", 1), ("feature", "F1"), ("publish_allowed", False)):
            gate._expect(manifest.get(key), expected, "F1 manifest " + key)
        if manifest.get("level") not in ("host", "native-fixture"):
            raise gate.EvidenceError("F1 level must be host or native-fixture; fixture cannot attest live/device/production")
        result["level"] = manifest["level"]
        gate._expect(manifest.get("external_unverified"), list(EXTERNAL), "F1 unverified external boundaries")
        root = gate.SOURCE_ROOT
        registry_path = root / PACKAGE / "execution.json"
        if not registry_path.is_file():
            raise gate.EvidenceError("F1 execution authorization overlay is missing")
        if validate_registry:
            errors = validate_execution(root, {f"{PACKAGE}/f1-execution.md"}, fingerprint)
            if errors:
                raise gate.EvidenceError(errors[0])
        validator = F1Validator({**manifest, "service_mode": "local-client"}, fingerprint, base_dir)
        item = validator.raw(manifest.get("quality"))
        gate._expect(item["kind"], "quality-run", "F1 quality evidence kind")
        quality = gate._object(gate._json(item["raw"], "F1 quality run"), "F1 quality run")
        validator.quality(quality, item)
        validator.host(manifest.get("host"), quality)
        if manifest["level"] == "native-fixture":
            validator.native(manifest.get("native"))
        elif "native" in manifest:
            raise gate.EvidenceError("F1 host level cannot include or claim native evidence")
        result["feature_allowed"] = True
    except (gate.EvidenceError, OSError, ValueError, TypeError, KeyError, UnicodeError, IndexError, AttributeError, RecursionError, gate.sqlite3.Error) as error:
        result["reasons"].append(str(error))
    return result


def collect_host(root, quality_path=None):
    """Generate candidate-bound F1 host receipts by inspecting raw full logs.

    The current test-source coverage map is a candidate input. Generated proof
    lives beside one immutable quality attempt and never overwrites evidence.
    """
    try:
        from . import checks
    except ImportError:
        import checks
    root = Path(root).resolve()
    fingerprint = checks.fingerprint(root)
    if quality_path is None:
        reports = sorted((root / "harness/runs").glob("*-quality/attempts/*/report.json"), reverse=True)
        quality_path = next((path for path in reports if _read(path).get("candidate") == {"source_fingerprint": fingerprint} and _read(path).get("job", {}).get("status") == "passed"), None)
        if quality_path is None:
            raise gate.EvidenceError("F1 collector needs a completed current-candidate quality attempt")
    quality_path = Path(quality_path).absolute()
    if quality_path.resolve() != quality_path or not quality_path.is_relative_to(root / "harness/runs"):
        raise gate.EvidenceError("F1 quality report must be original canonical evidence under harness/runs")
    quality = _read(quality_path)
    mapping_path = root / "app/test/next_phase/f1_coverage.json"
    mapping = _read(mapping_path)
    gate._expect(mapping.get("schema"), 1, "F1 host mapping schema")
    gate._expect(mapping.get("feature"), "F1", "F1 host mapping feature")
    host = {"schema": 1, "feature": "F1", "level": "host", "status": "passed", "candidate": fingerprint,
            "checks": [{**check, "status": "passed"} for check in gate._list(mapping.get("checks"), "F1 mapped tests")]}
    destination = quality_path.parent / "f1-host"
    destination.mkdir(exist_ok=False)
    def write(name, value, kind):
        path = destination / name
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "kind": kind}
    host_reference = write("coverage.json", host, "f1-host-coverage")
    manifest = {"schema": 1, "feature": "F1", "level": "host", "publish_allowed": False,
                "external_unverified": list(EXTERNAL), "candidate": {"source_fingerprint": fingerprint},
                "quality": {"path": str(quality_path), "sha256": hashlib.sha256(quality_path.read_bytes()).hexdigest(), "kind": "quality-run"},
                "host": host_reference}
    manifest_reference = write("manifest.json", manifest, "f1-manifest")
    result = evaluate(manifest, fingerprint, root)
    result["evidence_manifest"] = manifest_reference
    write("gate.json", result, "f1-gate")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["collect-host"])
    parser.add_argument("--quality-report", type=Path, help="Original quality attempt; default is latest passed current candidate")
    args = parser.parse_args()
    try:
        result = collect_host(gate.SOURCE_ROOT, args.quality_report)
    except (gate.EvidenceError, OSError, ValueError, TypeError, KeyError) as error:
        result = {"feature_allowed": False, "publish_allowed": False, "reasons": [str(error)]}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return int(not result["feature_allowed"])


if __name__ == "__main__":
    raise SystemExit(main())
