# Running the audit and evaluating a PC

This runbook takes a maintainer from a fresh clone to an audit of one PC and an evaluation of that audit against the workstation policy. The goal is to find out what on this PC is out of date or outside the standard, so it can be updated. Comparing two PCs is an optional extra, covered at the end.

Everything here is read-only. The audit never installs, upgrades, or reconfigures anything (`docs/policies/audit-safety.md`).

## 1. Prerequisites

- Windows with Windows PowerShell 5.1, which ships with Windows. PowerShell 7 is optional.
- Git, to clone the repository.
- Network access, if you want latest-version information. Without it, those fields are reported as unavailable and the audit still completes.

```powershell
git clone https://github.com/osozzz/Workstation.git
cd Workstation
git checkout v1.1.0
```

## 2. Configure your development roots (optional)

Project discovery and Git health run only under folders you list explicitly. Copy the example and edit it:

```powershell
Copy-Item config\workstation.local.example.json config\workstation.local.json
```

Set `projects.developmentRoots` to the folders that contain your projects (for example `C:\Users\<you>\source`). Whole drives such as `C:\` are rejected. This file is ignored by Git and stays on the machine (`config/README.md`).

Without it, the audit still runs, and the project and Git providers report `not-applicable`.

## 3. Run the audit

Double-click `Run-Audit.cmd`, or run it from a terminal. It uses Windows PowerShell 5.1, queries latest versions online, and includes the full WinGet inventory.

When it finishes it prints the report paths:

- `reports\<COMPUTER>-<timestamp>.json`, the normalized report used for evaluation and comparison;
- `reports\<COMPUTER>-<timestamp>.md`, a human-readable summary.

Both stay local. `reports\` is ignored by Git and must never be committed. They include machine-specific paths and commit IDs, so do not share them publicly.

For a faster run without network access, use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Audit-Workstation.ps1 -OfflineVersionIntelligence
```

## 4. Evaluate the report against the policy

```powershell
.\Run-Evaluate.cmd reports\PC1-<timestamp>.json
```

This compares one report with the declared standard in `config\workstation.policy.json` and writes `reports\evaluation\evaluation.json` and `evaluation.txt`. Each policy setting becomes `compliant`, `deviation`, `unknown` (evidence missing, for example in an offline audit), or `not-evaluable` (the audit never collects evidence for it). Like comparison output, evaluation output is shareable. It does not change the machine; deviations are the input for the update plan that comes next (#159). The rules are described in `../architecture/policy-evaluation-contract.md`.

## 5. Optional: compare with another PC

Run the **same release** on the other PC, then copy its JSON report to this PC over a private channel you control. Comparing the two needs only the JSON reports.

```powershell
.\Run-Compare.cmd reports\PC1-<timestamp>.json path\to\PC2-<timestamp>.json
```

The first report is the **reference**, usually this PC's report; the second is the **target**. You can also drag both files onto `Run-Compare.cmd`, but Explorer does not guarantee their order, so check the `Reference:` and `Target:` lines at the top of the output.

The launcher prints the human-readable comparison and writes:

- `reports\comparison\comparison.json`, structured differences;
- `reports\comparison\comparison.txt`, the same differences as text.

Comparison output is the shareable form. It excludes absolute paths, commit IDs, remote URLs, and secrets (`privacy-testing.md`).

### Reading a comparison

- Every difference has a category (component, version, PATH, environment, application, project, or Git) and a relation such as `different`, `reference-only`, `target-only`, `unavailable`, or `unknown`.
- `unavailable`/`unknown` mean one side could not determine a value. They do not mean the PCs differ.
- The comparison never decides which PC is correct and never suggests changes. Turn the findings you want to act on into issues.

Coverage by category and the known limitations are listed in `../architecture/audit-system-roadmap.md`.
