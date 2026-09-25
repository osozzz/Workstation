@{
    Run = @{
        Path     = @('tests/pester')
        Exit     = $false
        PassThru = $true
    }

    Output = @{
        Verbosity = 'Detailed'
    }

    Should = @{
        ErrorAction = 'Continue'
    }
}
