# Contributing

Small project, sharp edges. The constraints below exist because breaking them
produces bugs that look nothing like their cause.

## The three rules

1. **bash 3.2.** macOS ships bash 3.2 (2007) and the hooks run under it. No
   associative arrays, no `$BASHPID`, no `${var,,}`. That is why the installer
   uses the `eval "sel_$k=1"` idiom and why the speak pidfile is written from
   the parent via `$!`. If shellcheck passes but you used a bash 4+ feature,
   it still breaks on a real Mac.

2. **Windows/macOS parity.** The hooks are one Node implementation in `src/`
   with thin platform layers in `src/platform/`; parity there means keeping
   `darwin.mjs` and `win32.mjs` capable of the same operations. The
   installers, the voice picker and the small wrappers are still one file per
   platform: if you change one side, change the other in the same PR, or say
   explicitly in the PR why it does not apply.

3. **Never touch the real `$HOME` in tests.** Every test runs against a
   temporary home directory (see `test/register.test.mjs` for the pattern).
   The suite must pass on a machine where the developer actually uses
   agent-voice, without disturbing their install.

## Running the checks

```
npm test        # node:test suite; spawns the Python tests when Python 3 is present
npm run lint:ps # PowerShell parse gate + PSScriptAnalyzer if installed
npm run lint:sh # shellcheck (see .shellcheckrc for the three justified excludes)
```

CI runs all of these on Ubuntu, macOS and Windows, plus `bash -n`,
`python -m compileall`, and a referenced-path check that fails if any source
file names a repo path that does not exist.

## Adding an agent

Verify the vendor's hook contract against their documentation before writing
code, and cite the source in the PR. The agent entry needs: a config template
in `lib/register.mjs`, a transcript fixture in `test/fixtures/` if it needs
transcript recovery, a `register.mjs` test, and an honest note in the docs
about its degradation mode (see the Kimi note for the tone).

## Style

- `.editorconfig` is authoritative for whitespace.
- PowerShell must pass the parser gate and PSScriptAnalyzer at Error severity
  (`PSScriptAnalyzerSettings.psd1`).
- Comments explain constraints the code cannot show, not what the next line
  does. The long rationale essays live in the docs, not inline.
