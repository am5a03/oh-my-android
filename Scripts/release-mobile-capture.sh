#!/bin/zsh
set -euo pipefail
exec "${0:A:h}/release.sh" --mobile-capture "$@"
