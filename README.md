# whisper-local

Offline push-to-talk dictation for macOS. Press a key, speak, press it again —
the text is transcribed by [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
on your own machine and pasted at the cursor.

No account, no network, no audio leaving the computer.

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
installed, or set `WHISPER_LOCAL_MODEL`.

## Install

```sh
git clone https://github.com/YOUR-USERNAME/whisper-local ~/code/whisper-local
cd ~/code/whisper-local
./install.sh --hammerspoon
```

This symlinks the CLI into `~/.local/bin` and the Lua module into
`~/.hammerspoon`, so `git pull` updates them. It never edits your `init.lua`;
it prints the line to add:

```lua
require("whisper-local").setup({ hotkey = { { "alt" }, "space" } })
```

Reload Hammerspoon, then confirm everything works:

```sh
whisper-local doctor
```

macOS will ask for microphone access the first time you record. The permission
belongs to the app that *launches* the tool — Hammerspoon, or your terminal —
not to `whisper-local` itself.

## Usage

Press the hotkey, speak, press it again. The menu bar shows 🎙️ idle, 🔴
recording, ⏳ transcribing.

From the command line:

```sh
whisper-local start            # begin recording
whisper-local stop             # finish, print the transcript to stdout
whisper-local toggle           # start if idle, stop if recording
whisper-local transcribe FILE  # transcribe an existing audio file
whisper-local status           # current state and resolved configuration
whisper-local doctor           # check dependencies and test the microphone
```

`toggle` makes it easy to bind from any hotkey daemon:

```sh
whisper-local toggle | pbcopy
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

## History

Every successful transcription is stored, so a dictation you lost to the wrong
window or an overwritten clipboard is still recoverable.

```sh
whisper-local history                  # recent transcriptions, newest first
whisper-local history show 3           # entry 3 in full
whisper-local history last             # the most recent one
whisper-local history copy 2           # put entry 2 on the clipboard
whisper-local history search "domain"  # find past dictation by content
whisper-local history stats            # how much you have dictated
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
require("whisper-local").setup({
    hotkey      = { { "alt" }, "space" },  -- dictate
    pasteHotkey = { { "alt", "shift" }, "space" },  -- re-paste the last one
})
```

### Storage and privacy

History is dictated text, which can include anything you happened to say. It
is stored at `~/.local/share/whisper-local/history.jsonl`, mode `0600` inside a
`0700` directory, and never leaves the machine.

```sh
whisper-local history path             # where it lives
whisper-local history export           # raw JSONL, one object per line
whisper-local history clear --yes      # delete everything, permanently
```

To keep no history at all, set `WHISPER_LOCAL_HISTORY=0`. Nothing is written,
not even an empty file.

The format is JSONL — one self-contained JSON object per line — so it stays
greppable with ordinary tools and imports anywhere. To bring history in from
another tool:

```sh
whisper-local history add "text from somewhere else"
some-exporter | while IFS= read -r line; do whisper-local history add "$line"; done
```

## Configuration

Everything works unconfigured. To change something, copy
[`config/config.example`](config/config.example) to
`~/.config/whisper-local/config`:

| Setting | Default | Purpose |
|---------|---------|---------|
| `WHISPER_LOCAL_DEVICE` | *system default* | Pin one input device instead of following the OS |
| `WHISPER_LOCAL_MODEL` | best installed | Path to a ggml model |
| `WHISPER_LOCAL_LANG` | `en` | Spoken language, or `auto` |
| `WHISPER_LOCAL_THREADS` | whisper's choice | Decoding threads |
| `WHISPER_LOCAL_PEAK_MIN` | `0.0008` | Silence gate, peak amplitude |
| `WHISPER_LOCAL_RMS_MIN` | `0.0006` | Silence gate, RMS amplitude |
| `WHISPER_LOCAL_MIN_SEC` | `0.30` | Shortest capture worth transcribing |
| `WHISPER_LOCAL_MAX_SEC` | `1800` | Recording self-stops after this long |
| `WHISPER_LOCAL_HISTORY` | `1` | Set to `0` to store nothing |
| `WHISPER_LOCAL_HISTORY_FILE` | `~/.local/share/whisper-local/history.jsonl` | Where history lives |
| `WHISPER_LOCAL_HISTORY_MAX` | `1000` | Entries kept before the oldest are dropped |

Environment variables override the config file.

## Troubleshooting

Start with `whisper-local doctor`. It resolves every dependency, lists the
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
perfectly in your shell. `whisper-local` resolves every binary by absolute
path for exactly this reason, and the test suite runs under that restricted
PATH to keep it that way.

The log has a timestamped line for every run, including measured audio levels:

```sh
tail -f "$(whisper-local status | awk '/log/{print $2}')"
```

## Compared to Superwhisper

[Superwhisper](https://superwhisper.com/) is the polished commercial tool in
this space, and it is the benchmark worth measuring against. What it does that
this does not, as of now:

| | whisper-local | Superwhisper |
|---|---|---|
| Local transcription | yes | yes |
| Searchable history | yes | yes |
| Cost | free, MIT | paid |
| Scriptable CLI | yes | no |
| LLM cleanup of transcripts | no | yes |
| Custom vocabulary and replacements | no | yes |
| Streaming partial results | no | yes |
| Stop automatically on silence | no | yes |
| Per-application modes and prompts | no | yes |

The gaps are real. Custom vocabulary is the one most likely to matter day to
day: whisper reliably mangles proper nouns, product names and jargon, and no
amount of audio tuning fixes that. Contributions welcome.

## How it works

```
hotkey ─▶ whisper-local start ─▶ sox ─▶ 16 kHz mono WAV
hotkey ─▶ whisper-local stop  ─▶ silence gate ─▶ normalize ─▶ whisper.cpp
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

Thirty-seven checks covering dependency resolution, the output contract, the
silence and duration gates, stale-state handling, history storage and
retrieval, and a real end-to-end transcription.

No microphone is used: speech is synthesized to a file with `say -o`, which
renders silently. Every test runs with `PATH` reduced to what a GUI-launched
process gets, so the PATH class of bug cannot come back unnoticed.

## License

MIT
