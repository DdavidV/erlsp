#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/server"
rebar3 escriptize

mkdir -p "$ROOT_DIR/client/server"
cp "$ROOT_DIR/server/_build/default/bin/erlsp" "$ROOT_DIR/client/server/erlsp"

echo "Built escript copied to client/server/erlsp"
