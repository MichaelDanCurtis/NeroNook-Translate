# Milestone 2a · the plugin app and the self-test loop

**October 20, 2026 (late evening) · local only · reference Mac: Mac16,5 (M4 Max, 128 GB), macOS 27.0.1, Swift 6.4**

The decision of the evening (D‑4/D‑5: Apple by default, an optional Qwen recognition pack) made the first app milestone concrete: the application the NeroNook host launches, with one working lane from the microphone to the speakers through Apple recognition, Apple translation and Qwen TTS in the speaker's own voice. No process tap, no driver, no call: those need the owner's approvals and come next.

## What exists now

- **`TranslateApp`** (`Sources/TranslateApp`): the application-mode plugin. Under the host (`--neronook-plugin`) it runs as an accessory, connects to the host's loopback port with the token from the environment, answers `hello` with `ready` at sequence 0 (`appearance-v1`, `panels-v1`, `actions-v1` as offered), publishes a snapshot every second (title, status, activity, languages, voice, engine) with a 2 s heartbeat that stops after 30 s without a main-thread publish, opens the session window on the host's `configure`/`open` action, starts and stops on `start`/`stop`, and exits when the channel ends. `--protocol-test` runs the same handshake over stdio. Run directly, the session window opens at once; `--self-test <recording> [--hear]` feeds a recording through the pipeline headlessly and prints the captions.
- **`TranslateLive`**: `AppleRecognitionStream` (SpeechAnalyzer with volatile results on 16 kHz chunks; assets reserved and installed for this app on first use), `AppleTranslation` (one prepared session per pair), `SynthesisQueue` (Core's `UnitSplitter` → the engine → playback, finish-and-discard on stop), `LiveSession` (the state machine: preparing → listening → stopping, captions, levels, configuration persisted under the plugin folder), `HelperLocator` and `ModelLocator`.
- **`TranslateAudio`**: `MicrophoneCapture` (AVAudioEngine tap → 16 kHz mono chunks, device choice, level, failure on configuration change), `SpeechPlayback` (player node on the default output, conversion per sample rate, `drain`, `stop`, level from a tap), `AudioDevices`, `PCMBuffers`, `ChunkAccumulator`; 21 tests, none touching a device.
- **`scripts/package.py`** stages and signs `Translate.app` (Info.plist with the usage descriptions, audio-input entitlement, helpers and metallib signed with the hardened runtime, size and symlink checks, nothing installed) and **`scripts/protocol-test.py`** exercises the stdio handshake; both carry self-checks. `Resources/TranslateApp-Info.plist` is embedded into the bare development binary so it has a bundle identifier and the microphone and speech-recognition usage descriptions.
- Package: three new targets and two test targets; the app carries the same SDK-stamp linker flag as the harness (Apple Translation).

## Verified

| Check | Result |
| --- | --- |
| `swift build`, `swift test` | pass; 114 tests across six bundles |
| `scripts/protocol-test.py .build/debug/TranslateApp` | PASS: ready at sequence 0 with the three features, 3 snapshots and a heartbeat in 2.3 s, keeps running after `configure`, exits 0 on EOF |
| Direct launch | the session window opens; the process is still alive after 6 s |
| Headless self-test on the owner's 17.8 s reference take (`self-test-reference-take.txt`) | 6 phrases recognized and all 6 translated en→es in 19.5 s at real-time pace; engine started and stopped cleanly |
| `scripts/package.py --dry-run` | every check passes except the two expected ones: no signing identity in the environment, and (before this build) no release app |

## Not verified, and what it taught

- **The microphone loop itself** (permission prompt, capture, hearing the translation in your voice) needs a person at the Mac; the audio layer's capture and playback paths are unit-tested but have not opened a device. `--self-test --hear` plays the translation through the speakers and is the quickest check once someone is there.
- **Launch under the real host** needs a signed, installed bundle: `scripts/package.py` has only run in dry mode because no signing identity is set (`NERONOOK_SIGNING_IDENTITY`, or `--identity`).
- **Speech assets are per client.** The English assets the harness installed showed as not installed to the app's bundle identifier; the app now reserves the locale and installs on first use (a registration when the Mac already holds them). Any new language the user picks downloads the same way.
- **Apple's endpointing fragments phrases.** "not one point two" came back as "not one." and "2.", each translated alone. The commit rule needs a merge for very short fragments (or a pause threshold) before the live work; noted for Milestone 3.
- **One lane, simple queue.** The self-test uses one direction and a FIFO synthesis queue; the two-lane scheduler, epochs and journal from Milestone 1a are not wired yet (Milestone 3).

## Next

1. The owner runs `.build/debug/TranslateApp`, allows the microphone, picks a reference clip (the `reference.wav` take with its three sentences works), presses Start and speaks; then `--self-test Fixtures/Corpus/raw/en/reference.wav --hear` for the spoken side.
2. `scripts/package.py --identity <certificate>` and an install through NeroNook Settings → Modules, for the hosted path.
3. Milestone 2: the process tap and the driver (owner approvals), then Milestone 3's two lanes on this app.
