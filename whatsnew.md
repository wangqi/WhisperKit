# WhisperKit Upgrade — `tag-20261006` → `tag-20261024`

**Merged:** 2026-10-24
**Fork:** `github.com/wangqi/WhisperKit`, branch `tag-20261024` @ `3bb8200` (merge commit)
**Upstream:** `argmaxinc/argmax-oss-swift` `main` @ `9f99b5c`, release **v0.17.0**. 9 upstream commits,
2026-10-06 → 2026-10-10.
**Fork-side baseline:** `tag-20261006` @ `e9a6d11`
**Local integration docs:** `helper/docs/audio_asr.md`, `helper/docs/thirdparty_package_dependence.md`
**Consumers:** `libs/audio/WhisperKitASR.swift` (batch, `WhisperKitStreamSession`), reached through
`libs/audio/ASRHelper.swift`, `libs/audio/ASREngine.swift`, `libs/video/VideoAudioTranscriptHelper.swift`,
`ai/tool/localtools/ToolTranscribeMedia.swift`, `apps/keyboard/KeyboardSessionHandler.swift`;
`views/audio/whisper/WhisperModelManager.swift` and `WhisperModelDetailView.swift` import the module but
call no WhisperKit API (downloads go through `DownloadManagerCoreML`).

This is a small, low-risk release. 19 files changed, +391 / −180; 7 of them are under `Sources/`. The merge
was clean, and the fork is still byte-identical to upstream apart from this file (0 `wangqi modified`
blocks). `Package.swift` and `Package.resolved` did not change.

The item that matters most for the app is **#547**. A decoder step that returns no logits, or a sampler
that returns no token, used to hit a force-unwrap and crash the process. It now throws a `WhisperError`,
and every WhisperKit call site in the app already catches it. **The app needs no source change.**
Nothing in the range changes the decoding output for the same model and the same audio.

---

## Highlights

