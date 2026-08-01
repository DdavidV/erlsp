#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/package"

"$ROOT_DIR/scripts/build-server.sh"

mkdir -p "$OUT_DIR"

cd "$ROOT_DIR/client"
npx vsce package --out "$OUT_DIR/"

echo "VSIX written to $OUT_DIR"
