from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "schemas"

SPRINT2_FIXTURE_DIRS = (
    ROOT / "tests" / "fixtures" / "platform",
    ROOT / "tests" / "fixtures" / "javascript",
    ROOT / "tests" / "fixtures" / "java",
    ROOT / "tests" / "fixtures" / "mobile",
    ROOT / "tests" / "fixtures" / "python",
    ROOT / "tests" / "fixtures" / "dotnet",
    ROOT / "tests" / "fixtures" / "rust-go",
    ROOT / "tests" / "fixtures" / "developer-clis",
)

EXPECTED_REPORT_PROVIDER_IDS = {
    "host.system",
    "javascript.toolchain",
    "java.jvm",
    "mobile.flutter-android",
    "python.ecosystem",
    "dotnet.toolchain",
    "rust-go.toolchains",
    "developer.clis",
    "inventory.commands",
    "path.precedence",
    "javascript.precedence",
    "jvm-mobile.precedence",
    "environment.baseline",
    "winget.baseline",
}

EXPECTED_SPECIALIZED_PROVIDER_IDS = EXPECTED_REPORT_PROVIDER_IDS - {
    "inventory.commands",
    "path.precedence",
    "javascript.precedence",
    "jvm-mobile.precedence",
    "environment.baseline",
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

CORE_PATH = ROOT / "scripts" / "Core" / "Audit.Core.psm1"
AUDIT_PATH = ROOT / "scripts" / "Audit-Workstation.ps1"
INVENTORY_PATH = (
    ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"
)


def fail(message: str) -> None:
    raise AssertionError(message)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def build_validators() -> tuple[Draft202012Validator, Draft202012Validator]:
    provider_schema = load_json(SCHEMA_DIR / "provider-result.schema.json")
    report_schema = load_json(SCHEMA_DIR / "audit-report.schema.json")

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

    return (
        Draft202012Validator(
            provider_schema,
            registry=registry,
            format_checker=format_checker,
        ),
        Draft202012Validator(
            report_schema,
            registry=registry,
            format_checker=format_checker,
        ),
    )


def validate_provider_invariants(
    provider: dict[str, Any],
    source: str,
) -> None:
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
                    f"{source}: {collection_name} references missing "
                    f"evidence ids: {sorted(missing)}"
                )


def validate_fixture_safety(path: Path) -> None:
    raw = path.read_text(encoding="utf-8").lower()
    for marker in FORBIDDEN_FIXTURE_MARKERS:
        if marker in raw:
            fail(
                f"{path.relative_to(ROOT)} contains forbidden "
                f"machine/secret marker: {marker}"
            )


def validate_sprint2_fixture_suite(
    provider_validator: Draft202012Validator,
) -> None:
    provider_statuses: set[str] = set()
    component_states: set[str] = set()
    provider_ids: set[str] = set()

    has_multiple_installations = False
    has_multiple_resolutions = False
    fixture_count = 0

    for fixture_dir in SPRINT2_FIXTURE_DIRS:
        paths = sorted(fixture_dir.glob("*.json"))
        if not paths:
            fail(
                "Sprint 2 fixture directory is empty or missing: "
                f"{fixture_dir.relative_to(ROOT)}"
            )

        for path in paths:
            fixture_count += 1
            validate_fixture_safety(path)
            provider = load_json(path)
            provider_validator.validate(provider)
            validate_provider_invariants(
                provider,
                str(path.relative_to(ROOT)),
            )

            provider_ids.add(provider["providerId"])
            provider_statuses.add(provider["status"])

            for component in provider["components"]:
                component_states.add(component["state"])

                if len(component["installations"]) > 1:
                    has_multiple_installations = True

                if len(component["commandResolutions"]) > 1:
                    has_multiple_resolutions = True

    missing_specialized = (
        EXPECTED_SPECIALIZED_PROVIDER_IDS - provider_ids
    )
    if missing_specialized:
        fail(
            "Sprint 2 fixtures are missing specialized provider coverage: "
            f"{sorted(missing_specialized)}"
        )

    for required_status in ("success", "partial", "unavailable"):
        if required_status not in provider_statuses:
            fail(
                "Sprint 2 fixture suite must collectively cover provider "
                f"status '{required_status}'."
            )

    for required_state in ("present", "missing", "partial"):
        if required_state not in component_states:
            fail(
                "Sprint 2 fixture suite must collectively cover component "
                f"state '{required_state}'."
            )

    if not has_multiple_installations:
        fail(
            "Sprint 2 fixtures must include at least one component with "
            "multiple installations."
        )

    if not has_multiple_resolutions:
        fail(
            "Sprint 2 fixtures must include at least one command-resolution "
            "collision."
        )

    print(
        "Validated Sprint 2 fixture integration coverage: "
        f"{fixture_count} fixtures across "
        f"{len(SPRINT2_FIXTURE_DIRS)} provider suites."
    )


