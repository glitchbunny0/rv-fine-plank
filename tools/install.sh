#!/usr/bin/env bash
# Install RVFinePlank into a RV There Yet? installation (Linux / Proton).
#
#   ./tools/install.sh                       # auto-detect common Steam library paths
#   ./tools/install.sh /path/to/Ride         # explicit game root (the dir containing Ride/)
#
# Copies the mod next to UE4SS. Does not install UE4SS itself.

set -euo pipefail

MOD_NAME="RVFinePlank"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/$MOD_NAME"

[[ -d "$SRC" ]] || { echo "error: $SRC not found"; exit 1; }

candidates=()
if [[ $# -ge 1 ]]; then
    candidates+=("$1")
else
    candidates+=(
        "$HOME/.local/share/Steam/steamapps/common/Ride"
        "$HOME/.steam/steam/steamapps/common/Ride"
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Ride"
        "$HOME/Steam/steamapps/common/Ride"
    )
    # any extra library folders registered with Steam
    for vdf in "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
               "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/libraryfolders.vdf"; do
        [[ -f "$vdf" ]] || continue
        while read -r p; do
            [[ -n "$p" ]] && candidates+=("$p/steamapps/common/Ride")
        done < <(grep -oP '"path"\s*"\K[^"]+' "$vdf" 2>/dev/null || true)
    done
fi

GAME_ROOT=""
for c in "${candidates[@]}"; do
    if [[ -d "$c/Ride/Binaries/Win64" ]]; then GAME_ROOT="$c"; break; fi
done

if [[ -z "$GAME_ROOT" ]]; then
    echo "error: could not find the game. Looked in:"
    printf '  %s\n' "${candidates[@]}"
    echo "Pass the game root explicitly: ./tools/install.sh /path/to/common/Ride"
    exit 1
fi

WIN64="$GAME_ROOT/Ride/Binaries/Win64"
echo "game:  $WIN64"

if [[ ! -f "$WIN64/dwmapi.dll" ]]; then
    cat <<EOF

warning: $WIN64/dwmapi.dll is missing — UE4SS does not look installed.

  Download UE4SS_v3.0.1-<build>.zip (v3.0.1-1181 or newer; that is the first
  build with UE 5.6 support) from:
    https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest
  and unpack it into:
    $WIN64

EOF
fi

DEST="$WIN64/ue4ss/Mods/$MOD_NAME"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -r "$SRC" "$DEST"

echo "installed: $DEST"
find "$DEST" -type f -printf '  %P\n'

cat <<EOF

Proton: set this as the game's Steam launch option so UE4SS's proxy DLL loads —
  WINEDLLOVERRIDES="dwmapi=n,b" %command%

In game: F3 fine mode, F4 probe, numpad to nudge, \`rvfine\` in the console.
Log: $WIN64/ue4ss/UE4SS.log
EOF
