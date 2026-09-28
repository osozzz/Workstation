# Collection-safe PowerShell idioms

Production scripts run under `Set-StrictMode -Version Latest` on both Windows PowerShell 5.1 (used by `Run-Audit.cmd`) and PowerShell 7. Two common idioms break there on empty or single-item collections, so they are not allowed under `scripts/`.

## Assigning an `if` statement that returns `@(...)`

```powershell
# Unsafe: the if output is unrolled, so $items is $null or a scalar.
$items = if ($condition) { @(Get-Items) } else { @() }
$items.Count   # throws for zero items, and for one item on 5.1

# Safe: the whole statement is collected into an array.
$items = @(
    if ($condition) {
        Get-Items
    }
)
```

`@(if (...) { X })` yields exactly the same array as `@(X)` on both hosts, including when `X` is `$null`.

## Indexing `@(...)`

```powershell
# Unsafe: throws "Index was outside the bounds of the array" when nothing matches.
$first = @($items | Where-Object Name -eq $name)[0]

# Safe: returns $null when nothing matches.
$first = $items | Where-Object Name -eq $name | Select-Object -First 1
```

## Enforcement

`tests/pester/collection-safety/Audit.CollectionSafety.Tests.ps1`:

- parses every script under `scripts/` and rejects both idioms;
- runs the real audit under Windows PowerShell 5.1 and PowerShell 7 with a minimal `PATH` (operating system and PowerShell only) and no local configuration, and requires that no provider fails and no report-level error is raised.

The second check covers the most common real-world case, a workstation that lacks some developer tools. The GitHub runner has most tools installed, so without it that case would never execute in CI.

Mandatory array parameters that may legitimately receive an empty collection must declare `[AllowEmptyCollection()]`.
