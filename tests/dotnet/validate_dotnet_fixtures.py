from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "dotnet"
PROVIDER_PATH = ROOT / "scripts" / "Providers" / "DotNetToolchain.Provider.ps1"
COMMAND_INVENTORY_PATH = ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"
CORE_PATH = ROOT / "scripts" / "Core" / "Audit.Core.psm1"

EXPECTED_FIXTURES = {
    "multiple-sdks-runtimes.json",
    "missing-workloads.json",
    "runtime-only-host.json",
    "unavailable-cli.json",
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

FORBIDDEN_MUTATION_PATTERNS = (
    r"\bdotnet\s+workload\s+(install|update|uninstall|repair|restore|search)\b",
    r"\bdotnet\s+sdk\s+check\b",
    r"\bdotnet\s+tool\s+(install|update|uninstall|restore)\b",
    r"\bdotnet\s+new\s+install\b",
    r"\bdotnet\s+restore\b",
    r"\bdotnet\s+nuget\s+(push|delete)\b",
)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def fail(message: str) -> None:
    raise AssertionError(message)


def component(provider: dict[str, Any], component_id: str) -> dict[str, Any]:
    matches = [
        item
        for item in provider["components"]
        if item["componentId"] == component_id
    ]
    if len(matches) != 1:
        fail(
            f"{provider['providerId']}: expected exactly one component "
            f"'{component_id}', found {len(matches)}."
        )
    return matches[0]


def evidence(provider: dict[str, Any], evidence_id: str) -> dict[str, Any]:
    matches = [
        item
        for item in provider["evidence"]
        if item["evidenceId"] == evidence_id
    ]
    if len(matches) != 1:
        fail(
            f"{provider['providerId']}: expected exactly one evidence "
            f"'{evidence_id}', found {len(matches)}."
        )
    return matches[0]


def validate_fixture_safety(path: Path) -> None:
    raw = path.read_text(encoding="utf-8").lower()
    for marker in FORBIDDEN_FIXTURE_MARKERS:
        if marker in raw:
            fail(
                f"{path.relative_to(ROOT)} contains forbidden "
                f"machine/secret marker: {marker}"
            )


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
                    f"{source}: {collection_name} references missing "
                    f"evidence ids: {sorted(missing)}"
                )


def validate_domain_cases(fixtures: dict[str, dict[str, Any]]) -> None:
    multiple = fixtures["multiple-sdks-runtimes.json"]
    if multiple["status"] != "success":
        fail(
            "multiple-sdks-runtimes.json must represent a successful "
            "provider result."
        )

    sdk = component(multiple, "dotnet-sdk")
    runtime = component(multiple, "dotnet-runtime")
    workloads = component(multiple, "dotnet-workloads")

    if sdk["activeVersion"]["normalized"] != "10.0.100":
        fail("The active .NET SDK version must be preserved.")
    if len(sdk["installations"]) < 2:
        fail("Multiple installed SDKs must not be collapsed.")
    if len(sdk["discoveredVersions"]) < 2:
        fail("Multiple SDK versions must remain visible.")
    if len(runtime["installations"]) < 3:
        fail("Multiple runtime products/versions must remain visible.")
    if len(runtime["discoveredVersions"]) < 2:
        fail("Multiple runtime versions must remain visible.")
    if workloads["state"] != "present" or workloads["installed"] is not True:
        fail("Installed workload state must be represented.")

    sdk_metadata = evidence(multiple, "dotnet.sdks")["attributes"]["sdks"]
    if not any(
        item.get("version") == "10.0.100"
        and item.get("path", "").endswith(r"sdk\10.0.100")
        for item in sdk_metadata
    ):
        fail("SDK metadata must preserve the version-specific install path.")

    runtime_metadata = evidence(
        multiple, "dotnet.runtimes"
    )["attributes"]["runtimes"]
    if not any(
        item.get("product") == "Microsoft.AspNetCore.App"
        and item.get("version") == "10.0.0"
        for item in runtime_metadata
    ):
        fail("Runtime metadata must preserve product identity and version.")

    workload_metadata = evidence(
        multiple, "dotnet.workloads"
    )["attributes"]
    if workload_metadata.get("installed") != ["maui-windows", "wasm-tools"]:
        fail("Only installed workload IDs should be normalized.")
    if workload_metadata.get("updateMetadataIgnored") is not True:
        fail(
            "Sprint 2 workload detection must explicitly ignore update "
            "metadata."
        )

    workload_evidence = evidence(multiple, "dotnet.workloads")
    if workload_evidence.get("captured") is not None:
        fail(
            "Successful workload JSON must not be retained because it may "
            "contain updateAvailable metadata."
        )
    if workload_metadata.get("rawOutputRetained") is not False:
        fail(
            "Successful workload raw output must be explicitly discarded."
        )

    missing_workloads = fixtures["missing-workloads.json"]
    if missing_workloads["status"] != "partial":
        fail("missing-workloads.json must use provider status partial.")
    if component(
        missing_workloads, "dotnet-workloads"
    )["state"] != "partial":
        fail("Unavailable workload inspection must be partial.")
    if not any(
        item["code"] == "DOTNET_WORKLOAD_LIST_FAILED"
        for item in missing_workloads["warnings"]
    ):
        fail(
            "missing-workloads.json must preserve the workload enumeration "
            "warning."
        )

    runtime_only = fixtures["runtime-only-host.json"]
    if runtime_only["status"] != "partial":
        fail("runtime-only-host.json must use provider status partial.")
    if component(runtime_only, "dotnet-sdk")["state"] != "missing":
        fail("Runtime-only host must preserve missing SDK state.")
    if component(runtime_only, "dotnet-runtime")["state"] != "present":
        fail("Runtime-only host must preserve installed runtime state.")
    if component(runtime_only, "dotnet-workloads")["state"] != "missing":
        fail(
            "Workload inspection must remain skipped when no SDK is present."
        )
    if not any(
        item["code"] == "DOTNET_SDK_MISSING"
        for item in runtime_only["warnings"]
    ):
        fail("Runtime-only host must preserve the missing SDK warning.")

    unavailable = fixtures["unavailable-cli.json"]
    if unavailable["status"] != "unavailable":
        fail("unavailable-cli.json must use provider status unavailable.")
    for component_id in (
        "dotnet-sdk",
        "dotnet-runtime",
        "dotnet-workloads",
    ):
        item = component(unavailable, component_id)
        if item["state"] != "missing" or item["installed"] is not False:
            fail(
                "Unavailable CLI fixture must keep all .NET components "
                f"missing: {component_id}"
            )


