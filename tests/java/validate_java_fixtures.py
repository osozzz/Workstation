from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "java"
PROVIDER_PATH = ROOT / "scripts" / "Providers" / "JavaJvmToolchain.Provider.ps1"
COMMAND_INVENTORY_PATH = ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"

EXPECTED_FIXTURES = {
    "multiple-jdks.json",
    "missing-javac.json",
    "mismatched-java-home.json",
    "build-tools-present.json",
}

SPECIALIZED_COMPONENT_IDS = {
    "java",
    "javac",
    "maven",
    "gradle",
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
    r"\bwinget\s+(install|upgrade|uninstall)\b",
    r"\bchoco\s+(install|upgrade|uninstall)\b",
    r"\bscoop\s+(install|update|uninstall)\b",
    r"\bsdk\s+(install|use|default|uninstall)\b",
    r"\bsetx\s+java_home\b",
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
    multiple = fixtures["multiple-jdks.json"]
    if multiple["status"] != "success":
        fail("multiple-jdks.json must represent a successful provider result.")

    java = component(multiple, "java")
    javac = component(multiple, "javac")

    if java["activeVersion"]["normalized"] != "25.0.2":
        fail("multiple-jdks.json must preserve the active Java version.")
    if len(java["installations"]) < 2:
        fail("multiple-jdks.json must preserve multiple Java installations.")
    if len(java["discoveredVersions"]) < 2:
        fail("multiple-jdks.json must preserve multiple Java versions.")
    if javac["state"] != "present":
        fail("multiple-jdks.json must preserve an active Java compiler.")

    metadata = evidence(multiple, "java.installations")["attributes"][
        "installations"
    ]
    if not any(
        item.get("vendor") == "Eclipse Adoptium"
        and item.get("distribution") == "Temurin"
        and item.get("majorVersion") == 25
        and item.get("kind") == "jdk"
        for item in metadata
    ):
        fail(
            "multiple-jdks.json must preserve normalized vendor, "
            "distribution, major version, and JDK kind."
        )
    if not any(
        item.get("distribution") == "Microsoft Build of OpenJDK"
        and item.get("majorVersion") == 21
        for item in metadata
    ):
        fail(
            "multiple-jdks.json must preserve metadata for the secondary JDK."
        )

    missing_javac = fixtures["missing-javac.json"]
    if missing_javac["status"] != "partial":
        fail("missing-javac.json must use provider status partial.")
    if component(missing_javac, "javac")["state"] != "missing":
        fail("missing-javac.json must represent a missing javac command.")
    if not any(
        item["code"] == "JAVAC_COMMAND_MISSING"
        for item in missing_javac["warnings"]
    ):
        fail("missing-javac.json must preserve the javac warning.")

    mismatch = fixtures["mismatched-java-home.json"]
    if mismatch["status"] != "partial":
        fail("mismatched-java-home.json must use provider status partial.")
    if component(mismatch, "java")["state"] != "partial":
        fail(
            "mismatched-java-home.json must degrade the Java component "
            "when JAVA_HOME conflicts with the active command."
        )
    if not any(
        item["code"] == "JAVA_HOME_COMMAND_MISMATCH"
        for item in mismatch["warnings"]
    ):
        fail(
            "mismatched-java-home.json must preserve the JAVA_HOME mismatch."
        )

    build_tools = fixtures["build-tools-present.json"]
    for component_id in ("maven", "gradle"):
        item = component(build_tools, component_id)
        if item["state"] != "present":
            fail(
                f"build-tools-present.json must preserve {component_id}."
            )
        if len(item["commandResolutions"]) < 1:
            fail(
                f"build-tools-present.json must preserve {component_id} "
                "command resolution."
            )

    for component_id in ("maven", "gradle"):
        if component(missing_javac, component_id)["state"] != "missing":
            fail(
                "missing-javac.json also covers build-tool absence and must "
                f"keep {component_id} missing."
            )


def validate_source_ownership() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    command_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()

    if "providerid = 'java.jvm'" not in provider_source:
        fail("JavaJvmToolchain.Provider.ps1 must own java.jvm.")

    if not re.search(
        r"providerid\s*=\s*['\"]java\.jvm['\"][\s\S]*?"
        r"order\s*=\s*22",
        provider_source,
    ):
        fail("Java JVM provider must execute before the generic inventory.")

    for component_id in SPECIALIZED_COMPONENT_IDS:
        if component_id not in provider_source:
            fail(
                "JavaJvmToolchain.Provider.ps1 is missing expected "
                f"component ownership for '{component_id}'."
            )

        if re.search(
            rf"\bid\s*=\s*['\"]{re.escape(component_id)}['\"]",
            command_source,
        ):
            fail(
                "CommandInventory.Provider.ps1 must not duplicate Java "
                f"ownership for '{component_id}'."
            )

    required_read_only_probes = (
        "java' -arguments @('-xshowsettings:properties', '-version')",
        "javac' -arguments @('-version')",
        "mvn' -arguments @('-version')",
        "gradle' -arguments @('--version')",
    )
    for probe in required_read_only_probes:
        if probe not in provider_source:
            fail(
                "JavaJvmToolchain.Provider.ps1 is missing expected "
                f"read-only probe: {probe}"
            )

    if "get-auditenvironmentsnapshot -names @('java_home')" not in provider_source:
        fail("Java provider must inspect JAVA_HOME through the allowlisted API.")

    if "javasoft jdk/jre registry keys" not in provider_source:
        fail("Java provider must preserve bounded JavaSoft registry discovery.")

    if "bounded known java installation roots" not in provider_source:
        fail("Java provider must preserve bounded filesystem discovery.")

    if "java.installations" not in provider_source:
        fail(
            "Java provider must preserve normalized installation metadata "
            "evidence."
        )

    for marker in (
        "majorversion",
        "vendor",
        "distribution",
        "kind",
        "architecture",
    ):
        if marker not in provider_source:
            fail(
                "Java installation metadata must preserve normalized "
                f"'{marker}'."
            )

    for pattern in FORBIDDEN_MUTATION_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "JavaJvmToolchain.Provider.ps1 contains a forbidden "
                f"mutation pattern: {pattern}"
            )

    if re.search(r"\bwinget\s+(show|search)\b", provider_source):
        fail(
            "Java detection must not own latest-version intelligence; that "
            "belongs to the later version-intelligence milestone."
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
            "Java fixture set mismatch. "
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
        print(f"Validated Java fixture: {path.relative_to(ROOT)}")

    validate_domain_cases(fixtures)
    validate_source_ownership()

    print("Java/JVM toolchain provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
