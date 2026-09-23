from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MATRIX_PATH = ROOT / "tests" / "sprint4-integration" / "coverage-matrix.json"
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "validate.yml"
GITIGNORE_PATH = ROOT / ".gitignore"
LOCAL_CONFIG_EXAMPLE = ROOT / "config" / "workstation.local.example.json"
AUDIT_PATH = ROOT / "scripts" / "Audit-Workstation.ps1"

PROJECT_LOCAL_TEST = ROOT / "tests" / "projects-local" / "validate_projects_local.ps1"
PROJECT_LOCAL_CASES = ROOT / "tests" / "projects-local" / "project-discovery-cases.json"
JS_TEST = ROOT / "tests" / "projects-javascript" / "validate_javascript_projects.ps1"
NON_JS_TEST = (
    ROOT / "tests" / "projects-non-javascript" / "validate_non_javascript_projects.ps1"
)
GIT_HEALTH_TEST = (
    ROOT / "tests" / "git-repository-health" / "validate_git_repository_health.ps1"
)
GIT_HYGIENE_TEST = (
    ROOT
    / "tests"
    / "git-branch-worktree-hygiene"
    / "validate_git_branch_worktree_hygiene.ps1"
)

PROJECT_LOCAL_PROVIDER = ROOT / "scripts" / "Providers" / "ProjectsLocal.Provider.ps1"
JS_PROVIDER = ROOT / "scripts" / "Providers" / "JavaScriptWebProjects.Provider.ps1"
NON_JS_PROVIDER = ROOT / "scripts" / "Providers" / "NonJavaScriptProjects.Provider.ps1"
GIT_HEALTH_PROVIDER = (
    ROOT / "scripts" / "Providers" / "GitRepositoryHealth.Provider.ps1"
)
GIT_HYGIENE_PROVIDER = (
    ROOT / "scripts" / "Providers" / "GitBranchWorktreeHygiene.Provider.ps1"
)

SPRINT4_PROVIDER_IDS = {
    "projects.local",
    "projects.javascript-web",
    "projects.non-javascript",
    "git.repository-health",
    "git.branch-worktree-hygiene",
}

EXPECTED_CRITERIA = {
    "development-roots-configurable",
    "bounded-git-repository-discovery",
    "javascript-web-project-detection",
    "non-javascript-project-detection",
    "runtime-package-manager-pins",
    "git-repository-health",
    "branch-worktree-hygiene",
    "branch-naming-deviations",
    "cleanup-advisory-only",
}

FORBIDDEN_COMMITTED_MARKERS = (
    "c:\\users\\",
    "/home/",
    "bearer ",
    "ghp_",
    "github_pat_",
    "password=",
    "token=",
)

SPRINT4_ASSET_PATHS = (
    ROOT / "tests" / "projects-local",
    ROOT / "tests" / "projects-javascript",
    ROOT / "tests" / "projects-non-javascript",
    ROOT / "tests" / "git-repository-health",
    ROOT / "tests" / "git-branch-worktree-hygiene",
    ROOT / "tests" / "sprint4-integration",
)

TEXT_SUFFIXES = {
    ".json",
    ".md",
    ".ps1",
    ".py",
    ".yaml",
    ".yml",
    ".txt",
}


def fail(message: str) -> None:
    raise AssertionError(message)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def get_provider(report: dict[str, Any], provider_id: str) -> dict[str, Any]:
    matches = [
        provider
        for provider in report["providers"]
        if provider["providerId"] == provider_id
    ]
    if len(matches) != 1:
        fail(
            f"Expected exactly one provider '{provider_id}' in controlled report, "
            f"found {len(matches)}."
        )
    return matches[0]


def get_evidence(
    provider: dict[str, Any],
    evidence_id: str,
) -> dict[str, Any]:
    matches = [
        item
        for item in provider["evidence"]
        if item["evidenceId"] == evidence_id
    ]
    if len(matches) != 1:
        fail(
            f"Expected exactly one evidence record '{evidence_id}' in "
            f"{provider['providerId']}, found {len(matches)}."
        )
    return matches[0]