def extract_quoted_names(block: str) -> set[str]:
    return {
        match.group(1)
        for match in re.finditer(r"'([A-Z][A-Z0-9_]*)'", block)
    }


def extract_array_block(
    source: str,
    assignment_pattern: str,
    label: str,
) -> str:
    match = re.search(
        assignment_pattern + r"\s*=\s*@\((?P<body>[\s\S]*?)\n\)",
        source,
    )
    if not match:
        fail(f"Could not locate {label} array.")
    return match.group("body")


def validate_environment_allowlist_sync() -> None:
    core_source = CORE_PATH.read_text(encoding="utf-8")
    audit_source = AUDIT_PATH.read_text(encoding="utf-8")

    core_block = extract_array_block(
        core_source,
        r"\$script:AuditEnvironmentAllowList",
        "core audit environment allowlist",
    )
    context_block = extract_array_block(
        audit_source,
        r"\$environmentVariableNames",
        "aggregate audit environment context",
    )

    core_names = extract_quoted_names(core_block)
    context_names = extract_quoted_names(context_block)

    if core_names != context_names:
        fail(
            "Audit environment allowlist/context drift detected. "
            f"Only in core: {sorted(core_names - context_names)}; "
            f"only in context: {sorted(context_names - core_names)}"
        )

    print(
        "Validated audit environment allowlist/context synchronization: "
        f"{len(core_names)} approved variables."
    )


def validate_transitional_inventory_is_empty() -> None:
    source = INVENTORY_PATH.read_text(encoding="utf-8")

    if not re.search(
        r"\$toolSpecs\s*=\s*@\(\s*\)",
        source,
        flags=re.IGNORECASE,
    ):
        fail(
            "CommandInventory.Provider.ps1 must have an empty transitional "
            "tool specification list after Sprint 2."
        )

    print("Validated empty transitional command inventory ownership.")


def validate_provider_array_shape_guards() -> None:
    bad_patterns: list[str] = []

    for path in sorted(
        (ROOT / "scripts" / "Providers").glob("*.Provider.ps1")
    ):
        source = path.read_text(encoding="utf-8")
        if re.search(
            r"discoveredVersions\s*=\s*\$\(if\s*\(",
            source,
            flags=re.IGNORECASE,
        ):
            bad_patterns.append(str(path.relative_to(ROOT)))

    if bad_patterns:
        fail(
            "Provider source contains scalarizing discoveredVersions "
            "subexpressions. Use an array subexpression @(if (...) { ... }) "
            f"instead: {bad_patterns}"
        )

    print(
        "Validated provider discoveredVersions array-shape guards."
    )


def expected_report_status(
    summary: dict[str, Any],
    report_error_count: int,
) -> str:
    if summary["failedCount"] > 0 or report_error_count > 0:
        return "failed"
    if summary["partialCount"] > 0 or summary["unavailableCount"] > 0:
        return "partial"
    if summary["warningCount"] > 0:
        return "warning"
    return "success"


