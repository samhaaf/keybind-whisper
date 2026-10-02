# Roadmap

What is planned, and what is deliberately not. Benchmarked against
[Superwhisper](https://superwhisper.com/), the polished commercial tool in this
space. Items are roughly in the order they are likely to be built.

## Next

**Regex replacement rules.** Rules are literal today, which is the right
default — the file stays editable without knowing regex syntax. A `/pattern/`
form would cover the cases literals cannot: numbers, units, and anything
position-dependent. The matcher already runs rule-by-rule in a single pass, so
this is additive.

**Silence threshold calibration.** `doctor` recommends a threshold from one
three-second sample. Measuring room noise and speech separately, over a longer
window, would make the recommendation trustworthy enough to apply
automatically. Auto-stop is opt-in largely because the threshold is currently a
guess the user has to validate.

**Per-application behaviour.** Different vocabulary and replacement sets
depending on the frontmost application — code identifiers in an editor, prose
elsewhere. The CLI already takes file paths for both, so the front end can
select them; what is missing is the matching logic and the configuration
format.

## Considered, not committed

**LLM cleanup of transcripts.** Removing filler words, fixing grammar, and
reflowing dictated text into prose. This is the feature most at odds with the
project's main claim: a local model is slow enough to be felt on every
dictation, and a hosted one means the text leaves the machine. If it is built
it will be opt-in, local-only by default, and clearly labelled where the text
goes.

**Streaming partial results.** Showing words as they are recognized rather than
after you stop. This needs a different whisper.cpp integration — a persistent
process fed a live buffer, rather than one invocation per capture — which is a
substantial rewrite of the recording path for a change that does not make the
final transcript any better.

**Hands-free voice activation.** Starting on a wake word rather than a hotkey.
It means holding the microphone open continuously, which is a meaningful
privacy change for a tool whose premise is that it only listens when asked.

## Not planned

**A cloud model option.** The point of this tool is that nothing leaves the
machine. Anyone wanting hosted accuracy is better served by a hosted tool.

**A GUI.** The CLI is the program and the Hammerspoon module is a thin front
end. Anything needing a window is better built on top than folded in.

## Released

For what has shipped, see [CHANGELOG.md](CHANGELOG.md).

## Contributing

Any of the committed items is a good place to start, as is anything in
[the comparison table](README.md#compared-to-superwhisper). Open an issue
first for the larger ones so the approach can be agreed before the work.
