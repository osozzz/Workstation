BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1') -Force
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\VersionIntelligence.Core.psm1') -Force
}

Describe 'Runtime latest-version readers' {
    It 'takes the newest supported, non-preview .NET SDK' {
        $data = '{ "releases-index": [
            { "channel-version": "11.0", "latest-sdk": "11.0.100-rc.3.26522.148", "support-phase": "go-live" },
            { "channel-version": "10.0", "latest-sdk": "10.0.204", "support-phase": "active" },
            { "channel-version": "9.0", "latest-sdk": "9.0.311", "support-phase": "maintenance" },
            { "channel-version": "8.0", "latest-sdk": "8.0.420", "support-phase": "eol" } ] }' | ConvertFrom-Json
        Get-LatestDotNetSdkVersion -Data $data | Should -Be '10.0.204'
    }

    It 'takes the first stable Go release' {
        $data = '[ { "version": "go1.28rc1", "stable": false }, { "version": "go1.27.3", "stable": true }, { "version": "go1.26.9", "stable": true } ]' | ConvertFrom-Json
        Get-LatestGoVersion -Data $data | Should -Be '1.27.3'
    }

    It 'takes the latest patch of the newest released Python cycle' {
        $data = '[ { "cycle": "3.16", "releaseDate": "2027-10-01", "latest": "3.16.0" },
                   { "cycle": "3.15", "releaseDate": "2026-10-09", "latest": "3.15.1" },
                   { "cycle": "3.14", "releaseDate": "2025-10-07", "latest": "3.14.9" } ]' | ConvertFrom-Json
        Get-LatestPythonVersion -Data $data -Today '2026-10-26' | Should -Be '3.15.1'
    }

    It 'sets version intelligence only for an installed component' {
        $components = New-Object System.Collections.Generic.List[object]
        $evidence = New-Object System.Collections.Generic.List[object]
        $components.Add([pscustomobject]@{ componentId = 'go'; state = 'present'; versionIntelligence = $null })
        $components.Add([pscustomobject]@{ componentId = 'rustc'; state = 'missing'; versionIntelligence = $null })
        $context = [pscustomobject]@{
            ObservedAt                   = '2026-10-26T12:00:00+00:00'
            VersionIntelligenceTransport = { param($Request) [pscustomobject]@{ statusCode = 200; contentType = 'application/json'; body = '[ { "version": "go1.27.3", "stable": true } ]' } }
        }
        foreach ($id in 'go', 'rustc') {
            Set-AuditComponentLatestVersion -Context $context -Components $components -Evidence $evidence -ComponentId $id -Source "test:$id" `
                -Uri 'https://example.invalid/latest' -EvidenceId "test.$id-source" -Message 'm' -Read { param($Data) Get-LatestGoVersion -Data $Data }
        }
        $components[0].versionIntelligence.latestStable.normalized | Should -Be '1.27.3'
        $components[1].versionIntelligence | Should -BeNullOrEmpty
        $evidence.Count | Should -Be 1
    }
}
