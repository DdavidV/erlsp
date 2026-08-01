# erlang.tmLanguage.json

Official docs: [VS Code Syntax Highlight Guide](https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide). This file is a TL;DR of that guide, scoped to what's relevant for this grammar (read the official docs for the full picture).

A TextMate grammar: a JSON file that tells VS Code how to tokenize `.erl`/`.hrl`/`.escript` source
for syntax highlighting.
This is purely client-side and regex-based it does not talk to the `erlsp` language server.

## Top-level structure

- **`scopeName`** (`"source.erlang"`) - this grammar's own identifier.
- **`fileTypes`** - extensions this grammar applies to.
- **`patterns`** - the top-level list of rules, tried in order from the current position in the document.
Each `{ "include": "#name" }` references an entry in `repository`.
- **`repository`** - a dictionary of named, reusable rule definitions.

## How matching works

At each position, the tokenizer walks the active `patterns` list top-to-bottom and applies the **first**
regex that matches. Order in `patterns` (and in a rule's nested `patterns`) is significant.

Example: `remote-call` (matches `module:function(`) is listed *before* `function-call` (matches bare `function(`)
in the top-level `patterns` array.
If the order were reversed, `function-call` would grab just `function` out of `module:function(`,
leaving `module` to fall through to the generic `atoms` rule instead of getting its own distinct scope.

Two shapes of rule:

- **`match`** - a single-line regex. Matches once, moves on.
- **`begin` / `end`** - for constructs that need their own scoped sub-region (can span content with different internal rules).
Between `begin` and `end`, only that rule's own nested `patterns` apply.
- **`captures`** - when a single regex match has multiple parenthesized groups that should each get a
*different* scope, instead of one uniform `name` for the whole match.

## Scope names (the `"name"` values)

VS Code does not validate or enforce these strings, anything is technically accepted.
But there's a long-standing, near-universal convention (originating from TextMate,
followed by every built-in grammar VS Code ships) that themes rely on to decide colors:

```
entity.name.function.preprocessor.erlang
  │     │      │          │          └─ language suffix (by convention)
  │     │      │          └─ extra refinement (optional, as specific as needed)
  │     │      └─ standard second-level category
  └─────┴─ standard top-level category
```

Themes match by **prefix**.
A theme rule targeting `entity.name.function` will still color `entity.name.function.preprocessor.erlang`,
because the standardized part is the leading segments - the trailing `.preprocessor.erlang` just adds specificity without breaking that match.
The final `.erlang` suffix exists so a theme or tool that wants to target *only* this language's version of a scope can do so.

Common standard prefixes to reuse when extending this grammar:

| Prefix                                                                | For                                                 |
| --------------------------------------------------------------------- | --------------------------------------------------- |
| `comment.line` / `comment.block`                                      | comments                                            |
| `constant.numeric` / `constant.character` / `constant.language`       | literals, `true`/`false`/`nil`-style constants      |
| `entity.name.function` / `entity.name.type` / `entity.name.namespace` | definitions/references to functions, types, modules |
| `keyword.control` / `keyword.operator`                                | control-flow keywords, operators                    |
| `storage.type` / `storage.modifier`                                   | type keywords, modifiers                            |
| `string.quoted.double` / `string.quoted.single`                       | strings                                             |
| `variable.other` / `variable.parameter`                               | variables, parameters                               |
| `punctuation.*`                                                       | brackets, separators, delimiters                    |
| `meta.*`                                                              | structural grouping, rarely themed directly         |

## Extending the grammar

1. Add a `repository` entry: a `match` (or `begin`/`end` for multi-line/nested constructs) regex.
2. Give it a `name` (or per-group `captures`) built from a standard prefix plus an `.erlang` suffix.
3. Reference it via `{ "include": "#your-key" }` - at the top level, or nested inside another rule if it should only apply in that specific context. Position relative to other rules matters (first match wins).
4. Verify with `npm run check-grammar` (see below) before trusting it visually in the editor.

## Testing changes

`scripts/check-grammar.js` runs the grammar through the real tokenizer VS Code uses
(`vscode-textmate` + `vscode-oniguruma`), rather than relying on reading the regex by eye.
For every `test-fixtures/<name>.erl`, it writes a `test-fixtures/<name>.erl.tokens` file listing every
token and its full scope chain, line by line.

```sh
npm run check-grammar                            # regenerates the .tokens file for every fixture
node scripts/check-grammar.js path/to/file.erl   # regenerates the .tokens file for a single file
```

**The `.tokens` files are committed and version-tracked, and are autogenerated — do not hand-edit them.**
Each one carries a header saying so. After changing the grammar, run `npm run check-grammar` (it always
overwrites) and review the result with `git diff -- client/test-fixtures/*.tokens`: an unexpected diff on
a fixture you didn't mean to affect is a grammar regression; an expected diff gets committed alongside the
grammar change, so future changes to the same rule show up as a readable diff instead of a silent behavior
change.

`test-fixtures/` holds one `.erl` file per grammar feature, named after the `repository` key it exercises.

**When adding a new grammar feature, add a new fixture file for it** rather than growing an existing one (keep each file scoped to the one feature it's named after, covering the common case plus any known tricky edge cases).
Run `npm run check-grammar` afterward, and review the generated `.tokens` file to confirm the new pattern produces the scope you expect, not just that it didn't crash.
