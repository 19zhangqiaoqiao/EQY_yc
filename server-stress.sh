#!/usr/bin/env bash
# Git 仓库入口：实现保留在版本目录中，方便发布包与历史版本并存。
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec "$ROOT/server-stress-3.1.0/server-stress.sh" "$@"
