# elvis diagnostics

erlsp runs [elvis](https://github.com/inaka/elvis_core) (Erlang's
style/convention linter) against a project's own `elvis.config`, if one
exists at the project root.

# Current version
elvis_core 5.0.4

## It's opt-in per project

A project with no `elvis.config` gets no elvis diagnostics at all.

`elvis.config`'s own format is unchanged from what `elvis` itself
expects — erlsp doesn't introduce a second config surface for this. See
[elvis_core's own docs](https://github.com/inaka/elvis_core) for the
full format.

## When diagnostics run

elvis diagnostics run alongside compiler diagnostics, on the same
triggers: opening a file (`textDocument/didOpen`) and saving it
(`textDocument/didSave`). Both sources' diagnostics are shown together.

elvis diagnostics are always reported at
[`DiagnosticSeverity.Warning`](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#diagnostic)
with a `source` naming the specific rule that fired, e.g. `elvis(elvis_style/operator_spaces)`.

## Implementation note: where elvis actually runs

elvis diagnostics run on the HOST's own `erl` (whatever `erl` is on your
`PATH`), not inside erlsp's own bundled runtime.
This is a requirement of how `elvis_core` itself resolves `elvis.config`
(it needs the process's current working directory set to your project root),
not a limitation specific to erlsp — delegating to a disposable host `erl`
subprocess per elvis run keeps erlsp's own long-running server process
unaffected no matter how many projects/files trigger elvis diagnostics
concurrently.

If no working host `erl` can be found, elvis diagnostics are silently
unavailable for that save (logged as a warning server-side) rather than
blocking compiler diagnostics or crashing the session.
