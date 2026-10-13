[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][version]$RequiredVersion,
    [ValidateRange(1, 10)][int]$Attempts = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# CI-only: installs a pinned module on the ephemeral runner. Hosted runners intermittently
# lose the PSGallery registration ("Unable to find repository 'PSGallery'"), so re-register
# it and retry with backoff instead of failing a required check on infrastructure noise.
for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default
        }

        Install-Module -Name $Name -RequiredVersion $RequiredVersion -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -Confirm:$false

        if (-not (Get-Module -ListAvailable -Name $Name | Where-Object Version -eq $RequiredVersion)) {
            throw "$Name $RequiredVersion is not available after installation."
        }

        Write-Host "Installed $Name $RequiredVersion on attempt $attempt."
        return
    }
    catch {
        if ($attempt -eq $Attempts) {
            throw
        }

        Write-Warning "Installing $Name $RequiredVersion failed on attempt $attempt of ${Attempts}: $($_.Exception.Message)"
        Start-Sleep -Seconds (10 * $attempt)
    }
}
