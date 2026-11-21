#!/usr/bin/env bash
# airdcpp-windows smoke test. cvcpkg runs a recipe's test script with bash (Git Bash on
# Windows); the test itself is test.ps1, beside this file.
set -euo pipefail
: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_DEPS_PREFIX:?CVC_DEPS_PREFIX must be set}"
here="$(cd "$(dirname "$0")" && pwd)"
exec pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$here/test.ps1")"
