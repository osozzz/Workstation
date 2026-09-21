from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "python"
PROVIDER_PATH = ROOT / "scripts" / "Providers" / "PythonEcosystem.Provider.ps1"
COMMAND_INVENTORY_PATH = (
    ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"
)

EXPECTED_FIXTURES = {
    "multiple-interpreters.json",
    "launcher-only.json",
    "missing-pip.json",
    "uv-pipx-present.json",
    "conflicting-resolutions.json",
}

SPECIALIZED_COMPONENT_IDS = {
    "python",
    "python-launcher",
    "pip",
    "pipx",
    "uv",
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
    r"\bpy\s+install\b",
    r"\bpymanager\s+install\b",
    r"\bpython(?:\.exe)?\s+-m\s+venv\b",
    r"\bpip\s+install\b",
    r"\bpipx\s+(install|upgrade|uninstall|ensurepath|repair)\b",
    r"\buv\s+(add|remove|sync|venv|python\s+install|python\s+upgrade)\b",
    r"\bpyenv\s+(install|uninstall|global|local|shell|rehash)\b",
    r"\bsetx\s+pyenv_root\b",
    r"\[environment\]::setenvironmentvariable",
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
    multiple = fixtures["multiple-interpreters.json"]
    if multiple["status"] != "success":
        fail(
            "multiple-interpreters.json must represent a successful provider "
            "result."
        )

    python = component(multiple, "python")
    launcher = component(multiple, "python-launcher")
    pyenv = component(multiple, "pyenv-win")

    if python["activeVersion"]["normalized"] != "3.14.7":
        fail(
            "multiple-interpreters.json must preserve the active Python "
            "version."
        )
    if len(python["installations"]) < 2:
        fail(
            "multiple-interpreters.json must preserve multiple interpreters."
        )
    if len(python["discoveredVersions"]) < 2:
        fail(
            "multiple-interpreters.json must preserve multiple Python "
            "versions."
        )
    if launcher["state"] != "present":
        fail(
            "multiple-interpreters.json must preserve the Windows launcher/"
            "manager."
        )
    if pyenv["state"] != "present":
        fail(
            "multiple-interpreters.json must demonstrate conservative "
            "pyenv-win detection."
        )

    inventory = evidence(
        multiple, "python.installations"
    )["attributes"]
    if len(inventory["launcherMappings"]) < 2:
        fail(
            "Python installation evidence must preserve launcher mappings."
        )
    if not any(
        item.get("company") == "PythonCore"
        and item.get("version") == "3.14.7"
        for item in inventory["launcherMappings"]
    ):
        fail(
            "Python launcher mappings must preserve company/tag/version "
            "metadata."
        )

    launcher_only = fixtures["launcher-only.json"]
    if launcher_only["status"] != "partial":
        fail("launcher-only.json must use provider status partial.")
    if component(launcher_only, "python")["state"] != "partial":
        fail(
            "launcher-only.json must not claim an active Python command when "
            "only launcher mappings are available."
        )
    if not any(
        item["code"] == "PYTHON_COMMAND_UNRESOLVED"
        for item in launcher_only["warnings"]
    ):
        fail(
            "launcher-only.json must preserve the unresolved python command "
            "warning."
        )

    missing_pip = fixtures["missing-pip.json"]
    if missing_pip["status"] != "partial":
        fail("missing-pip.json must use provider status partial.")
    if component(missing_pip, "pip")["state"] != "missing":
        fail("missing-pip.json must preserve missing pip state.")
    if not any(
        item["code"] == "PIP_MISSING_FOR_PYTHON"
        for item in missing_pip["warnings"]
    ):
        fail("missing-pip.json must preserve the missing pip warning.")

    tools = fixtures["uv-pipx-present.json"]
    for component_id in ("pipx", "uv"):
        item = component(tools, component_id)
        if item["state"] != "present":
            fail(
                f"uv-pipx-present.json must preserve {component_id}."
            )
        if len(item["commandResolutions"]) < 1:
            fail(
                f"uv-pipx-present.json must preserve {component_id} "
                "command resolution."
            )

    conflict = fixtures["conflicting-resolutions.json"]
    if conflict["status"] != "partial":
        fail("conflicting-resolutions.json must use provider status partial.")
    conflict_python = component(conflict, "python")
    if len(conflict_python["commandResolutions"]) < 2:
        fail(
            "conflicting-resolutions.json must preserve multiple command "
            "resolutions."
        )
    if not any(
        item["code"] == "PYTHON_COMMAND_COLLISION"
        for item in conflict["warnings"]
    ):
        fail(
            "conflicting-resolutions.json must preserve the resolution "
            "collision warning."
        )


def validate_source_ownership() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()

    if "providerid = 'python.ecosystem'" not in provider_source:
        fail("PythonEcosystem.Provider.ps1 must own python.ecosystem.")

    if not re.search(
        r"providerid\s*=\s*['\"]python\.ecosystem['\"][\s\S]*?"
        r"order\s*=\s*24",
        provider_source,
    ):
        fail("Python ecosystem provider must execute before generic inventory.")

    for component_id in SPECIALIZED_COMPONENT_IDS:
        if component_id not in provider_source:
            fail(
                "PythonEcosystem.Provider.ps1 is missing expected "
                f"component ownership for '{component_id}'."
            )

        if re.search(
            rf"\bid\s*=\s*['\"]{re.escape(component_id)}['\"]",
            command_source,
        ):
            fail(
                "CommandInventory.Provider.ps1 must not duplicate Python "
                f"ownership for '{component_id}'."
            )

    if "get-auditenvironmentsnapshot -names @('pyenv_root')" not in provider_source:
        fail("Python provider must inspect PYENV_ROOT through the allowlist.")

    required_read_only_probes = (
        "py' -arguments @('list', '--format=json')",
        "py' -arguments @('-0p')",
        "pip' -arguments @('--version')",
        "pipx' -arguments @('--version')",
        "uv' -arguments @('--version')",
        "pyenv' -arguments @('--version')",
        "pyenv' -arguments @('versions', '--bare')",
    )
    for probe in required_read_only_probes:
        if probe not in provider_source:
            fail(
                "PythonEcosystem.Provider.ps1 is missing expected "
                f"read-only probe: {probe}"
            )

    if "microsoft\\windowsapps" not in provider_source:
        fail(
            "Python provider must guard WindowsApps aliases before executing "
            "python."
        )

    if "pythonsoftwarefoundation\\.pythonmanager" not in provider_source:
        fail(
            "Python provider must guard Python Install Manager aliases before "
            "direct interpreter probes."
        )

    if "pep 514 python registry registrations" not in provider_source:
        fail(
            "Python provider must preserve bounded PEP 514 registry "
            "discovery."
        )

    if "convertfrom-json" not in provider_source:
        fail(
            "Modern Python install manager mappings must use structured JSON "
            "when available."
        )

    if "py list --online" in provider_source:
        fail(
            "Python detection must never query online runtime inventory in "
            "Sprint 2."
        )

    for pattern in FORBIDDEN_MUTATION_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "PythonEcosystem.Provider.ps1 contains a forbidden mutation "
                f"pattern: {pattern}"
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
            "Python fixture set mismatch. "
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
        print(f"Validated Python fixture: {path.relative_to(ROOT)}")

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print("Python ecosystem provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
