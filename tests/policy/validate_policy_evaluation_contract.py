"""Validate the policy evaluation contract: schema, invariants, determinism, and privacy."""
from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path
from typing import Any, Callable

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "policy-evaluation.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "policy-evaluation"

# Shareable output: no drive or UNC paths, user profiles, commit IDs, or credentials in URLs.
PRIVACY_PATTERNS = {
    "absolute path": re.compile(r"(?i)\b[a-z]:[\\/]|\\\\[a-z0-9]"),
    "commit id": re.compile(r"\b[0-9a-f]{40}\b"),
    "url credentials": re.compile(r"://[^/\s:@]+:[^/\s@]+@"),
}


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def invariant_problems(evaluation: dict[str, Any]) -> list[str]:
    problems: list[str] = []
    findings = evaluation["findings"]
    summary = evaluation["summary"]
    counts = {status: sum(1 for f in findings if f["status"] == status) for status in ("compliant", "deviation", "unknown", "not-evaluable")}

    expected_summary = {
        "findingCount": len(findings),
        "compliantCount": counts["compliant"],
        "deviationCount": counts["deviation"],
        "unknownCount": counts["unknown"],
        "notEvaluableCount": counts["not-evaluable"],
    }
    for key, value in expected_summary.items():
        if summary[key] != value:
            problems.append(f"summary.{key} is {summary[key]}, expected {value}")

    expected_status = "deviations" if counts["deviation"] else "incomplete" if counts["unknown"] else "compliant"
    if summary["status"] != expected_status:
        problems.append(f"summary.status is {summary['status']}, expected {expected_status}")

    keys = [(f["policyKey"], f["ruleId"], f["subjectId"] or "") for f in findings]
    if keys != sorted(keys):
        problems.append("findings are not ordered by policyKey, ruleId, subjectId")
    if len(keys) != len(set(keys)):
        problems.append("findings repeat the same policyKey, ruleId, subjectId")

    text = json.dumps(evaluation, ensure_ascii=False)
    for label, pattern in PRIVACY_PATTERNS.items():
        if pattern.search(text):
            problems.append(f"contains a prohibited {label}")
    return problems


def main() -> int:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    fixtures = sorted(FIXTURE_DIR.glob("*.json"))
    if not fixtures:
        fail("No policy evaluation fixtures found.")

    seen_statuses: set[str] = set()
    base: dict[str, Any] | None = None
    for path in fixtures:
        evaluation = json.loads(path.read_text(encoding="utf-8"))
        errors = list(validator.iter_errors(evaluation))
        if errors:
            fail(f"{path.name}: " + "; ".join(f"{list(e.absolute_path)} {e.message}" for e in errors[:5]))
        problems = invariant_problems(evaluation)
        if problems:
            fail(f"{path.name}: " + "; ".join(problems))
        seen_statuses.update(f["status"] for f in evaluation["findings"])
        base = base or evaluation
        print(f"Valid evaluation fixture: {path.name}")

    if seen_statuses != {"compliant", "deviation", "unknown", "not-evaluable"}:
        fail(f"Fixtures must cover every finding status; found {sorted(seen_statuses)}")

    assert base is not None
    schema_cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("unknown finding status", lambda e: e["findings"][0].__setitem__("status", "warning")),
        ("unknown summary status", lambda e: e["summary"].__setitem__("status", "ok")),
        ("deviation without evidence", lambda e: next(f for f in e["findings"] if f["status"] == "deviation").__setitem__("evidence", [])),
        ("compliant without evidence", lambda e: next(f for f in e["findings"] if f["status"] == "compliant").__setitem__("evidence", [])),
        ("not-evaluable with an observed value", lambda e: next(f for f in e["findings"] if f["status"] == "not-evaluable").__setitem__("observed", True)),
        ("malformed policy key", lambda e: e["findings"][0].__setitem__("policyKey", "node")),
        ("malformed policy digest", lambda e: e["policy"].__setitem__("digest", "abc")),
        ("extra finding property", lambda e: e["findings"][0].__setitem__("severity", "high")),
        ("unsupported audit schema major", lambda e: e.__setitem__("auditSchemaMajor", 2)),
    ]
    for label, mutate in schema_cases:
        candidate = copy.deepcopy(base)
        mutate(candidate)
        if validator.is_valid(candidate):
            fail(f"Negative schema case unexpectedly passed: {label}")
        print(f"Expected invalid (schema): {label}")

    invariant_cases: list[tuple[str, Callable[[dict[str, Any]], None]]] = [
        ("summary count drift", lambda e: e["summary"].__setitem__("deviationCount", 0)),
        ("summary status drift", lambda e: e["summary"].__setitem__("status", "compliant")),
        ("unordered findings", lambda e: e["findings"].reverse()),
        ("absolute path in a value", lambda e: e["findings"][1].__setitem__("observed", "C:\\Users\\someone\\project")),
        ("forward-slash absolute path", lambda e: e["findings"][1].__setitem__("observed", "c:/tools/bin")),
        ("commit id in a value", lambda e: e["findings"][1].__setitem__("observed", "a" * 40)),
    ]
    for label, mutate in invariant_cases:
        candidate = copy.deepcopy(base)
        mutate(candidate)
        if not invariant_problems(candidate):
            fail(f"Negative invariant case unexpectedly passed: {label}")
        print(f"Expected invalid (invariant): {label}")

    print(f"Policy evaluation contract validation passed ({len(schema_cases) + len(invariant_cases)} negative cases).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
