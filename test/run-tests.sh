#!/usr/bin/env bash
#
# run-tests.sh — conformance tests for keybind-whisper.
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
CLI="$ROOT/bin/keybind-whisper"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The restricted environment a GUI-launched process actually gets.
run() {
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KEYBIND_STATE_DIR="$WORK/state" \
        KEYBIND_CONFIG="$WORK/nonexistent-config" \
        KEYBIND_HISTORY_FILE="$WORK/history.jsonl" \
        KEYBIND_VOCAB_FILE="$WORK/vocabulary" \
        KEYBIND_REPLACEMENTS_FILE="$WORK/replacements" \
        "$CLI" "$@"
}

PASS=0; FAIL=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; FAIL=$((FAIL + 1)); }
check() { # check <name> <condition-result> <detail>
    if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "$3"; fi
}

SOX="$(command -v sox || echo /opt/homebrew/bin/sox)"

printf '\nkeybind-whisper test suite\n'
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

# ── History ─────────────────────────────────────────────────────────────────
printf '\nhistory\n'

# Earlier tests transcribe real audio, which correctly records history. Start
# this section from a known-empty store so the counts below mean something.
rm -f "$WORK/history.jsonl"

run history list >/dev/null 2>&1; rc=$?
check "history on an empty store exits non-zero" \
    "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

# Text that breaks a naive JSON writer: quotes, backslashes, brace characters.
NASTY='He said "hi" then typed C:\path\to\file plus {"a":1} and 50%'
run history add "$NASTY" >/dev/null 2>&1
got="$(run history last)"
check "adversarial text round-trips byte-identically" \
    "$([ "$got" = "$NASTY" ] && echo 0 || echo 1)" "got: [$got]"

# The store must stay valid JSON, or `history export` is worthless downstream.
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import json,sys
for line in open('$WORK/history.jsonl'):
    json.loads(line)
" 2>/dev/null; then ok "every stored line is valid JSON"
    else bad "every stored line is valid JSON" "a line failed to parse"; fi
else
    printf '  skip python3 unavailable; JSON validity not checked\n'
fi

run history add "second entry"  >/dev/null 2>&1
run history add "third entry"   >/dev/null 2>&1

# Index 1 is the newest. Getting this backwards makes "show the last one" wrong.
check "index 1 is the most recent entry" \
    "$([ "$(run history last)" = "third entry" ] && echo 0 || echo 1)" \
    "got: [$(run history last)]"
check "index counts backwards from newest" \
    "$([ "$(run history show 2)" = "second entry" ] && echo 0 || echo 1)" \
    "got: [$(run history show 2)]"

n="$(run history list 2>/dev/null | wc -l | tr -d ' ')"
check "list returns every entry" "$([ "$n" = "3" ] && echo 0 || echo 1)" "listed $n of 3"

n="$(run history list 2 2>/dev/null | wc -l | tr -d ' ')"
check "list honours a count limit" "$([ "$n" = "2" ] && echo 0 || echo 1)" "listed $n, wanted 2"

run history show 99 >/dev/null 2>&1; rc=$?
check "an out-of-range index exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

run history show abc >/dev/null 2>&1; rc=$?
check "a non-numeric index is rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

out="$(run history search "SECOND" 2>&1)"
case "$out" in
    *"second entry"*) ok "search is case-insensitive" ;;
    *) bad "search is case-insensitive" "$out" ;;
esac

run history search "no-such-text" >/dev/null 2>&1; rc=$?
check "search with no matches exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

# Searching must not match metadata, or every query would hit every row.
run history search "epoch" >/dev/null 2>&1; rc=$?
check "search ignores metadata fields" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "matched a metadata key"

perms="$(/usr/bin/stat -f '%Lp' "$WORK/history.jsonl" 2>/dev/null)"
check "history file is not world-readable" \
    "$([ "$perms" = "600" ] && echo 0 || echo 1)" "mode was $perms"

run history clear >/dev/null 2>&1; rc=$?
check "clear refuses without --yes" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"
check "clear without --yes leaves the store intact" \
    "$([ -s "$WORK/history.jsonl" ] && echo 0 || echo 1)" "the store was deleted anyway"

