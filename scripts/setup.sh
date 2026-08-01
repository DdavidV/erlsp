#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Installing client dependencies..."
cd "$ROOT_DIR/client"
npm install

echo "Building server escript..."
"$ROOT_DIR/scripts/build-server.sh"

echo "Setup complete."
