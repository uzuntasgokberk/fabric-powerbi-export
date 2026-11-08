@{
    # Rules that are excluded on purpose:
    ExcludeRules = @(
        # Colored console output is intended; every line is also written to the log file.
        'PSAvoidUsingWriteHost',

        # Applies to public cmdlets; these are small internal helpers of a single script.
        'PSUseShouldProcessForStateChangingFunctions',

        # Informational only; short internal helper calls stay readable without parameter names.
        'PSAvoidUsingPositionalParameters'
    )
}