run history clear --yes >/dev/null 2>&1
check "clear --yes removes the store" \
    "$([ ! -s "$WORK/history.jsonl" ] && echo 0 || echo 1)" "the store survived"

# Opting out must mean nothing is written at all.
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KEYBIND_STATE_DIR="$WORK/state" \
    KEYBIND_CONFIG="$WORK/nonexistent-config" \
    KEYBIND_HISTORY_FILE="$WORK/optout.jsonl" \
    KEYBIND_HISTORY=0 \
    "$CLI" history add "must not be stored" >/dev/null 2>&1
check "KEYBIND_HISTORY=0 writes nothing" \
    "$([ ! -f "$WORK/optout.jsonl" ] && echo 0 || echo 1)" "a history file was created anyway"

# ── Replacements ────────────────────────────────────────────────────────────
printf '\nreplacements\n'

# With no rules file the text must pass through untouched, or every install
# without a rules file would corrupt transcripts.
check "text passes through with no rules file" \
    "$([ "$(run replace 'hello world')" = "hello world" ] && echo 0 || echo 1)" \
    "got: [$(run replace 'hello world')]"

cat > "$WORK/replacements" <<'RULES'
# comments and blank lines are ignored

arm sixty four = arm64
arm            = ARM
kubernetes     = Kubernetes
post gres      = PostgreSQL
filler         =
RULES

r() { run replace "$1"; }
check "a multi-word phrase is replaced" \
    "$([ "$(r 'the arm sixty four runner')" = "the arm64 runner" ] && echo 0 || echo 1)" \
    "got: [$(r 'the arm sixty four runner')]"
check "matching is case-insensitive" \
    "$([ "$(r 'KUBERNETES and kubernetes')" = "Kubernetes and Kubernetes" ] && echo 0 || echo 1)" \
    "got: [$(r 'KUBERNETES and kubernetes')]"

# The important safety property: a short rule must not rewrite the inside of a
# longer word. Without a boundary check, "arm" would corrupt "alarm" and "farm".
check "rules do not match inside words" \
    "$([ "$(r 'an alarm on a farm')" = "an alarm on a farm" ] && echo 0 || echo 1)" \
    "got: [$(r 'an alarm on a farm')]"
check "rules match next to punctuation" \
    "$([ "$(r 'arm, and arm.')" = "ARM, and ARM." ] && echo 0 || echo 1)" \
    "got: [$(r 'arm, and arm.')]"
check "every occurrence is replaced" \
    "$([ "$(r 'post gres then post gres')" = "PostgreSQL then PostgreSQL" ] && echo 0 || echo 1)" \
    "got: [$(r 'post gres then post gres')]"
check "an earlier rule wins over a shorter later one" \
    "$([ "$(r 'arm sixty four')" = "arm64" ] && echo 0 || echo 1)" \
    "got: [$(r 'arm sixty four')]"
check "an empty replacement deletes and reflows spacing" \
    "$([ "$(r 'a filler b')" = "a b" ] && echo 0 || echo 1)" \
    "got: [$(r 'a filler b')]"

# A replacement must never be rescanned by a later rule, or rules could cascade
# into each other unpredictably.
cat > "$WORK/replacements" <<'RULES'
cat = dog
dog = ferret
RULES
check "a replacement is not rescanned by later rules" \
    "$([ "$(r 'cat')" = "dog" ] && echo 0 || echo 1)" "got: [$(r 'cat')]"

# Regex metacharacters in a rule must be treated literally.
cat > "$WORK/replacements" <<'RULES'
c++ = cpp
RULES
check "regex metacharacters are literal" \
    "$([ "$(r 'I write c++ daily')" = "I write cpp daily" ] && echo 0 || echo 1)" \
    "got: [$(r 'I write c++ daily')]"
: > "$WORK/replacements"

# ── Vocabulary ──────────────────────────────────────────────────────────────
printf '\nvocabulary\n'
cat > "$WORK/vocabulary" <<'VOCAB'
# comments ignored
arm64
Kubernetes
PostgreSQL
VOCAB
out="$(run status 2>&1)"
case "$out" in
    *"vocab     $WORK/vocabulary"*) ok "status reports the vocabulary file" ;;
    *) bad "status reports the vocabulary file" "$out" ;;
