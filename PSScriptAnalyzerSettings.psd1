@{
    Severity = @(
        'Error'
        'Warning'
    )

    IncludeRules = @(
        'PSAvoidAssignmentToAutomaticVariable'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
    )

    # No repository-wide suppressions. Add an exclusion only when a rule is
    # demonstrably incompatible with the repository contract and document why.
    ExcludeRules = @()
}
