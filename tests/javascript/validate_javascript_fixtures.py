from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "javascript"
PROVIDER_PATH = ROOT / "scripts" / "Providers" / "JavaScriptToolchain.Provider.ps1"
COMMAND_INVENTORY_PATH = ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"

EXPECTED_FIXTURES = {
    "standalone-node.json",
    "nvm-managed-node.json",
    "missing-package-managers.json",
    "command-collisions.json",
    "partial-nvm-configuration.json",
}

SPECIALIZED_COMPONENT_IDS = {
    "node",
    "npm",
    "pnpm",
    "corepack",
    "nvm-windows",
    "angular-cli",
    "typescript",
    "prisma",
    "nodemon",
    "rimraf",
    "zoho-extension-toolkit",
    "zoho-catalyst-cli",
    "redis-commander",
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
    r"\bnvm\s+(install|use|uninstall)\b",
    r"\bcorepack\s+(enable|disable|prepare|use|install)\b",
    r"\bnpm\s+(install|update)\s+(-g|--global)\b",
    r"\bpnpm\s+(add|install|update|remove)\s+(-g|--global)\b",
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
            f"{provider['providerId']}: expected exactly one "
            f"component '{component_id}', found {len(matches)}."
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
            f"{provider['providerId']}: expected exactly one "
            f"evidence '{evidence_id}', found {len(matches)}."
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
    standalone = fixtures["standalone-node.json"]
    if standalone["status"] != "success":
        fail("standalone-node.json must represent a successful provider result.")

    standalone_node = component(standalone, "node")
    if standalone_node["state"] != "present":
        fail("standalone-node.json must contain present Node.js.")
    if standalone_node["activeVersion"]["normalized"] != "24.13.0":
        fail("standalone-node.json must preserve the active Node.js version.")
    if component(standalone, "nvm-windows")["state"] != "missing":
        fail("standalone-node.json must represent a standalone Node installation.")
    if component(standalone, "angular-cli")["state"] != "present":
        fail(
            "standalone-node.json must preserve representative global "
            "JavaScript CLI visibility."
        )

    angular = component(standalone, "angular-cli")
    package_manager_installations = [
        item
        for item in angular["installations"]
        if item["source"] == "package-manager"
    ]
    if len(package_manager_installations) < 1:
        fail(
            "standalone-node.json must preserve selected global package "
            "installation provenance."
        )

    for evidence_id in (
        "javascript.npm.global-inventory",
        "javascript.pnpm.global-inventory",
    ):
        inventory = evidence(standalone, evidence_id)
        if inventory["captured"] is not None or inventory["redacted"] is not True:
            fail(
                f"{evidence_id} must redact raw global package inventory output."
            )
        if inventory["attributes"].get("parseSucceeded") is not True:
            fail(f"{evidence_id} must represent successful structured parsing.")

    pnpm_inventory = evidence(
        standalone,
        "javascript.pnpm.global-inventory",
    )
    matched_packages = pnpm_inventory["attributes"].get("matchedPackages", [])
    if not any(
        item.get("packageName") == "@angular/cli"
        and item.get("manager") == "pnpm"
        and item.get("version") == "22.1.8"
        and item.get("pathKnown") is True
        for item in matched_packages
    ):
        fail(
            "standalone-node.json must preserve selected pnpm global package "
            "metadata without exposing raw inventory."
        )

    nvm_managed = fixtures["nvm-managed-node.json"]
    nvm_node = component(nvm_managed, "node")
    nvm_component = component(nvm_managed, "nvm-windows")

    if nvm_component["state"] != "present":
        fail("nvm-managed-node.json must contain NVM for Windows.")
    if len(nvm_node["discoveredVersions"]) < 2:
        fail("nvm-managed-node.json must preserve multiple Node versions.")
    if len(nvm_node["installations"]) < 3:
        fail(
            "nvm-managed-node.json must preserve the active command path "
            "plus multiple NVM-managed installations."
        )
    active_installations = [
        item for item in nvm_node["installations"] if item["active"]
    ]
    if len(active_installations) < 1:
        fail("nvm-managed-node.json must identify an active Node installation.")

    missing = fixtures["missing-package-managers.json"]
    if component(missing, "node")["state"] != "present":
        fail("missing-package-managers.json must keep Node.js present.")
    for component_id in ("npm", "pnpm", "corepack"):
        if component(missing, component_id)["state"] != "missing":
            fail(
                "missing-package-managers.json must normalize missing "
                f"{component_id} state."
            )

    collisions = fixtures["command-collisions.json"]
    for component_id in ("node", "npm", "pnpm"):
        item = component(collisions, component_id)
        if len(item["commandResolutions"]) < 2:
            fail(
                f"command-collisions.json must preserve multiple "
                f"{component_id} command resolutions."
            )
        active = [
            resolution
            for resolution in item["commandResolutions"]
            if resolution["active"]
        ]
        if len(active) != 1 or active[0]["precedence"] != 0:
            fail(
                f"command-collisions.json must preserve active precedence "
                f"for {component_id}."
            )

    partial = fixtures["partial-nvm-configuration.json"]
    if partial["status"] != "partial":
        fail(
            "partial-nvm-configuration.json must use provider status partial."
        )
    partial_nvm = component(partial, "nvm-windows")
    if partial_nvm["state"] != "partial":
        fail(
            "partial-nvm-configuration.json must represent partial NVM state."
        )
    if not any(
        item["code"] == "NVM_CONFIGURATION_PARTIAL"
        for item in partial["warnings"]
    ):
        fail(
            "partial-nvm-configuration.json must preserve the partial "
            "NVM configuration warning."
        )


def validate_source_ownership() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()

    if "providerid = 'javascript.toolchain'" not in provider_source:
        fail("JavaScriptToolchain.Provider.ps1 must own javascript.toolchain.")

    for component_id in SPECIALIZED_COMPONENT_IDS:
        if component_id not in provider_source:
            fail(
                "JavaScriptToolchain.Provider.ps1 is missing expected "
                f"component ownership for '{component_id}'."
            )

        if re.search(
            rf"\bid\s*=\s*['\"]{re.escape(component_id)}['\"]",
            command_source,
        ):
            fail(
                "CommandInventory.Provider.ps1 must not duplicate "
                f"JavaScript ownership for '{component_id}'."
            )

    if not re.search(
        r"providerid\s*=\s*['\"]inventory\.commands['\"][\s\S]*?"
        r"order\s*=\s*25",
        command_source,
    ):
        fail(
            "CommandInventory.Provider.ps1 must run after the specialized "
            "JavaScript provider."
        )

    for pattern in FORBIDDEN_MUTATION_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "JavaScriptToolchain.Provider.ps1 contains a forbidden "
                f"mutation pattern: {pattern}"
            )

    expected_inventory_probes = (
        r"-command\s+['\"]npm['\"][\s\S]*?"
        r"-listarguments\s+@\(['\"]list['\"],\s*['\"]--global['\"],"
        r"\s*['\"]--depth=0['\"],\s*['\"]--json['\"]\)",
        r"-command\s+['\"]pnpm['\"][\s\S]*?"
        r"-listarguments\s+@\(['\"]list['\"],\s*['\"]--global['\"],"
        r"\s*['\"]--depth=0['\"],\s*['\"]--json['\"]\)",
    )
    for pattern in expected_inventory_probes:
        if not re.search(pattern, provider_source):
            fail(
                "JavaScriptToolchain.Provider.ps1 must keep bounded read-only "
                "global package inventory probes for npm and pnpm."
            )

    for evidence_suffix in ("global-inventory", "global-root"):
        pattern = (
            r"new-auditevidence\s+-evidenceid\s+"
            rf"['\"]?\$evidenceprefix\.{evidence_suffix}['\"]?"
            r"[\s\S]*?-sensitive"
        )
        if not re.search(pattern, provider_source):
            fail(
                "JavaScript global package/root evidence must remain redacted "
                f"for {evidence_suffix}."
            )

    nvm_invocations = set(
        re.findall(
            r"invoke-auditcommand\s+-command\s+['\"]nvm['\"]"
            r"\s+-arguments\s+@\(['\"]([^'\"]+)['\"]\)",
            provider_source,
        )
    )
    allowed_nvm_invocations = {"version", "current", "list", "root"}
    if nvm_invocations - allowed_nvm_invocations:
        fail(
            "JavaScriptToolchain.Provider.ps1 uses unexpected NVM "
            f"subcommands: {sorted(nvm_invocations - allowed_nvm_invocations)}"
        )
    if nvm_invocations != allowed_nvm_invocations:
        fail(
            "JavaScriptToolchain.Provider.ps1 must keep the expected "
            f"read-only NVM probes: {sorted(allowed_nvm_invocations)}"
        )

    if re.search(r"\bnpm\s+outdated\b", provider_source):
        fail(
            "JavaScriptToolchain.Provider.ps1 must not own latest-version "
            "intelligence."
        )

    if re.search(r"\bpnpm\s+outdated\b", provider_source):
        fail(
            "JavaScriptToolchain.Provider.ps1 must not own latest-version "
            "intelligence."
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
            "JavaScript fixture set mismatch. "
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
        print(
            "Validated JavaScript fixture: "
            f"{path.relative_to(ROOT)}"
        )

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print("JavaScript toolchain provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
