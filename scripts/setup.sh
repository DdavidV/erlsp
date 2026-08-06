#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Installing client dependencies..."
cd "$ROOT_DIR/client"
npm install

echo "Building server release..."
"$ROOT_DIR/scripts/build-server.sh"

echo "Setup complete."
