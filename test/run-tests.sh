#!/usr/bin/env bash
#
# run-tests.sh — conformance tests for whisper-local.
#
# Every test runs with PATH reduced to /usr/bin:/bin:/usr/sbin:/sbin, which is
# what macOS gives a process launched by a GUI app. That is not incidental: a
# bare `sox` works in a login shell and fails with 127 under a hotkey daemon,
# which is exactly the failure mode this suite exists to catch.
#
# No microphone is used. Speech is synthesized to a file with `say -o`, which
# renders silently, so the suite is safe to run on a busy machine and in CI.
#
#   ./test/run-tests.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/whisper-local"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The restricted environment a GUI-launched process actually gets.
run() {
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        WHISPER_LOCAL_STATE_DIR="$WORK/state" \
        WHISPER_LOCAL_CONFIG="$WORK/nonexistent-config" \
        "$CLI" "$@"
}

PASS=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { # check <name> <condition-result> <detail>
    if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "$3"; fi
}

SOX="$(command -v sox || echo /opt/homebrew/bin/sox)"

printf '\nwhisper-local test suite\n'
printf 'PATH under test: /usr/bin:/bin:/usr/sbin:/sbin (GUI-launch equivalent)\n\n'

# ── Dependency resolution ───────────────────────────────────────────────────
printf 'dependency resolution\n'
out="$(run status 2>&1)"

# Assert the ABSOLUTE path, not merely that something was printed. A bare
# binary name looks fine in `status` and still fails with 127 when the tool is
# launched by a GUI app, which is precisely the bug that motivated this suite.
resolved() { printf '%s\n' "$out" | awk -v k="$1" '$1==k{print $2; exit}'; }
for dep in sox whisper; do
    path="$(resolved "$dep")"
    case "$path" in
        /*) if [ -x "$path" ]; then ok "resolves $dep to an executable absolute path"
            else bad "resolves $dep to an executable absolute path" "not executable: $path"; fi ;;
        *)  bad "resolves $dep to an executable absolute path" "not absolute: [$path]" ;;
    esac
done
case "$out" in
    *"model     NOT FOUND"*) bad "discovers a model without configuration" "$out" ;;
    *) ok "discovers a model without configuration" ;;
esac
case "$out" in
    *"input     system default"*) ok "defaults to the system default input" ;;
    *) bad "defaults to the system default input" "$out" ;;
esac

# ── Output contract ─────────────────────────────────────────────────────────
printf '\noutput contract\n'
o="$(run stop 2>"$WORK/err")"; rc=$?
check "stop without start exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"
check "stop without start prints nothing on stdout" "$([ -z "$o" ] && echo 0 || echo 1)" "stdout: [$o]"
check "stop without start explains itself on stderr" "$([ -s "$WORK/err" ] && echo 0 || echo 1)" "stderr was empty"

run badsubcommand >/dev/null 2>&1; rc=$?
check "unknown subcommand exits 2" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "exit was $rc"

o="$(run version 2>&1)"; rc=$?
check "version reports cleanly" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "$o"

# ── Audio gates, using synthesized files only ───────────────────────────────
printf '\naudio gates (no microphone)\n'

"$SOX" -n -r 16000 -c 1 -b 16 "$WORK/silence.wav" trim 0 3 2>/dev/null
o="$(run transcribe "$WORK/silence.wav" 2>"$WORK/err")"; rc=$?
check "silence exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "exit was $rc"
check "silence produces no transcript" "$([ -z "$o" ] && echo 0 || echo 1)" "stdout: [$o]"
case "$(cat "$WORK/err")" in
    *"silent capture"*) ok "silence is reported as a silent capture" ;;
    *) bad "silence is reported as a silent capture" "$(cat "$WORK/err")" ;;
esac

"$SOX" -n -r 16000 -c 1 -b 16 "$WORK/blip.wav" synth 0.1 sine 440 2>/dev/null
o="$(run transcribe "$WORK/blip.wav" 2>"$WORK/err")"; rc=$?
case "$(cat "$WORK/err")" in
    *"too short"*) ok "a sub-threshold capture is reported as too short" ;;
    *) bad "a sub-threshold capture is reported as too short" "$(cat "$WORK/err")" ;;
esac
check "too-short capture produces no transcript" "$([ -z "$o" ] && echo 0 || echo 1)" "stdout: [$o]"

run transcribe "$WORK/does-not-exist.wav" >/dev/null 2>&1; rc=$?
check "a missing input file exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

# ── End-to-end transcription ────────────────────────────────────────────────
printf '\nend-to-end transcription\n'
PHRASE="the quick brown fox jumps over the lazy dog"
if command -v say >/dev/null 2>&1; then
    # `say -o` renders to a file; it does not play through the speakers.
    say -o "$WORK/speech.aiff" -r 170 "$PHRASE" 2>/dev/null
    o="$(run transcribe "$WORK/speech.aiff" 2>"$WORK/err")"; rc=$?
    check "synthesized speech exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "exit $rc: $(cat "$WORK/err")"
    norm="$(printf '%s' "$o" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z ')"
    case "$norm" in
        *"quick brown fox"*) ok "transcript matches the spoken phrase" ;;
        *) bad "transcript matches the spoken phrase" "got: [$o]" ;;
    esac
    check "transcript is a single line" \
        "$([ "$(printf '%s' "$o" | wc -l | tr -d ' ')" -le 1 ] && echo 0 || echo 1)" "[$o]"
else
    printf '  skip say(1) unavailable; end-to-end transcription not tested\n'
fi

# ── State hygiene ───────────────────────────────────────────────────────────
printf '\nstate hygiene\n'
mkdir -p "$WORK/state"
cp "$WORK/silence.wav" "$WORK/state/capture.wav"
run stop >/dev/null 2>&1
check "a stale capture is discarded, not re-transcribed" \
    "$([ ! -f "$WORK/state/capture.wav" ] && echo 0 || echo 1)" \
    "capture.wav survived a stop with no recording in progress"

echo "99999999" > "$WORK/state/recorder.pid"
o="$(run status 2>&1)"
case "$o" in
    *"stale pidfile"*) ok "a stale pidfile is detected rather than trusted" ;;
    *) bad "a stale pidfile is detected rather than trusted" "$o" ;;
esac
rm -f "$WORK/state/recorder.pid"

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
