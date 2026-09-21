from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "schemas"
PROVIDER_FIXTURE_DIR = ROOT / "tests" / "fixtures" / "providers"
REPORT_FIXTURE_DIR = ROOT / "tests" / "fixtures" / "reports"

EXPECTED_PROVIDER_FIXTURES = {
    "present-success.json",
    "missing-success.json",
    "partial.json",
    "failed.json",
    "unavailable.json",
}

FORBIDDEN_FIXTURE_MARKERS = (
    "c:\\users\\",
    "/home/",
    "bearer ",
    "ghp_",
    "github_pat_",
    "password=",
    "token=",
)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def fail(message: str) -> None:
    raise AssertionError(message)


def validate_fixture_safety(path: Path) -> None:
    raw = path.read_text(encoding="utf-8").lower()
    for marker in FORBIDDEN_FIXTURE_MARKERS:
        if marker in raw:
            fail(f"{path.relative_to(ROOT)} contains forbidden machine/secret marker: {marker}")


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


def validate_report_invariants(report: dict[str, Any], source: str) -> None:
    providers = report["providers"]
    provider_ids = [item["providerId"] for item in providers]
    if len(provider_ids) != len(set(provider_ids)):
        fail(f"{source}: providerId values must be unique.")

    for provider in providers:
        validate_provider_invariants(provider, f"{source}:{provider['providerId']}")

    summary = report["summary"]
    counts = {
        "successCount": sum(p["status"] == "success" for p in providers),
        "warningCount": sum(p["status"] == "warning" for p in providers),
        "partialCount": sum(p["status"] == "partial" for p in providers),
        "failedCount": sum(p["status"] == "failed" for p in providers),
        "unavailableCount": sum(p["status"] == "unavailable" for p in providers),
        "notApplicableCount": sum(p["status"] == "not-applicable" for p in providers),
    }

    if summary["providerCount"] != len(providers):
        fail(f"{source}: providerCount does not match providers length.")

    for field, expected in counts.items():
        if summary[field] != expected:
            fail(
                f"{source}: {field} is {summary[field]} but expected {expected} "
                "from provider statuses."
            )

    expected_status = expected_report_status(summary, len(report["errors"]))
    if summary["status"] != expected_status:
        fail(
            f"{source}: summary status is {summary['status']} but expected "
            f"{expected_status}."
        )


def assert_invalid(
    validator: Draft202012Validator,
    instance: Any,
    label: str,
) -> None:
    errors = list(validator.iter_errors(instance))
    if not errors:
        fail(f"Negative validation case unexpectedly passed: {label}")
    print(f"Expected invalid: {label}")


def main() -> int:
    provider_schema_path = SCHEMA_DIR / "provider-result.schema.json"
    report_schema_path = SCHEMA_DIR / "audit-report.schema.json"

    provider_schema = load_json(provider_schema_path)
    report_schema = load_json(report_schema_path)

    Draft202012Validator.check_schema(provider_schema)
    Draft202012Validator.check_schema(report_schema)

    registry = (
        Registry()
        .with_resource(
            provider_schema["$id"],
            Resource.from_contents(provider_schema),
        )
        .with_resource(
            report_schema["$id"],
            Resource.from_contents(report_schema),
        )
    )

    format_checker = FormatChecker()
    provider_validator = Draft202012Validator(
        provider_schema,
        registry=registry,
        format_checker=format_checker,
    )
    report_validator = Draft202012Validator(
        report_schema,
        registry=registry,
        format_checker=format_checker,
    )

    provider_paths = sorted(PROVIDER_FIXTURE_DIR.glob("*.json"))
    actual_provider_fixtures = {path.name for path in provider_paths}
    if actual_provider_fixtures != EXPECTED_PROVIDER_FIXTURES:
        fail(
            "Provider fixture set mismatch. "
            f"Expected {sorted(EXPECTED_PROVIDER_FIXTURES)}, "
            f"found {sorted(actual_provider_fixtures)}."
        )

    providers: dict[str, dict[str, Any]] = {}
    for path in provider_paths:
        validate_fixture_safety(path)
        instance = load_json(path)
        provider_validator.validate(instance)
        validate_provider_invariants(instance, str(path.relative_to(ROOT)))
        providers[path.name] = instance
        print(f"Validated provider fixture: {path.relative_to(ROOT)}")

    report_paths = sorted(REPORT_FIXTURE_DIR.glob("*.json"))
    if not report_paths:
        fail("At least one normalized audit report fixture is required.")

    reports: dict[str, dict[str, Any]] = {}
    for path in report_paths:
        validate_fixture_safety(path)
        instance = load_json(path)
        report_validator.validate(instance)
        validate_report_invariants(instance, str(path.relative_to(ROOT)))
        reports[path.name] = instance
        print(f"Validated report fixture: {path.relative_to(ROOT)}")

    # Negative cases are generated in memory so invalid fixtures are never committed.
    missing_status = copy.deepcopy(providers["present-success.json"])
    del missing_status["status"]
    assert_invalid(provider_validator, missing_status, "missing required provider status")

    invalid_status = copy.deepcopy(providers["present-success.json"])
    invalid_status["status"] = "broken"
    assert_invalid(provider_validator, invalid_status, "invalid provider status enum")

    invalid_present = copy.deepcopy(providers["present-success.json"])
    invalid_present["components"][0]["installed"] = False
    assert_invalid(
        provider_validator,
        invalid_present,
        "present component with installed=false",
    )

    invalid_missing = copy.deepcopy(providers["missing-success.json"])
    invalid_missing["components"][0]["installed"] = True
    assert_invalid(
        provider_validator,
        invalid_missing,
        "missing component with installed=true",
    )

    invalid_warning_severity = copy.deepcopy(providers["partial.json"])
    invalid_warning_severity["warnings"][0]["severity"] = "error"
    assert_invalid(
        provider_validator,
        invalid_warning_severity,
        "warning record with error severity",
    )

    invalid_schema_version = copy.deepcopy(reports["mixed-provider-report.json"])
    invalid_schema_version["schemaVersion"] = "2.0.0"
    assert_invalid(
        report_validator,
        invalid_schema_version,
        "unsupported audit schemaVersion",
    )

    print("Contract fixture validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
