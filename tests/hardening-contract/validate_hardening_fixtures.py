from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "schemas"
FIXTURE_DIR = ROOT / "tests" / "hardening-contract" / "fixtures"
MANIFEST_PATH = FIXTURE_DIR / "fixture-manifest.json"

EXPECTED_FIXTURES = {
    "audit-state-matrix.json",
    "comparison-state-matrix.json",
}

FORBIDDEN_MARKERS = (
    "c:\\users\\",
    "/home/",
    "%userprofile%",
    "runneradmin",
    "bearer ",
    "ghp_",
    "github_pat_",
    "password=",
    "token=",
    "@gmail.com",
    "@outlook.com",
)


def fail(message: str) -> None:
    raise AssertionError(message)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def assert_invalid(
    validator: Draft202012Validator,
    instance: Any,
    label: str,
) -> None:
    errors = list(validator.iter_errors(instance))
    if not errors:
        fail(f"Negative validation case unexpectedly passed: {label}")
    print(f"Expected invalid: {label}")


def validate_fixture_safety(path: Path, instance: Any) -> None:
    raw = path.read_text(encoding="utf-8").lower()
    for marker in FORBIDDEN_MARKERS:
        if marker in raw:
            fail(
                f"{path.relative_to(ROOT)} contains forbidden machine/secret marker: "
                f"{marker}"
            )

    canonical = canonical_json(instance)
    round_trip = canonical_json(json.loads(canonical))
    if canonical != round_trip:
        fail(f"{path.relative_to(ROOT)} is not canonically deterministic.")


def validate_manifest(fixtures: dict[str, Any]) -> None:
    manifest = load_json(MANIFEST_PATH)
    if manifest.get("schemaVersion") != "1.0.0":
        fail("Hardening fixture manifest must use schemaVersion 1.0.0.")

    expected_entries = manifest.get("fixtures", {})
    if set(expected_entries) != EXPECTED_FIXTURES:
        fail(
            "Hardening fixture manifest does not match the required fixture set. "
            f"Expected {sorted(EXPECTED_FIXTURES)}, found {sorted(expected_entries)}."
        )

    for name, fixture in fixtures.items():
        expected_digest = expected_entries[name]["canonicalSha256"]
        actual_digest = canonical_sha256(fixture)
        if actual_digest != expected_digest:
            fail(
                f"{name}: canonical SHA-256 mismatch. "
                f"Expected {expected_digest}, found {actual_digest}."
            )
        print(f"Deterministic fixture digest verified: {name} -> {actual_digest}")


def validate_provider_invariants(provider: dict[str, Any], source: str) -> None:
    component_ids = [item["componentId"] for item in provider["components"]]
    if len(component_ids) != len(set(component_ids)):
        fail(f"{source}: componentId values must be unique.")

    evidence_ids = [item["evidenceId"] for item in provider["evidence"]]
    if len(evidence_ids) != len(set(evidence_ids)):
        fail(f"{source}: evidenceId values must be unique.")

    evidence_id_set = set(evidence_ids)
    for collection_name in ("warnings", "errors"):
        for item in provider[collection_name]:
            missing = set(item["evidenceIds"]) - evidence_id_set
            if missing:
                fail(
                    f"{source}: {collection_name} references missing evidence ids: "
                    f"{sorted(missing)}"
                )


def expected_report_status(summary: dict[str, Any], report_error_count: int) -> str:
    if summary["failedCount"] > 0 or report_error_count > 0:
        return "failed"
    if summary["partialCount"] > 0 or summary["unavailableCount"] > 0:
        return "partial"
    if summary["warningCount"] > 0:
        return "warning"
    return "success"