def validate_coverage_matrix() -> None:
    matrix = load_json(MATRIX_PATH)

    if matrix.get("issue") != 8:
        fail("Sprint 4 coverage matrix must target parent issue #8.")

    criteria = matrix.get("criteria", [])
    ids = {item.get("id") for item in criteria}

    if ids != EXPECTED_CRITERIA:
        fail(
            "Sprint 4 parent acceptance coverage drift. "
            f"Expected {sorted(EXPECTED_CRITERIA)}, found {sorted(ids)}."
        )

    if len(criteria) != len(EXPECTED_CRITERIA):
        fail("Sprint 4 coverage matrix must contain exactly nine criteria.")

    for item in criteria:
        evidence = item.get("evidence", [])
        if not evidence:
            fail(
                f"Coverage criterion '{item.get('id')}' has no evidence paths."
            )

        for relative_path in evidence:
            path = ROOT / relative_path
            if not path.exists():
                fail(
                    f"Coverage criterion '{item.get('id')}' references missing "
                    f"evidence: {relative_path}"
                )

    print(
        "Validated Sprint 4 parent acceptance coverage matrix: "
        f"{len(criteria)} criteria."
    )


def validate_committed_asset_privacy() -> None:
    checked_files = 0

    for root_path in SPRINT4_ASSET_PATHS:
        if not root_path.exists():
            fail(f"Missing Sprint 4 validation asset directory: {root_path}")

        for path in root_path.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
                continue

            checked_files += 1
            raw = read_text(path).lower()

            for marker in FORBIDDEN_COMMITTED_MARKERS:
                if marker in raw:
                    fail(
                        f"{path.relative_to(ROOT)} contains forbidden "
                        f"machine/secret marker: {marker}"
                    )

    example_raw = read_text(LOCAL_CONFIG_EXAMPLE).lower()
    for marker in FORBIDDEN_COMMITTED_MARKERS:
        if marker in example_raw:
            fail(
                "Committed local configuration example contains forbidden "
                f"machine/secret marker: {marker}"
            )

    reports_dir = ROOT / "reports"
    if reports_dir.exists():
        generated = [
            path
            for path in reports_dir.rglob("*")
            if path.is_file()
            and path.name.lower() not in {"readme.md", ".gitkeep"}
            and path.suffix.lower() in {".json", ".md", ".html"}
        ]
        if generated:
            fail(
                "Generated machine-specific reports must not be committed: "
                f"{[str(path.relative_to(ROOT)) for path in generated]}"
            )

    gitignore = read_text(GITIGNORE_PATH).lower()
    for required in ("reports/", "config/workstation.local.json"):
        if not re.search(
            rf"(?m)^{re.escape(required)}\s*$",
            gitignore,
        ):
            fail(f".gitignore must preserve '{required}'.")

    print(
        "Validated Sprint 4 committed fixture/config privacy boundary: "
        f"{checked_files} text assets."
    )


def validate_local_configuration_contract() -> None:
    config = load_json(LOCAL_CONFIG_EXAMPLE)

    projects = config.get("projects", {})
    if projects.get("developmentRoots") != []:
        fail(
            "Committed local config example must keep developmentRoots empty."
        )

    if projects.get("maxDiscoveryDepth") != 6:
        fail(
            "Committed local config example must preserve maxDiscoveryDepth=6."
        )

    git = config.get("git", {})
    if git.get("branchStaleDays") != 90:
        fail(
            "Committed local config example must preserve branchStaleDays=90."
        )

    audit_source = read_text(AUDIT_PATH)
    for marker in (
        "LocalConfigurationPath",
        "DevelopmentRoots",
        "ProjectDiscoveryMaxDepth",
        "GitBranchStaleDays",
        "git.branchStaleDays must be an integer from 1 through 3650.",
    ):
        if marker not in audit_source:
            fail(
                "Aggregate audit local configuration integration is missing "
                f"marker: {marker}"
            )

    print(
        "Validated local-only Sprint 4 configuration contract and safe defaults."
    )


