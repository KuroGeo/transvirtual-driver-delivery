"""Evaluate the project's production evidence contract, without publishing.

Every required entry must refer to the current source and hashed raw evidence.
Specialized JSON reports describe the actual validation layer. A test fixture
passing this schema does not demonstrate product or external release readiness.
"""

import hashlib
import json
from pathlib import Path


CAPABILITIES = tuple(f"H{i:02d}" for i in range(1, 9))
GATES = tuple(f"G{i}" for i in range(7))


def evaluate(manifest, current_fingerprint, base_dir):
    """Return ``{allowed, reasons}`` for the production H01-H08/G0-G6 gate.

    Entries use status/candidate/evidence; candidate is the source fingerprint.
    Evidence uses path/sha256/kind. Specialized evidence is JSON with candidate
    and status, plus the fields checked below. No scope label skips production
    requirements. CI and release enforcement are separately required.
    """
    reasons, checked = [], {}
    candidate = manifest.get("candidate", {})
    fingerprint = candidate.get("source_fingerprint") if isinstance(candidate, dict) else None
    if not current_fingerprint:
        reasons.append("current source fingerprint is missing")
    if not fingerprint or fingerprint != current_fingerprint:
        reasons.append("candidate.source_fingerprint is missing or stale")
    if manifest.get("enforcement_deployed") is not True:
        reasons.append("enforcement_deployed must be true; CI/release enforcement is not demonstrated")
    service_mode = manifest.get("service_mode")
    if service_mode not in ("connected", "local-client"):
        reasons.append("service_mode must explicitly be connected or local-client")

    for group, ids, required_status in (
        ("harness", CAPABILITIES, "demonstrated"),
        ("gates", GATES, "passed"),
    ):
        entries = manifest.get(group, {})
        if not isinstance(entries, dict):
            reasons.append(f"{group} must be an ID-to-entry dictionary")
            entries = {}
        for entry_id in ids:
            label = f"{group}.{entry_id}"
            entry = entries.get(entry_id)
            checked[entry_id] = []
            if not isinstance(entry, dict):
                reasons.append(f"{label} is missing")
                continue
            if entry.get("status") != required_status:
                reasons.append(f"{label}.status must be {required_status}; got {entry.get('status', 'missing')!r}")
            if not fingerprint or entry.get("candidate") != fingerprint:
                reasons.append(f"{label}.candidate is missing or stale")
            evidence = entry.get("evidence")
            if not isinstance(evidence, list) or not evidence:
                reasons.append(f"{label}.evidence is missing")
                continue
            for index, item in enumerate(evidence):
                evidence_label = f"{label}.evidence[{index}]"
                if not isinstance(item, dict) or not item.get("path") or not item.get("kind"):
                    reasons.append(f"{evidence_label} requires path, sha256 and kind")
                    continue
                path = Path(base_dir) / item["path"]
                try:
                    raw = path.read_bytes()
                except OSError as error:
                    reasons.append(f"{evidence_label}: cannot read {item['path']}: {error}")
                    continue
                actual_hash = hashlib.sha256(raw).hexdigest()
                if item.get("sha256") != actual_hash:
                    reasons.append(f"{evidence_label}: sha256 mismatch for {item['path']}")
                    continue
                checked[entry_id].append({**item, "raw": raw})

    def reports(entry_id, kind, expected):
        matches = [item for item in checked[entry_id] if item["kind"] == kind]
        if not matches:
            reasons.append(f"{entry_id} requires valid {kind} evidence")
            return []
        accepted = []
        for item in matches:
            label = f"{entry_id} {kind} ({item['path']})"
            try:
                report = json.loads(item["raw"])
            except (ValueError, UnicodeDecodeError):
                reasons.append(f"{label}: expected a raw JSON report")
                continue
            if not isinstance(report, dict):
                reasons.append(f"{label}: expected a JSON object")
                continue
            fields = {"candidate": fingerprint, "status": "passed", **expected}
            valid = True
            for field, value in fields.items():
                if report.get(field) != value or (isinstance(value, bool) and report.get(field) is not value):
                    reasons.append(f"{label}: {field} must be {value!r}; got {report.get(field)!r}")
                    valid = False
            if valid:
                accepted.append(report)
        return accepted

    quality_items = [item for item in checked["G1"] if item["kind"] == "quality-run"]
    if not quality_items:
        reasons.append("G1 requires valid quality-run evidence")
    for item in quality_items:
        label = f"G1 quality-run ({item['path']})"
        try:
            report = json.loads(item["raw"])
        except (ValueError, UnicodeDecodeError):
            reasons.append(f"{label}: expected a raw JSON report")
            continue
        if not isinstance(report, dict) or report.get("command") != "quality":
            reasons.append(f"{label}: command must be quality")
            continue
        for field in ("candidate", "candidate_after"):
            if report.get(field) != {"source_fingerprint": fingerprint}:
                reasons.append(f"{label}: {field} is missing or stale")
        if report.get("job", {}).get("status") != "passed":
            reasons.append(f"{label}: job.status must be passed")
        stages = report.get("stages", [])
        if not isinstance(stages, list) or any(not isinstance(stage, dict) for stage in stages):
            reasons.append(f"{label}: stages must be quality stage records")
            continue
        required = {"repository", "tooling-tests", "sdk", "format", "analyze", "flutter-tests"}
        ids = [stage.get("id") for stage in stages]
        if required - set(ids) or len(ids) != len(set(ids)):
            reasons.append(f"{label}: required quality stages are missing or duplicated")
        for stage in stages:
            stage_label = f"{label} stage {stage.get('id')}"
            if stage.get("status") != "passed" or stage.get("exit_code") != 0:
                reasons.append(f"{stage_label}: status/exit_code must be passed/0")
            if not stage.get("log_path") or not stage.get("sha256"):
                reasons.append(f"{stage_label}: raw log path/hash is missing")
                continue
            log = (Path(base_dir) / item["path"]).parent / stage["log_path"]
            try:
                if hashlib.sha256(log.read_bytes()).hexdigest() != stage["sha256"]:
                    reasons.append(f"{stage_label}: raw log sha256 mismatch")
            except OSError as error:
                reasons.append(f"{stage_label}: cannot read raw log: {error}")

    reports("H06", "ci-enforcement", {"enforced": True})
    reports("H06", "release-enforcement", {"enforced": True})
    native_reports = reports("G2", "native-acceptance", {"process_restart": True})
    for report in native_reports:
        if report.get("platform") not in ("android", "ios"):
            reasons.append("G2 native-acceptance: platform must be android or ios; browser/host evidence is insufficient")
    reports("G3", "performance", {"device_type": "real", "build_mode": "profile"})
    if service_mode == "connected":
        reports("G4", "connected-service", {"transport": "connected"})

    artifacts = [item for item in checked["G5"] if item["kind"] == "release-artifact"]
    artifact_hashes = {item["sha256"] for item in artifacts}
    if not artifacts:
        reasons.append("G5 requires a hashed release-artifact")
    signatures = reports("G5", "release-signature", {
        "build_mode": "release", "signed": True, "signing_kind": "production",
    })
    signed_hashes = set()
    for signature in signatures:
        if signature.get("artifact_sha256") not in artifact_hashes:
            reasons.append("G5 release-signature: artifact_sha256 does not match a hashed release-artifact")
        else:
            signed_hashes.add(signature["artifact_sha256"])
    for artifact in artifacts:
        if artifact["sha256"] not in signed_hashes:
            reasons.append(f"G5 release-artifact ({artifact['path']}): no matching production signature")
    authorizations = reports("G6", "authorization-receipt", {"authorized": True})
    deliveries = reports("G6", "delivery-receipt", {"delivered": True})
    destinations = set()
    for authorization in authorizations:
        destination = authorization.get("destination")
        if not isinstance(destination, str) or not destination.strip():
            reasons.append("G6 authorization-receipt: destination is missing")
        else:
            destinations.add(destination)
    for delivery in deliveries:
        if delivery.get("destination") not in destinations:
            reasons.append("G6 delivery-receipt: destination has no matching authorization")
        if delivery.get("artifact_sha256") not in signed_hashes:
            reasons.append("G6 delivery-receipt: artifact_sha256 does not match a signed release-artifact")
    return {"allowed": not reasons, "reasons": reasons}