def validate_audit_invariants(report: dict[str, Any]) -> None:
    if not report["host"]["name"].startswith("SYNTHETIC-"):
        fail("Audit hardening host name must remain explicitly synthetic.")

    providers = report["providers"]
    provider_ids = [item["providerId"] for item in providers]
    if len(provider_ids) != len(set(provider_ids)):
        fail("Audit hardening fixture contains duplicate providerId values.")

    for provider in providers:
        validate_provider_invariants(
            provider,
            f"audit-state-matrix.json:{provider['providerId']}",
        )

    summary = report["summary"]
    counts = {
        "successCount": sum(p["status"] == "success" for p in providers),
        "warningCount": sum(p["status"] == "warning" for p in providers),
        "partialCount": sum(p["status"] == "partial" for p in providers),
        "failedCount": sum(p["status"] == "failed" for p in providers),
        "unavailableCount": sum(p["status"] == "unavailable" for p in providers),
        "notApplicableCount": sum(
            p["status"] == "not-applicable" for p in providers
        ),
    }

    if summary["providerCount"] != len(providers):
        fail("Audit hardening providerCount does not match providers length.")

    for field, expected in counts.items():
        if summary[field] != expected:
            fail(
                f"Audit hardening {field} is {summary[field]}, expected {expected}."
            )

    expected_status = expected_report_status(summary, len(report["errors"]))
    if summary["status"] != expected_status:
        fail(
            f"Audit hardening summary status is {summary['status']}, "
            f"expected {expected_status}."
        )

    components = [
        component
        for provider in providers
        for component in provider["components"]
    ]
    component_states = {component["state"] for component in components}
    required_states = {
        "present",
        "missing",
        "partial",
        "unavailable",
        "unknown",
    }
    if not required_states.issubset(component_states):
        fail(
            "Audit hardening component-state matrix is incomplete. "
            f"Required {sorted(required_states)}, found {sorted(component_states)}."
        )

    provider_statuses = {provider["status"] for provider in providers}
    required_provider_statuses = {
        "success",
        "partial",
        "unavailable",
        "not-applicable",
    }
    if not required_provider_statuses.issubset(provider_statuses):
        fail(
            "Audit hardening provider-status matrix is incomplete. "
            f"Required {sorted(required_provider_statuses)}, "
            f"found {sorted(provider_statuses)}."
        )

    intelligence_statuses = {
        component["versionIntelligence"]["status"] for component in components
    }
    required_intelligence_statuses = {
        "known",
        "unknown",
        "unavailable",
        "not-applicable",
    }
    if not required_intelligence_statuses.issubset(intelligence_statuses):
        fail(
            "Audit hardening version-intelligence matrix is incomplete. "
            f"Required {sorted(required_intelligence_statuses)}, "
            f"found {sorted(intelligence_statuses)}."
        )

    offline_components = [
        component
        for component in components
        if component["versionIntelligence"]["status"] == "unavailable"
        and "offline" in (component["versionIntelligence"]["message"] or "").lower()
    ]
    if not offline_components:
        fail("Audit hardening matrix must include an explicit offline source case.")


def validate_comparison_invariants(comparison: dict[str, Any]) -> None:
    if comparison["direction"] != "reference-to-target":
        fail("Comparison hardening direction must remain reference-to-target.")

    for role in ("reference", "target"):
        endpoint = comparison[role]
        if not endpoint["host"]["name"].startswith("SYNTHETIC-"):
            fail(f"Comparison {role} host must remain explicitly synthetic.")

        major_text = endpoint["schemaVersion"].split(".", 1)[0]
        try:
            major = int(major_text)
        except ValueError as exc:
            raise AssertionError(
                f"Comparison {role} schemaVersion is not semantic: "
                f"{endpoint['schemaVersion']}"
            ) from exc

        if major != comparison["auditSchemaMajor"]:
            fail(
                f"Comparison {role} audit schema major {major} does not match "
                f"auditSchemaMajor {comparison['auditSchemaMajor']}."
            )

    differences = comparison["differences"]
    summary = comparison["summary"]

    expected_counts = {
        "differenceCount": len(differences),
        "providerDifferenceCount": sum(
            item["category"] == "provider" for item in differences
        ),
        "componentDifferenceCount": sum(
            item["category"] == "component" for item in differences
        ),
        "versionDifferenceCount": sum(
            item["category"] == "version" for item in differences
        ),
        "unavailableCount": sum(
            item["relation"] == "unavailable" for item in differences
        ),
        "unknownCount": sum(
            item["relation"] == "unknown" for item in differences
        ),
        "notApplicableCount": sum(
            item["relation"] == "not-applicable" for item in differences
        ),
    }

    for field, expected in expected_counts.items():
        if summary[field] != expected:
            fail(
                f"Comparison hardening {field} is {summary[field]}, "
                f"expected {expected}."
            )

    expected_status = "equal" if not differences else "different"
    if summary["status"] != expected_status:
        fail(
            f"Comparison hardening status is {summary['status']}, "
            f"expected {expected_status}."
        )

    relations = {item["relation"] for item in differences}
    required_relations = {
        "different",
        "unavailable",
        "unknown",
        "not-applicable",
        "target-only",
    }
    if not required_relations.issubset(relations):
        fail(
            "Comparison hardening relation matrix is incomplete. "
            f"Required {sorted(required_relations)}, found {sorted(relations)}."
        )

    state_difference = [
        item
        for item in differences
        if item["category"] == "component"
        and item["kind"] == "state"
        and item["relation"] == "different"
        and "partial" in {item["referenceState"], item["targetState"]}
    ]
    if not state_difference:
        fail(
            "Comparison hardening matrix must include a conflicting/different "
            "component state involving partial."
        )


