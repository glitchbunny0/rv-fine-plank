#!/usr/bin/env bash
# Run the off-game test suite. Builds a local Lua 5.4 if none is installed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LUA="$(command -v lua || command -v lua5.4 || true)"
if [[ -z "$LUA" ]]; then
    CACHE="${TMPDIR:-/tmp}/lua-5.4.7"
    if [[ ! -x "$CACHE/src/lua" ]]; then
        echo "no lua found — building 5.4.7 into $CACHE"
        mkdir -p "$(dirname "$CACHE")"
        curl -sL https://www.lua.org/ftp/lua-5.4.7.tar.gz | tar xz -C "$(dirname "$CACHE")"
        make -s -C "$CACHE" linux
    fi
    LUA="$CACHE/src/lua"
fi

echo "lua: $LUA"
"$LUA" -v
exec "$LUA" tests/test_main.lua
