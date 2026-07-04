#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

find "$ROOT/out" -type f -perm -111 2>/dev/null | sort
