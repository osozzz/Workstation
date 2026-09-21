from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "rust-go"
PROVIDER_PATH = (
    ROOT / "scripts" / "Providers" / "RustGoToolchains.Provider.ps1"
)
COMMAND_INVENTORY_PATH = (
    ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"
)
CORE_PATH = ROOT / "scripts" / "Core" / "Audit.Core.psm1"

EXPECTED_FIXTURES = {
    "rustup-managed-go.json",
    "standalone-rust.json",
    "rustup-no-active-toolchain.json",
    "go-present-rust-missing.json",
    "conflicting-resolutions.json",
    "legacy-rustup-skipped.json",
}

SPECIALIZED_COMPONENT_IDS = {
    "rust",
    "cargo",
    "rustup",
    "go",
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
    r"\brustup\s+(update|default|override\s+set|toolchain\s+(install|uninstall|remove)|component\s+(add|remove)|target\s+(add|remove))\b",
    r"\bcargo\s+(install|uninstall|update|add|remove|new|init)\b",
    r"\bgo\s+env\s+-w\b",
    r"\bgo\s+(install|get|clean|work\s+(use|sync))\b",
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
    managed = fixtures["rustup-managed-go.json"]
    if managed["status"] != "success":
        fail("rustup-managed-go.json must represent successful detection.")

    rustup = component(managed, "rustup")
    toolchains = component(managed, "rust-toolchains")
    rustc = component(managed, "rustc")
    cargo = component(managed, "cargo")
    go = component(managed, "go")

    if rustup["activeVersion"]["normalized"] != "1.28.2":
        fail("Managed fixture must preserve rustup version.")
    if toolchains["state"] != "present":
        fail("Managed fixture must preserve installed rustup toolchains.")
    if rustc["activeVersion"]["normalized"] != "1.90.0":
        fail("Managed fixture must preserve active rustc version.")
    if cargo["activeVersion"]["normalized"] != "1.90.0":
        fail("Managed fixture must preserve active Cargo version.")
    if go["activeVersion"]["normalized"] != "1.26.1":
        fail("Managed fixture must preserve active Go version.")

    toolchain_meta = evidence(
        managed, "rust.toolchains"
    )["attributes"]["toolchains"]
    if len(toolchain_meta) < 2:
        fail("Managed Rust fixture must preserve multiple toolchains.")
    if not any(
        item.get("active") is True
        and item.get("default") is True
        and item.get("channel") == "stable"
        for item in toolchain_meta
    ):
        fail(
            "Managed Rust fixture must distinguish the active/default stable "
            "toolchain."
        )

    active_toolchain = evidence(
        managed, "rust.active-toolchain"
    )["attributes"]
    if active_toolchain.get("activeToolchain") != (
        "stable-x86_64-pc-windows-msvc"
    ):
        fail(
            "Managed Rust fixture must prove the active toolchain through "
            "rustup show active-toolchain."
        )
    if active_toolchain.get("autoInstallGuard") != "RUSTUP_AUTO_INSTALL=0":
        fail(
            "Modern rustup active-toolchain inspection must disable "
            "automatic installation."
        )

    go_env = evidence(managed, "go.environment")["attributes"]
    if go_env.get("GOROOT") != r"C:\Synthetic\Go":
        fail("Go evidence must preserve observed GOROOT.")
    if go_env.get("GOPATH") != r"C:\Synthetic\GoPath":
        fail("Go evidence must preserve observed GOPATH.")
    if go_env.get("rawOutputRetained") is not False:
        fail("Raw go env JSON must not be retained.")

    standalone = fixtures["standalone-rust.json"]
    if standalone["status"] != "warning":
        fail("standalone-rust.json must normalize standalone Rust as warning.")
    if component(standalone, "rustup")["state"] != "missing":
        fail("Standalone Rust must keep rustup missing.")
    if component(standalone, "rustc")["state"] != "present":
        fail("Standalone Rust must keep rustc present.")
    if component(standalone, "cargo")["state"] != "present":
        fail("Standalone Rust must keep Cargo present.")
    if not any(
        item["code"] == "RUST_STANDALONE_WITHOUT_RUSTUP"
        for item in standalone["warnings"]
    ):
        fail("Standalone Rust must preserve non-inferred ownership finding.")

    blocked = fixtures["rustup-no-active-toolchain.json"]
    if blocked["status"] != "partial":
        fail("rustup-no-active-toolchain.json must use partial status.")
    if component(blocked, "rustc")["state"] != "partial":
        fail("rustc proxy must be partial when execution is skipped.")
    if component(blocked, "cargo")["state"] != "partial":
        fail("Cargo proxy must be partial when execution is skipped.")
    codes = {item["code"] for item in blocked["warnings"]}
    for expected in (
        "RUSTC_PROXY_NOT_EXECUTED",
        "CARGO_PROXY_NOT_EXECUTED",
        "RUSTUP_ACTIVE_TOOLCHAIN_UNPROVEN",
    ):
        if expected not in codes:
            fail(f"Missing Rust proxy-safety finding: {expected}")

    for evidence_id in ("rust.rustc.version", "rust.cargo.version"):
        item = evidence(blocked, evidence_id)
        if item["attributes"].get("executionSkipped") is not True:
            fail(
                "Rustup proxy safety fixture must prove version execution "
                f"was skipped: {evidence_id}"
            )

    blocked_active = evidence(
        blocked, "rust.active-toolchain"
    )["attributes"]
    if blocked_active.get("activeToolchain") is not None:
        fail(
            "Blocked Rust fixture must not invent an active toolchain."
        )

    go_only = fixtures["go-present-rust-missing.json"]
    if go_only["status"] != "success":
        fail("Go-only fixture must remain successful.")
    if component(go_only, "go")["state"] != "present":
        fail("Go-only fixture must preserve Go present.")
    for component_id in ("rustup", "rust-toolchains", "rustc", "cargo"):
        if component(go_only, component_id)["state"] != "missing":
            fail(f"Go-only fixture must keep {component_id} missing.")

    conflicts = fixtures["conflicting-resolutions.json"]
    if conflicts["status"] != "partial":
        fail("conflicting-resolutions.json must use partial status.")
    if len(component(conflicts, "rustc")["commandResolutions"]) < 2:
        fail("Rust command collisions must preserve all resolutions.")
    if len(component(conflicts, "go")["commandResolutions"]) < 2:
        fail("Go command collisions must preserve all resolutions.")
    conflict_codes = {item["code"] for item in conflicts["warnings"]}
    if "RUSTC_COMMAND_COLLISION" not in conflict_codes:
        fail("Rust collision finding is missing.")
    if "GO_COMMAND_COLLISION" not in conflict_codes:
        fail("Go collision finding is missing.")


    legacy = fixtures["legacy-rustup-skipped.json"]
    if legacy["status"] != "partial":
        fail("legacy-rustup-skipped.json must use partial status.")
    if component(legacy, "rustup")["state"] != "partial":
        fail("Legacy rustup must remain a partial manager state.")
    legacy_version = evidence(
        legacy, "rust.rustup.version"
    )["attributes"]
    if legacy_version.get("executionSkipped") is not True:
        fail("Legacy rustup CLI execution must be skipped.")
    if legacy_version.get("minimumSafeInspectionVersion") != "1.28.0":
        fail("Legacy rustup safety threshold must remain explicit.")
    if evidence(
        legacy, "rust.toolchains"
    )["attributes"].get("status") != "safety-skipped":
        fail("Legacy managed-toolchain inspection must be safety-skipped.")
    legacy_codes = {item["code"] for item in legacy["warnings"]}
    if "RUSTUP_LEGACY_EXECUTION_SKIPPED" not in legacy_codes:
        fail("Legacy rustup fixture must preserve the execution-skip finding.")
    for evidence_id in ("rust.rustc.version", "rust.cargo.version"):
        if evidence(
            legacy, evidence_id
        )["attributes"].get("executionSkipped") is not True:
            fail(
                "Legacy rustup proxy execution must remain skipped: "
                f"{evidence_id}"
            )


def validate_source_ownership() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()
    core_source = CORE_PATH.read_text(encoding="utf-8").lower()

    if "providerid = 'rust-go.toolchains'" not in provider_source:
        fail("RustGoToolchains.Provider.ps1 must own rust-go.toolchains.")

    specialized_order = re.search(
        r"providerid\s*=\s*['\"]rust-go\.toolchains['\"][\s\S]*?"
        r"order\s*=\s*(\d+)",
        provider_source,
    )
    inventory_order = re.search(
        r"providerid\s*=\s*['\"]inventory\.commands['\"][\s\S]*?"
        r"order\s*=\s*(\d+)",
        command_source,
    )
    if (
        not specialized_order
        or not inventory_order
        or int(inventory_order.group(1))
        <= int(specialized_order.group(1))
    ):
        fail("Generic inventory must run after the Rust/Go provider.")

    for component_id in SPECIALIZED_COMPONENT_IDS:
        if re.search(
            rf"\bid\s*=\s*['\"]{re.escape(component_id)}['\"]",
            command_source,
        ):
            fail(
                "CommandInventory.Provider.ps1 must not duplicate Rust/Go "
                f"ownership for '{component_id}'."
            )

    for env_name in ("rustup_home", "cargo_home", "goroot", "gopath"):
        if env_name not in provider_source:
            fail(f"Provider must inspect approved {env_name.upper()} state.")
        if f"'{env_name}'" not in core_source:
            fail(
                f"{env_name.upper()} must remain in the core environment "
                "allowlist."
            )

    required_probes = (
        "rustup' -arguments @('--version')",
        "rustup' -arguments @('toolchain', 'list')",
        "rustup' -arguments @('show', 'active-toolchain')",
        "rustc' -arguments @('--version')",
        "cargo' -arguments @('--version')",
        "go' -arguments @('version')",
        "go' -arguments @('env', '-json', 'goroot', 'gopath')",
    )
    for probe in required_probes:
        if probe not in provider_source:
            fail(f"Missing required read-only probe: {probe}")

    if "test-samecommanddirectory" not in provider_source:
        fail(
            "Rust provider must classify rustup proxies before executing "
            "rustc/Cargo."
        )

    if "flags -contains 'active'" in provider_source:
        fail(
            "rustup toolchain list flags must not be treated as the source "
            "of active-toolchain truth."
        )

    if "get-rustupactivetoolchainname" not in provider_source:
        fail(
            "Rust provider must parse rustup show active-toolchain explicitly."
        )

    if "get-executableversionrecord" not in provider_source:
        fail(
            "Rustup safety gating must inspect executable metadata before "
            "legacy CLI execution."
        )

    if "minimumsafeinspectionversion = '1.28.0'" not in provider_source:
        fail(
            "Rustup legacy safety threshold must remain explicit at 1.28.0."
        )

    if provider_source.count("rustup_auto_install") < 6:
        fail(
            "Modern rustup probes and proxies must consistently disable "
            "automatic installation."
        )

    if "rustc_proxy_not_executed" not in provider_source:
        fail(
            "Provider must preserve the rustc auto-install safety guard."
        )
    if "cargo_proxy_not_executed" not in provider_source:
        fail(
            "Provider must preserve the Cargo auto-install safety guard."
        )

    if "rawoutputretained = $false" not in provider_source:
        fail("Go environment raw JSON must not be retained.")

    if provider_source.count("gotoolchain = 'local'") < 2:
        fail(
            "Both Go probes must force GOTOOLCHAIN=local in the isolated "
            "child environment to prevent automatic toolchain switching or "
            "downloads."
        )

    core_source_original = CORE_PATH.read_text(encoding="utf-8")
    if "EnvironmentOverrides" not in core_source_original:
        fail(
            "Audit core must support isolated child-process environment "
            "overrides for side-effect-safe probes."
        )

    for pattern in FORBIDDEN_MUTATION_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "RustGoToolchains.Provider.ps1 contains forbidden mutation "
                f"behavior: {pattern}"
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
            "Rust/Go fixture set mismatch. "
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
        print(f"Validated Rust/Go fixture: {path.relative_to(ROOT)}")

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print("Rust/Go toolchain provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
