# keybind-whisper

[![CI](https://github.com/samhaaf/keybind-whisper/actions/workflows/ci.yml/badge.svg)](https://github.com/samhaaf/keybind-whisper/actions/workflows/ci.yml)

Offline push-to-talk dictation for macOS. Press a key, speak, press it again —
the text is transcribed by [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
on your own machine and pasted at the cursor.

No account, no network, no audio leaving the computer.

The name is the point of the design: dictation is *bound to a key*. Press it,
talk, press it again. Nothing listens until you ask it to.

- **Follows the system default microphone.** Whatever you pick in System
  Settings is what it records, like any other app. Nothing to configure.
- **Never pastes hallucinated text.** whisper invents plausible filler when
  handed silent audio — "Thank you.", "Thanks for watching". A silent capture
  is detected and discarded before the model ever sees it.
- **Says what went wrong.** Every failure has a specific message. Dictation
  that quietly produces nothing is the failure mode this tool is built to avoid.
- **Usable without a GUI.** The CLI is the whole program; the Hammerspoon
  module is a thin front end. Bind it to any hotkey daemon, or script it.
- **Keeps what you dictated.** Every transcription is stored, searchable, and
  re-pastable — dictation you can go back to, not just a log file.
- **Learns your words.** Proper nouns and jargon are biased toward during
  decoding and corrected deterministically afterwards.

## Requirements

- macOS
- [sox](http://sox.sourceforge.net/) — `brew install sox`
- whisper.cpp, built, plus a ggml model
- Optional: [Hammerspoon](https://www.hammerspoon.org/) for the hotkey binding
- Optional: `brew install switchaudio-osx` so `doctor` can name audio devices

Building whisper.cpp and fetching a model:

```sh
git clone https://github.com/ggerganov/whisper.cpp ~/code/whisper.cpp
cd ~/code/whisper.cpp && cmake -B build && cmake --build build -j --config Release
./models/download-ggml-model.sh large-v3-turbo
```

`large-v3-turbo` is a good default: near the accuracy of `large-v3` at a
fraction of the time. Any ggml model works — the tool finds the best one
installed, or set `KEYBIND_MODEL`.

## Install

```sh
curl -fsSL https://github.com/samhaaf/keybind-whisper/raw/main/install.sh | bash
```

That installs the command, installs `sox` if Homebrew is present, links the
Hammerspoon module, adds one line to your `init.lua`, and reloads Hammerspoon.
It backs up anything it touches and running it twice changes nothing. Then
press ⌥Space, speak, and press it again.

On a machine with no whisper.cpp yet, add `--whisper` to build it and fetch a
model (a compile and about 1.6 GB, which is why it is not the default):

```sh
curl -fsSL https://github.com/samhaaf/keybind-whisper/raw/main/install.sh | bash -s -- --whisper
```

<details>
<summary>Options, and installing from a clone</summary>

```sh
git clone https://github.com/samhaaf/keybind-whisper
cd keybind-whisper && ./install.sh
```

Run from a checkout it installs *that* checkout, so your edits are what runs.
Piped from curl it clones itself to `~/.local/share/keybind-whisper/src`. Either
way the command is a symlink, so `git pull` updates it.

| Flag | Effect |
|---|---|
| `--no-deps` | Skip Homebrew dependency installation |
| `--no-hammerspoon` | Install the command only |
| `--no-wire` | Link the Hammerspoon module but do not edit `init.lua` |
| `--whisper` | Also build whisper.cpp and download a model |
| `--prefix DIR` | Install the command into `DIR/bin` (default `~/.local`) |
| `--uninstall` | Remove everything the installer added |

macOS will ask for microphone access the first time you record. The permission
belongs to the app that *launches* the tool — Hammerspoon, or your terminal —
not to `keybind-whisper` itself. Pasting synthesizes ⌘V, which needs
Accessibility permission for the same app.

</details>

Confirm it works:

```sh
keybind-whisper doctor
```

## Usage

Press the hotkey, speak, press it again. The menu bar shows 🎙️ idle, 🔴
recording, ⏳ transcribing.

From the command line. The Hammerspoon module calls the executable by absolute
path, so the command name only matters if you type it yourself — and if you do,
symlink it to something shorter:

```sh
ln -s ~/.local/bin/keybind-whisper ~/.local/bin/stt
```

```sh
keybind-whisper start            # begin recording
keybind-whisper stop             # finish, print the transcript to stdout
keybind-whisper toggle           # start if idle, stop if recording
keybind-whisper transcribe FILE  # transcribe an existing audio file
keybind-whisper status           # current state and resolved configuration
keybind-whisper doctor           # check dependencies and test the microphone
```

`toggle` makes it easy to bind from any hotkey daemon:

```sh
keybind-whisper toggle | pbcopy
```

### Output contract

Scripts can rely on this:

| Exit | stdout | Meaning |
|------|--------|---------|
| 0 | the transcript | Speech was recognized |
| 0 | empty | Nothing usable was heard; stderr says why |
| non-zero | empty | A real failure; stderr carries the message |

stdout is only ever the transcript, so it is safe to paste blind. Diagnostics
go to stderr and to the log.

## Getting your words right

whisper reliably mangles proper nouns, product names and jargon, and no amount
of audio tuning fixes it. Two mechanisms address this, because they fail
differently.

**Vocabulary** biases the model while it decodes. Put one term per line in
`~/.config/keybind-whisper/vocabulary`:

```
arm64
Kubernetes
PostgreSQL
```

This works when the model is already close — "Postgres" becomes "PostgreSQL" —
but it is a nudge, not a guarantee. When a word is acoustically far from the
term you wanted, biasing will not rescue it.

**Replacements** fix what the model gets wrong anyway, deterministically. Put
`find = replace` lines in `~/.config/keybind-whisper/replacements`:

```
# comments and blank lines are ignored
arm sixty four = arm64
post gres      = PostgreSQL
kay eight s    = k8s
```

Matching is literal, case-insensitive, and whole-word, so a rule for `arm`
cannot rewrite the middle of `alarm`. Rules are tried in file order and the
first match wins, so **list longer phrases before shorter ones they contain**.
A replacement is never rescanned by a later rule, so rules cannot cascade into
each other. An empty replacement deletes the term and reflows the spacing.

Preview rules against any text without recording:

```sh
keybind-whisper replace "deploy the arm sixty four build"
# deploy the arm64 build
```

## Stopping automatically

By default dictation is push-to-talk: the hotkey starts it and the hotkey stops
it. To end a recording once you stop speaking instead:

```sh
KEYBIND_SILENCE_SEC=2 keybind-whisper dictate
```

or in Hammerspoon:

```lua
require("keybind-whisper").setup({
    hotkey   = { { "alt" }, "space" },
    autoStop = 2,   -- seconds of silence that end the recording
})
```

The hotkey still ends a recording early. This is off by default because the
silence threshold depends on your room and microphone: too high and quiet
speech never registers, too low and room noise never counts as a pause.
`keybind-whisper doctor` measures your actual levels and recommends a value:

```
  speech peaked at 34.20% of full scale
  for auto-stop, try: KEYBIND_SILENCE_THRESHOLD="8.6%"
```

## History

Every successful transcription is stored, so a dictation you lost to the wrong
window or an overwritten clipboard is still recoverable.

```sh
keybind-whisper history                  # recent transcriptions, newest first
keybind-whisper history show 3           # entry 3 in full
keybind-whisper history last             # the most recent one
keybind-whisper history copy 2           # put entry 2 on the clipboard
keybind-whisper history search "domain"  # find past dictation by content
keybind-whisper history stats            # how much you have dictated
```

```
   1  2026-04-18 09:14:02  Ask about the quarterly numbers in tomorrow's meeting
   2  2026-04-18 09:13:44  The build is failing on the arm64 runner
   3  2026-04-18 09:13:41  Remember to renew the domain before the thirtieth
```

Index 1 is always the most recent, so `show 2` means "the one before last".

In Hammerspoon, the menu bar lists recent transcriptions and clicking one
copies it. To re-paste the last thing you dictated without recording again,
bind a second hotkey:

```lua
require("keybind-whisper").setup({
    hotkey      = { { "alt" }, "space" },  -- dictate
    pasteHotkey = { { "alt", "shift" }, "space" },  -- re-paste the last one
})
```

### Storage and privacy

History is dictated text, which can include anything you happened to say. It
is stored at `~/.local/share/keybind-whisper/history.jsonl`, mode `0600` inside a
`0700` directory, and never leaves the machine.

```sh
keybind-whisper history path             # where it lives
keybind-whisper history export           # raw JSONL, one object per line
keybind-whisper history clear --yes      # delete everything, permanently
```

To keep no history at all, set `KEYBIND_HISTORY=0`. Nothing is written,
not even an empty file.

The format is JSONL — one self-contained JSON object per line — so it stays
greppable with ordinary tools and imports anywhere. To bring history in from
another tool:

```sh
keybind-whisper history add "text from somewhere else"
some-exporter | while IFS= read -r line; do keybind-whisper history add "$line"; done
```

## Configuration

Everything works unconfigured. To change something, copy
[`config/config.example`](config/config.example) to
`~/.config/keybind-whisper/config`:

| Setting | Default | Purpose |
|---------|---------|---------|
| `KEYBIND_DEVICE` | *system default* | Pin one input device instead of following the OS |
| `KEYBIND_MODEL` | best installed | Path to a ggml model |
| `KEYBIND_LANG` | `en` | Spoken language, or `auto` |
| `KEYBIND_THREADS` | whisper's choice | Decoding threads |
| `KEYBIND_PEAK_MIN` | `0.0008` | Silence gate, peak amplitude |
| `KEYBIND_RMS_MIN` | `0.0006` | Silence gate, RMS amplitude |
| `KEYBIND_MIN_SEC` | `0.30` | Shortest capture worth transcribing |
| `KEYBIND_MAX_SEC` | `1800` | Recording self-stops after this long |
| `KEYBIND_HISTORY` | `1` | Set to `0` to store nothing |
| `KEYBIND_HISTORY_FILE` | `~/.local/share/keybind-whisper/history.jsonl` | Where history lives |
| `KEYBIND_HISTORY_MAX` | `1000` | Entries kept before the oldest are dropped |
| `KEYBIND_SILENCE_SEC` | `0` | Seconds of silence that end a recording; `0` disables |
| `KEYBIND_SILENCE_THRESHOLD` | `2%` | Amplitude below which audio counts as silence |
| `KEYBIND_VOCAB_FILE` | `~/.config/keybind-whisper/vocabulary` | Terms to bias decoding toward |
| `KEYBIND_REPLACEMENTS_FILE` | `~/.config/keybind-whisper/replacements` | Post-transcription fix-ups |

Environment variables override the config file.

## Troubleshooting

Start with `keybind-whisper doctor`. It resolves every dependency, lists the
audio devices, records three seconds, and prints the levels it measured.

**"silent capture"** — the microphone produced near-zero samples. Either the
app launching the tool lacks microphone permission (System Settings > Privacy
& Security > Microphone), or the selected input is not delivering audio.
Bluetooth headsets are a common cause: many expose an input that stays silent
until macOS switches them to their headset profile, which also degrades
playback quality. A wired or built-in microphone is more reliable.

**Nothing pastes, but the transcript looks right** — pasting synthesizes ⌘V,
which needs Accessibility permission for the launching app.

**It works in a terminal but not from the hotkey** — this is the classic one.
GUI-launched processes on macOS inherit `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
which excludes Homebrew, so a bare `sox` fails with exit 127 while working
perfectly in your shell. `keybind-whisper` resolves every binary by absolute
path for exactly this reason, and the test suite runs under that restricted
PATH to keep it that way.

The log has a timestamped line for every run, including measured audio levels:

```sh
tail -f "$(keybind-whisper status | awk '/log/{print $2}')"
```

## Compared to Superwhisper

[Superwhisper](https://superwhisper.com/) is the polished commercial tool in
this space, and it is the benchmark worth measuring against. What it does that
this does not, as of now:

| | keybind-whisper | Superwhisper |
|---|---|---|
| Local transcription | yes | yes |
| Searchable history | yes | yes |
| Cost | free, MIT | paid |
| Scriptable CLI | yes | no |
| Custom vocabulary and replacements | yes | yes |
| Stop automatically on silence | yes | yes |
| LLM cleanup of transcripts | no | yes |
| Streaming partial results | no | yes |
| Per-application modes and prompts | no | yes |

The remaining gaps are real, and [ROADMAP.md](ROADMAP.md) says which are
planned and which are deliberately not. The short version: per-application
modes are next, streaming is a large rewrite for no gain in final accuracy, and
LLM cleanup is the one feature genuinely at odds with "nothing leaves the
machine".

## How it works

```
hotkey ─▶ start ─▶ sox ─▶ 16 kHz mono WAV          ◀── auto-stop ends this
hotkey ─▶ stop  ─▶ silence gate ─▶ normalize ─▶ whisper.cpp ◀── vocabulary
                                                   │
                                          replacements
                                                   │
                                         stdout ─▶ paste
                                                   └─▶ history.jsonl
```

Recording is a backgrounded `sox` process writing 16 kHz mono 16-bit — whisper's
native format, so nothing is resampled later. On stop, the capture is measured
before anything else: if peak *or* RMS energy is below the floor, it is
discarded without being transcribed. A real capture is peak-normalized to about
-1 dBFS so a low-gain microphone lands in the range the model was trained on,
then decoded with a bounded text context, which prevents the repeat-loops
whisper can fall into on long audio. Non-speech annotations (`[BLANK_AUDIO]`,
`*music*`) are stripped and the result flattened to one line.

## Tests

```sh
./test/run-tests.sh
```

Sixty-six checks covering dependency resolution, the output contract, the
silence and duration gates, stale-state handling, history storage and
retrieval, the replacement matcher, auto-stop, state-directory safety, the
installer under `curl | bash`, and a real end-to-end transcription.

The Lua module has its own harness, which loads it against a stubbed
Hammerspoon API:

```sh
lua test/test-hammerspoon.lua
```

Hammerspoon only raises an error when the offending line actually runs, so a
mistake like calling a helper declared further down the file stays invisible
until someone presses the hotkey. This turns that into a test failure.

No microphone is used: speech is synthesized to a file with `say -o`, which
renders silently. Every test runs with `PATH` reduced to what a GUI-launched
process gets, so the PATH class of bug cannot come back unnoticed.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and the two conventions that
matter most here, and [ROADMAP.md](ROADMAP.md) for what is planned.
[CHANGELOG.md](CHANGELOG.md) records what has changed.

## License

MIT