esac

if command -v say >/dev/null 2>&1; then
    say -o "$WORK/vocab.aiff" -r 175 "the kubernetes cluster runs postgres" 2>/dev/null
    with="$(run transcribe "$WORK/vocab.aiff" 2>/dev/null)"
    case "$with" in
        *PostgreSQL*) ok "vocabulary biases decoding toward a listed term" ;;
        # A nudge, not a guarantee: report it without failing the suite.
        *) printf '  note vocabulary did not change this transcript: [%s]\n' "$with" ;;
    esac
fi
: > "$WORK/vocabulary"

# ── Auto-stop on silence ────────────────────────────────────────────────────
printf '\nauto-stop\n'
out="$(run status 2>&1)"
case "$out" in
    *"auto-stop off (push-to-talk)"*) ok "auto-stop is off by default" ;;
    *) bad "auto-stop is off by default" "$out" ;;
esac

out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KEYBIND_STATE_DIR="$WORK/state" KEYBIND_CONFIG="$WORK/none" \
    KEYBIND_SILENCE_SEC=2 "$CLI" status 2>&1)"
case "$out" in
    *"auto-stop 2s below"*) ok "auto-stop is reported when enabled" ;;
    *) bad "auto-stop is reported when enabled" "$out" ;;
esac

run finish >/dev/null 2>&1; rc=$?
check "finish with no recording exits non-zero" \
    "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

# The silence effect is what makes auto-stop work, so verify sox actually ends
# a stream on trailing silence rather than trusting the flag is accepted.
# Built from files, so no microphone is involved.
say -o "$WORK/sp.aiff" -r 175 "this is a test of silence detection" 2>/dev/null
"$SOX" "$WORK/sp.aiff" -r 16000 -c 1 -b 16 "$WORK/sp.wav" 2>/dev/null
"$SOX" -n -r 16000 -c 1 -b 16 "$WORK/tone.wav" synth 5 whitenoise vol 0.002 2>/dev/null
"$SOX" "$WORK/tone.wav" "$WORK/sp.wav" "$WORK/tone.wav" "$WORK/long.wav" 2>/dev/null
"$SOX" "$WORK/long.wav" "$WORK/cut.wav" silence 1 0.1 2% 1 2.0 2% 2>/dev/null
long="$("$SOX" --i -D "$WORK/long.wav" 2>/dev/null)"
cut="$("$SOX" --i -D "$WORK/cut.wav" 2>/dev/null)"
check "the silence effect ends a stream on trailing silence" \
    "$(awk -v a="$long" -v b="$cut" 'BEGIN{exit !(b > 0.5 && b < a - 3)}' && echo 0 || echo 1)" \
    "input ${long}s produced ${cut}s; expected a substantial cut"

# ── Backends ────────────────────────────────────────────────────────────────
printf '\nbackends\n'

out="$(run status 2>&1)"
case "$out" in
    *"backend   cli"*) ok "the default backend is the local CLI" ;;
    *) bad "the default backend is the local CLI" "$out" ;;
esac
case "$out" in
    *"audio stays on this machine"*) ok "status states where the audio goes" ;;
    *) bad "status states where the audio goes" "$out" ;;
esac

be() { # be <backend> <args...>
    _b="$1"; shift
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        KEYBIND_STATE_DIR="$WORK/state" KEYBIND_CONFIG="$WORK/none" \
        KEYBIND_HISTORY=0 KEYBIND_VOCAB_FILE="$WORK/novocab" \
        KEYBIND_REPLACEMENTS_FILE="$WORK/norepl" KEYBIND_LOG="$WORK/backend.log" \
        KEYBIND_BACKEND="$_b" "$@" "$CLI" transcribe "$WORK/speech.aiff"
}

be telepathy >/dev/null 2>&1; rc=$?
check "an unknown backend exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"

# The api backend must refuse a remote endpoint with no credentials BEFORE it
# records or uploads anything, not after.
out="$(be api 2>&1)"; rc=$?
check "api without a key for a remote endpoint is refused" \
    "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc"
