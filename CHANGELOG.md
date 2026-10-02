# Changelog

Notable changes to keybind-whisper. Versions follow
[semantic versioning](https://semver.org/).

## [1.0.0] — unreleased

First public release.

### Dictation

- Offline push-to-talk dictation: record from the system default input,
  transcribe locally with whisper.cpp, paste at the cursor. Nothing leaves the
  machine.
- Auto-stop on silence, via `KEYBIND_SILENCE_SEC`. Off by default,
  because the threshold depends on the room and the microphone; `doctor`
  measures both and recommends a value.
- `dictate` records until you stop speaking and prints the transcript.
  `finish` ends a recording without transcribing it, so a hotkey can end an
  auto-stop recording early without racing `dictate` for the same audio.
- Silence gating on peak *and* RMS energy before the model runs. whisper
  invents plausible filler when handed silent audio — "Thank you.", "Thanks
  for watching" — so a dead capture is discarded rather than transcribed.

### Getting words right

- **Vocabulary.** Terms in `~/.config/keybind-whisper/vocabulary` are fed to the
  model as an initial prompt, biasing decoding toward them. Framed as a
  sentence rather than a bare list: whisper imitates the prompt's style, and an
  unpunctuated fragment costs you capitalization in the transcript.
- **Replacements.** `find = replace` rules in
  `~/.config/keybind-whisper/replacements`, applied after transcription. Literal,
  case-insensitive, whole-word, so a rule for `arm` cannot rewrite the middle
  of `alarm`. Applied in a single left-to-right pass so a replacement is never
  rescanned and rules cannot cascade into each other.
- `replace TEXT` previews rules without recording.

### History

- Searchable transcription history: `list`, `show`, `last`, `copy`, `search`,
  `add`, `stats`, `export`, `clear`.
- Stored as JSONL at `~/.local/share/keybind-whisper/history.jsonl`, mode 0600
  inside a 0700 directory, capped at `KEYBIND_HISTORY_MAX` entries, and
  disabled entirely by `KEYBIND_HISTORY=0` — which creates no file at all.
- The Hammerspoon menu bar lists recent transcriptions and copies on click.
  Clicking does not paste: a menu click has already moved focus, so the paste
  could land in the wrong window. `pasteHotkey` covers paste-at-cursor.

### Diagnostics

- `doctor` resolves every dependency, lists audio devices, records three
  seconds, and reports the levels actually measured.
- `status` reports resolved configuration and current state.
- Timestamped log of every run, including measured audio levels. whisper's
  stderr goes to the log rather than `/dev/null`, so a failing model load does
  not look identical to silence.

### Notes for packagers and contributors

- Every external binary is resolved by absolute path. macOS gives
  GUI-launched processes `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which excludes
  Homebrew, so a bare `sox` works in a shell and fails with exit 127 under a
  hotkey daemon. The test suite runs under that restricted PATH to keep it
  that way.
- Bash targets 3.2, the version macOS ships.
- A strict output contract: exit 0 with text is a transcript, exit 0 without is
  a stated reason on stderr, non-zero is a failure. Nothing collapses a failure
  into silence.
