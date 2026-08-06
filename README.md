# erlsp

> **Early-stage project.** erlsp is under active development and not yet feature-complete.
Expect bugs, missing functionality, and breaking changes between commits.
Not currently recommended for production or daily-driver use. Much of erlsp's testing
has been manual, and the codebase is a little messy in places as a result, though an
EUnit suite (`server/test/`) now covers its core logic against real fixture projects
(`test-fixtures/`).

Erlang language server (`server/`, shipped as a self-contained OTP release with bundled ERTS) and its VS Code extension client (`client/`).

Inspired by [`erlang_ls`](https://github.com/erlang-ls/erlang_ls) and [`elp`](https://github.com/WhatsApp/erlang-language-platform) (Erlang Language Platform),
two existing Erlang language servers whose design choices (and tradeoffs) informed several architectural decisions here.

## Requirements

To build erlsp from source:

- Erlang/OTP 28.2
- rebar3 3.27.0
- Node.js 24.18.1

erlsp's own server ships with a bundled ERTS, so a built/packaged extension
has no runtime dependency on the host having Erlang installed. Compiling the
*user's own project* for diagnostics still uses the host's `erl` when
available, falling back to erlsp's bundled runtime otherwise.

## Setup

```sh
./scripts/setup.sh
```

## Run the extension

Open this folder in VS Code and press F5 (`Run Extension`), or:

```sh
cd client && npm run compile
```

## Test the server

```sh
./scripts/test-server.sh
```

## Package the extension

Builds the server release and produces a `.vsix` at `package/erlsp-<version>.vsix`:

```sh
./scripts/package.sh
```

Install it with `code --install-extension package/erlsp-<version>.vsix`.