case "$out" in
    *KEYBIND_API_KEY*) ok "the refusal names the missing setting" ;;
    *) bad "the refusal names the missing setting" "$out" ;;
esac

if command -v python3 >/dev/null 2>&1; then
    FAKE="$ROOT/test/fake-transcription-server.py"

    start_fake() { # start_fake <port> <record> [extra args]
        _p="$1"; shift
        python3 "$FAKE" "$_p" "$@" >/dev/null 2>&1 &
        FAKE_PID=$!
        _n=0
        until curl -s -o /dev/null "http://127.0.0.1:$_p/" 2>/dev/null; do
            _n=$((_n + 1)); [ "$_n" -gt 100 ] && break
            sleep 0.1
        done
    }
    stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }

    # ── server backend ──────────────────────────────────────────────────────
    start_fake 18431 "$WORK/rec-server.json"
    out="$(be server KEYBIND_SERVER_URL=http://127.0.0.1:18431 2>"$WORK/be.err")"; rc=$?
    stop_fake
    check "the server backend transcribes through HTTP" \
        "$([ "$rc" -eq 0 ] && [ "$out" = "the fake endpoint replied" ] && echo 0 || echo 1)" \
        "exit $rc, out [$out], err $(cat "$WORK/be.err")"
    if [ -f "$WORK/rec-server.json" ]; then
        path="$(python3 -c "import json;print(json.load(open('$WORK/rec-server.json'))['path'])" 2>/dev/null)"
        check "the server backend posts to /inference" \
            "$([ "$path" = "/inference" ] && echo 0 || echo 1)" "posted to $path"
    fi

    # A dead local server must not lose an utterance the user already spoke:
    # both paths are on this machine, so falling back costs nothing but speed.
    out="$(be server KEYBIND_SERVER_URL=http://127.0.0.1:18432 2>"$WORK/be.err")"; rc=$?
    check "an unreachable server falls back to the local CLI" \
        "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "exit $rc: $(cat "$WORK/be.err")"
    case "$(cat "$WORK/be.err")" in
        *unreachable*) ok "the fallback is announced rather than silent" ;;
        *) bad "the fallback is announced rather than silent" "$(cat "$WORK/be.err")" ;;
    esac

    out="$(be server KEYBIND_SERVER_URL=http://127.0.0.1:18432 KEYBIND_SERVER_FALLBACK=0 2>&1)"; rc=$?
    check "fallback can be disabled, and then it fails loudly" \
        "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit $rc: $out"

    # ── api backend ─────────────────────────────────────────────────────────
    start_fake 18433 "$WORK/rec-api.json" --require-auth
    out="$(be api KEYBIND_API_URL=http://127.0.0.1:18433/v1/audio/transcriptions \
                  KEYBIND_API_KEY=sk-test-SECRET-value 2>"$WORK/be.err")"; rc=$?
    stop_fake
    check "the api backend transcribes through HTTP" \
        "$([ "$rc" -eq 0 ] && [ "$out" = "the fake endpoint replied" ] && echo 0 || echo 1)" \
        "exit $rc, out [$out], err $(cat "$WORK/be.err")"

    if [ -f "$WORK/rec-api.json" ]; then
        auth="$(python3 -c "import json;print(json.load(open('$WORK/rec-api.json'))['authorization'])" 2>/dev/null)"
        check "the api key is sent as a bearer token" \
            "$([ "$auth" = "Bearer sk-test-SECRET-value" ] && echo 0 || echo 1)" "got [$auth]"
        model="$(python3 -c "import json;print(json.load(open('$WORK/rec-api.json'))['fields'].get('model',''))" 2>/dev/null)"
        check "the api backend sends a model name" \
            "$([ -n "$model" ] && echo 0 || echo 1)" "got [$model]"
    fi

    # Credentials must never reach the log.
    check "the api key never appears in the log" \
        "$(grep -q "sk-test-SECRET-value" "$WORK/backend.log" 2>/dev/null && echo 1 || echo 0)" \
        "the key was written to $WORK/backend.log"

    # Nor the process list: argv is readable by every process of this user, so
    # the key goes through a curl config file instead of -H.
    check "the key is passed by config file, never on the command line" \
        "$(grep -q 'curl.*-H.*Authorization' "$CLI" && echo 1 || echo 0)" \
        "the source passes Authorization as a curl argument"
    check "the implementation uses curl --config for credentials" \
        "$(grep -q -- '--config "\$_cfg"' "$CLI" && echo 0 || echo 1)" \
        "no --config use found in the api backend"

    # Redaction must survive a key that is hostile to the redactor itself. An
    # earlier sed-based version built a pattern out of the key, and a key
    # containing / broke the expression — at which point the redactor failed
    # OPEN and wrote the secret straight to the log. The fixture reflects the
    # Authorization header back in its error body so there is really something
    # to redact.
    for hostile in 'sk-a|b&c.d*e$f[g]h/i' 'sk-/slash/key/' 'sk-"quoted"-key'; do
        start_fake 18435 "$WORK/rec-hostile.json" --status 500
        rm -f "$WORK/hostile.log"
        err="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
            KEYBIND_STATE_DIR="$WORK/state" KEYBIND_CONFIG="$WORK/none" KEYBIND_HISTORY=0 \
            KEYBIND_VOCAB_FILE="$WORK/novocab" KEYBIND_REPLACEMENTS_FILE="$WORK/norepl" \
            KEYBIND_LOG="$WORK/hostile.log" KEYBIND_BACKEND=api \
            KEYBIND_API_URL=http://127.0.0.1:18435/v1/audio/transcriptions \
            KEYBIND_API_KEY="$hostile" \
            "$CLI" transcribe "$WORK/speech.aiff" 2>&1)"
        stop_fake
        if grep -qF -- "$hostile" "$WORK/hostile.log" 2>/dev/null \
           || printf '%s' "$err" | grep -qF -- "$hostile"; then
            bad "a key with metacharacters is still redacted" "leaked: $hostile"
        else
            ok "a key with metacharacters is still redacted (${hostile})"
        fi
    done

    # An authentication failure must be reported, and must NOT quietly produce
    # a locally-transcribed result as though the endpoint had answered.
    start_fake 18434 "$WORK/rec-401.json" --require-auth
    out="$(be api KEYBIND_API_URL=http://127.0.0.1:18434/v1/audio/transcriptions 2>&1)"; rc=$?
    stop_fake
    check "an api auth failure exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit $rc"
    case "$out" in
        *authentication*) ok "an api auth failure says what went wrong" ;;
        *) bad "an api auth failure says what went wrong" "$out" ;;
    esac
    case "$out" in
        *"quick brown fox"*|*"test of silence"*)
            bad "api never falls back to local transcription" "a local transcript was produced anyway" ;;
        *) ok "api never falls back to local transcription" ;;
    esac
