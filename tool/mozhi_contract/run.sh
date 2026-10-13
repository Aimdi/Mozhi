#!/usr/bin/env bash
# Builds the upstream Mozhi server pinned in server/go.mod and runs the
# contract test against it (the script starts and stops the server).
#
# Usage: tool/mozhi_contract/run.sh [--destructive] [--json <file>]
#
# Environment:
#   MOZHI_CONTRACT_PORT  port to serve on (default 3123)
#   MOZHI_SERVER_BIN     use this prebuilt server binary instead of building
#   GO                   Go toolchain (default: `go` on PATH, else
#                        /usr/local/go/bin/go); needs Go >= 1.25 and
#                        proxy.golang.org (codeberg.org itself is not needed)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
port="${MOZHI_CONTRACT_PORT:-3123}"
bin="${MOZHI_SERVER_BIN:-}"

if [ -z "$bin" ]; then
  go="${GO:-$(command -v go || echo /usr/local/go/bin/go)}"
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
  bin="$out/mozhi-server"
  echo "Building Mozhi server ($(grep -m1 'codeberg.org/aryak/mozhi ' "$here/server/go.mod" | xargs))..."
  (cd "$here/server" && "$go" build -o "$bin" .)
fi

cd "$root"
dart run tool/mozhi_contract/contract_test.dart \
  --server "$bin" --base "http://127.0.0.1:$port" "$@"
