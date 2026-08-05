#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/server"
rebar3 release

rm -rf "$ROOT_DIR/client/server"
mkdir -p "$ROOT_DIR/client/server"
cp -R "$ROOT_DIR/server/_build/default/rel/erlsp" "$ROOT_DIR/client/server/erlsp"

echo "Built release copied to client/server/erlsp"