else
    printf '  skip python3 unavailable; HTTP backends not tested\n'
fi

# ── Model validation ────────────────────────────────────────────────────────
printf '\nmodel validation\n'

# A truncated download keeps the ggml magic of its first bytes, so size has to
# be judged against what the filename claims. Found on a real machine: a 57 MB
# ggml-medium.bin that outranked every smaller good model and then failed at
# transcription time with only an exit code.
mkdir -p "$WORK/models"
printf '\x6c\x6d\x67\x67' > "$WORK/models/ggml-medium.bin"
dd if=/dev/zero bs=1048576 count=40 >> "$WORK/models/ggml-medium.bin" 2>/dev/null
out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KEYBIND_STATE_DIR="$WORK/state" KEYBIND_CONFIG="$WORK/none" \
    KEYBIND_MODEL="$WORK/models/ggml-medium.bin" "$CLI" status 2>&1)"
case "$out" in
    *truncated*) ok "a truncated model is identified as truncated" ;;
    *) bad "a truncated model is identified as truncated" "$(printf '%s' "$out" | grep -i model)" ;;
esac

printf 'this is not a model at all, not even close, padding padding' > "$WORK/models/ggml-tiny.bin"
out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KEYBIND_STATE_DIR="$WORK/state" KEYBIND_CONFIG="$WORK/none" \
    KEYBIND_MODEL="$WORK/models/ggml-tiny.bin" "$CLI" status 2>&1)"
