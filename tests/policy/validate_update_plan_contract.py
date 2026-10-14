"""Validate the update plan contract: schema, invariants, determinism, and privacy."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any, Callable

from jsonschema import Draft202012Validator, FormatChecker

from validate_policy_evaluation_contract import PRIVACY_PATTERNS

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "update-plan.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "update-plan"
RISK_RANK = {"low": 0, "medium": 1, "high": 2}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def invariant_problems(plan: dict[str, Any]) -> list[str]:
    problems: list[str] = []
    actions = plan["actions"]
    summary = plan["summary"]

    expected_summary = {
        "actionCount": len(actions),
        "lowRiskCount": sum(1 for a in actions if a["risk"] == "low"),
        "mediumRiskCount": sum(1 for a in actions if a["risk"] == "medium"),
        "highRiskCount": sum(1 for a in actions if a["risk"] == "high"),
        "reversibleCount": sum(1 for a in actions if a["reversible"]),
        "manualCount": sum(1 for a in actions if a["command"] is None),
    }
    for key, value in expected_summary.items():
        if summary[key] != value:
            problems.append(f"summary.{key} is {summary[key]}, expected {value}")

    if [a["order"] for a in actions] != list(range(1, len(actions) + 1)):
        problems.append("order must count 1, 2, 3, ... without gaps")

    keys = [(RISK_RANK[a["risk"]], a["actionId"]) for a in actions]
    if keys != sorted(keys):
        problems.append("actions are not ordered by risk, then actionId")
    if len({a["actionId"] for a in actions}) != len(actions):
        problems.append("actions repeat the same actionId")

    text = json.dumps(plan, ensure_ascii=False)
    for label, pattern in PRIVACY_PATTERNS.items():
        if pattern.search(text):
            problems.append(f"contains a prohibited {label}")
    return problems


def first(plan: dict[str, Any], source_type: str) -> dict[str, Any]:
    return next(a for a in plan["actions"] if a["source"]["type"] == source_type)


def main() -> int:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    # Explicit paths validate generated plans (schema and invariants only).
    explicit = [Path(arg) for arg in sys.argv[1:]]
    plans = explicit or sorted(FIXTURE_DIR.glob("*.json"))
    if not plans:
        fail("No update plan fixtures found.")

    base: dict[str, Any] | None = None
    for path in plans:
        plan = json.loads(path.read_text(encoding="utf-8"))
        errors = list(validator.iter_errors(plan))
        if errors:
            fail(f"{path.name}: " + "; ".join(f"{list(e.absolute_path)} {e.message}" for e in errors[:5]))
        problems = invariant_problems(plan)
        if problems:
            fail(f"{path.name}: " + "; ".join(problems))
        base = base or plan
        print(f"Valid update plan: {path.name}")

    if explicit:
        return 0

    assert base is not None
    covered = {(a["kind"], a["risk"], a["source"]["type"]) for a in base["actions"]}
    for field, values in (("kind", {"upgrade", "install", "configure", "cleanup"}), ("risk", set(RISK_RANK)), ("source", set(schema["$defs"]["action"]["properties"]["source"]["properties"]["type"]["enum"]))):
        index = ("kind", "risk", "source").index(field)
        if {c[index] for c in covered} != values:
            fail(f"Fixtures must cover every {field}.")

    schema_cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("unknown kind", lambda p: p["actions"][0].__setitem__("kind", "remove")),
        ("unknown risk", lambda p: p["actions"][0].__setitem__("risk", "critical")),
        ("action without evidence", lambda p: p["actions"][0].__setitem__("evidence", [])),
        ("policy source without key", lambda p: first(p, "policy")["source"].__setitem__("policyKey", None)),
        ("winget source with a policy key", lambda p: first(p, "winget")["source"].__setitem__("policyKey", "node.manager")),
        ("empty command string", lambda p: p["actions"][2].__setitem__("command", "")),
        ("malformed actionId", lambda p: p["actions"][0].__setitem__("actionId", "Policy android")),
        ("extra action property", lambda p: p["actions"][0].__setitem__("executed", True)),
        ("unsupported audit schema major", lambda p: p.__setitem__("auditSchemaMajor", 2)),
    ]
    for label, mutate in schema_cases:
        candidate = copy.deepcopy(base)
        mutate(candidate)
        if validator.is_valid(candidate):
            fail(f"Negative schema case unexpectedly passed: {label}")
        print(f"Expected invalid (schema): {label}")

    invariant_cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("summary count drift", lambda p: p["summary"].__setitem__("manualCount", 0)),
        ("order gap", lambda p: p["actions"][1].__setitem__("order", 7)),
        ("risk order", lambda p: p["actions"].reverse()),
        ("duplicate action", lambda p: p["actions"][1].__setitem__("actionId", p["actions"][0]["actionId"])),
        ("absolute path in a command", lambda p: p["actions"][2].__setitem__("command", "setx PATH C:\\Users\\someone\\bin")),
        ("credentials in a URL", lambda p: p["actions"][2].__setitem__("message", "see https://user:token@example.invalid/x")),
    ]
    for label, mutate in invariant_cases:
        candidate = copy.deepcopy(base)
        mutate(candidate)
        if not invariant_problems(candidate):
            fail(f"Negative invariant case unexpectedly passed: {label}")
        print(f"Expected invalid (invariant): {label}")

    print(f"Update plan contract validation passed ({len(schema_cases) + len(invariant_cases)} negative cases).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
