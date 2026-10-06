# WhisperKit Upgrade — `tag-20261006` → `main`

**Merged:** 2026-10-06
**Fork:** `github.com/wangqi/WhisperKit` `main` @ `8cbcec9`
**Upstream base:** `argmaxinc/WhisperKit` main @ `f4e5d6b` (36 upstream commits, 2025-11-25 → 2026-09-25)
**Fork-side baseline:** `tag-20261006` @ `bcfe763` (the fork's head before the merge)
**Local integration docs:** `helper/docs/audio_asr.md`, `helper/docs/thirdparty_package_dependence.md`
**Primary consumer:** `libs/audio/WhisperKitASR.swift` (also `views/audio/whisper/WhisperModelManager.swift`,
`views/audio/whisper/WhisperModelDetailView.swift`, `testcases/audio/ASRSegmentWordsTests.swift`)

This is the largest upgrade the fork has taken: 112 files under `Sources/` and `Package.swift`,
+21,157 / −1,483. The repository is now a multi-kit SDK. It was renamed **`argmax-oss-swift`** and gained
two new libraries, **TTSKit** (Qwen3-TTS) and **SpeakerKit** (Pyannote diarization). A new
**`ArgmaxCore`** target holds the shared code.

For this app, the main effect is that **WhisperKit no longer depends on swift-transformers**. Upstream
vendored the Hub and Tokenizers code into `ArgmaxCore`. That retires every patch the fork carried. After
the merge the fork is **byte-identical to upstream**, with no `// wangqi modified` blocks left.

The app needed one source change (see "Breaking changes"). Both `AIAssistant` (iOS Simulator) and
`AIAssistantMac` build clean.

---

## Highlights

### Package structure
- **Renamed to `argmax-oss-swift` (#456).** The `WhisperKit` product name is unchanged, and the app links
  it through the local package reference `thirdparty/WhisperKit`, so `project.pbxproj` needed no edit.
- **New `ArgmaxCore` target (#455).** It holds shared utilities (`FoundationExtensions`,
  `MLMultiArrayExtensions`, `ConcurrencyUtilities`, logging) and the vendored Hub and Tokenizers code
  (from swift-transformers v1.1.6, marked `// Argmax-modification:`). `WhisperKit` does
  `@_exported import ArgmaxCore`, so `import WhisperKit` still exposes all of it.
- **New products:** `TTSKit`, `SpeakerKit`, an umbrella `ArgmaxOSS` library, `ArgmaxOSSDynamic`
  (#469, a dynamic-library variant) and the `argmax-cli` executable. `whisperkit-cli` is kept as an alias.
  **The app links none of the new products.** SwiftPM builds only the products a target depends on, so
  TTSKit and SpeakerKit code does not reach either app binary.
- **Dependencies are now just `swift-argument-parser`.** Vapor and OpenAPI are added only for
  `BUILD_ALL=1` CLI builds. `Package.resolved` shrank from about 27 pins (the swift-transformers and
  swift-huggingface closure: swift-nio, swift-crypto, yyjson, …) to one.
- **Platforms: iOS 16 / macOS 13 / watchOS 10 / visionOS 1.** The fork's iOS 17 / macOS 14 bump existed
  only for swift-transformers 1.2, so it was dropped. The app targets iOS 18.6 / macOS 26 regardless.

### Swift 6 concurrency
- **Swift 6 concurrency support (#458).** Public types gained `Sendable` conformances and actor
  annotations (36 files), and every target builds with `StrictConcurrency`. Our `@preconcurrency import
  WhisperKit` in `WhisperKitASR.swift` still compiles and is still appropriate.
- **`@Protected` around every `MLModel?` (#495).** A new property wrapper backed by
  `OSAllocatedUnfairLock` guards `AudioEncoder`, `TextDecoder` and `FeatureExtractor`, plus the
  TTSKit and SpeakerKit models. It closes a use-after-free when load or unload races inference. This
  matters to us: `WhisperKitASR` unloads on memory pressure and from `SystemMemoryHelper`.

### Transcription correctness (on our path)
- **Chinese word timestamps fixed (#511).** `NLLanguageRecognizer` returns `zh-Hans` / `zh-Hant`, but the
  no-space-language list in `splitToWordTokens` expects Whisper's `zh`. So Chinese never took the
  Unicode split path: clauses were glued into single "words" and then truncated by the 1.4 s
  max-word-duration heuristic. Simplified Chinese, Traditional Chinese and Cantonese all produced badly
  wrong word timings. **We hit this path.** `WhisperKitASR` sets `wordTimestamps:
  whisperModel.enableTimestamps`, and `ASRSegmentWordsTests` maps those words onto `ASRWord`.
- **Empty transcription with `promptTokens` fixed (#514).** If trimming left the prompt empty, the
  decoder was still sent a bare `<|startofprev|>`, which biases it toward ending the segment
  immediately. That is now skipped. The prefix is also capped so the prefill always leaves room for at
  least one sampled token. Negative ids in `suppressTokens`, including the `-1` "default non-speech"
  sentinel, are now ignored and logged instead of being written out of bounds. We don't pass
  `promptTokens` today, but `usePrefillPrompt: true` goes through the same prefill assembly.
- **`transcribeWithOptions` indexes per-element options globally (#512).** Previously the index reset in
  every batch, so element *n* of batch 2 used the options of element *n* of batch 1.
  We pass one `DecodingOptions` for everything, so this doesn't affect us.

### Audio input and streaming
- **Incremental file loading (#507).** The new `AudioInputOptions.audioLoadingMode` is either `.fullFile`
  (the default and the old behaviour) or `.incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)`.
  It streams a long file through the transcriber instead of decoding it all into memory first.
  `AudioInputConfig` remains as a typealias. **Not adopted.** `WhisperKitASR` passes already-decoded
  samples (`transcribe(audioArray:)`). This is a possible future memory win for long audio files.
- **Input suppression without pausing the engine (#401).** `AudioProcessor.setInputSuppressed(_:)` /
  `isInputSuppressed` replace captured buffers with silence (`vDSP_vclr`) and keep timing intact.
  Not used. We don't use WhisperKit's live capture.
- **Bluetooth teardown fix (#402).** `AudioProcessor.stopRecording` now resets the engine and disconnects
  the input node. That removes the StartIO and thread warnings on some Bluetooth devices.
- **`AudioStreamTranscriber` changes.** It gains `inputDeviceID` (#503), and recording now stops when
  streaming transcription exits on an error (#533; before, the mic stayed open). Not used: WhisperKit is
  our batch-only engine.

### Model download and loading
- **The local Hub cache is validated before use (#495).** `resolveRepo` used to serve the cache as soon as
  each pattern's directory existed and was non-empty. That let a partly downloaded `.mlmodelc` (missing
  `model.mil` or its `.metadata` sidecar) load and fail. Not on our path: we construct `WhisperKit` with
  `download: false` and a `modelFolder` that our own `DownloadManagerHF` filled.
- **A cancelled Hub snapshot download now throws (#534)** instead of returning as if it had succeeded.
  This is also only on WhisperKit's own downloader.
- **The model variant is no longer logged before it is detected (#536).**
- **`prewarm` is documented (#387).** The new `WhisperKitConfig` doc comment explains that it loads and
  unloads each model in turn to force Core ML specialization: lower peak memory, at the cost of roughly
  doubling load time when the specialization cache is already warm. We set `prewarm: true`, which is the
  right trade for a memory-constrained app that unloads aggressively.

### New kits (not adopted)
- **TTSKit (#425, #494, #513, #520, #521, #524, #464).** Qwen3-TTS on Core ML: multifunction
  `SpeechDecoder` and `MultiCodeDecoder` (stepped and fused) with per-schema dimension detection, legacy
  single-function assets, a `TextChunker` that uses Unicode sentence segmentation (#515), and playback
  that reuses a compatible iOS audio session (#464). It ships with an example app in
  `Examples/TTS/TTSKitExample/`. It could be a candidate engine next to `SherpaONNXSpeaker` and
  `CoreAIKokoroSpeaker`.
- **SpeakerKit (#440, #444, #452, #463).** Pyannote speaker diarization built on a reusable
  `ModelManager` base class. `DiarizationResult` exposes speaker centroid embeddings (#463). On macOS 14
  / iOS 17 it falls back to the `W32A32` segmenter, because `W8A16` needs iOS 18 / macOS 15 (#495). This is an alternative
  to the FluidAudio diarization we use today.

### Housekeeping
- GitHub Actions pinned to commit SHAs (#426) and Xcode pinned to 26 (#386). Python example
  dependencies bumped: urllib3 (#441), idna (#496). README model recommendations (#490). A typo fix,
  "supress" → "suppress" (#296).
- `ArgmaxCoreTests` vendors the swift-transformers v1.1.6 Hub and Tokenizers tests (#495).

---

## Breaking changes

### Hit by this app, and fixed
- **`TextDecoderContextPrefill` model removed (#467).** `DecodingOptions.usePrefillCache` and
  `ModelComputeOptions.prefillCompute` no longer exist. `WhisperKitASR.swift` passed both
  (`usePrefillCache: true`, `prefillCompute: .cpuOnly`). Both arguments were removed, and the local
  variable `nonPrefill` was renamed to `computeUnits`. Behaviour is unchanged: the prefill cache model is
  gone upstream, so the option no longer had anything to switch on. The keyboard background
  path still uses `.cpuAndNeuralEngine` for mel, encoder and decoder.

### Removed deprecated APIs (#466): none used by the app
- `WhisperKit.transcribe(audioPath:)` / `transcribe(audioArray:)` overloads returning
  `TranscriptionResult?`. Use the `[TranscriptionResult]` versions, which we already do.
- The `TextDecoding.decodeText` / `detectLanguage` overloads that took `MLMultiArray`.
- Top-level free functions, now on `ModelUtilities`, `TranscriptionUtilities`, `TextUtilities`, `Logging`
  and `FileManager`. Includes the free `resolveAbsolutePath(_:)` and `WhisperKit.formatModelFiles`.
- `ModelUtilities.getModelInputDimention` / `getModelOutputDimention` (misspelled). Use `…Dimension`.
- Synchronous `MLTensor.asIntArray()` / `asFloatArray()` / `asMLMultiArray()`. Use `await toIntArray()`
  and the other `to…` methods. As a result, **`TokenSampling.update(...)` is now `async`**.

---

## Fork patches retired

Every patch on `tag-20261006` was a workaround for swift-transformers, and `ArgmaxCore` now covers each
one. Keeping them would have caused ambiguous-overload errors, because `WhisperKit` re-exports
`ArgmaxCore`. They were therefore dropped in the merge rather than carried forward.

| Fork patch (on `tag-20261006`) | Replaced upstream by |
|---|---|
| `Package.swift`: swift-transformers `.upToNextMinor(from: "1.2.0")` (wangqi 2026-03-15) | Dependency removed (#455) |
| `Package.swift`: `.iOS(.v17)`, `.macOS(.v14)` (wangqi 2026-03-17) | Not needed without swift-transformers; back to iOS 16 / macOS 13 |
| `Extensions+Public.swift`: `Float.rounded(_:)` using Foundation `pow()` (wangqi 2026-04-12) | `ArgmaxCore/FoundationExtensions.swift` `Float.rounded(_:)` |
| `Extensions+Public.swift`: `String.trimmingFromEnd(character: String, upto:)` (Wangqi 2025-10-05) | `ArgmaxCore` `String.trimmingFromEnd(character: Character, upto:)` |
| `TextDecoder.swift`: `MLMultiArray.from(_:)` for `[Int]` / `[Float]` / `[Double]` (Wangqi 2025-10-05) | `ArgmaxCore/MLMultiArrayExtensions.swift` `MLMultiArray.from(_:dims:)` |
| `WhisperKit.swift`: `_wk_stringsMatching(_:glob:)` regex helper (Wangqi 2025-10-05) | `ArgmaxCore` `[String].matching(glob:)` (uses `fnmatch`) |

The fork's history before this merge (`tag-20261006`) records the swift-transformers upgrades these
patches supported: 0.1.8 → 1.0.0 → 1.1.0 → 1.2.0, then the iOS 17 / macOS 14 bump and the
`Float.pow` build fix.

---

## Verification

- `swift build --target WhisperKit` (macOS) succeeds, with warnings only.
- `xcodebuild -scheme AIAssistant -destination "platform=iOS Simulator,name=iPhone 18 Pro Max"`: **BUILD SUCCEEDED**.
- `xcodebuild -scheme AIAssistantMac -destination "platform=macOS"`: **BUILD SUCCEEDED**.
- Not yet run: `ASRSegmentWordsTests`, or a Chinese word-timestamp transcription on a device to confirm
  #511 end to end.

## Follow-ups to consider
1. Run `./run_tests.sh --no-build ASRSegmentWordsTests`, and add a Chinese case to it, since #511 changes
   the word splits we map onto `ASRWord`.
2. Evaluate `AudioInputOptions.audioLoadingMode = .incremental` for long file transcription. That means
   passing a path instead of pre-decoded samples.
3. Evaluate SpeakerKit against FluidAudio diarization, and TTSKit (Qwen3-TTS) as a TTS engine.
4. `helper/docs/thirdparty_package_dependence.md` already records WhisperKit leaving the
   HuggingFace/MLX dependency chain. The next upstream merge should be conflict-free unless the fork
   gains new patches.