def main() -> int:
    provider_schema = load_json(SCHEMA_DIR / "provider-result.schema.json")
    audit_schema = load_json(SCHEMA_DIR / "audit-report.schema.json")
    comparison_schema = load_json(SCHEMA_DIR / "comparison-result.schema.json")

    for schema in (provider_schema, audit_schema, comparison_schema):
        Draft202012Validator.check_schema(schema)

    registry = (
        Registry()
        .with_resource(
            provider_schema["$id"],
            Resource.from_contents(provider_schema),
        )
        .with_resource(
            audit_schema["$id"],
            Resource.from_contents(audit_schema),
        )
    )

    format_checker = FormatChecker()
    audit_validator = Draft202012Validator(
        audit_schema,
        registry=registry,
        format_checker=format_checker,
    )
    comparison_validator = Draft202012Validator(
        comparison_schema,
        format_checker=format_checker,
    )

    fixture_paths = {
        path.name: path
        for path in FIXTURE_DIR.glob("*.json")
        if path.name != MANIFEST_PATH.name
    }

    if set(fixture_paths) != EXPECTED_FIXTURES:
        fail(
            "Hardening fixture set mismatch. "
            f"Expected {sorted(EXPECTED_FIXTURES)}, "
            f"found {sorted(fixture_paths)}."
        )

    fixtures: dict[str, Any] = {}
    for name, path in sorted(fixture_paths.items()):
        instance = load_json(path)
        validate_fixture_safety(path, instance)
        fixtures[name] = instance

    validate_manifest(fixtures)

    audit = fixtures["audit-state-matrix.json"]
    audit_validator.validate(audit)
    validate_audit_invariants(audit)
    print("Validated audit hardening fixture matrix.")

    comparison = fixtures["comparison-state-matrix.json"]
    comparison_validator.validate(comparison)
    validate_comparison_invariants(comparison)
    print("Validated comparison hardening fixture matrix.")

    unsupported_audit = copy.deepcopy(audit)
    unsupported_audit["schemaVersion"] = "2.0.0"
    assert_invalid(
        audit_validator,
        unsupported_audit,
        "unsupported audit schemaVersion 2.0.0",
    )

    invalid_present = copy.deepcopy(audit)
    invalid_present["providers"][0]["components"][0]["installed"] = False
    assert_invalid(
        audit_validator,
        invalid_present,
        "present component with installed=false",
    )

    invalid_missing = copy.deepcopy(audit)
    invalid_missing["providers"][0]["components"][1]["installed"] = True
    assert_invalid(
        audit_validator,
        invalid_missing,
        "missing component with installed=true",
    )

    unsupported_comparison = copy.deepcopy(comparison)
    unsupported_comparison["schemaVersion"] = "2.0.0"
    assert_invalid(
        comparison_validator,
        unsupported_comparison,
        "unsupported comparison schemaVersion 2.0.0",
    )

    unsupported_endpoint = copy.deepcopy(comparison)
    unsupported_endpoint["target"]["schemaVersion"] = "2.0.0"
    assert_invalid(
        comparison_validator,
        unsupported_endpoint,
        "comparison endpoint with unsupported audit schema major 2",
    )

    invalid_relation = copy.deepcopy(comparison)
    invalid_relation["differences"][0]["relation"] = "conflicting"
    assert_invalid(
        comparison_validator,
        invalid_relation,
        "unsupported comparison relation conflicting",
    )

    print("Schema hardening fixture validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