### Transcription (on our path)
- **Throw instead of crash on missing logits or sampled tokens (#547, `adf10e4`).** `TextDecoder`
  `detectLanguage` and `decodeText` now `guard` the `logits` output and `sampleResult.tokens.last` /
  `logProbs.last`, throwing `WhisperError.decodingLogitsFailed` or `.decodingFailed("Token sampler
  returned no tokens…")`. Before, a Core ML prediction whose output dictionary lacked `logits` (for example a
  damaged `TextDecoder.mlmodelc`, or a compute-unit failure) crashed the app. **We hit this path** on every
  transcription. `detectLanguage` runs whenever the language resolves to `nil` (`detectLanguage: true`).
  - Batch (`WhisperKitASR.transcribe`, `WhisperKitASR.swift:709-737`): `catch` → `ASRError.transcriptionFailed`.
  - Streaming pass (`passBody`, `:529-555`): logged, counted towards `maxConsecutiveFailures`, then the session closes.
  - Streaming final pass (`:433-454`): logged; confirmed and pending text are kept.
  - The detached batch APIs (`transcribe(audioPaths:)`, `transcribe(audioArrays:)`) wrap errors in
    `Result`, but we don't use them.

### Model loading
- **Overridable load and unload hooks (#553, `c88f830`).** `WhisperKit.loadModels(prewarmMode:)` now calls
  a new `open func loadModelComponents(prewarmMode:)`, and `unloadModels()` calls a new `open func
  unloadModelComponents()`. TTSKit gets the same pair. Two behaviour changes come with it:
  1. **A failed `loadModels` now calls `unloadModels()` before it rethrows**, so components that had already
     loaded are released and `modelState` ends `.unloaded`, not stuck at `.loading`.
  2. **`unloadModels()` now also sets `tokenizer = nil`**, so a later `loadModels()` on the same instance
     loads the tokenizer again.

  Neither change is visible to us. `WhisperKitASR.makeLoadTask` builds `WhisperKit(config)` with `load:
  true, prewarm: true, download: false`. A failed init drops the instance, which already freed its models.
  We never call `unloadModels()`: `WhisperKitASR.unloadModel()` drops the reference.

### Hugging Face Hub client (the tokenizer download reaches us)
The catalogue's model folders (`flyingfishinwater/whisperkit-coreml/<variant>/`) ship only the three
`.mlmodelc` folders plus `config.json` and `generation_config.json`, with **no `tokenizer.json`**. So on the
first load of each model family, `ModelUtilities.loadTokenizer` falls back to
`AutoTokenizerWrapper.from(pretrained: "openai/whisper-…")`, a Hub snapshot into the default
`Documents/huggingface` base. That puts the vendored Hub client on our path once per tokenizer.
- **HEAD stays HEAD across the Hub's relative redirects (#544, `9e49632`).** `RedirectDelegate` rebuilt
  the redirected request with `URLRequest(url:)`, which defaults to GET. Every non-LFS file that the Hub
  redirects with a relative 307 (`tokenizer.json`, `tokenizer_config.json`, …) was therefore downloaded in
  full just to read its metadata headers. That cost bandwidth and time on the first tokenizer fetch. It
  did not affect correctness.
- **HF token from environment only; auth errors carry the status code (#546, `7ab3483`).**
  `hfTokenFromEnv()` no longer reads `HF_TOKEN_PATH`, `HF_HOME/token`, `~/.cache/huggingface/token` or
  `~/.huggingface/token`; only `HF_TOKEN` and `HUGGING_FACE_HUB_TOKEN` remain. An empty token no longer
  sends an empty `Authorization: Bearer` header. `HubClientError.authorizationRequired` became
  `authorizationRequired(statusCode: Int?)`, and its message names the 401/403. **We pass no token**
  (`WhisperKitConfig` has no `token:`/`modelToken:` argument at our call site), and the sandboxed app has no
  such files or env vars. The only visible effect: a 401/403 on the tokenizer fetch now logs the status code
  in `WhisperKitASR: load of … failed: …`. `HubClientError` is internal, so no app code can switch on it.
- **`useBackgroundDownloadSession` reaches the config fetch (#461, `fd7b63a`).** `recommendedRemoteModels`
  and `fetchModelSupportConfig` gain `useBackgroundSession: Bool = false`, which `setupModels` passes
  through. Not on our path: we always name the model, and use neither API.

### TTSKit and SpeakerKit (not linked by the app)
- **TTSKit:** the load and unload hooks (#553); `GreedyTokenSampler.sampleFromProbs` returns the top-1 index
  when every top-k probability underflows to zero, where it used to call `Float.random(in: 0..<0)` and trap
  (#459, `ef41e03`); `TextChunker` strips trailing whitespace before re-tokenizing the accepted prefix, so the
  first word of the next sentence is no longer swallowed (#548, `93a97e3`).
- **SpeakerKit:** a one-line test change only (`SpeakerCentroidEmbeddingsTests`).

### Housekeeping
- CI on macOS 27, drops macOS 14 runners, faster simulator unit tests (#545). New `model-cache.yml`,
  `expo-update.yml` removed, release automation updated (#552). `Package.swift` platforms unchanged
  (iOS 16 / macOS 13).
- New tests: `HubApiTests` (empty token, HEAD redirect), `UnitTests` (no-logits throw, load-failure
  unload), `TTSKitUnitTests` (zero-sum sampling, chunker word kept).

---

## Public API

| Symbol | Change | Our usage / fix |
|---|---|---|
| `WhisperKit.loadModelComponents(prewarmMode:)` | New `open` hook called by `loadModels` | Not used. Opportunity only |
| `WhisperKit.unloadModelComponents()` | New `open` hook called by `unloadModels` | Not used |
| `WhisperKit.loadModels(prewarmMode:)` | Unloads on failure; state logic moved out of the body | No change. Init failure already drops the instance |
| `WhisperKit.unloadModels()` | Also clears `tokenizer` | Never called by the app |
| `WhisperKit.recommendedRemoteModels(…)`, `fetchModelSupportConfig(…)` | `+ useBackgroundSession: Bool = false` (defaulted, source-compatible) | Not used |
| `TextDecoder.detectLanguage` / `decodeText` | Throw `WhisperError` instead of force-unwrap crash | Already `try` inside `do/catch` at every site (above) |
| `Hub.HubClientError.authorizationRequired` | Now `(statusCode: Int?)` | Internal type, not visible to the app |
| `TTSKit.loadModelComponents` / `unloadModelComponents` | New `open` hooks | TTSKit not linked |

## Breaking changes

None for this app. Every signature change is either defaulted or on an internal type. The app needs no
source change.

## Conflicts and fork patches

Clean merge, no conflicts. Fork patch inventory: **0 → 0** `wangqi modified` blocks; `git diff upstream/main
tag-20261024` touches only `whatsnew.md`.

## Dependencies

No dependency move. `Package.swift` and `Package.resolved` are identical to `tag-20261006` (one pin,
`swift-argument-parser`).

---

## Risk assessment — 3 risks (0 high, 1 medium, 2 low)

### R1 — No WhisperKit model regression gate (MEDIUM)
**Problem:** No runner covers the Whisper catalogue. A green P1/P10 shows the package compiles and the
streaming core behaves, but not that all 13 catalogue models still load and transcribe.
**Verify:** On a simulator and a device, load `whisper-base` and `whisper-large-v3-v20240930_turbo_632MB` in
ASR Test and transcribe `coreai_asr_sample.wav`. Compare with the pre-upgrade transcript.
**Status:** needs device.

### R2 — Former crash now a transcription error (LOW)
**Problem:** #547 turns a process crash into a thrown error. A model that used to crash now fails "quietly":
an `ASRError.transcriptionFailed` in batch, a closed session after `maxConsecutiveFailures` in streaming. In
streaming the user sees dictation stop, not an error message.
**Verify:** `grep -n "pass failed\|final pass failed\|transcriptionFailed" libs/audio/WhisperKitASR.swift`
shows every path logs. On a device run, check `WhisperKitASR` logs for `decodingLogitsFailed` /
`Token sampler returned no tokens`.
**Status:** code-reviewed; nothing to run.

### R3 — First-run tokenizer fetch behaviour (LOW)
**Problem:** #544 and #546 change the Hub client that fetches `openai/whisper-*` tokenizers on first load. A
HEAD that now stays HEAD could in principle hit a Hub response the old GET path tolerated.
**Verify:** On a clean simulator, delete `Documents/huggingface/models/openai/`, then load a Whisper model.
The log shows no `load of … failed`, and `tokenizer.json` appears under that folder.
**Status:** needs a run (simulator is enough).

## New models

Upstream ships no models with the SDK, and the `argmaxinc/whisperkit-coreml` repo was last modified on
2026-08-19, before this range. Variants within the 700 MB ASR limit that are missing from the catalogue:
`distil-whisper_distil-large-v3_turbo_600MB` and `openai_whisper-large-v3-v20240930_626MB`. Both are
**candidates only**: no row can be added until a regression runner exists. Everything else in that repo
is already in the catalogue or over the size limit (`large-v2*`, `large-v3*` full, `medium*`).

## Opportunities (not built)

| Upstream feature | Consumer that would use it | Value |
|---|---|---|
| `loadModelComponents(prewarmMode:)` hook (#553) | `WhisperKitASR.makeLoadTask` via a `WhisperKit` subclass | Per-component load control (e.g. load the decoder lazily, or retry the encoder on CPU after an ANE compile failure). Low: `WhisperComputePlan` already covers compute placement |
| Tokenizer folder | `WhisperKitASR` `WhisperKitConfig(tokenizerFolder:)` | Pre-existing gap, not new in this range: the first load fetches the tokenizer from Hugging Face into `Documents/huggingface`, outside `get_destination_url`. Bundling it with the model download, or pointing `tokenizerFolder` at `WHISPER_MODELS`, would make the first load work offline |
| TTSKit fixes (#459, #548) | A future TTSKit speaker next to `SherpaONNXSpeaker` / `CoreAIKokoroSpeaker` | Makes TTSKit more robust if it is ever adopted |

## Verification

- **No WhisperKit model regression gate** exists; see R1.
- P1 baseline (pre-merge): `WhisperKitASRConfigTests` 16, `WhisperKitStreamSessionTests` 11,
  `WhisperStreamConfirmerTests` 12, `WhisperStreamSchedulerTests` 10, `WhisperReadinessTests` 5,
  `ASRSegmentWordsTests` 10, all green.
- `swift build` in `thirdparty/WhisperKit`: `Build complete!` (warnings only).
- P10 still to run: the same six suites after the merge, plus both app builds (`AIAssistant` iOS Simulator,
  `AIAssistantMac`).

## Follow-ups to consider
1. Build `run_whisperkit_tests.py` (one `xcodebuild` per `whisper_model_test.json` row, transcript vs the
   `coreai_asr_sample.wav` oracle), so future merges and the two candidate models can be gated.
2. Move the tokenizer fetch under `get_destination_url`, or bundle it with the model download (see
   Opportunities).
