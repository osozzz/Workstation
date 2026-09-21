from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "schemas" / "provider-result.schema.json"
FIXTURE_DIR = ROOT / "tests" / "fixtures" / "developer-clis"
PROVIDER_PATH = ROOT / "scripts" / "Providers" / "DeveloperClis.Provider.ps1"
COMMAND_INVENTORY_PATH = (
    ROOT / "scripts" / "Providers" / "CommandInventory.Provider.ps1"
)
JAVASCRIPT_PROVIDER_PATH = (
    ROOT / "scripts" / "Providers" / "JavaScriptToolchain.Provider.ps1"
)
POLICY_PATH = ROOT / "config" / "workstation.policy.json"

EXPECTED_FIXTURES = {
    "all-installed.json",
    "all-missing.json",
    "command-collisions.json",
    "nonfunctional-compose.json",
    "legacy-compose-only.json",
    "nonfunctional-cli.json",
}

SPECIALIZED_COMPONENT_IDS = {
    "git",
    "github-cli",
    "docker",
    "docker-compose",
    "supabase-cli",
    "vercel-cli",
    "heroku-cli",
}

CONTINUITY_COMPONENT_IDS = {
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

FORBIDDEN_PROVIDER_PATTERNS = (
    r"\bgit\s+config\b",
    r"\bgh\s+(auth|api|config)\b",
    r"\bdocker\s+(info|login|logout|context|system|start|stop)\b",
    r"\bdocker\s+compose\s+(up|down|start|stop|restart|pull|push|build|run|exec)\b",
    r"\bsupabase\s+(login|logout|link|start|stop|db\s+push|migration)\b",
    r"\bvercel\s+(login|logout|whoami|link|env|deploy|build|pull)\b",
    r"\bheroku\s+(login|logout|whoami|auth|plugins:install|plugins:uninstall)\b",
    r"\bnpm\s+(install|update|uninstall)\b",
    r"\bnpx\b",
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
    installed = fixtures["all-installed.json"]
    if installed["status"] != "success":
        fail("all-installed.json must represent successful detection.")

    expected_versions = {
        "git": "2.55.0.windows.1",
        "github-cli": "2.80.0",
        "docker": "28.4.0",
        "docker-compose": "5.0.0",
        "supabase-cli": "2.45.4",
        "vercel-cli": "59.1.4",
        "heroku-cli": "10.13.2",
    }

    for component_id, expected_version in expected_versions.items():
        item = component(installed, component_id)
        if item["state"] != "present":
            fail(f"Installed fixture must keep {component_id} present.")
        if item["activeVersion"]["normalized"] != expected_version:
            fail(
                f"Installed fixture must preserve {component_id} version "
                f"{expected_version}."
            )
        if len(item["commandResolutions"]) < 1:
            fail(
                f"Installed fixture must preserve {component_id} resolution."
            )

    vercel_evidence = evidence(
        installed, "developer.vercel.version"
    )
    if "Update available 60.0.0" not in (vercel_evidence.get("captured") or ""):
        fail(
            "The Vercel fixture must retain an update notice so the "
            "installed-version parser regression remains meaningful."
        )
    if component(
        installed, "vercel-cli"
    )["activeVersion"]["normalized"] != "59.1.4":
        fail(
            "Vercel installed version must not be replaced by an update "
            "notice version."
        )

    boundary = evidence(
        installed, "developer.safety-boundary"
    )["attributes"]
    expected_false = (
        "authenticationStateCollected",
        "accountStateCollected",
        "gitConfigurationCollected",
        "dockerDaemonInspected",
        "dockerContextsCollected",
        "servicesStartedOrStopped",
    )
    for key in expected_false:
        if boundary.get(key) is not False:
            fail(
                "Developer CLI safety boundary must explicitly keep "
                f"{key}=false."
            )

    missing = fixtures["all-missing.json"]
    if missing["status"] != "unavailable":
        fail("all-missing.json must use provider status unavailable.")
    for component_id in SPECIALIZED_COMPONENT_IDS:
        item = component(missing, component_id)
        if item["state"] != "missing" or item["installed"] is not False:
            fail(
                "All-missing fixture must keep every component missing: "
                f"{component_id}"
            )

    collisions = fixtures["command-collisions.json"]
    if collisions["status"] != "partial":
        fail("command-collisions.json must use provider status partial.")
    for component_id in ("git", "github-cli"):
        if len(component(collisions, component_id)["commandResolutions"]) < 2:
            fail(
                "Collision fixture must preserve multiple resolutions for "
                f"{component_id}."
            )
    collision_codes = {item["code"] for item in collisions["warnings"]}
    if "GIT_COMMAND_COLLISION" not in collision_codes:
        fail("Git collision finding is missing.")
    if "GITHUB_CLI_COMMAND_COLLISION" not in collision_codes:
        fail("GitHub CLI collision finding is missing.")

    broken_compose = fixtures["nonfunctional-compose.json"]
    if broken_compose["status"] != "partial":
        fail("nonfunctional-compose.json must use provider status partial.")
    compose = component(broken_compose, "docker-compose")
    if compose["state"] != "partial" or compose["installed"] is not None:
        fail(
            "Non-functional Compose must remain partial with unknown "
            "installed state."
        )
    if not any(
        item["code"] == "DOCKER_COMPOSE_VERSION_INCOMPLETE"
        for item in broken_compose["warnings"]
    ):
        fail("Non-functional Compose warning is missing.")

    legacy = fixtures["legacy-compose-only.json"]
    if legacy["status"] != "warning":
        fail("legacy-compose-only.json must use provider status warning.")
    legacy_compose = component(legacy, "docker-compose")
    if legacy_compose["state"] != "present":
        fail("Legacy-only Compose must remain detectably present.")
    if legacy_compose["activeVersion"]["normalized"] != "1.29.2":
        fail("Legacy-only Compose version must be preserved.")
    if not any(
        item["code"] == "DOCKER_COMPOSE_LEGACY_ONLY"
        for item in legacy["warnings"]
    ):
        fail("Legacy-only Compose informational finding is missing.")

    broken_cli = fixtures["nonfunctional-cli.json"]
    if broken_cli["status"] != "partial":
        fail("nonfunctional-cli.json must use provider status partial.")
    heroku = component(broken_cli, "heroku-cli")
    if heroku["state"] != "partial" or heroku["installed"] is not True:
        fail(
            "A resolvable but failing Heroku CLI must remain partial and "
            "installed."
        )
    if not any(
        item["code"] == "HEROKU_CLI_VERSION_INCOMPLETE"
        for item in broken_cli["warnings"]
    ):
        fail("Non-functional Heroku CLI warning is missing.")


def validate_source_and_policy() -> None:
    provider_source = PROVIDER_PATH.read_text(encoding="utf-8").lower()
    inventory_source = COMMAND_INVENTORY_PATH.read_text(
        encoding="utf-8"
    ).lower()
    javascript_source = JAVASCRIPT_PROVIDER_PATH.read_text(
        encoding="utf-8"
    ).lower()
    policy = load_json(POLICY_PATH)

    if "providerid = 'developer.clis'" not in provider_source:
        fail("DeveloperClis.Provider.ps1 must own developer.clis.")

    specialized_order = re.search(
        r"providerid\s*=\s*['\"]developer\.clis['\"][\s\S]*?"
        r"order\s*=\s*(\d+)",
        provider_source,
    )
    inventory_order = re.search(
        r"providerid\s*=\s*['\"]inventory\.commands['\"][\s\S]*?"
        r"order\s*=\s*(\d+)",
        inventory_source,
    )
    if (
        not specialized_order
        or not inventory_order
        or int(inventory_order.group(1))
        <= int(specialized_order.group(1))
    ):
        fail("Generic inventory must run after developer.clis.")

    if "$toolspecs = @()" not in inventory_source:
        fail(
            "All remaining generic command inventory ownership must be "
            "migrated by issue #33."
        )

    for component_id in SPECIALIZED_COMPONENT_IDS:
        if re.search(
            rf"\bid\s*=\s*['\"]{re.escape(component_id)}['\"]",
            inventory_source,
        ):
            fail(
                "CommandInventory.Provider.ps1 must not duplicate developer "
                f"CLI ownership for '{component_id}'."
            )

    for component_id in CONTINUITY_COMPONENT_IDS:
        if component_id not in javascript_source:
            fail(
                "Existing JavaScript-owned developer CLI coverage must remain "
                f"intact for '{component_id}'."
            )

    for command in (
        "git",
        "gh",
        "docker",
        "supabase",
        "vercel",
        "heroku",
    ):
        if not re.search(
            rf"command\s*=\s*['\"]{re.escape(command)}['\"][\s\S]*?"
            r"arguments\s*=\s*@\(['\"]--version['\"]\)",
            provider_source,
        ):
            fail(
                "Missing required read-only developer CLI version spec for "
                f"{command}."
            )

    for probe in (
        "docker' -arguments @('compose', 'version')",
        "docker-compose' -arguments @('--version')",
    ):
        if probe not in provider_source:
            fail(f"Missing required Compose read-only probe: {probe}")

    required_patterns = (
        "git version",
        "gh version",
        "docker version",
        "vercel cli",
        "heroku/",
        "docker compose version",
        "docker-compose|docker compose",
    )
    for pattern in required_patterns:
        if pattern not in provider_source:
            fail(
                "Developer CLI provider must use explicit installed-version "
                f"pattern: {pattern}"
            )

    if "developer.safety-boundary" not in provider_source:
        fail("Developer CLI provider must emit explicit safety-boundary evidence.")

    for pattern in FORBIDDEN_PROVIDER_PATTERNS:
        if re.search(pattern, provider_source, flags=re.IGNORECASE):
            fail(
                "DeveloperClis.Provider.ps1 contains forbidden state/auth/"
                f"mutation behavior: {pattern}"
            )

    developer_policy = policy.get("developerClis")
    if not isinstance(developer_policy, dict):
        fail("workstation.policy.json must define developerClis policy.")
    if developer_policy.get("defaultTrack") != "latest-stable":
        fail("Developer CLI default track must remain latest-stable.")

    for key in (
        "inspectAuthenticationState",
        "inspectAccountState",
        "inspectGitConfiguration",
        "inspectDockerDaemon",
        "inspectDockerContexts",
    ):
        if developer_policy.get(key) is not False:
            fail(f"Developer CLI policy must keep {key}=false.")


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
            "Developer CLI fixture set mismatch. "
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
            f"Validated developer CLI fixture: "
            f"{path.relative_to(ROOT)}"
        )

    validate_domain_cases(fixtures)
    validate_source_and_policy()

    print("Developer CLI provider validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
