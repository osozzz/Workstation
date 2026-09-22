from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CORE_PATH = ROOT / "scripts" / "Core" / "Audit.Core.psm1"
AUDIT_PATH = ROOT / "scripts" / "Audit-Workstation.ps1"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "validate.yml"
SAFETY_POLICY_PATH = ROOT / "docs" / "policies" / "audit-safety.md"
COVERAGE_MATRIX_PATH = (
    ROOT / "tests" / "sprint3-integration" / "coverage-matrix.json"
)

PATH_CASES_PATH = ROOT / "tests" / "path" / "path-model-cases.json"
PATH_VALIDATOR_PATH = ROOT / "tests" / "path" / "validate_path_model.ps1"
ENV_CASES_PATH = (
    ROOT / "tests" / "environment" / "environment-model-cases.json"
)
COMMAND_CASES_PATH = (
    ROOT / "tests" / "path-precedence" / "command-path-cases.json"
)
JAVASCRIPT_CASES_PATH = (
    ROOT
    / "tests"
    / "javascript-precedence"
    / "javascript-precedence-cases.json"
)
JVM_MOBILE_CASES_PATH = (
    ROOT
    / "tests"
    / "jvm-mobile-precedence"
    / "jvm-mobile-precedence-cases.json"
)
RUNTIME_CASES_PATH = (
    ROOT
    / "tests"
    / "runtime-precedence"
    / "runtime-precedence-cases.json"
)

SPRINT3_FIXTURE_PATHS = (
    PATH_CASES_PATH,
    ENV_CASES_PATH,
    COMMAND_CASES_PATH,
    JAVASCRIPT_CASES_PATH,
    JVM_MOBILE_CASES_PATH,
    RUNTIME_CASES_PATH,
    COVERAGE_MATRIX_PATH,
)

EXPECTED_CRITERIA = {
    "path-normalization",
    "missing-and-duplicates",
    "unresolved-variables",
    "command-precedence",
    "javascript-conflicts",
    "jvm-mobile-and-python-conflicts",
    "relevant-environment-variables",
    "no-arbitrary-environment-dump",
}

EXPECTED_ALLOWLIST = {
    "NVM_HOME",
    "NVM_SYMLINK",
    "PNPM_HOME",
    "JAVA_HOME",
    "ANDROID_HOME",
    "ANDROID_SDK_ROOT",
    "FLUTTER_ROOT",
    "PUB_CACHE",
    "CARGO_HOME",
    "RUSTUP_HOME",
    "GOPATH",
    "GOROOT",
    "PYENV_ROOT",
    "DOTNET_ROOT",
    "DOTNET_ROOT_X64",
    "DOTNET_ROOT_X86",
}

