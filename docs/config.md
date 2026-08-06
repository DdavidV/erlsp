# erlsp configuration

erlsp reads an optional `erlsp.config` file from the workspace root.
Every key is optional; a missing file, or any key you don't
set, falls back to erlsp's built-in defaults, so `erlsp.config` is only
needed when a project's layout or environment doesn't match those
defaults.

`erlsp.config` is loaded once when the workspace is opened, and is
re-read whenever the workspace is reindexed, so editing it and
reindexing is enough to pick up changes — no need to restart the server.

## Format

`erlsp.config` is a single Erlang term: a proplist, read with `file:consult/1``.
If you're familiar with `rebar.config`, this is the same style:

```erlang
[
  {include_dirs, ["priv/include"]},
  {source_dirs, ["lib"]},
  {otp_apps_exclude, [wx, observer]},
  {rebar_profile, test}
].
```

Erlang terms (not YAML or TOML) were chosen because erlsp is an Erlang
tool for Erlang projects — every erlsp user already reads/writes this
exact syntax in `rebar.config`, so there's no new format to learn and no
new parsing dependency to add.

A file that fails to parse is logged as a warning and treated as if it
were absent — erlsp always starts up with defaults rather than refusing
to index a project over a config typo.

## Keys

### `include_dirs`

- **Type:** list of strings (paths, relative to the workspace root; glob
  wildcards like `"*"` are supported)
- **Default:** `[]`
- **Effect:** appended to erlsp's built-in include-path list (`src`,
  `include`, `test`, `apps`, `apps/*/include`, `apps/*/test`,
  `_build/*/lib/`, `_build/*/lib/*/include`) when resolving
  `-include`/`-include_lib` directives for a project.

Use this when a project keeps headers somewhere those built-in globs
don't reach (e.g. a `priv/include` directory, or a nonstandard vendored
layout).

```erlang
{include_dirs, ["priv/include", "third_party/*/include"]}.
```

### `source_dirs`

- **Type:** list of strings (paths, relative to the workspace root; glob
  wildcards supported)
- **Default:** `[]`
- **Effect:** appended to erlsp's built-in source-directory list (`src`,
  `apps/*/src`, `test`, `apps/*/test`) when discovering which files to
  index and watch for a project.

Use this when a project's own modules live outside the conventional
`src`/`apps/*/src` layout (e.g. a `lib` directory, matching Mix's
convention, or a generated-code directory).

```erlang
{source_dirs, ["lib", "gen"]}.
```

### `otp_path`

- **Type:** string (an absolute filesystem path to an OTP installation
  root — the directory `code:root_dir/0` would return for that
  installation, e.g. `/usr/lib/erlang` or an asdf/kerl install path)
- **Default:** `undefined` — erlsp auto-discovers a working `erl` on the
  host's `PATH` and asks it for its own root
- **Effect:** used as-is as the OTP installation whose `stdlib`/`kernel`/
  etc. source is indexed for go-to-definition into OTP functions/types,
  instead of auto-discovery.

Use this when a host has multiple Erlang installations (e.g. several
versions managed by `asdf` or `kerl`) and auto-discovery would pick the
wrong one, or when the intended installation isn't on `PATH` at all.

```erlang
{otp_path, "/home/user/.asdf/installs/erlang/27.1.2"}.
```

### `otp_apps_exclude`

- **Type:** list of atoms (OTP application names, e.g. `wx`)
- **Default:** `[]`
- **Effect:** these OTP applications' source is skipped entirely when
  indexing the host's OTP installation.

OTP indexing covers on the order of 800 files by default. Excluding
applications a project never calls into (GUI toolkits like `wx`,
diagnostic tools like `observer`, telecom-specific apps like `megaco`)
reduces indexing time without losing go-to-definition for anything the
project actually uses.

```erlang
{otp_apps_exclude, [wx, observer, megaco, debugger, et]}.
```

### `deps_exclude`

- **Type:** list of atoms (dependency application names, as they appear
  under `_build/<profile>/lib/`)
- **Default:** `[]`
- **Effect:** these dependencies' source is skipped entirely when
  indexing a project's fetched dependencies.

Use this for large dependencies a project pulls in but rarely or never
navigates into (e.g. a big generated-client library), to reduce indexing
time.

```erlang
{deps_exclude, [some_large_generated_client]}.
```

### `rebar_profile`

- **Type:** atom
- **Default:** `default` — rebar3's own default profile name
- **Effect:** when the same application has been built under more than
  one rebar3 profile (e.g. both `rebar3 compile` and `rebar3 as test
  compile` have been run, producing both `_build/default/lib/<app>/ebin`
  and `_build/test/lib/<app>/ebin`), erlsp prefers the named profile's
  build output when resolving that application's compiled `.beam` files
  (used to make parse_transforms and `-include_lib` resolution work
  against real build output).

Use this if a project is conventionally built/tested under a non-default
profile and you want erlsp to consistently prefer that profile's output
over `default`'s when both exist.

```erlang
{rebar_profile, test}.
```

## Example: full config file

```erlang
%% erlsp.config
[
  {include_dirs, ["priv/include"]},
  {source_dirs, ["lib"]},
  {otp_path, "/home/user/.asdf/installs/erlang/27.1.2"},
  {otp_apps_exclude, [wx, observer, megaco, debugger, et]},
  {deps_exclude, [some_large_generated_client]},
  {rebar_profile, test}
].
```
