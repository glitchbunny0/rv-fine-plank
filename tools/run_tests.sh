#!/usr/bin/env bash
# Run the off-game test suite. Builds a local Lua 5.4 if none is installed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LUA="$(command -v lua || command -v lua5.4 || true)"
LUAC="$(command -v luac || command -v luac5.4 || true)"

if [[ -z "$LUA" ]]; then
    CACHE="${TMPDIR:-/tmp}/lua-5.4.7"
    if [[ ! -x "$CACHE/src/lua" ]]; then
        echo "no lua found — building 5.4.7 into $CACHE"
        mkdir -p "$(dirname "$CACHE")"
        curl -sL https://www.lua.org/ftp/lua-5.4.7.tar.gz | tar xz -C "$(dirname "$CACHE")"
        make -s -C "$CACHE" linux
    fi
    LUA="$CACHE/src/lua"
    LUAC="$CACHE/src/luac"
fi

echo "lua: $LUA"
"$LUA" -v

echo
echo "--- syntax ---"
"$LUAC" -p RVFinePlank/Scripts/*.lua tests/*.lua
echo "ok"

echo
echo "--- maths ---"
"$LUA" tests/test_math.lua

echo
echo "--- integration ---"
exec "$LUA" tests/test_main.lua