DERIVED_PROVIDER_IDS = {
    "javascript.precedence",
    "jvm-mobile.precedence",
    "python-dotnet-rust-go.precedence",
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


def fail(message: str) -> None:
    raise AssertionError(message)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


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


def validate_coverage_matrix() -> None:
    matrix = load_json(COVERAGE_MATRIX_PATH)

    if matrix.get("issue") != 7:
        fail("Sprint 3 coverage matrix must target parent issue #7.")

    criteria = matrix.get("criteria", [])
    ids = {item.get("id") for item in criteria}

    if ids != EXPECTED_CRITERIA:
        fail(
            "Sprint 3 coverage matrix criteria drift. "
            f"Expected {sorted(EXPECTED_CRITERIA)}, found {sorted(ids)}."
        )

    for item in criteria:
        evidence = item.get("evidence", [])
        if not evidence:
            fail(
                f"Coverage criterion '{item.get('id')}' has no evidence paths."
            )

        for relative_path in evidence:
            evidence_path = ROOT / relative_path
            if not evidence_path.exists():
                fail(
                    f"Coverage criterion '{item.get('id')}' references missing "
                    f"evidence path: {relative_path}"
                )

    print(
        "Validated Sprint 3 parent acceptance coverage matrix: "
        f"{len(criteria)} criteria."
    )


def validate_fixture_safety() -> None:
    for path in SPRINT3_FIXTURE_PATHS:
        raw = read_text(path).lower()
        for marker in FORBIDDEN_FIXTURE_MARKERS:
            if marker in raw:
                fail(
                    f"{path.relative_to(ROOT)} contains forbidden "
                    f"machine/secret marker: {marker}"
                )

    reports_dir = ROOT / "reports"
    if reports_dir.exists():
        committed_report_candidates = [
            path
            for path in reports_dir.rglob("*")
            if path.is_file()
            and path.name.lower() not in {"readme.md", ".gitkeep"}
            and path.suffix.lower() in {".json", ".md", ".html"}
        ]
        if committed_report_candidates:
            fail(
                "Generated machine reports must not exist in the repository: "
                f"{[str(path.relative_to(ROOT)) for path in committed_report_candidates]}"
            )

    gitignore = read_text(ROOT / ".gitignore").lower()
    if not re.search(r"(?m)^reports/\s*$", gitignore):
        fail("Repository .gitignore must continue to exclude reports/.")

    safety = read_text(SAFETY_POLICY_PATH).lower()
    for required_phrase in (
        "read-only by default",
        "explicit environment-variable whitelist",
        "mutate path or environment variables",
        "expose credentials, tokens, secrets",
        "commit machine-specific reports",
    ):
        if required_phrase not in safety:
            fail(
                "Audit safety policy is missing required Sprint 3 boundary: "
                f"{required_phrase}"
            )

    print("Validated Sprint 3 fixture/report safety boundary.")


def validate_path_scope_coverage() -> None:
    fixture = load_json(PATH_CASES_PATH)
    expected = fixture["expected"]

    if expected["machineDuplicateCount"] < 1:
        fail("PATH fixture must cover a within-scope duplicate.")

    if expected["crossScopeDuplicateCount"] < 1:
        fail("PATH fixture must cover persistent Machine/User scope drift.")

    if "c:\\missing\\" not in fixture["machinePath"].lower():
        fail("PATH fixture must cover a dead/missing entry.")

    if "%workstation_path_unresolved%" not in fixture["machinePath"].lower():
        fail("PATH fixture must cover an unresolved variable reference.")

    for scope_key in ("machinePath", "userPath", "processPath"):
        if not fixture.get(scope_key):
            fail(f"PATH fixture must include {scope_key}.")

    validator_source = read_text(PATH_VALIDATOR_PATH).lower()
    if "machine|user|process" not in validator_source:
        fail(
            "PATH validator must explicitly enforce deterministic "
            "Machine -> User -> Process scope ordering."
        )

    print(
        "Validated Sprint 3 PATH coverage: normalization, duplicates, dead "
        "entries, unresolved variables, scope drift, deterministic ordering."
    )


def validate_environment_coverage() -> None:
    fixture = load_json(ENV_CASES_PATH)
    expected_names = set(fixture["expectedAllowedNames"])

    if expected_names != EXPECTED_ALLOWLIST:
        fail(
            "Environment fixture allowlist drift. "
            f"Expected {sorted(EXPECTED_ALLOWLIST)}, "
            f"found {sorted(expected_names)}."
        )

    snapshots = {
        item["name"]: item
        for item in fixture["snapshot"]
    }

    unexpected_snapshot_names = set(snapshots) - EXPECTED_ALLOWLIST
    if unexpected_snapshot_names:
        fail(
            "Environment fixture contains unapproved snapshot names: "
            f"{sorted(unexpected_snapshot_names)}"
        )

    nvm_home = snapshots.get("NVM_HOME")
    if (
        nvm_home is None
        or not nvm_home.get("process")
        or not nvm_home.get("user")
        or nvm_home["process"] == nvm_home["user"]
    ):
        fail("Environment fixtures must cover NVM_HOME scope drift.")

    flutter_root = snapshots.get("FLUTTER_ROOT")
    if (
        flutter_root is None
        or "{{MISSING}}" not in str(flutter_root.get("process"))
    ):
        fail("Environment fixtures must cover a missing approved root.")

    android_home = snapshots.get("ANDROID_HOME")
    if (
        android_home is None
        or "%WORKSTATION_SECRET_TEST%" not in str(android_home.get("process"))
    ):
        fail(
            "Environment fixtures must prove unapproved references remain "
            "opaque and unresolved."
        )

    dotnet_x86 = snapshots.get("DOTNET_ROOT_X86")
    if (
        dotnet_x86 is None
        or "%DOTNET_ROOT%" not in str(dotnet_x86.get("process"))
    ):
        fail(
            "Environment fixtures must distinguish approved unresolved "
            "references from unapproved references."
        )

    gopath = snapshots.get("GOPATH")
    if gopath is None or ";" not in str(gopath.get("process")):
        fail("Environment fixtures must cover GOPATH path-list semantics.")

    core_source = read_text(CORE_PATH)
    audit_source = read_text(AUDIT_PATH)

    core_names = extract_quoted_names(
        extract_array_block(
            core_source,
            r"\$script:AuditEnvironmentAllowList",
            "core environment allowlist",
        )
    )
    audit_names = extract_quoted_names(
        extract_array_block(
            audit_source,
            r"\$environmentVariableNames",
            "aggregate audit environment context",
        )
    )

    if core_names != EXPECTED_ALLOWLIST:
        fail(
            "Core environment allowlist drift. "
            f"Expected {sorted(EXPECTED_ALLOWLIST)}, found {sorted(core_names)}."
        )

    if audit_names != EXPECTED_ALLOWLIST:
        fail(
            "Aggregate audit environment context drift. "
            f"Expected {sorted(EXPECTED_ALLOWLIST)}, "
            f"found {sorted(audit_names)}."
        )

    print(
        "Validated Sprint 3 approved environment allowlist and scope/missing/"
        "unresolved/path-list coverage."
    )


def validate_command_precedence_coverage() -> None:
    fixture = load_json(COMMAND_CASES_PATH)
    cases = fixture["cases"]

    required_cases = {
        "singleMapped",
        "pathCollision",
        "nonPathPrecedence",
        "unmapped",
        "equivalentPathEntries",
    }
    if set(cases) != required_cases:
        fail(
            "Command precedence fixture set drift. "
            f"Expected {sorted(required_cases)}, found {sorted(cases)}."
        )

    collision = cases["pathCollision"]["resolutions"]
    if len(collision) < 2:
        fail("PATH collision fixture must preserve multiple resolutions.")

    active = [item for item in collision if item.get("active")]
    shadowed = [item for item in collision if not item.get("active")]
    if (
        len(active) != 1
        or not shadowed
        or active[0].get("precedence") != 0
        or shadowed[0].get("precedence") != 1
    ):
        fail(
            "PATH collision fixture must preserve active/shadowed command "
            "precedence."
        )

    non_path = cases["nonPathPrecedence"]["resolutions"][0]
    if non_path.get("commandType") != "Alias":
        fail("Command precedence fixtures must cover non-PATH resolution.")

    unmapped = cases["unmapped"]
    if "d:\\outside\\" not in unmapped["resolutions"][0]["path"].lower():
        fail("Command precedence fixtures must cover an unmapped PATH origin.")

    equivalent_path = cases["equivalentPathEntries"]["processPath"].lower()
    if "c:\\tools" not in equivalent_path or "c:/tools/" not in equivalent_path:
        fail(
            "Command precedence fixtures must cover equivalent normalized "
            "PATH entries."
        )

    print(
        "Validated Sprint 3 command precedence fixture coverage and preserved "
        "active/shadowed evidence."
    )


def warning_union(path: Path) -> tuple[set[str], bool, bool]:
    fixture = load_json(path)
    warnings: set[str] = set()
    has_aligned = False
    has_conflict = False

    for case in fixture["cases"].values():
        codes = set(case.get("expectedWarningCodes", []))
        warnings.update(codes)
        if codes:
            has_conflict = True
        else:
            has_aligned = True

    return warnings, has_aligned, has_conflict


def validate_ecosystem_coverage() -> None:
    js_warnings, js_aligned, js_conflict = warning_union(
        JAVASCRIPT_CASES_PATH
    )
    jvm_warnings, jvm_aligned, jvm_conflict = warning_union(
        JVM_MOBILE_CASES_PATH
    )
    runtime_warnings, runtime_aligned, runtime_conflict = warning_union(
        RUNTIME_CASES_PATH
    )

    required_js = {
        "NVM_HOME_STALE_PATH",
        "NVM_SYMLINK_STALE_PATH",
        "NODE_BYPASSES_NVM_SYMLINK",
        "PNPM_HOME_PRECEDENCE_MISMATCH",
    }
    required_jvm = {
        "JAVA_HOME_JAVA_PRECEDENCE_MISMATCH",
        "FLUTTER_ROOT_PRECEDENCE_MISMATCH",
        "DART_STANDALONE_SHADOWS_FLUTTER",
        "ANDROID_SDK_ROOT_DISAGREEMENT",
        "ADB_SDK_ROOT_PRECEDENCE_MISMATCH",
    }
    required_runtime = {
        "PYTHON_BYPASSES_PYENV_ROOT",
        "DOTNET_ROOT_PRECEDENCE_MISMATCH",
        "CARGO_HOME_PRECEDENCE_MISMATCH",
        "RUSTUP_HOME_TOOLCHAIN_MISMATCH",
        "GO_GOROOT_PRECEDENCE_MISMATCH",
    }

    for label, actual, required in (
        ("JavaScript", js_warnings, required_js),
        ("JVM/mobile", jvm_warnings, required_jvm),
        ("Python/.NET/Rust/Go", runtime_warnings, required_runtime),
    ):
        missing = required - actual
        if missing:
            fail(
                f"{label} Sprint 3 fixtures are missing required conflict "
                f"coverage: {sorted(missing)}"
            )

    if not all(
        (
            js_aligned,
            js_conflict,
            jvm_aligned,
            jvm_conflict,
            runtime_aligned,
            runtime_conflict,
        )
    ):
        fail(
            "Every Sprint 3 ecosystem suite must contain both aligned and "
            "conflicting states."
        )

    print(
        "Validated Sprint 3 ecosystem coverage across JavaScript, JVM/mobile, "
        "and Python/.NET/Rust/Go aligned/conflicting states."
    )


def validate_failure_isolation_gate() -> None:
    workflow = read_text(WORKFLOW_PATH)

    required_markers = (
        "synthetic.failure",
        "Expected fifteen built-in providers plus the synthetic failure provider.",
        "providerCount -ne 16",
        "Expected all 15 built-in providers to continue after an additional provider path failure.",
        "providerCount -ne 15",
    )

    for marker in required_markers:
        if marker not in workflow:
            fail(
                "Workflow no longer proves built-in provider failure/path "
                f"isolation; missing marker: {marker}"
            )

    print(
        "Validated CI failure-isolation gate for all 15 built-in providers."
    )


def validate_environment_report(provider: dict[str, Any]) -> None:
    evidence = provider["evidence"]
    environment_evidence = [
        item
        for item in evidence
        if item["evidenceId"].startswith("environment.")
    ]

    expected_ids = {
        f"environment.{name.lower()}"
        for name in EXPECTED_ALLOWLIST
    }
    expected_ids.add("environment.allowlist.boundary")

    actual_ids = {item["evidenceId"] for item in environment_evidence}

    if actual_ids != expected_ids:
        fail(
            "Controlled audit environment evidence drift. "
            f"Expected {sorted(expected_ids)}, found {sorted(actual_ids)}."
        )

    boundary = next(
        item
        for item in environment_evidence
        if item["evidenceId"] == "environment.allowlist.boundary"
    )
    attributes = boundary["attributes"]

    if set(attributes.get("approvedNames", [])) != EXPECTED_ALLOWLIST:
        fail(
            "Controlled audit environment allowlist boundary does not match "
            "the approved names."
        )

    if attributes.get("arbitraryEnumeration") is not False:
        fail(
            "Controlled audit must explicitly prove arbitrary environment "
            "enumeration is disabled."
        )

    if attributes.get("inspectedCount") != len(EXPECTED_ALLOWLIST):
        fail(
            "Controlled audit must inspect exactly the approved environment "
            "allowlist."
        )


def validate_precedence_report(provider: dict[str, Any]) -> None:
    command_evidence = [
        item
        for item in provider["evidence"]
        if item["evidenceId"].startswith("path-precedence.command.")
    ]
    if not command_evidence:
        fail("Controlled audit must contain command precedence evidence.")

    mapped_count = 0

    for item in command_evidence:
        attributes = item["attributes"]
        resolutions = attributes.get("resolutions", [])
        active = attributes.get("activeResolution")
        shadowed = attributes.get("shadowedResolutions", [])

        if active is not None:
            active_matches = [
                resolution
                for resolution in resolutions
                if resolution.get("active") is True
                and resolution.get("precedence") == active.get("precedence")
                and resolution.get("path") == active.get("path")
            ]
            if not active_matches:
                fail(
                    f"{item['evidenceId']} active resolution is not preserved "
                    "in the underlying resolution evidence."
                )

        for shadow in shadowed:
            if shadow.get("active") is True:
                fail(
                    f"{item['evidenceId']} marks a shadowed resolution active."
                )

        for resolution in resolutions:
            mapping_status = resolution.get("pathMappingStatus")
            position = resolution.get("pathPosition")
            path_based = resolution.get("pathBased")

            if mapping_status in {"not-path-based", "not-in-process-path"}:
                if position is not None:
                    fail(
                        f"{item['evidenceId']} fabricated PATH position for "
                        f"mapping state '{mapping_status}'."
                    )

            if mapping_status and str(mapping_status).startswith("mapped"):
                if not isinstance(position, int):
                    fail(
                        f"{item['evidenceId']} mapped resolution lacks a real "
                        "PATH position."
                    )
                mapped_count += 1

            if path_based is False and position is not None:
                fail(
                    f"{item['evidenceId']} assigned PATH position to a "
                    "non-PATH command resolution."
                )

    if mapped_count < 1:
        fail(
            "Controlled audit must map at least one preserved command "
            "resolution to Process PATH."
        )


def validate_derived_providers(report: dict[str, Any]) -> None:
    providers = {
        provider["providerId"]: provider
        for provider in report["providers"]
    }

    missing = DERIVED_PROVIDER_IDS - set(providers)
    if missing:
        fail(
            "Controlled audit is missing Sprint 3 ecosystem providers: "
            f"{sorted(missing)}"
        )

    expected_dependencies = {
        "javascript.precedence": {
            "javascriptToolchain",
            "pathPrecedence",
            "environmentBaseline",
        },
        "jvm-mobile.precedence": {
            "javaJvm",
            "mobileFlutterAndroid",
            "pathPrecedence",
            "environmentBaseline",
        },
        "python-dotnet-rust-go.precedence": {
            "pythonEcosystem",
            "dotnetToolchain",
            "rustGoToolchains",
            "pathPrecedence",
            "environmentBaseline",
        },
    }

    summary_ids = {
        "javascript.precedence": "javascript-precedence.summary",
        "jvm-mobile.precedence": "jvm-mobile-precedence.summary",
        "python-dotnet-rust-go.precedence":
            "python-dotnet-rust-go-precedence.summary",
    }

    for provider_id in sorted(DERIVED_PROVIDER_IDS):
        provider = providers[provider_id]

        if provider["components"]:
            fail(
                f"{provider_id} must remain derived and own zero components."
            )

        if provider["status"] == "failed":
            fail(
                f"{provider_id} failed during the controlled Sprint 3 audit."
            )

        summary = next(
            (
                item
                for item in provider["evidence"]
                if item["evidenceId"] == summary_ids[provider_id]
            ),
            None,
        )
        if summary is None:
            fail(f"{provider_id} is missing its summary evidence.")

        attributes = summary["attributes"]
        if attributes.get("readOnly") is not True:
            fail(f"{provider_id} must remain explicitly read-only.")

        for key in (
            "duplicatedRuntimeDiscovery",
            "directEnvironmentAccess",
            "filesystemProbes",
        ):
            if key in attributes and attributes.get(key) is not False:
                fail(f"{provider_id} must preserve {key}=false.")

        dependencies = attributes.get("dependencies", {})
        for dependency_name in expected_dependencies[provider_id]:
            if dependencies.get(dependency_name) is not True:
                fail(
                    f"{provider_id} missing dependency evidence for "
                    f"{dependency_name}."
                )


def validate_real_report(path: Path) -> None:
    report = load_json(path)

    if report["audit"]["mode"] != "read-only":
        fail("Controlled Sprint 3 audit must remain read-only.")

    providers = {
        provider["providerId"]: provider
        for provider in report["providers"]
    }

    for provider_id in (
        "environment.baseline",
        "path.precedence",
        *sorted(DERIVED_PROVIDER_IDS),
    ):
        if provider_id not in providers:
            fail(
                f"Controlled Sprint 3 audit is missing provider {provider_id}."
            )

    if any(
        provider["status"] == "failed"
        for provider in report["providers"]
    ):
        failed = [
            provider["providerId"]
            for provider in report["providers"]
            if provider["status"] == "failed"
        ]
        fail(
            "No built-in provider may fail the controlled Sprint 3 audit: "
            f"{failed}"
        )

    if report.get("errors"):
        fail(
            "Controlled Sprint 3 audit must not contain report-level errors."
        )

    validate_environment_report(providers["environment.baseline"])
    validate_precedence_report(providers["path.precedence"])
    validate_derived_providers(report)

    print(
        "Validated controlled real-machine Sprint 3 audit: approved "
        "environment boundary, non-fabricated command precedence, and all "
        "ecosystem conflict providers executing together."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        type=Path,
        help=(
            "Optional controlled real-machine audit JSON to validate in "
            "addition to Sprint 3 fixture/integration checks."
        ),
    )
    args = parser.parse_args()

    validate_coverage_matrix()
    validate_fixture_safety()
    validate_path_scope_coverage()
    validate_environment_coverage()
    validate_command_precedence_coverage()
    validate_ecosystem_coverage()
    validate_failure_isolation_gate()

    if args.report is not None:
        validate_real_report(args.report)

    print("Sprint 3 PATH/environment integration gate validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
