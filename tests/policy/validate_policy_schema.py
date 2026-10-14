"""Validate config/workstation.policy.json against its schema, plus controlled invalid variants."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any, Callable

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "workstation-policy.schema.json"
POLICY_PATH = ROOT / "config" / "workstation.policy.json"


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def load(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    schema = load(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    policy = load(POLICY_PATH)
    errors = sorted(validator.iter_errors(policy), key=lambda error: list(error.absolute_path))
    if errors:
        fail("Committed policy is invalid:\n" + "\n".join(f"  {list(e.absolute_path)}: {e.message}" for e in errors))
    print(f"Valid policy: {POLICY_PATH.relative_to(ROOT)}")

    # Every section in the schema must exist in the committed policy and vice versa.
    if set(policy) != set(schema["properties"]):
        fail(f"Policy sections and schema properties differ: {sorted(set(policy) ^ set(schema['properties']))}")

    # Negative cases are generated in memory so invalid policies are never committed.
    cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("unknown top-level section", lambda p: p.__setitem__("ruby", {})),
        ("misspelled key inside a section", lambda p: p["node"].__setitem__("defaultTrak", "lts")),
        ("missing section", lambda p: p.pop("path")),
        ("missing key inside a section", lambda p: p["javascript"].pop("primaryPackageManager")),
        ("invalid track value", lambda p: p["versioning"].__setitem__("globalDefaultTrack", "newest")),
        ("invalid Node default track", lambda p: p["node"].__setitem__("defaultTrack", "latest")),
        ("wrong value type", lambda p: p["path"].__setitem__("allowDuplicateEntries", "no")),
        ("unsupported schema version", lambda p: p.__setitem__("schemaVersion", "2.0")),
        ("audit accepting Android licenses", lambda p: p["android"].__setitem__("acceptLicensesDuringAudit", True)),
        ("audit auto-installing Rust", lambda p: p["rust"].__setitem__("autoInstallDuringAudit", True)),
        ("audit inspecting CLI authentication", lambda p: p["developerClis"].__setitem__("inspectAuthenticationState", True)),
        ("audit inspecting Git configuration", lambda p: p["developerClis"].__setitem__("inspectGitConfiguration", True)),
        ("malformed minimum Rust version", lambda p: p["rust"].__setitem__("minimumSafeInspectionVersion", "1.28")),
    ]

    for label, mutate in cases:
        candidate = copy.deepcopy(policy)
        mutate(candidate)
        if validator.is_valid(candidate):
            fail(f"Negative policy case unexpectedly passed: {label}")
        print(f"Expected invalid: {label}")

    print(f"Workstation policy schema validation passed ({len(cases)} negative cases).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
