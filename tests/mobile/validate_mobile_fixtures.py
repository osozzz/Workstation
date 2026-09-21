from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "mobile"
PROVIDER_PATH = (
    ROOT / "scripts" / "Providers" / "FlutterAndroidToolchain.Provider.ps1"
)
COMMAND_INVENTORY_PATH = (
    ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"
)

EXPECTED_FIXTURES = {
    "bundled-dart.json",
    "standalone-dart.json",
    "missing-adb.json",
    "conflicting-sdk-roots.json",
    "partial-flutter.json",
}

SPECIALIZED_COMPONENT_IDS = {
    "flutter",
    "dart",
    "adb",
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
    r"\bflutter\s+(upgrade|downgrade|channel|precache)\b",
    r"\bflutter\s+config\b",
    r"\bsdkmanager\s+--licenses\b",
    r"\bsdkmanager\s+(--install|--update|--uninstall)\b",
    r"\bandroid\s+sdk\s+(install|update|remove)\b",
    r"\badb\s+(start-server|kill-server)\b",
    r"\bsetx\s+(flutter_root|android_home|android_sdk_root|pub_cache)\b",
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
    bundled = fixtures["bundled-dart.json"]
    if bundled["status"] != "success":
        fail("bundled-dart.json must represent a successful provider result.")

    flutter = component(bundled, "flutter")
    dart = component(bundled, "dart")
    adb = component(bundled, "adb")

    if flutter["activeVersion"]["normalized"] != "3.47.2":
        fail("bundled-dart.json must preserve the Flutter version.")
    if flutter["activeVersion"]["channel"] != "stable":
        fail("bundled-dart.json must preserve the Flutter stable channel.")
    if dart["activeVersion"]["normalized"] != "3.10.0":
        fail("bundled-dart.json must preserve the active Dart version.")
    if adb["activeVersion"]["normalized"] != "37.0.1":
        fail(
            "bundled-dart.json must normalize the platform-tools/ADB "
            "package version rather than the ADB protocol version."
        )

    relationship = evidence(
        bundled, "mobile.dart.relationship"
    )["attributes"]
    if relationship.get("activeSource") != "flutter-bundled":
        fail("Bundled Dart must be explicitly classified as flutter-bundled.")
    if relationship.get("bundledInstallationCount", 0) < 1:
        fail("Bundled Dart evidence must preserve its Flutter relationship.")

    android_metadata = evidence(
        bundled, "mobile.android-sdk.metadata"
    )["attributes"]["roots"]
    if len(android_metadata) < 1:
        fail("bundled-dart.json must preserve an Android SDK root.")
    components = android_metadata[0].get("components", [])
    if not any(
        item.get("component") == "platform-tools"
        and item.get("revision") == "37.0.1"
        for item in components
    ):
        fail(
            "Android metadata must preserve local platform-tools revision."
        )
    if not any(
        item.get("component") == "cmdline-tools/latest"
        for item in components
    ):
        fail("Android metadata must preserve command-line tools.")

    standalone = fixtures["standalone-dart.json"]
    if standalone["status"] != "partial":
        fail("standalone-dart.json must use provider status partial.")
    standalone_relationship = evidence(
        standalone, "mobile.dart.relationship"
    )["attributes"]
    if standalone_relationship.get("activeSource") != "standalone-or-external":
        fail("Standalone Dart must be classified separately from bundled Dart.")
    if not any(
        item["code"] == "DART_ACTIVE_NOT_FLUTTER_BUNDLED"
        for item in standalone["warnings"]
    ):
        fail(
            "standalone-dart.json must preserve the active Dart relationship "
            "warning."
        )

    missing_adb = fixtures["missing-adb.json"]
    if component(missing_adb, "adb")["state"] != "partial":
        fail(
            "missing-adb.json must preserve discovered ADB installation "
            "evidence even when the command is unresolved."
        )
    if not any(
        item["code"] == "ADB_COMMAND_UNRESOLVED"
        for item in missing_adb["warnings"]
    ):
        fail("missing-adb.json must preserve the ADB resolution warning.")

    conflict = fixtures["conflicting-sdk-roots.json"]
    if component(conflict, "android-sdk")["state"] != "partial":
        fail(
            "conflicting-sdk-roots.json must degrade the Android SDK state."
        )
    if not any(
        item["code"] == "ANDROID_SDK_ROOT_CONFLICT"
        for item in conflict["warnings"]
    ):
        fail(
            "conflicting-sdk-roots.json must preserve the SDK root conflict."
        )
    roots = evidence(
        conflict, "mobile.android-sdk.metadata"
    )["attributes"]["roots"]
    if len(roots) < 2:
        fail("Conflicting Android SDK roots must not be silently collapsed.")

    partial_flutter = fixtures["partial-flutter.json"]
    if component(partial_flutter, "flutter")["state"] != "partial":
        fail("partial-flutter.json must preserve partial Flutter state.")
    codes = {item["code"] for item in partial_flutter["warnings"]}
    if "FLUTTER_COMMAND_UNRESOLVED" not in codes:
        fail("partial-flutter.json must preserve the Flutter warning.")
    if "DART_COMMAND_UNRESOLVED" not in codes:
        fail(
            "partial-flutter.json must preserve bundled Dart evidence when "
            "the dart command is unresolved."
        )


def validate_source_ownership() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()

    if "providerid = 'mobile.flutter-android'" not in provider_source:
        fail(
            "FlutterAndroidToolchain.Provider.ps1 must own "
            "mobile.flutter-android."
        )

    if not re.search(
        r"providerid\s*=\s*['\"]mobile\.flutter-android['\"][\s\S]*?"
        r"order\s*=\s*23",
        provider_source,
    ):
        fail("Mobile provider must execute before the generic inventory.")

    for component_id in SPECIALIZED_COMPONENT_IDS:
        if component_id not in provider_source:
            fail(
                "FlutterAndroidToolchain.Provider.ps1 is missing expected "
                f"component ownership for '{component_id}'."
            )

        if re.search(
            rf"\bid\s*=\s*['\"]{re.escape(component_id)}['\"]",
            command_source,
        ):
            fail(
                "CommandInventory.Provider.ps1 must not duplicate mobile "
                f"ownership for '{component_id}'."
            )

    required_environment_names = (
        "flutter_root",
        "pub_cache",
        "android_home",
        "android_sdk_root",
    )
    for name in required_environment_names:
        if name not in provider_source:
            fail(f"Mobile provider must inspect allowlisted {name.upper()}.")

    required_read_only_probes = (
        "flutter' -arguments @('--version')",
        "dart' -arguments @('--version')",
        "adb' -arguments @('version')",
        "sdkmanager' -arguments @('--version')",
    )
    for probe in required_read_only_probes:
        if probe not in provider_source:
            fail(
                "FlutterAndroidToolchain.Provider.ps1 is missing expected "
                f"read-only probe: {probe}"
            )

    if "flutter doctor" in provider_source:
        fail(
            "Issue #29 must not depend on deep flutter doctor diagnostics."
        )

    if "bounded android sdk root/component inspection" not in provider_source:
        fail(
            "Android SDK detection must preserve bounded local component "
            "metadata."
        )

    if "source.properties" not in provider_source:
        fail(
            "Android SDK package revisions must be derived from local "
            "source.properties metadata where available."
        )

    for pattern in FORBIDDEN_MUTATION_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "FlutterAndroidToolchain.Provider.ps1 contains a forbidden "
                f"mutation pattern: {pattern}"
            )

    for latest_probe in (
        r"\bflutter\s+upgrade\b",
        r"\bsdkmanager\s+--list\b",
        r"\bsdkmanager\s+--update\b",
    ):
        if re.search(latest_probe, provider_source, flags=re.IGNORECASE):
            fail(
                "Mobile detection must not own remote/latest-version "
                f"intelligence: {latest_probe}"
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
            "Mobile fixture set mismatch. "
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
        print(f"Validated mobile fixture: {path.relative_to(ROOT)}")

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print("Flutter/Dart/Android toolchain provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