def validate_real_report(
    path: Path,
    report_validator: Draft202012Validator,
) -> None:
    report = load_json(path)
    report_validator.validate(report)

    if report["audit"]["mode"] != "read-only":
        fail("Controlled integration audit must remain read-only.")

    providers = report["providers"]
    provider_ids = [item["providerId"] for item in providers]

    if set(provider_ids) != EXPECTED_REPORT_PROVIDER_IDS:
        fail(
            "Real integration audit provider set mismatch. "
            f"Expected {sorted(EXPECTED_REPORT_PROVIDER_IDS)}, "
            f"found {sorted(provider_ids)}."
        )

    if len(provider_ids) != len(set(provider_ids)):
        fail("Real integration audit contains duplicate provider IDs.")

    for provider in providers:
        validate_provider_invariants(
            provider,
            f"real-audit:{provider['providerId']}",
        )

        if provider["status"] == "failed":
            fail(
                "No built-in provider may fail the controlled integration "
                f"audit: {provider['providerId']}"
            )

    if report["errors"]:
        fail(
            "Controlled integration audit must not contain report-level "
            "errors."
        )

    summary = report["summary"]
    if summary["providerCount"] != len(providers):
        fail(
            "Real integration audit providerCount does not match provider "
            "array length."
        )

    count_fields = {
        "successCount": "success",
        "warningCount": "warning",
        "partialCount": "partial",
        "failedCount": "failed",
        "unavailableCount": "unavailable",
        "notApplicableCount": "not-applicable",
    }

    for field, status in count_fields.items():
        expected = sum(
            provider["status"] == status
            for provider in providers
        )
        if summary[field] != expected:
            fail(
                f"Real integration audit {field}={summary[field]} but "
                f"expected {expected}."
            )

    expected_status = expected_report_status(
        summary,
        len(report["errors"]),
    )
    if summary["status"] != expected_status:
        fail(
            "Real integration audit summary status mismatch: "
            f"{summary['status']} != {expected_status}"
        )

    inventory = next(
        provider
        for provider in providers
        if provider["providerId"] == "inventory.commands"
    )
    if inventory["components"]:
        fail(
            "Transitional command inventory must have zero components after "
            "Sprint 2 ownership migration."
        )

    component_owners: dict[str, str] = {}
    for provider in providers:
        for component in provider["components"]:
            component_id = component["componentId"]
            if component_id in component_owners:
                fail(
                    "Component ownership is duplicated across providers: "
                    f"{component_id} -> {component_owners[component_id]} and "
                    f"{provider['providerId']}"
                )
            component_owners[component_id] = provider["providerId"]

    developer = next(
        provider
        for provider in providers
        if provider["providerId"] == "developer.clis"
    )
    safety = next(
        (
            item
            for item in developer["evidence"]
            if item["evidenceId"] == "developer.safety-boundary"
        ),
        None,
    )
    if safety is None:
        fail(
            "Real integration audit is missing developer CLI safety-boundary "
            "evidence."
        )

    for key in (
        "authenticationStateCollected",
        "accountStateCollected",
        "gitConfigurationCollected",
        "dockerDaemonInspected",
        "dockerContextsCollected",
        "servicesStartedOrStopped",
    ):
        if safety["attributes"].get(key) is not False:
            fail(
                "Developer CLI safety boundary must remain false for "
                f"{key}."
            )

    precedence = next(
        provider
        for provider in providers
        if provider["providerId"] == "path.precedence"
    )
    if precedence["components"]:
        fail(
            "PATH precedence provider must remain derived and own no "
            "components."
        )

    precedence_summary = next(
        (
            item
            for item in precedence["evidence"]
            if item["evidenceId"] == "path-precedence.summary"
        ),
        None,
    )
    if precedence_summary is None:
        fail("Controlled audit is missing PATH precedence summary evidence.")

    precedence_attributes = precedence_summary["attributes"]
    if precedence_attributes.get("readOnly") is not True:
        fail("PATH precedence analysis must remain explicitly read-only.")

    if precedence_attributes.get("analyzedCommandCount", 0) < 1:
        fail(
            "Controlled audit must analyze prior command-resolution "
            "evidence."
        )

    mapped_command_evidence = [
        item
        for item in precedence["evidence"]
        if item["evidenceId"].startswith("path-precedence.command.")
        and item["attributes"].get("mappedResolutionCount", 0) > 0
    ]
    if not mapped_command_evidence:
        fail(
            "Controlled audit must map at least one command resolution "
            "to Process PATH."
        )

    javascript_precedence = next(
        provider
        for provider in providers
        if provider["providerId"] == "javascript.precedence"
    )
    if javascript_precedence["components"]:
        fail(
            "JavaScript precedence provider must remain derived and own no "
            "components."
        )

    javascript_summary = next(
        (
            item
            for item in javascript_precedence["evidence"]
            if item["evidenceId"] == "javascript-precedence.summary"
        ),
        None,
    )
    if javascript_summary is None:
        fail(
            "Controlled audit is missing JavaScript precedence summary "
            "evidence."
        )

    javascript_attributes = javascript_summary["attributes"]
    if javascript_attributes.get("readOnly") is not True:
        fail(
            "JavaScript precedence analysis must remain explicitly read-only."
        )
    if javascript_attributes.get("duplicatedRuntimeDiscovery") is not False:
        fail(
            "JavaScript precedence analysis must not duplicate runtime "
            "discovery."
        )

    dependencies = javascript_attributes.get("dependencies", {})
    for dependency_name in (
        "javascriptToolchain",
        "pathPrecedence",
        "environmentBaseline",
    ):
        if dependencies.get(dependency_name) is not True:
            fail(
                "JavaScript precedence controlled audit is missing dependency "
                f"evidence for {dependency_name}."
            )

    jvm_mobile_precedence = next(
        provider
        for provider in providers
        if provider["providerId"] == "jvm-mobile.precedence"
    )
    if jvm_mobile_precedence["components"]:
        fail(
            "JVM/mobile precedence provider must remain derived and own no "
            "components."
        )

    jvm_mobile_summary = next(
        (
            item
            for item in jvm_mobile_precedence["evidence"]
            if item["evidenceId"] == "jvm-mobile-precedence.summary"
        ),
        None,
    )
    if jvm_mobile_summary is None:
        fail(
            "Controlled audit is missing JVM/mobile precedence summary "
            "evidence."
        )

    jvm_mobile_attributes = jvm_mobile_summary["attributes"]
    if jvm_mobile_attributes.get("readOnly") is not True:
        fail("JVM/mobile precedence analysis must remain explicitly read-only.")
    for key in (
        "duplicatedRuntimeDiscovery",
        "directEnvironmentAccess",
        "filesystemProbes",
    ):
        if jvm_mobile_attributes.get(key) is not False:
            fail(
                "JVM/mobile precedence analysis must preserve "
                f"{key}=false."
            )

    jvm_mobile_dependencies = jvm_mobile_attributes.get("dependencies", {})
    for dependency_name in (
        "javaJvm",
        "mobileFlutterAndroid",
        "pathPrecedence",
        "environmentBaseline",
    ):
        if jvm_mobile_dependencies.get(dependency_name) is not True:
            fail(
                "JVM/mobile precedence controlled audit is missing dependency "
                f"evidence for {dependency_name}."
            )

    environment = next(
        provider
        for provider in providers
        if provider["providerId"] == "environment.baseline"
    )
    environment_evidence_ids = {
        item["evidenceId"]
        for item in environment["evidence"]
    }
    for env_name in (
        "DOTNET_ROOT",
        "DOTNET_ROOT_X64",
        "DOTNET_ROOT_X86",
    ):
        expected_id = f"environment.{env_name.lower()}"
        if expected_id not in environment_evidence_ids:
            fail(
                "Environment baseline is missing approved .NET root "
                f"evidence: {expected_id}"
            )

    print(
        "Validated controlled real-machine Sprint 2 audit: "
        f"{len(providers)} providers, "
        f"{len(component_owners)} uniquely owned components, "
        f"summary={summary['status']}."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        type=Path,
        help=(
            "Optional controlled real-machine audit JSON to validate in "
            "addition to static integration checks."
        ),
    )
    args = parser.parse_args()

    provider_validator, report_validator = build_validators()

    validate_sprint2_fixture_suite(provider_validator)
    validate_environment_allowlist_sync()
    validate_transitional_inventory_is_empty()
    validate_provider_array_shape_guards()

    if args.report is not None:
        validate_real_report(args.report, report_validator)

    print("Sprint 2 integration gate validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
