#!/usr/bin/env bash
#
# install.sh — link keybound-whisper into place.
#
#   ./install.sh                 install the CLI into ~/.local/bin
#   ./install.sh --hammerspoon   also link the Hammerspoon module
#   ./install.sh --prefix DIR    install the CLI into DIR/bin instead
#
# Symlinks rather than copies, so `git pull` updates the installed tool.
# Nothing is overwritten without telling you, and your Hammerspoon init.lua is
# never edited — the snippet to add is printed for you to paste.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="$HOME/.local"
DO_HS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --hammerspoon) DO_HS=1 ;;
        --prefix) shift; PREFIX="${1:-}" ;;
        -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

link() { # link <source> <destination>
    src="$1"; dst="$2"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        printf '  already linked  %s\n' "$dst"; return 0
    fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        backup="$dst.backup-$(date +%Y%m%d-%H%M%S)"
        mv "$dst" "$backup"
        printf '  existing file moved to %s\n' "$backup"
    fi
    ln -s "$src" "$dst"
    printf '  linked          %s\n' "$dst"
}

printf '\nInstalling keybound-whisper\n\n'

mkdir -p "$PREFIX/bin"
link "$ROOT/bin/keybound-whisper" "$PREFIX/bin/keybound-whisper"

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) printf '\n  note: %s/bin is not on your PATH. Add it:\n' "$PREFIX"
       printf '        echo '"'"'export PATH="%s/bin:$PATH"'"'"' >> ~/.zshrc\n' "$PREFIX" ;;
esac

if [ "$DO_HS" -eq 1 ]; then
    HS_DIR="$HOME/.hammerspoon"
    if [ -d "$HS_DIR" ]; then
        printf '\nHammerspoon\n\n'
        link "$ROOT/hammerspoon/keybound-whisper.lua" "$HS_DIR/keybound-whisper.lua"
        printf '\n  Add this to %s/init.lua, then reload Hammerspoon:\n\n' "$HS_DIR"
        printf '      require("keybound-whisper").setup({ hotkey = { { "alt" }, "space" } })\n'
    else
        printf '\n  Hammerspoon config directory not found at %s; skipping.\n' "$HS_DIR"
    fi
fi

printf '\nChecking dependencies\n\n'
"$ROOT/bin/keybound-whisper" doctor 2>/dev/null | sed -n '1,8p' | sed 's/^/  /'
printf '\nRun `keybound-whisper doctor` for a full check, including a microphone test.\n\n'