def validate_discovery_fixture_coverage() -> None:
    fixture = load_json(PROJECT_LOCAL_CASES)
    expected = fixture["expected"]

    if expected.get("configuredRootCount", 0) < 2:
        fail("Project discovery fixture must cover multiple configured roots.")

    if expected.get("duplicateRootCount", 0) < 1:
        fail("Project discovery fixture must cover duplicate roots.")

    if expected.get("missingRootCount", 0) < 1:
        fail("Project discovery fixture must cover missing roots.")

    labels = set(expected.get("expectedCandidateLabels", []))
    if not {"nestedRepo", "pythonPackage"}.issubset(labels):
        fail(
            "Project discovery fixture must cover nested repository/project "
            "candidates."
        )

    forbidden = set(expected.get("forbiddenCandidateLabels", []))
    if not {"tooDeep", "outside"}.issubset(forbidden):
        fail(
            "Project discovery fixture must prove depth and configured-root "
            "boundaries."
        )

    source = read_text(PROJECT_LOCAL_TEST)
    for marker in (
        "boundedToConfiguredRoots",
        "wholeDiskTraversal",
        "implicitHomeTraversal",
        "followsReparsePoints",
        "outside configured development roots",
    ):
        if marker not in source:
            fail(
                "Project discovery validator is missing safety/boundary marker: "
                f"{marker}"
            )

    provider = read_text(PROJECT_LOCAL_PROVIDER)
    if "projectClassificationOwned = $false" not in provider:
        fail(
            "projects.local must explicitly avoid owning project classification."
        )
    if "gitHealthOwned = $false" not in provider:
        fail("projects.local must explicitly avoid owning Git-health analysis.")

    print(
        "Validated bounded project discovery fixture coverage and ownership."
    )


def validate_project_classifier_fixture_coverage() -> None:
    js_test = read_text(JS_TEST)
    js_provider = read_text(JS_PROVIDER)

    for marker in (
        "PlainNode",
        "AngularApp",
        "NextApp",
        "PrismaApp",
        "Conflict",
        ".nvmrc",
        ".node-version",
        "engines",
        "packageManager",
        "pnpm-lock.yaml",
        "package-lock.json",
        "nodePinConflictCount",
        "packageManagerConflictCount",
    ):
        if marker not in js_test:
            fail(
                "JavaScript/web fixture suite is missing required coverage "
                f"marker: {marker}"
            )

    for marker in (
        "canonicalFilesOnly = $true",
        "independentFilesystemTraversal = $false",
        "nodeModulesInspected = $false",
        "executesProjectCode = $false",
        "packageManagersInvoked = $false",
        "globalRuntimeEvidenceModified = $false",
    ):
        if marker not in js_provider:
            fail(
                "JavaScript/web provider is missing safety/ownership marker: "
                f"{marker}"
            )

    non_js_test = read_text(NON_JS_TEST)
    non_js_provider = read_text(NON_JS_PROVIDER)

    for marker in (
        "pubspec.yaml",
        "pyproject.toml",
        "Cargo.toml",
        "go.mod",
        "global.json",
        "pom.xml",
        "build.gradle",
    ):
        if marker not in non_js_test and marker not in non_js_provider:
            fail(
                "Non-JavaScript fixture/provider coverage is missing canonical "
                f"marker: {marker}"
            )

    for ecosystem in (
        "flutter",
        "dart",
        "python",
        "rust",
        "go",
        "dotnet",
        "maven",
        "gradle",
    ):
        if ecosystem not in non_js_test.lower():
            fail(
                "Non-JavaScript fixture suite is missing ecosystem coverage: "
                f"{ecosystem}"
            )

    for marker in (
        "canonicalFilesOnly = $true",
        "independentFilesystemTraversal = $false",
        "executesProjectCode = $false",
        "buildOrRestoreInvoked = $false",
        "dependencyResolutionInvoked = $false",
        "environmentCreated = $false",
        "packageInstallationInvoked = $false",
        "globalRuntimeEvidenceModified = $false",
    ):
        if marker not in non_js_provider:
            fail(
                "Non-JavaScript provider is missing safety/ownership marker: "
                f"{marker}"
            )

    print(
        "Validated JavaScript/web and non-JavaScript classification/pin coverage."
    )


