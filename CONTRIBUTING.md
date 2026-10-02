# Contributing

## Getting set up

```sh
git clone https://github.com/YOUR-USERNAME/whisper-local
cd whisper-local
./bin/whisper-local doctor     # confirms dependencies and the microphone
./test/run-tests.sh            # no microphone needed
```

## Running the tests

```sh
./test/run-tests.sh            # the shell CLI, end to end
lua test/test-hammerspoon.lua  # the Lua module against a stubbed hs API
```

The suite needs no microphone: speech is synthesized to a file with `say -o`,
which renders silently. It does need sox, whisper.cpp and a model, because the
end-to-end checks transcribe real audio.

## Two rules that matter here

**Never rely on `PATH`.** macOS gives GUI-launched processes
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, which excludes Homebrew. A bare `sox`
works perfectly in your shell and fails with exit 127 under a hotkey daemon.
That bug is the reason this project exists in this shape: it produced an empty
transcript on every run and swallowed its own error. Resolve binaries through
`resolve_bin`, and note that the test suite runs under that restricted PATH
specifically so this cannot come back.

**A green test you have never seen fail is not evidence.** Before trusting a
new test, break the thing it covers and confirm it goes red. Several real bugs
in this codebase were found exactly this way, and at least one test initially
passed against a reintroduced defect because it asserted too loosely.

## Style

- Bash targets 3.2, the version macOS ships. No bash 4+ syntax.
- `stdout` is only ever the transcript. Diagnostics go to stderr and the log.
- Every failure gets a specific message. Dictation that quietly produces
  nothing is the failure mode this tool exists to avoid, so never collapse an
  error into "nothing heard".
- Comments explain *why*, especially where the code looks odd. Most of the odd
  code here is load-bearing.

## Submitting

Open an issue first for anything in [ROADMAP.md](ROADMAP.md) under "Considered"
or larger, so the approach can be agreed before the work. Smaller fixes can go
straight to a pull request. Include a test, and say in the description what you
did to confirm the test actually fails without your change.