case "$out" in
    *"not a ggml model"*) ok "a file with the wrong magic is rejected" ;;
    *) bad "a file with the wrong magic is rejected" "$(printf '%s' "$out" | grep -i model)" ;;
esac

out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KEYBIND_STATE_DIR="$WORK/state" KEYBIND_CONFIG="$WORK/none" \
    KEYBIND_MODEL="$WORK/models/ggml-medium.bin" "$CLI" doctor 2>&1)"
case "$out" in
    *"re-download"*) ok "doctor says what to do about a bad model" ;;
    *) bad "doctor says what to do about a bad model" "$out" ;;
esac

# ── State directory safety ──────────────────────────────────────────────────
printf '\nstate directory\n'

# The default state directory lives under the world-writable /tmp, where
# another user could plant a symlink at that path and read every capture and
# transcript that passes through it.
ln -s "$WORK/elsewhere" "$WORK/evil-state"
out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    KEYBIND_STATE_DIR="$WORK/evil-state" "$CLI" status 2>&1)"; rc=$?
check "a symlinked state directory is refused" \
    "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "exit was $rc: $out"
case "$out" in
    *symlink*) ok "the refusal says why" ;;
    *) bad "the refusal says why" "got: [$out]" ;;
esac
rm -f "$WORK/evil-state"

# doctor opens the microphone. Doing that mid-dictation puts two processes on
# the same input. A null-input sox stands in for a recorder, so no microphone
# is needed to test the guard.
mkdir -p "$WORK/state"
# A real `sox -n ... trim 0 20` is NOT a stand-in: with a null input it computes
# 20 seconds of silence as fast as it can and exits immediately, so the guard
# correctly saw a dead process. What is needed is something long-lived whose
# command line looks like the recorder, which is exactly what the guard checks.
printf '#!/bin/sh\nsleep 30\n' > "$WORK/sox-recorder"
chmod +x "$WORK/sox-recorder"
"$WORK/sox-recorder" >/dev/null 2>&1 &
SOXPID=$!
echo "$SOXPID" > "$WORK/state/recorder.pid"
sleep 0.3
# Confirm the stand-in really is live and really does look like a recorder,
# or the test below would pass for the wrong reason.
if ! /bin/ps -o command= -p "$SOXPID" 2>/dev/null | grep -q sox; then
    bad "the doctor guard test set itself up correctly" "the stand-in recorder is not running"
fi
out="$(run doctor 2>&1)"
case "$out" in
    *"recording is in progress"*) ok "doctor refuses to open the mic mid-recording" ;;
    *) bad "doctor refuses to open the mic mid-recording" "$(printf '%s' "$out" | tail -3)" ;;
esac
kill "$SOXPID" 2>/dev/null; wait "$SOXPID" 2>/dev/null
rm -f "$WORK/state/recorder.pid" "$WORK/sox-recorder"

# ── Installer ───────────────────────────────────────────────────────────────
printf '\ninstaller\n'

# The installer is meant to be run as `curl ... | bash`, where bash reads the
# script from stdin as it executes. Any child that reads stdin eats the rest of
# the script and bash exits 0 partway through, looking like success. That
# really happened: `hs -c` reads stdin, so the installer stopped right after
# reloading Hammerspoon and never printed its results. Piping it here and
# requiring the FINAL line is the only way to catch that.
# Drive the FULL path, Hammerspoon branch included, against a throwaway config
# directory. Skipping that branch would skip the `hs` call that reads stdin,
# which is exactly the hazard being tested — an earlier version of this test
# passed with the bug reintroduced for precisely that reason.
mkdir -p "$WORK/hs"
printf -- '-- test config\n' > "$WORK/hs/init.lua"
if cat "$ROOT/install.sh" | env KEYBIND_SRC="$ROOT" KEYBIND_NO_FETCH=1 \
        KEYBIND_HS_DIR="$WORK/hs" \
        bash -s -- --no-deps --no-reload --prefix "$WORK/prefix" \
        > "$WORK/install.out" 2>&1; then
    if grep -q '^Installed\.' "$WORK/install.out"; then
        ok "piped to bash, the installer runs to completion"
    else
        bad "piped to bash, the installer runs to completion" \
            "the final line is missing — a child process ate stdin: $(tail -3 "$WORK/install.out")"
    fi