def validate_source_ownership() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()
    core_source = CORE_PATH.read_text(encoding="utf-8").lower()

    if "providerid = 'dotnet.toolchain'" not in provider_source:
        fail("DotNetToolchain.Provider.ps1 must own dotnet.toolchain.")

    if not re.search(
        r"providerid\s*=\s*['\"]dotnet\.toolchain['\"][\s\S]*?"
        r"order\s*=\s*25",
        provider_source,
    ):
        fail(".NET provider must execute before the generic inventory.")

    dotnet_order = re.search(
        r"providerid\s*=\s*['\"]dotnet\.toolchain['\"][\s\S]*?"
        r"order\s*=\s*(\d+)",
        provider_source,
    )
    inventory_order = re.search(
        r"providerid\s*=\s*['\"]inventory\.commands['\"][\s\S]*?"
        r"order\s*=\s*(\d+)",
        command_source,
    )
    if (
        not dotnet_order
        or not inventory_order
        or int(inventory_order.group(1)) <= int(dotnet_order.group(1))
    ):
        fail("Generic inventory must run after the .NET provider.")

    if re.search(r"\bid\s*=\s*['\"]dotnet-sdk['\"]", command_source):
        fail(
            "CommandInventory.Provider.ps1 must not duplicate .NET SDK "
            "ownership."
        )

    required_probes = (
        "dotnet' -arguments @('--version')",
        "dotnet' -arguments @('--info')",
        "dotnet' -arguments @('--list-sdks')",
        "dotnet' -arguments @('--list-runtimes')",
        "dotnet' -arguments @('workload', 'list', '--machine-readable')",
    )
    for probe in required_probes:
        if probe not in provider_source:
            fail(
                "DotNetToolchain.Provider.ps1 is missing expected read-only "
                f"probe: {probe}"
            )

    for env_name in (
        "dotnet_root",
        "dotnet_root_x64",
        "dotnet_root_x86",
    ):
        if env_name not in provider_source:
            fail(
                "DotNetToolchain.Provider.ps1 must inspect approved "
                f"{env_name.upper()} state."
            )
        if f"'{env_name}'" not in core_source:
            fail(
                f"{env_name.upper()} must be present in the core environment "
                "allowlist."
            )

    if "workloadlistjsonoutputstart" not in provider_source:
        fail(
            "The workload parser must tolerate pre-.NET 9 machine-readable "
            "wrapper markers."
        )

    if "updatemetadataignored = $true" not in provider_source:
        fail(
            "Workload update metadata must be explicitly ignored in Sprint 2."
        )

    for pattern in FORBIDDEN_MUTATION_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "DotNetToolchain.Provider.ps1 contains a forbidden mutation "
                f"or later-milestone probe: {pattern}"
            )


def main() -> int:
    schema = load_json(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(
        schema,
        format_checker=FormatChecker(),
    )

    fixture_paths = sorted(FIXTURE_DIR.glob("*.json"))
    actual = {path.name for path in fixture_paths}
    if actual != EXPECTED_FIXTURES:
        fail(
            ".NET fixture set mismatch. "
            f"Expected {sorted(EXPECTED_FIXTURES)}, found {sorted(actual)}."
        )

    fixtures: dict[str, dict[str, Any]] = {}
    for path in fixture_paths:
        validate_fixture_safety(path)
        instance = load_json(path)
        validator.validate(instance)
        validate_provider_invariants(
            instance,
            str(path.relative_to(ROOT)),
        )
        fixtures[path.name] = instance
        print(f"Validated .NET fixture: {path.relative_to(ROOT)}")

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print(".NET SDK/runtime/workload provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