def validate_git_fixture_coverage() -> None:
    health_test = read_text(GIT_HEALTH_TEST)
    health_provider = read_text(GIT_HEALTH_PROVIDER)

    for marker in (
        "clean-no-upstream",
        "dirty",
        "detached",
        "ahead",
        "behind",
        "diverged",
        "stagedCount",
        "unstagedCount",
        "untrackedCount",
        "GIT_UNPUSHED_COMMITS",
    ):
        if marker not in health_test:
            fail(
                "Git repository health fixture suite is missing coverage marker: "
                f"{marker}"
            )

    for marker in (
        "readOnly = $true",
        "usesOnlyDiscoveredRepositories = $true",
        "performsFilesystemTraversal = $false",
        "networkAccessRequired = $false",
        "fetchPerformed = $false",
        "pullPerformed = $false",
        "pushPerformed = $false",
        "checkoutPerformed = $false",
        "resetPerformed = $false",
        "cleanPerformed = $false",
        "stashPerformed = $false",
        "commitPerformed = $false",
        "remoteUrlsCollected = $false",
        "credentialHelpersCollected = $false",
        "optionalLocksDisabled = $true",
    ):
        if marker not in health_provider:
            fail(
                "Git repository health provider is missing safety marker: "
                f"{marker}"
            )

    hygiene_test = read_text(GIT_HYGIENE_TEST)
    hygiene_provider = read_text(GIT_HYGIENE_PROVIDER)

    for marker in (
        "feat/merged",
        "feat/unmerged",
        "feat/stale",
        "feat/gone",
        "scratch-bad-name",
        "feat/worktree",
        "feat/prunable",
        "GIT_BRANCH_NAMING_DEVIATION",
        "GIT_WORKTREE_PRUNABLE",
        "GIT_LINKED_WORKTREE_DIRTY",
    ):
        if marker not in hygiene_test:
            fail(
                "Git branch/worktree fixture suite is missing coverage marker: "
                f"{marker}"
            )

    for marker in (
        "readOnly = $true",
        "reusesRepositoryHealth = $true",
        "independentRepositoryDiscovery = $false",
        "branchDeletionPerformed = $false",
        "worktreePrunePerformed = $false",
        "worktreeRemovePerformed = $false",
        "checkoutPerformed = $false",
        "resetPerformed = $false",
        "historyRewritePerformed = $false",
        "gitConfigurationModified = $false",
        "advisoryOnly = $true",
    ):
        if marker not in hygiene_provider:
            fail(
                "Git branch/worktree hygiene provider is missing safety marker: "
                f"{marker}"
            )

    print(
        "Validated Git repository, branch, naming, and worktree fixture coverage."
    )


def validate_workflow_gate() -> None:
    workflow = read_text(WORKFLOW_PATH)

    for marker in (
        "Validate bounded local project discovery",
        "Validate JavaScript and web project detection",
        "Validate non-JavaScript project detection",
        "Validate Git repository state and upstream health",
        "Validate Git branch and worktree hygiene",
        "Validate Sprint 4 Project and Git Discovery integration gate",
        "validate_sprint4_suite.py",
        "Expected twenty built-in providers plus the synthetic failure provider.",
        "providerCount -ne 21",
        "Expected all 20 built-in providers to continue after an additional provider path failure.",
        "providerCount -ne 20",
        "RUNNER_TEMP",
        "LocalConfigurationPath",
        "branchStaleDays = 90",
    ):
        if marker not in workflow:
            fail(f"Workflow is missing Sprint 4 release-gate marker: {marker}")

    if "actions/upload-artifact" in workflow:
        fail(
            "Sprint 4 controlled machine reports must not be uploaded as CI artifacts."
        )

    for cleanup_marker in (
        "Remove-Item -LiteralPath $path -Recurse -Force",
        "Controlled integration temporary state must be deleted after validation",
    ):
        if cleanup_marker not in workflow:
            fail(
                "Workflow is missing controlled Sprint 4 cleanup marker: "
                f"{cleanup_marker}"
            )

    print(
        "Validated Sprint 4 CI gate, provider failure isolation, and report cleanup."
    )


