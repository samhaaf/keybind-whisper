#!/usr/bin/env bash
#
# install.sh — install keybind-whisper and wire it into Hammerspoon.
#
# Run it from a clone, or pipe it straight from the web:
#
#   curl -fsSL https://github.com/samhaaf/keybind-whisper/raw/main/install.sh | bash
#
# With no arguments it does the whole job: installs the command, installs any
# missing Homebrew dependencies, links the Hammerspoon module, adds one line to
# init.lua, and reloads Hammerspoon. Every step says what it did, every file it
# touches is backed up first, and running it twice changes nothing.
#
#   --no-deps          skip Homebrew dependency installation
#   --no-hammerspoon   install the command only
#   --no-wire          link the Hammerspoon module but do not edit init.lua
#   --whisper          also build whisper.cpp and download a model
#   --prefix DIR       install the command into DIR/bin (default ~/.local)
#   --uninstall        remove everything this script installs

set -uo pipefail

REPO_URL="https://github.com/samhaaf/keybind-whisper"
SRC_DEFAULT="$HOME/.local/share/keybind-whisper/src"
PREFIX="$HOME/.local"
DO_DEPS=1; DO_HS=1; DO_WIRE=1; DO_WHISPER=0; DO_UNINSTALL=0
HS_DIR="$HOME/.hammerspoon"
MARK="keybind-whisper"   # how the init.lua line is recognized

while [ $# -gt 0 ]; do
    case "$1" in
        --no-deps)        DO_DEPS=0 ;;
        --no-hammerspoon) DO_HS=0 ;;
        --no-wire)        DO_WIRE=0 ;;
        --whisper)        DO_WHISPER=1 ;;
        --uninstall)      DO_UNINSTALL=1 ;;
        --prefix)         shift; PREFIX="${1:-$PREFIX}" ;;
        -h|--help)        sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '  %s\n' "$*"; }
head2() { printf '\n%s\n\n' "$*"; }
die()  { printf '\nerror: %s\n\n' "$*" >&2; exit 1; }

# ── Locate the source tree ──────────────────────────────────────────────────
# Piped from curl there is no $0 to work from, so the script clones itself and
# carries on. Run from a checkout it uses that checkout, so a contributor's
# edits are what gets installed.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -n "$SELF_DIR" ] && [ -x "$SELF_DIR/bin/keybind-whisper" ]; then
    SRC="$SELF_DIR"
else
    SRC="${KEYBIND_SRC:-$SRC_DEFAULT}"
    head2 "Fetching keybind-whisper"
    command -v git >/dev/null 2>&1 || die "git is required to bootstrap. Install the Xcode command line tools: xcode-select --install"
    if [ -d "$SRC/.git" ]; then
        say "updating $SRC"
        git -C "$SRC" pull --ff-only --quiet || say "could not fast-forward; using the existing checkout"
    else
        mkdir -p "$(dirname "$SRC")"
        say "cloning into $SRC"
        git clone --quiet --depth 1 "$REPO_URL" "$SRC" || die "clone failed: $REPO_URL"
    fi
    [ -x "$SRC/bin/keybind-whisper" ] || die "the checkout at $SRC looks wrong: bin/keybind-whisper is missing"
fi

CLI="$SRC/bin/keybind-whisper"

# ── Uninstall ───────────────────────────────────────────────────────────────
if [ "$DO_UNINSTALL" -eq 1 ]; then
    head2 "Uninstalling keybind-whisper"
    [ -L "$PREFIX/bin/keybind-whisper" ] && { rm -f "$PREFIX/bin/keybind-whisper"; say "removed $PREFIX/bin/keybind-whisper"; }
    [ -L "$HS_DIR/keybind-whisper.lua" ] && { rm -f "$HS_DIR/keybind-whisper.lua"; say "removed $HS_DIR/keybind-whisper.lua"; }
    if [ -f "$HS_DIR/init.lua" ] && grep -q "$MARK" "$HS_DIR/init.lua"; then
        cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.backup-$(date +%Y%m%d-%H%M%S)"
        grep -v "$MARK" "$HS_DIR/init.lua" > "$HS_DIR/init.lua.tmp" && mv "$HS_DIR/init.lua.tmp" "$HS_DIR/init.lua"
        say "removed the require line from init.lua (backed up)"
    fi
    say "left in place: the source at $SRC, your config, and your history"
    printf '\n'
    exit 0
fi

