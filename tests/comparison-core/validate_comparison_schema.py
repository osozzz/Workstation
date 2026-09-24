import json
from pathlib import Path

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "comparison-result.schema.json"

schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)

valid = {
    "schemaVersion": "1.0.0",
    "auditSchemaMajor": 1,
    "direction": "reference-to-target",
    "reference": {
        "schemaVersion": "1.0.0",
        "generatedAt": "2026-09-23T20:00:00+00:00",
        "audit": {"mode": "read-only", "toolVersion": "0.7.0"},
        "host": {
            "name": "SYNTHETIC-REFERENCE",
            "platform": "windows",
            "architecture": "x64",
        },
    },
    "target": {
        "schemaVersion": "1.0.0",
        "generatedAt": "2026-09-23T20:00:00+00:00",
        "audit": {"mode": "read-only", "toolVersion": "0.7.0"},
        "host": {
            "name": "SYNTHETIC-TARGET",
            "platform": "windows",
            "architecture": "x64",
        },
    },
    "summary": {
        "status": "different",
        "differenceCount": 1,
        "providerDifferenceCount": 0,
        "componentDifferenceCount": 1,
        "unavailableCount": 0,
        "unknownCount": 1,
        "notApplicableCount": 0,
    },
    "differences": [
        {
            "category": "component",
            "kind": "state",
            "providerId": "runtime.synthetic",
            "componentId": "synthetic-runtime",
            "subjectId": None,
            "relation": "unknown",
            "referenceState": "present",
            "targetState": "unknown",
            "referenceValue": None,
            "targetValue": None,
        }
    ],
}

validator.validate(valid)

invalid_relation = json.loads(json.dumps(valid))
invalid_relation["differences"][0]["relation"] = "better"
try:
    validator.validate(invalid_relation)
except ValidationError:
    pass
else:
    raise AssertionError("comparison schema accepted an unsupported relation")

invalid_extra_property = json.loads(json.dumps(valid))
invalid_extra_property["unexpected"] = True
try:
    validator.validate(invalid_extra_property)
except ValidationError:
    pass
else:
    raise AssertionError("comparison schema accepted an unexpected top-level property")

print("Comparison result schema validation passed.")
