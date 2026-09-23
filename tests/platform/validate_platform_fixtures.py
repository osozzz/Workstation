from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "platform"
HOST_PROVIDER_PATH = ROOT / "scripts" / "Providers" / "Host.Provider.ps1"
WINGET_PROVIDER_PATH = ROOT / "scripts" / "Providers" / "WinGetBaseline.Provider.ps1"
COMMAND_INVENTORY_PATH = ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"

EXPECTED_FIXTURES = {
    "host-full.json",
    "host-windows-only.json",
    "host-partial.json",
    "winget-present.json",
    "winget-unavailable.json",
    "winget-partial.json",
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


def validate_domain_cases(fixtures: dict[str, dict[str, Any]]) -> None:
    full = fixtures["host-full.json"]
    if full["providerId"] != "host.system" or full["status"] != "success":
        fail("host-full.json must represent a successful host.system result.")

    windows = component(full, "windows")
    windows_ps = component(full, "powershell.windows")
    core_ps = component(full, "powershell.core")

    if windows["state"] != "present" or windows["installed"] is not True:
        fail("host-full.json must contain present Windows state.")

    cim = evidence(full, "host.windows.cim")
    registry = evidence(full, "host.windows.registry")
    cim_caption = cim["attributes"].get("caption")
    registry_product_name = registry["attributes"].get("productName")

    if windows["name"] != cim_caption:
        fail(
            "host-full.json must preserve the CIM Windows caption as the "
            "normalized component name."
        )
    if not registry_product_name or registry_product_name == cim_caption:
        fail(
            "host-full.json must exercise a registry ProductName compatibility "
            "string that differs from the CIM caption."
        )

    if windows_ps["state"] != "present":
        fail("host-full.json must contain Windows PowerShell.")
    if core_ps["state"] != "present":
        fail("host-full.json must contain PowerShell Core.")
    if len(core_ps["commandResolutions"]) < 2:
        fail(
            "host-full.json must preserve multiple PowerShell Core "
            "command resolutions."
        )
    if len(core_ps["installations"]) < 2:
        fail(
            "host-full.json must preserve multiple PowerShell Core "
            "installations."
        )

    windows_only = fixtures["host-windows-only.json"]
    if component(windows_only, "powershell.windows")["state"] != "present":
        fail("host-windows-only.json must keep Windows PowerShell present.")
    if component(windows_only, "powershell.core")["state"] != "missing":
        fail("host-windows-only.json must represent missing PowerShell Core.")

    partial_host = fixtures["host-partial.json"]
    if partial_host["status"] != "partial":
        fail("host-partial.json must use provider status partial.")
    if component(partial_host, "powershell.core")["state"] != "partial":
        fail("host-partial.json must represent partial PowerShell Core state.")

    winget_present = fixtures["winget-present.json"]
    winget_component = component(winget_present, "winget")
    if (
        winget_present["status"] != "success"
        or winget_component["state"] != "present"
    ):
        fail("winget-present.json must represent healthy WinGet detection.")

    winget_sources = evidence(winget_present, "winget.sources")
    if winget_sources["captured"] is not None or winget_sources["redacted"] is not True:
        fail(
            "winget-present.json must redact raw source details while preserving "
            "the command status."
        )

    winget_unavailable = fixtures["winget-unavailable.json"]
    if winget_unavailable["status"] != "unavailable":
        fail("winget-unavailable.json must use provider status unavailable.")
    if component(winget_unavailable, "winget")["state"] != "missing":
        fail("winget-unavailable.json must represent missing WinGet.")

    winget_partial = fixtures["winget-partial.json"]
    if winget_partial["status"] != "partial":
        fail("winget-partial.json must use provider status partial.")
    if component(winget_partial, "winget")["state"] != "partial":
        fail("winget-partial.json must represent partial WinGet state.")

    winget_partial_sources = evidence(winget_partial, "winget.sources")
    if (
        winget_partial_sources["captured"] is not None
        or winget_partial_sources["redacted"] is not True
    ):
        fail("winget-partial.json must redact raw source details.")

    for name in (
        "winget-present.json",
        "winget-unavailable.json",
        "winget-partial.json",
    ):
        fixture_text = json.dumps(fixtures[name]).lower()
        if "winget upgrade" in fixture_text:
            fail(f"{name} must not contain WinGet upgrade diagnostics.")
        if "--accept-source-agreements" in fixture_text:
            fail(f"{name} must not accept source agreements.")


def validate_source_ownership() -> None:
    host_source = HOST_PROVIDER_PATH.read_text(encoding="utf-8").lower()
    winget_source = WINGET_PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(encoding="utf-8").lower()

    for component_id in ("powershell.windows", "powershell.core"):
        if component_id not in host_source:
            fail(
                "Host.Provider.ps1 must own both Windows PowerShell "
                "and PowerShell Core detection."
            )

    if "$oscaption = [string]$windowsregistry.productname" in host_source:
        fail(
            "Host.Provider.ps1 must not let the registry ProductName "
            "override the CIM Windows caption."
        )

    if not re.search(
        r"invoke-auditcommand\s+-command\s+['\"]winget['\"]"
        r"[\s\S]{0,160}['\"]upgrade['\"]"
        r"[\s\S]{0,160}['\"]--disable-interactivity['\"]",
        winget_source,
    ):
        fail(
            "WinGetBaseline.Provider.ps1 must preserve the read-only "
            "non-interactive upgrade availability lookup."
        )

    if re.search(
        r"['\"]upgrade['\"][\s\S]{0,160}['\"]--all['\"]",
        winget_source,
    ):
        fail(
            "WinGetBaseline.Provider.ps1 must not invoke bulk package upgrades."
        )

    for forbidden in (
        "--accept-source-agreements",
        "--accept-package-agreements",
        "'install'",
        '"install"',
        "'uninstall'",
        '"uninstall"',
        "'repair'",
        '"repair"',
    ):
        if forbidden in winget_source:
            fail(
                "WinGetBaseline.Provider.ps1 contains a forbidden mutation "
                f"or agreement marker: {forbidden}"
            )

    if re.search(r"\bid\s*=\s*['\"]winget['\"]", command_source):
        fail(
            "CommandInventory.Provider.ps1 must not duplicate WinGet "
            "ownership after specialized detection exists."
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
            "Platform fixture set mismatch. "
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
        print(f"Validated platform fixture: {path.relative_to(ROOT)}")

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print("Platform provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