# ── Dependencies ────────────────────────────────────────────────────────────
if [ "$DO_DEPS" -eq 1 ]; then
    head2 "Dependencies"
    if command -v brew >/dev/null 2>&1; then
        for pkg in sox switchaudio-osx; do
            if brew list --formula "$pkg" >/dev/null 2>&1; then
                say "ok       $pkg"
            else
                say "install  $pkg"
                brew install "$pkg" >/dev/null 2>&1 && say "ok       $pkg" || say "FAILED   $pkg — run: brew install $pkg"
            fi
        done
    else
        say "Homebrew not found; skipping. sox is required: https://brew.sh"
    fi
fi

# whisper.cpp and a model are a compile and a large download, so they are only
# touched when asked for explicitly.
if [ "$DO_WHISPER" -eq 1 ]; then
    head2 "whisper.cpp"
    WC="${WHISPER_CPP_DIR:-$HOME/code/whisper.cpp}"
    if [ -x "$WC/build/bin/whisper-cli" ]; then
        say "ok       already built at $WC"
    else
        say "cloning and building into $WC (this takes a few minutes)"
        git clone --quiet --depth 1 https://github.com/ggerganov/whisper.cpp "$WC" 2>/dev/null || say "using the existing directory"
        ( cd "$WC" && cmake -B build >/dev/null && cmake --build build -j --config Release >/dev/null ) \
            && say "ok       built" || die "the whisper.cpp build failed; build it by hand in $WC"
    fi
    if ls "$WC"/models/ggml-*.bin >/dev/null 2>&1; then
        say "ok       a model is already present"
    else
        say "downloading the large-v3-turbo model (about 1.6 GB)"
        ( cd "$WC" && ./models/download-ggml-model.sh large-v3-turbo >/dev/null ) \
            && say "ok       downloaded" || say "FAILED   run: cd $WC && ./models/download-ggml-model.sh large-v3-turbo"
    fi
fi

# ── The command ─────────────────────────────────────────────────────────────
# A symlink rather than a copy, so `git pull` in the source tree updates the
# installed command too.
link() {
    src="$1"; dst="$2"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        say "ok       $dst"
        return 0
    fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        mv "$dst" "$dst.backup-$(date +%Y%m%d-%H%M%S)"
        say "moved the existing $(basename "$dst") aside"
    fi
    ln -s "$src" "$dst" && say "linked   $dst"
}

head2 "Command"
mkdir -p "$PREFIX/bin"
link "$CLI" "$PREFIX/bin/keybind-whisper"

case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) say ""
       say "$PREFIX/bin is not on your PATH. To use the command directly:"
       say "  echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.zshrc"
       say "(Hammerspoon calls it by absolute path, so dictation works regardless.)" ;;
esac

# ── Hammerspoon ─────────────────────────────────────────────────────────────
if [ "$DO_HS" -eq 1 ]; then
    head2 "Hammerspoon"
    if [ ! -d "$HS_DIR" ]; then
        say "no config directory at $HS_DIR"
        say "install Hammerspoon from https://www.hammerspoon.org/ and re-run this"
    else
        link "$SRC/hammerspoon/keybind-whisper.lua" "$HS_DIR/keybind-whisper.lua"

        LINE='require("keybind-whisper").setup({ hotkey = { { "alt" }, "space" } })'
        if [ "$DO_WIRE" -eq 0 ]; then
            say ""
            say "add this to $HS_DIR/init.lua yourself:"
            say "  $LINE"
        elif [ -f "$HS_DIR/init.lua" ] && grep -q "$MARK" "$HS_DIR/init.lua"; then
            say "ok       init.lua already loads it"
        else
            [ -f "$HS_DIR/init.lua" ] && cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.backup-$(date +%Y%m%d-%H%M%S)"
            {
                printf '\n-- keybind-whisper: offline push-to-talk dictation (%s)\n' "$REPO_URL"
                printf '%s\n' "$LINE"
            } >> "$HS_DIR/init.lua"
            say "added the require line to init.lua (backed up first)"
        fi

        # Reload so the hotkey is live now rather than after a manual click.
        if command -v hs >/dev/null 2>&1 && hs -c 'true' >/dev/null 2>&1; then
            hs -c 'hs.reload()' >/dev/null 2>&1
            say "reloaded Hammerspoon"
        elif pgrep -q Hammerspoon; then
            open -g "hammerspoon://reload" 2>/dev/null \
                && say "asked Hammerspoon to reload" \
                || say "reload Hammerspoon yourself to pick up the change"
        else
            say "Hammerspoon is not running; start it to enable the hotkey"
        fi
    fi
fi

# ── Check it works ──────────────────────────────────────────────────────────
head2 "Checking dependencies"
"$CLI" doctor 2>/dev/null | sed -n '/^Dependencies/,/^$/p' | sed 's/^/  /'

printf '\nInstalled. Press ⌥Space, speak, press it again.\n'
printf 'Run `keybind-whisper doctor` for a full check, including a microphone test.\n\n'