else
    bad "piped to bash, the installer runs to completion" "non-zero exit: $(tail -3 "$WORK/install.out")"
fi

case "$(cat "$WORK/install.out")" in
    *"hs"*|*"Hammerspoon"*) ok "the Hammerspoon branch actually ran (the stdin hazard was exercised)" ;;
    *) bad "the Hammerspoon branch actually ran" "it was skipped, so the test proves nothing" ;;
esac

check "the installer wires the require line into init.lua" \
    "$(grep -q 'require("keybind-whisper")' "$WORK/hs/init.lua" && echo 0 || echo 1)" \
    "init.lua was not wired: $(cat "$WORK/hs/init.lua")"

check "the installer links the Hammerspoon module" \
    "$([ -L "$WORK/hs/keybind-whisper.lua" ] && echo 0 || echo 1)" \
    "no module symlink in the test config dir"

check "the installer links the command" \
    "$([ -L "$WORK/prefix/bin/keybind-whisper" ] && echo 0 || echo 1)" \
    "no symlink at $WORK/prefix/bin/keybind-whisper"

# Every command in the installer must be inside main(), called on the last
# line, so bash parses the whole thing before executing any of it.
# --help used to slice a line range out of "$0". Piped from curl there is no $0
# file, so it printed nothing and exited 0.
out="$(cat "$ROOT/install.sh" | bash -s -- --help 2>&1)"
case "$out" in
    *"install.sh"*"--uninstall"*) ok "--help works when the script is piped" ;;
    *) bad "--help works when the script is piped" "got: [$out]" ;;
esac

check "the installer body is wrapped in main()" \
    "$([ "$(tail -1 "$ROOT/install.sh")" = 'main "$@"' ] && echo 0 || echo 1)" \
    "the last line is: $(tail -1 "$ROOT/install.sh")"

# Running it twice must change nothing.
cat "$ROOT/install.sh" | env KEYBIND_SRC="$ROOT" KEYBIND_NO_FETCH=1 \
    KEYBIND_HS_DIR="$WORK/hs" \
    bash -s -- --no-deps --no-reload --prefix "$WORK/prefix" \
    > "$WORK/install2.out" 2>&1
case "$(cat "$WORK/install2.out")" in
    *"ok       $WORK/prefix/bin/keybind-whisper"*) ok "a second run is idempotent" ;;
    *) bad "a second run is idempotent" "$(grep -A1 '^Command' "$WORK/install2.out")" ;;
esac

# And it must be able to undo itself.
cat "$ROOT/install.sh" | env KEYBIND_SRC="$ROOT" KEYBIND_NO_FETCH=1 \
    KEYBIND_HS_DIR="$WORK/hs" \
    bash -s -- --uninstall --prefix "$WORK/prefix" > "$WORK/uninstall.out" 2>&1
check "--uninstall removes the command" \
    "$([ ! -e "$WORK/prefix/bin/keybind-whisper" ] && echo 0 || echo 1)" \
    "the symlink survived uninstall"
check "--uninstall removes the require line from init.lua" \
    "$(grep -q 'require("keybind-whisper")' "$WORK/hs/init.lua" && echo 1 || echo 0)" \
    "the require line survived uninstall"

# ── Hammerspoon module ──────────────────────────────────────────────────────
if command -v lua >/dev/null 2>&1; then
    if lua "$ROOT/test/test-hammerspoon.lua" > "$WORK/lua.out" 2>&1; then
        n="$(grep -c '^  ok' "$WORK/lua.out" || echo 0)"
        printf '\nhammerspoon module\n'
        ok "module loads and dispatches correctly ($n checks)"
    else
        printf '\nhammerspoon module\n'
        bad "module tests failed" "$(cat "$WORK/lua.out")"
    fi
else
    printf '\nhammerspoon module\n  skip lua unavailable; run test/test-hammerspoon.lua under Hammerspoon\n'
fi

# ── Summary ─────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
