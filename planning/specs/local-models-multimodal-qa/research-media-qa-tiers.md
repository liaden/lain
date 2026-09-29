# Media, voice, and tiered QA for lain: research notes, 2026-09-22

Scope: image, audio, and video input to local models (Ollama 0.32.12 on an RX 7900 XTX), speech-to-text and text-to-speech, the voice → notes → plan pipeline, screenshot and video QA, and cheapest-first QA cascades.
Evidence levels: **[SRC]** means I read the source code (Ollama tag v0.32.12, commit e0e1d3c7, dated 2026-08-14). **[LIVE]** means I ran it against the local Ollama 0.32.12 on 2026-09-22. **[DOC]** means vendor docs, fetched 2026-09-22. **[UNVERIFIED]** means a secondary source or my memory.

Version note: the latest Ollama release is **v0.34.2** (2026-09-15), and **v0.34.3-rc1** came out 2026-09-19. The local install is 0.32.12. Everything below describes 0.32.12 unless it says otherwise. Source: `gh api repos/ollama/ollama/releases`.

---

## 1. Image input to Ollama

**Wire shape**
- `messages[].images` is an array of base64 strings, per message. The docs say "Base64-encoded image content… Optional list of inline images for multimodal models" [DOC https://docs.ollama.com/api/chat]. The SDKs also accept file paths and raw bytes; the REST API needs base64 [DOC https://docs.ollama.com/capabilities/vision].
- `api.Message` is `{role, content, thinking, images, tool_calls, tool_name, tool_call_id}`. `images` is a field on **every** message and is not limited to the user role [SRC api/types.go].
- **Tool-role images work.** `imageTaggedMessages` walks all messages without filtering by role, and every image becomes media [SRC server/prompt.go:94-132]. On the llama-server chat path, any role's media is turned into OpenAI-style content parts (`image_url` data URI) [SRC llm/llama_server.go:2199-2258].
  - [LIVE] I sent `gemma4:e4b` a `role:"tool"` message carrying a PNG. It correctly read "ERROR 4172 overlap" out of the image. Prompt eval was only 113 tokens, which is consistent with Gemma 4's small default vision token budget.
  - Whether a given model *renders* a tool-role image depends on its template or renderer. Ollama issue #18426 (2026-09-13, open) reports that `kimi-k3:cloud` returns HTTP 500 on tool-role images while kimi-k2.6 and glm-5.3-flash accept them. Its reference processor filters vision input to the user role only. https://github.com/ollama/ollama/issues/18426
  - Issue #16332 (2026-05-27, open) asks for images in "any message type". It is stale relative to current code. https://github.com/ollama/ollama/issues/16332
  - The stdapi.ai issue #255 (2026-09-17) about images being "silently dropped" on tool, assistant, and system roles is a bug in **their adapter**, not in Ollama. https://github.com/stdapi-ai/stdapi.ai/issues/255
- **Limits**
  - The docs state no size, count, or format limit [DOC].
  - Media type is sniffed from the bytes with `http.DetectContentType`, and anything that is not an image is sent as `image/jpeg` [SRC llm/llama_server.go:2248]. In practice that means PNG, JPEG, GIF, WebP, and BMP.
  - The only hard count limit in the code is for the `mllama` family: one image per message [SRC server/prompt.go:99].
  - For context truncation, Ollama counts each image as **768 tokens** whatever its real cost. A TODO in the code admits this is wrong [SRC server/prompt.go:27-30].
  - The context window is the practical cap.

**Models, from local `/api/show` [LIVE] and the library page [DOC]**

| model | capabilities | ctx |
|---|---|---|
| qwen3.8:27b | completion, **vision**, tools, thinking | 262,144 |
| gemma4:e4b | completion, **vision, audio**, tools, thinking | 131,072 |
| muse-glimmer:30b | completion, **vision**, tools, thinking | 131,072 |
| ornith-1.5:9b | not installed | 256K |

- ornith-1.5:9b: the ollama.com library page lists "Vision, Text" only, with no tools or thinking badge. Sizes are 9B (6.6 GB), 35B (23 GB), and 397B [DOC https://ollama.com/library/ornith-1.5]. Tool support is **[UNVERIFIED]**: pull the model and check `/api/show` capabilities.
- On the Gemma 4 family, only E2B and E4B take audio. All sizes take images, with configurable vision token budgets of 70, 140, 280, 560, or 1120. Google advises putting media **before** the text [DOC https://ollama.com/library/gemma4].

**`format` (structured output) combined with `tools` and `think`**
- **How it works** [SRC server/routes.go:2803-2815]
  - For a thinking-capable model with a parser, Ollama runs the first pass **unconstrained**.
  - When content starts after the thinking, it cancels that pass and re-runs with the grammar applied. A double request is how it does this.
  - `think:false` forces the grammar on from the first token.
  - This two-pass design fixed the old think+format conflict (#10538, closed; #15260, gemma4 `think=false` ignoring the format, closed via PRs #15392 and #15678). https://github.com/ollama/ollama/issues/10538, https://github.com/ollama/ollama/issues/15260
- **Format plus tools, tested live on 2026-09-22 with the same weather tool and schema:**
  - gemma4:e4b, think=false: a tool call came through, but the args were corrupted (`city: "\"Paris\""`) and content was a schema-shaped `{"answer":""}`.
  - qwen3.8:27b, think=false: **no tool call.** The grammar forced JSON, and the model answered "I can't use tools".
  - gemma4:e4b and qwen3.8:27b, think=true: a clean tool call, because it is emitted during the unconstrained first pass.
- **Verdict on the HN claim (2026-09-09) that format is "still incompatible" with tools:** it is **true when thinking is off, and effectively works when thinking is on**. That is an emergent property of the two-pass design, not a documented contract. The docs never discuss the combination [DOC https://docs.ollama.com/capabilities/structured-outputs]. Old issue #8095 (empty tool_calls with a schema) is closed and #8155 ("format vs tools") is still open.
- The structured-outputs doc also says **Ollama Cloud does not support structured outputs** [DOC].

→ lain:
- Carry images on any message, including the tool result. That fits a `screenshot` tool returning an image block, which the Anthropic API also supports in `tool_result`.
- The Ollama provider should put `images` on the tool message. For a model known to reject tool-role images, fall back to a follow-up `user` message holding the image; a per-model capability table is enough.
- **Never send `format` and `tools` in the same request with thinking off.** Either make it two calls (a tool loop, then a final structured call without tools), or validate on the client side.
- Image token accounting should come from the model, not from Ollama's flat 768.

## 2. Audio in Ollama

- **Audio uses the `images` field.** `DetectMediaKind` sniffs the bytes: a `RIFF…WAVE` header means WAV, and `ID3` or an MPEG frame sync means MP3. Anything else goes through the image sniffer [SRC llm/media.go]. Audio is forwarded to llama-server as an OpenAI `input_audio` part `{data, format}` [SRC llm/llama_server.go:2236-2246]. There is **no `audio` field** in the /api/chat schema [DOC]. Only WAV and MP3 are recognised, so Opus, M4A, WebM, and FLAC have to be transcoded with ffmpeg first.
- **OpenAI-compatible input**
  - `/v1/chat/completions` accepts `{"type":"input_audio","input_audio":{"data":b64}}`, which is mapped onto `images` [SRC openai/openai.go:597-610].
  - **`POST /v1/audio/transcriptions` exists** [SRC server/routes.go:1905]. It takes multipart `file`, `model`, and `language`.
  - The endpoint is a chat request underneath, with the system prompt "Transcribe the audio exactly as spoken… Do not answer any question in the audio" and the user text "What exact words are spoken in this audio?" [SRC openai/openai.go:864-880].
- **Live tests, 2026-09-22**
  - A WAV sent in `images` to gemma4:e4b was described correctly ("single-tone… sound").
  - The same 2-second sine-tone WAV sent to `/v1/audio/transcriptions` returned `{"text":"What exact words are spoken in this audio?"}`. On non-speech it **echoes its own prompt**, a hallucination, so a VAD gate is needed first.
  - qwen3.8:27b returned `400 Failed to load image or audio file` for audio.
- **No TTS endpoint.** There is no `/v1/audio/speech` in the route table [SRC server/routes.go:1860-1908].
- **Quality is [UNVERIFIED].** I found no WER numbers for Gemma 4 E4B on standard ASR sets, and I had no TTS on the box to make test speech.

→ lain:
- Gemma 4 E4B can be a "zero extra install" transcriber and audio understander, through the same `images` array. Treat it as a fallback.
- A dedicated ASR (section 3) gives timestamps, which Ollama's transcription endpoint does not return (`{text}` only), and timestamps are what the notes pipeline needs.

## 3. Local STT and TTS on this box

**Speech-to-text**

| option | accuracy tier | speed | AMD path | API shape |
|---|---|---|---|---|
| **whisper.cpp** (large-v3-turbo, q5) | Whisper-L3 class | fast on GPU | **Vulkan and HIP/ROCm** both supported [DOC https://github.com/ggml-org/whisper.cpp] | `whisper-server`: "HTTP transcription server with OAI-like API"; Silero `--vad`; `whisper-stream` for mics; tinydiarize speaker turns (experimental) |
| **faster-whisper** (CTranslate2) | same models | ~4x reference Whisper [UNVERIFIED] | CTranslate2 v4.7.1 (Feb 2026) ships ROCm wheels [UNVERIFIED, community repo https://github.com/nabe2030/faster-whisper-rocm-strix-halo]; a crash on gfx1201 is open in CTranslate2 issue #2021 https://github.com/OpenNMT/CTranslate2/issues/2021 | Python; served by **speaches** |
| **speaches** | wraps faster-whisper + Kokoro/Piper | loads and unloads models by TTL, "like Ollama for audio" | inherits CT2 | **OpenAI-compatible** `/v1/audio/transcriptions`, `/v1/audio/speech`, `/v1/realtime` [DOC https://github.com/speaches-ai/speaches] |
| **Parakeet TDT/CTC** (NVIDIA) | slightly below LLM-decoder ASR; CTC 1.1B has RTFx 2,794 vs Whisper-L3's 68.6 | fastest | NeMo is CUDA-first; on AMD use ONNX via sherpa-onnx (CPU is fine at this RTFx) [UNVERIFIED on ROCm] | sherpa-onnx has a websocket server |
| **Canary-Qwen-2.5B / Granite Speech** | top of the Open ASR leaderboard (Canary-Qwen ~5.63% avg WER) | slower (LLM decoder) | PyTorch ROCm [UNVERIFIED] | Python |
| **Moonshine v2** (Feb 2026) | Tiny 12.66% / Base 10.07% WER; a "Medium streaming" model claimed at 6.65% | streaming, reuses its encoder cache | CPU/ONNX, so vendor-neutral | libraries for Python, Android, iOS, and WASM; MIT for most models [DOC https://github.com/moonshine-ai/moonshine; WER from secondary https://github.com/Jackfood2/MoonshineSpeechToText, UNVERIFIED] |

- Leaderboard sources:
  - HF Open ASR Leaderboard post, 2025-11-21: Conformer+LLM decoders give the best WER, and CTC/TDT decoders are 10–100x faster. https://huggingface.co/blog/open-asr-leaderboard
  - Newer claims [UNVERIFIED, MarkTechPost 2026-07-23]: Cohere Transcribe 2B at 5.42% and IBM Granite Speech 4.1 2B at 5.33% avg WER. https://www.marktechpost.com/2026/07/23/best-open-speech-recognition-asr-models-in-2026-wer-languages-latency-and-license-compared/

**Text-to-speech**
- **Kokoro-82M.** It topped TTS Arena at launch. RTF is about 0.03 on a datacenter GPU and roughly real time (x0.9) on two ARM cores [UNVERIFIED, https://github.com/obole-ia/tts-cpu-benchmark].
- **Piper.** About 8.7–9.3x faster than Kokoro on CPU, with first audio in ~40 ms [same source]. It is now `OHF-Voice/piper1-gpl`.
- Both run in speaches and sherpa-onnx.
- Neither needs the GPU, which matters because the LLM wants all 22.5 GB of VRAM.

**OpenAI reference shape [DOC https://developers.openai.com/api/docs/guides/speech-to-text, /text-to-speech]**
- Transcription is `/v1/audio/transcriptions`. Models: `gpt-transcribe` (general), `gpt-4o-transcribe-diarize`, and `whisper-1` (word and segment timestamps via `timestamp_granularities[]`).
  - Files are capped at 25 MB, in mp3, mp4, mpeg, mpga, m4a, wav, or webm.
  - Diarization uses `response_format=diarized_json`, with `known_speaker_names[]` and up to four 2–10 s reference clips.
  - `stream=true` emits `transcript.text.delta` events. Live audio uses `gpt-live-transcribe` over realtime.
- TTS is `/v1/audio/speech`. Models: `gpt-4o-mini-tts` (takes an `instructions` style prompt), `tts-1`, and `tts-1-hd`.
  - 13 voices.
  - mp3, opus, aac, flac, wav, or pcm output.
  - Streams with chunked transfer.

→ lain:
- Standardize on the **OpenAI audio wire shape** (`/v1/audio/transcriptions`, `/v1/audio/speech`) as the `Provider`-like seam. Three backends fit behind it with no client changes: speaches or whisper-server locally, OpenAI in the cloud, and Ollama/Gemma 4 as a fallback.
- Run ASR and TTS on the **CPU**, or with whisper.cpp on Vulkan while the LLM is idle, so they do not compete for VRAM with a 27–30B model.
- Require segment timestamps from the backend. That rules out Ollama's endpoint as the primary.

## 4. Voice → notes → plan pipeline

**Android answering app (sideloaded)**
- Platform STT:
  - `SpeechRecognizer.createOnDeviceSpeechRecognizer` and `isOnDeviceRecognitionAvailable` arrived in API 31. `checkRecognitionSupport` and `triggerModelDownload` arrived in API 33 [UNVERIFIED, from memory plus secondary sources https://picovoice.ai/blog/android-speech-recognition/].
  - The on-device recognizer **fails if the locale pack is missing**.
  - `EXTRA_PREFER_OFFLINE` is a hint "honored inconsistently".
  - It returns no timestamps and cannot take long-form audio, so it suits short answers only.
- In-app models:
  - **sherpa-onnx** ships prebuilt Android APKs and libraries for Whisper, Moonshine, SenseVoice, and Parakeet-TDT-0.6B, plus Kokoro and Piper TTS, VAD, and speaker diarization, all offline [DOC https://github.com/k2-fsa/sherpa-onnx, https://k2-fsa.github.io/sherpa/onnx/android/prebuilt-apk.html].
  - Moonshine has a native Android library [DOC].
  - whisper.cpp has an Android example.
- Recommended split: **record Opus on the phone, upload, transcribe on the desktop.** This gives one ASR quality bar, timestamps, and no model shipping.
  - Keep on-device Moonshine or platform STT only for a live preview and for use when offline.
  - Transcode Opus to WAV before sending it to Ollama, which only sniffs WAV and MP3 (section 2).

**Diarization**
- **pyannote.audio 4.0 with `community-1`** is the best open pipeline, and pyannote says it "significantly outperform[s] 3.1" [DOC https://www.pyannote.ai/blog/community-1]. DER varies a lot by domain: roughly 11–19% for 3.1 on standard sets [UNVERIFIED].
- **WhisperX** combines Whisper, wav2vec2 word alignment, and pyannote. It runs on ROCm, per a community Docker writeup [UNVERIFIED https://dominic-boettger.com/blog/whisperx-gpu-amd-radeon-rocm-docker/].
- sherpa-onnx diarization runs on CPU.
- `gpt-4o-transcribe-diarize` is the cloud reference, and it can map speakers to names from reference clips.

**Transcript → notes → requirements without dropping details**
- The evidence says naive summarizing drops details:
  - FRAME (arXiv 2509.15901, v2 2025-11-14) names hallucinations, omissions, and irrelevance as the chronic failures of LLM meeting summaries. Its pipeline, **extract and score salient facts, then cluster by theme, then enrich an outline**, cuts hallucination plus omission by about 40% on QMSum and FAME. The P-MESA reference-free checker reaches ≥89% balanced accuracy against humans. https://arxiv.org/abs/2509.15901
  - QMSum-Mistake (arXiv 2407.11919) annotates 9 error types, omission among them. https://arxiv.org/abs/2407.11919
  - FABLES (arXiv 2404.01261) finds that all LLMs omit key details. https://arxiv.org/abs/2404.01261
  - For requirements from stakeholder-interview transcripts, GPT-4 reached **precision 0.46 and recall 0.43** on one system (WER 2025, Freire et al.). A single pass misses more than half of the requirements. https://werpapers.dimap.ufrn.br/papers/WER2025/wer202511.pdf
  - LENS (arXiv 2606.25867, June 2026) extracts explicit requirements and infers latent ones from interviews plus organizational context. https://arxiv.org/abs/2606.25867
- Pattern:
  1. ASR with segment timestamps and speaker labels.
  2. **Chunked atomic-fact extraction.** Each fact is a record `{speaker, t_start, t_end, verbatim_quote, claim, kind: decision|requirement|constraint|open_question|preference}`, and the quote must be a substring of the transcript, checked in code.
  3. Dedupe and cluster.
  4. The plan cites fact ids.
  5. A **coverage check**: every fact of kind requirement or constraint must be cited by a plan item or explicitly deferred. This is a set difference, not an LLM judgment.
  6. An optional second, independent extractor to estimate misses (capture-recapture, section 6).

→ lain:
- Model meeting input as an artifact whose facts are events with timestamp provenance, not as a summary string.
- "Did the plan drop the designer's specifics?" then becomes a mechanically checkable coverage query. That is the study bench's comparison metric too: recall of the fact set across context strategies.

## 5. Screenshots and video for a QA agent

**Web apps**
- Playwright: `page.screenshot` (full-page or element), and CDP for more.
- Video comes from `recordVideo`, or `video: 'on' | 'retain-on-failure' | 'on-first-retry'` in the test runner. The default size is the viewport scaled to fit 800x800, the format is WebM, and the file is **written only when the context closes** (`page.video().path()`) [DOC https://playwright.dev/docs/videos].
- Headless Chromium needs no display.

**Native GUI**
- Wayland:
  - `grim` (screenshot, with `-g` for a region) and `wf-recorder` (video) for wlroots compositors.
  - Headless: `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway`, plus `WAYLAND_DISPLAY`, grim, and optionally wayvnc [UNVERIFIED secondary https://github.com/pellepang/note-color/issues/194; ArchWiki Sway].
  - Also `weston --backend=headless` and `cage` for kiosk-style runs [UNVERIFIED flags].
  - Input: `ydotool` (uinput, needs its daemon) or the compositor's IPC (`swaymsg`).
- X11: `Xvfb :99` with `ffmpeg -f x11grab -i :99`, `xdotool`, and `import` or `scrot`.
- The local box has **only ffmpeg** of these tools installed (checked 2026-09-22). grim, wf-recorder, Xvfb, sway, and xdotool are all absent.

**Getting video into a VLM**
- **Ollama takes no video.** Only images (and audio) are sniffed [SRC llm/media.go]. So video means frames.
- ffmpeg recipes [DOC https://ffmpeg.org/ffmpeg-filters.html]:
  - Keyframes on change: `select='gt(scene,0.3)'` (scene score 0–1), or the `scdet` filter.
  - Drop static frames: `mpdecimate`.
  - Representative frames: `thumbnail`.
  - **Contact sheet**: `tile=4x3` onto one image. Each image costs vision tokens, so one grid image is far cheaper than 12 separate ones, at the price of resolution per cell.
- For UI QA, sampling on *event boundaries* is better than a fixed fps: take a screenshot after each driver action (Playwright step, xdotool action). Use scene-cut keyframes only for animation and transition bugs.

**How good VLMs are at spotting UI defects**
- Macklon & Bezemer (arXiv 2501.09236, EMSE, 2025-01-16): 80 bug-injected and 20 clean canvas screenshots. Detection reaches up to **100% per application**, but **only when given context**: the README, a description of bug types, and a **bug-free reference screenshot**. https://arxiv.org/abs/2501.09236
- VideoGameQA-Bench (arXiv 2505.15952, v2 2025-12-18) covers visual unit tests, visual regression, needle-in-haystack, glitch detection, and bug reports from images and video. https://arxiv.org/abs/2505.15952
- UXBench (arXiv 2606.13192, CVPR 2026 Findings): 2,000 mobile UI VQA items. The fine-tuned Qwen3-VL-4B "UI-UX" scores 0.796, against **Claude-4.5-Sonnet at 0.655**, so general models are mediocre at fine UI reasoning. https://arxiv.org/abs/2606.13192
- XBIDetective (arXiv 2512.15804) applies VLMs to cross-browser inconsistencies. https://arxiv.org/abs/2512.15804
- GUI grounding, ScreenSpot-Pro (1,581 instructions, professional high-resolution apps): about 88% for the top frontier model in a Sept-2026 snapshot [UNVERIFIED aggregator https://benchlm.ai/benchmarks/screenspot-pro; benchmark https://arxiv.org/abs/2504.07981]. This measures *grounding*, not defect detection, and depends heavily on crop and resolution.

→ lain:
- Give the QA agent **reference-diff framing**: a baseline screenshot plus a candidate screenshot plus a spec of defect types. That is the condition under which VLMs actually work.
- Pixel-diff first, which is cheap and deterministic. Send only the changed regions, cropped, to the VLM.
- Capture a screenshot per action instead of a video, and use contact sheets for transitions.
- Put the capture backend (Playwright, grim, x11grab) behind one `capture` tool so the experiment can swap it.

## 6. Cheapest-first tiered QA and LLM cascades

- **FrugalGPT** (arXiv 2305.05176, 2023-05-09): prompt adaptation, LLM approximation, and an **LLM cascade**, in which a learned scorer decides whether to accept a cheap model's answer. It matches the best model at "up to 98% cost reduction". https://arxiv.org/abs/2305.05176
- **Cascade routing** (Dekoninck, Baader, Vechev, arXiv 2410.10347, ICML 2025): proves the optimal cascading strategy and unifies routing with cascading. Its finding: **quality estimators are the critical factor**. Code: https://github.com/eth-sri/cascade-routing. Paper: https://arxiv.org/abs/2410.10347
- **Mixture-of-thought cascades** (Yue et al., arXiv 2310.03094, ICLR 2024): use the weak model's **answer consistency** across samples and representations (CoT vs PoT) as the escalation signal. They match GPT-4 at about 40% of the cost. https://arxiv.org/abs/2310.03094
- **Trust or Escalate** (Jung, Brahman, Choi, arXiv 2407.18370, 2024-07-25): a cascaded *judge* with a provable human-agreement guarantee. Confidence comes from "simulated annotators", and the judge escalates or abstains below a calibrated threshold. It reaches >80% human agreement at about 80% coverage using Mistral-7B first. https://arxiv.org/abs/2407.18370
- **Small models as reviewers means false positives dominate.**
  - SWR-Bench (arXiv 2509.01494, updated 2026-06) uses 1,000 real PRs, including *clean* PRs, where any comment counts as a false positive. The best system reaches **F1 19.38%**, limited by low precision, with some setups averaging more than 7 false positives.
  - **Multi-review aggregation** (n=10 samples) raises F1 by up to 43.67% relative.
  - https://arxiv.org/abs/2509.01494
- **Planted-defect evaluation and stopping rules.**
  - Capture-recapture for inspections (Eick et al. 1992/93; Briand et al. 1998; Petersson, Thelin, Runeson & Wohlin, JSS 2004 review): the overlap among independent reviewers estimates how many defects remain. https://wohlin.eu/jss04-1.pdf
  - Its assumption, independent reviewers, maps onto *different* cheap models or prompts, not onto temperature samples of one model.
  - Seeding known defects (mutation testing for reviewers) gives each tier's recall directly, which calibrates capture-recapture.
- **A concrete design for lain, synthesized, not taken from a single source:**
  1. **Tier 0**, deterministic and free: linters, type checks, pixel-diff, and the transcript-coverage set difference from section 4.
  2. **Tier 1**, cheap local models (e4b, 9B): k≥2 *different* models or prompts, each emitting structured findings with a location and evidence quote.
     - Accept a finding at this tier only if it reproduces mechanically (a failing test, a quote substring match, a diff region).
     - **Escalate** when models disagree, when a model's self-consistency across samples is low, or when a finding cannot be verified mechanically.
  3. **Tier 2**, a local 27–30B model with thinking: adjudicates only the escalated findings (precision stage) and runs one independent sweep (recall stage).
  4. **Tier 3**, the Anthropic API: only for the residue, or when the capture-recapture estimate of remaining defects exceeds a threshold.
  5. **Stopping rule:** stop when the capture-recapture estimate of undetected defects falls below ε, or when the marginal new-defects-per-minute of the last tier falls below the cost rate.
  6. **Score each tier** on a planted-defect corpus: recall (defects found), precision (false-positive cost counted as human minutes), and wall time per true positive.

→ lain:
- The cascade is an orchestration strategy, so it belongs on the bench as a swappable policy. The planted-defect corpus plus capture-recapture give a comparable metric: defects per wall-minute and per dollar, at a measured false-positive rate.
- Keep the escalation signals (disagreement, self-consistency, verifiability) as recorded events so runs can be replayed and compared.

---
Scratch artifacts from the live tests are in this directory: `ollama-v0.32.12-mediaqa/` (source clone), `mediaqa-*.json|wav|png`. After testing I unloaded the models from VRAM with `keep_alive:0`. The repo was not modified.
