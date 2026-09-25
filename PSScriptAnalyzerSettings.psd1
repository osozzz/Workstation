@{
    Severity = @(
        'Error'
        'Warning'
    )

    IncludeRules = @(
        'PSAvoidUsingAllowUnencryptedAuthentication'
        'PSAvoidUsingBrokenHashAlgorithms'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingWMICmdlet'
    )

    # These rules are intentionally not part of the Sprint 7 baseline yet.
    # They are listed here to make the exclusions explicit rather than relying
    # on undocumented analyzer defaults.
    ExcludeRules = @(
        'PSAvoidUsingPositionalParameters'
        'PSAvoidUsingWriteHost'
        'PSReviewUnusedParameter'
        'PSUseApprovedVerbs'
        'PSUseBOMForUnicodeEncodedFile'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
