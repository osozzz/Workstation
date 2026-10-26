BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $providerPath = Join-Path $repositoryRoot 'scripts\Providers\EditorExtensions.Provider.ps1'
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1') -Force

    # Only a fake VS Code CLI is resolvable, so the real editors on the machine are never queried.
    $fakeBin = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeBin 'code.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'if "%1"=="--version" echo 1.143.1& echo 0123abcd& echo x64& exit /b 0'
        'if "%1"=="--list-extensions" echo ms-python.python@2026.10.0& echo esbenp.prettier-vscode@11.0.0& echo Warning: not an extension line& exit /b 0'
        'exit /b 1'
    )
    $originalPath = $env:PATH
    $env:PATH = @($fakeBin, "$env:SystemRoot\System32\WindowsPowerShell\v1.0") -join ';'
    try {
        $script:result = & $providerPath -Context ([pscustomobject]@{ ObservedAt = '2026-10-26T12:00:00+00:00' })
    }
    finally {
        $env:PATH = $originalPath
    }
}

Describe 'Editor extensions provider' {
    It 'returns a valid provider result' {
        { Assert-AuditProviderResult -Result $script:result -ProviderId 'editors.extensions' -Category 'editor' } | Should -Not -Throw
        $script:result.status | Should -Be 'success'
    }

    It 'reads the editor version and its extensions' {
        $vscode = $script:result.components | Where-Object componentId -eq 'vscode'
        $vscode.state | Should -Be 'present'
        $vscode.activeVersion.normalized | Should -Be '1.143.1'
        $list = ($script:result.evidence | Where-Object evidenceId -eq 'editors.vscode.extensions.normalized').attributes
        $list.extensionCount | Should -Be 2
        ($list.extensions | Where-Object id -eq 'ms-python.python').version | Should -Be '2026.10.0'
    }

    It 'reports editors without a CLI as missing' {
        @($script:result.components | Where-Object { $_.componentId -ne 'vscode' } | ForEach-Object state) | Should -Be @('missing', 'missing', 'missing')
    }

    It 'only lists extensions; it never installs or updates them' {
        @($script:result.evidence | Where-Object type -eq 'command' | ForEach-Object source) | Should -Be @('code --version', 'code --list-extensions --show-versions')
    }
}