def validate_report(report_path: Path) -> None:
    report = load_json(report_path)

    providers = {
        provider["providerId"]: provider
        for provider in report.get("providers", [])
    }

    missing = SPRINT4_PROVIDER_IDS - set(providers)
    if missing:
        fail(
            "Controlled report is missing Sprint 4 providers: "
            f"{sorted(missing)}"
        )

    for provider_id in SPRINT4_PROVIDER_IDS:
        provider = providers[provider_id]
        if provider["status"] == "failed":
            fail(
                f"Sprint 4 provider failed in controlled audit: {provider_id}"
            )
        if provider["components"]:
            fail(
                f"Sprint 4 provider must remain evidence-only with zero "
                f"components: {provider_id}"
            )

    local = get_provider(report, "projects.local")
    local_summary = get_evidence(local, "projects.local.summary")["attributes"]
    discovery = get_evidence(local, "projects.local.discovery")["attributes"]

    for key in ("readOnly", "boundedToConfiguredRoots"):
        if local_summary.get(key) is not True:
            fail(f"projects.local must preserve {key}=true.")

    for key in (
        "wholeDiskTraversal",
        "implicitHomeTraversal",
        "followsReparsePoints",
        "filesystemMutation",
        "projectClassificationOwned",
        "gitHealthOwned",
    ):
        if local_summary.get(key) is not False:
            fail(f"projects.local must preserve {key}=false.")

    if local_summary.get("configurationState") != "loaded":
        fail("Controlled Sprint 4 audit must load local project configuration.")

    if local_summary.get("candidateCount", 0) < 1:
        fail("Controlled Sprint 4 audit must discover project candidates.")

    if local_summary.get("repositoryCount", 0) < 1:
        fail("Controlled Sprint 4 audit must discover Git repositories.")

    candidate_paths = [
        item.get("path")
        for item in discovery.get("candidates", [])
        if item.get("path")
    ]
    if len(candidate_paths) != len(set(path.lower() for path in candidate_paths)):
        fail("projects.local discovery contains duplicate candidate paths.")

    js = get_provider(report, "projects.javascript-web")
    js_summary = get_evidence(
        js,
        "projects.javascript-web.summary",
    )["attributes"]

    for key in (
        "readOnly",
        "reusedProjectsLocalDiscovery",
        "canonicalFilesOnly",
    ):
        if js_summary.get(key) is not True:
            fail(f"projects.javascript-web must preserve {key}=true.")

    for key in (
        "independentFilesystemTraversal",
        "nodeModulesInspected",
        "executesProjectCode",
        "installsDependencies",
        "packageManagersInvoked",
        "globalRuntimeEvidenceModified",
    ):
        if js_summary.get(key) is not False:
            fail(f"projects.javascript-web must preserve {key}=false.")

    if js_summary.get("projectCount", 0) < 1:
        fail(
            "Controlled Sprint 4 audit must classify at least one JavaScript "
            "project."
        )

    js_projects = js_summary.get("projects", [])
    js_paths = [item.get("path") for item in js_projects if item.get("path")]
    if len(js_paths) != len(set(path.lower() for path in js_paths)):
        fail("JavaScript/web classification contains duplicate project paths.")

    if not set(path.lower() for path in js_paths).issubset(
        set(path.lower() for path in candidate_paths)
    ):
        fail(
            "JavaScript/web classifier emitted a project outside projects.local "
            "discovery ownership."
        )

    has_js_pin = any(
        bool(project.get("nodePins"))
        or bool(project.get("packageManager"))
        for project in js_projects
    )
    if not has_js_pin:
        fail(
            "Controlled Sprint 4 audit must preserve at least one JavaScript "
            "runtime/package-manager pin."
        )

    non_js = get_provider(report, "projects.non-javascript")
    non_js_summary = get_evidence(
        non_js,
        "projects.non-javascript.summary",
    )["attributes"]

    for key in (
        "readOnly",
        "reusedProjectsLocalDiscovery",
        "canonicalFilesOnly",
    ):
        if non_js_summary.get(key) is not True:
            fail(f"projects.non-javascript must preserve {key}=true.")

    for key in (
        "independentFilesystemTraversal",
        "executesProjectCode",
        "buildOrRestoreInvoked",
        "dependencyResolutionInvoked",
        "environmentCreated",
        "packageInstallationInvoked",
        "globalRuntimeEvidenceModified",
    ):
        if non_js_summary.get(key) is not False:
            fail(f"projects.non-javascript must preserve {key}=false.")

    if non_js_summary.get("projectCount", 0) < 1:
        fail(
            "Controlled Sprint 4 audit must classify at least one non-JavaScript "
            "project."
        )

    non_js_projects = non_js_summary.get("projects", [])
    non_js_paths = [
        item.get("path")
        for item in non_js_projects
        if item.get("path")
    ]
    if len(non_js_paths) != len(set(path.lower() for path in non_js_paths)):
        fail("Non-JavaScript classification contains duplicate project paths.")

    if not set(path.lower() for path in non_js_paths).issubset(
        set(path.lower() for path in candidate_paths)
    ):
        fail(
            "Non-JavaScript classifier emitted a project outside projects.local "
            "discovery ownership."
        )

    if not any(project.get("constraints") for project in non_js_projects):
        fail(
            "Controlled Sprint 4 audit must preserve at least one non-JavaScript "
            "runtime/toolchain constraint."
        )

    health = get_provider(report, "git.repository-health")
    health_summary = get_evidence(
        health,
        "git.repository-health.summary",
    )["attributes"]

    for key in (
        "readOnly",
        "usesOnlyDiscoveredRepositories",
        "optionalLocksDisabled",
    ):
        if health_summary.get(key) is not True:
            fail(f"git.repository-health must preserve {key}=true.")

    for key in (
        "performsFilesystemTraversal",
        "networkAccessRequired",
        "fetchPerformed",
        "pullPerformed",
        "pushPerformed",
        "checkoutPerformed",
        "resetPerformed",
        "cleanPerformed",
        "stashPerformed",
        "commitPerformed",
        "gitConfigurationCollected",
        "remoteUrlsCollected",
        "credentialHelpersCollected",
    ):
        if health_summary.get(key) is not False:
            fail(f"git.repository-health must preserve {key}=false.")

    if health_summary.get("inspectedRepositoryCount", 0) < 1:
        fail("Controlled Sprint 4 audit must inspect at least one Git repository.")

    hygiene = get_provider(report, "git.branch-worktree-hygiene")
    hygiene_summary = get_evidence(
        hygiene,
        "git.branch-worktree-hygiene.summary",
    )["attributes"]

    for key in (
        "readOnly",
        "reusesRepositoryHealth",
        "defaultBranchDetectionUsesLocalRefsOnly",
        "optionalLocksDisabled",
        "advisoryOnly",
    ):
        if hygiene_summary.get(key) is not True:
            fail(f"git.branch-worktree-hygiene must preserve {key}=true.")

    for key in (
        "independentRepositoryDiscovery",
        "networkAccessRequired",
        "branchDeletionPerformed",
        "worktreePrunePerformed",
        "worktreeRemovePerformed",
        "checkoutPerformed",
        "resetPerformed",
        "historyRewritePerformed",
        "gitConfigurationModified",
        "remoteUrlsCollected",
        "credentialHelpersCollected",
    ):
        if hygiene_summary.get(key) is not False:
            fail(f"git.branch-worktree-hygiene must preserve {key}=false.")

    if hygiene_summary.get("repositoryCount", 0) < 1:
        fail(
            "Controlled Sprint 4 audit must pass repository evidence into "
            "Git hygiene."
        )

    if hygiene_summary.get("branchCount", 0) < 1:
        fail("Controlled Sprint 4 audit must enumerate local branches.")

    if hygiene_summary.get("worktreeCount", 0) < 1:
        fail("Controlled Sprint 4 audit must enumerate the main worktree.")

    if hygiene_summary.get("staleThresholdDays") != 90:
        fail(
            "Controlled Sprint 4 audit must preserve branchStaleDays=90."
        )

    print(
        "Validated controlled Sprint 4 report: bounded discovery, both project "
        "classifiers, local pin evidence, Git health, and advisory hygiene."
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        type=Path,
        help="Optional controlled aggregate audit JSON report.",
    )
    args = parser.parse_args()

    validate_coverage_matrix()
    validate_committed_asset_privacy()
    validate_local_configuration_contract()
    validate_discovery_fixture_coverage()
    validate_project_classifier_fixture_coverage()
    validate_git_fixture_coverage()
    validate_workflow_gate()

    if args.report is not None:
        if not args.report.exists():
            fail(f"Controlled audit report does not exist: {args.report}")
        validate_report(args.report)

    print("Sprint 4 Project & Git Discovery integration validation passed.")


if __name__ == "__main__":
    main()
