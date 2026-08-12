@{
    # CI gates on Error only; warnings are advisory.
    Severity     = @('Error')

    ExcludeRules = @(
        # Play-Mp3/Play-Wav predate the rule and renaming them buys nothing.
        'PSUseApprovedVerbs'
        # False positive on assignments inside ForEach-Object blocks, which
        # run in the caller's scope (verified; see uninstall.ps1).
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
