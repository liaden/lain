# Spike: images end to end, with a `screenshot` tool as the driver

Date: 2026-09-22. Status: exploratory. Nothing is committed.

## Where the code is, and why it is not in this worktree

This worktree was cut from a stale `origin/main` (b1927ce7, 2026-08-25), which
is 488 commits behind local `main` (ec396926) and still predates Zeitwerk. Moving
it onto `main` was refused twice (`git reset --hard main` and `git switch -c ... main`).
A spike against a tree four weeks old would have measured the wrong seams, so the
work was done against **current `main`** somewhere else and is delivered as a patch:

- `spike-images.patch` (worktree root): `diff -ruN` against `main` at ec396926.
  Apply it in any checkout of that commit with `patch -p1 < spike-images.patch`.
  (`git apply` also works; the paths are `a/`/`b/`-prefixed.)
- `/home/tara/dev/lain/.claude/worktrees/spike-images`, branch `spike-images`:
  a clean worktree of `main` that I created and then could not write to, because
  the isolation guard allows writes only here. It is the natural place to apply
  the patch, or you can delete it with `git worktree remove`.
- The patched tree, plus every probe script and piece of evidence, is at
  `/home/tara/tmp/lain/claude-1000/-home-tara-dev-lain/c401093e-a43b-407b-8356-177c97f0daa3/scratchpad/`
  (`lain-main/` is the patched copy; `evidence-*.json`, `e2e.rb`, `measure.rb`,
  `ollama_probe.rb`, `shots.sh`, `fail_probe.sh`). The four evidence files are
  also under `spike-images-evidence/` here.

Every spec below was run against the patched copy of `main`, targeted and never
through `pspec`: **569 examples, 0 failures**. That covers the new specs, the
touched specs, and the whole-toolset discipline specs (`tool_bounds_discipline`,
`parallel_safety`, `tool_surface`, `gate`, `bench/harness`, `telemetry`,
`zeitwerk`, `output_discipline`, `cli/wiring`). `rubocop` finds no offences in
the 25 touched files.

## What I built

| File | What it is |
|---|---|
| `lib/lain/image.rb` | `Lain::Image`: builds the neutral image block from bytes (`Image.block`), identifies the media type from the bytes' own signature (PNG/JPEG/GIF/WebP), provides `each_in` to walk image blocks at any nesting including inside a tool_result, provides `data` to read an inline payload and raise `Unresolved` on a reference, and has `anthropic_tokens(w, h)` |
| `lib/lain/image/blobs.rb` | Prototype of the digest-reference alternative: a content-addressed blob directory, `reference(bytes)` producing a small `"source" => {"type" => "blob", "digest" => ...}` block, and `inline(content)`, which an encoder calls to restore the base64 |
| `lib/lain/image/admission.rb` | `:strict`/`:degrade` handling for images sent to a model without vision (refuse by name, or replace with a placeholder and journal it) |
| `lib/lain/telemetry/images_withheld.rb` | The journal record `:degrade` writes |
| `lib/lain/provider.rb` | `Provider::Vision` (SEES/BLIND/UNKNOWN), plus `#vision(model)` defaulting to UNKNOWN |
| `lib/lain/provider/ollama.rb` | `#vision(model)` computed per model from `/api/show`'s `capabilities` |
| `lib/lain/provider/anthropic.rb` | `#vision` always answers SEES |
| `lib/lain/provider/ollama/encoding.rb` | Image blocks go into the message's `images` array, on user, assistant **and tool** messages. When there are none the key is absent, so text-only payloads are byte-identical |
| `lib/lain/tools/screenshot.rb` | `Tools::Screenshot`: headless Chromium CLI, a fresh profile for every call, returns `[caption text, image block]` |
| `lib/lain/tool/bounds.rb` | `IMAGE_BYTES = 3 MiB` and a `"screenshot"` row in CEILINGS |
| `lib/lain/cli/wiring.rb` | Adds `Screenshot` to `BaseTools.build` |
| `lib/lain/bench/harness.rb` | Adds `screenshot` to `READERS` |
| specs | `spec/lain/image_spec.rb`, `spec/lain/image/{blobs,admission}_spec.rb`, `spec/lain/tools/screenshot_spec.rb` (with one real-Chromium `:seam` example against a local socket), `spec/support/image_fixtures.rb` (a real 70-byte PNG); new examples in the ollama encoding, anthropic encoding, ollama, and provider specs; the whole-toolset partitions updated |

A real end-to-end run also works: `e2e.rb` drives a real `Lain::Agent` with
`Provider::Ollama` on gemma4:e4b and the real `screenshot` tool, which renders a
local page in real Chromium. The model called the tool, received the PNG in the
tool message's `images`, and answered *"The codeword written on the page is
PELICAN-4417, and the colour of the rectangle is blue."* (42s wall, cold model load included).

## Design decisions

### 1. Image blocks use the Anthropic shape, and Canonical passes them through as text

`{"type"=>"image","source"=>{"type"=>"base64","media_type"=>...,"data"=>...}}`.
Base64 uses only ASCII characters, so the block needs no changes anywhere to pass `Canonical.normalize`, the
UTF-8 check in `Tool::ResultBlock::Content`, `Event` hashing, and `Ractor.shareable?` (all pinned by specs).
One wrinkle: `Array#pack("m0")` returns **US-ASCII**, and `ResultBlock::Text`
re-tags that encoding by **copying** the String, which would copy about 300KB for every result. `Image.block`
tags the string UTF-8 when it builds it, so the result passes through by identity (pinned by a spec).

The media type is identified from the bytes, not from a filename or from what the caller claims.
Anthropic checks the declared type against the bytes, and a mismatch comes back as a 400
far from whoever mislabelled it.

### 2. Inline base64 against a digest reference: measured, and the reference wins

Measurement script: `measure.rb`. The session it builds is: ask → `screenshot` tool_use → a
tool_result holding one real 1280x800 PNG → N further text exchanges. It rendered each
request through the real `Context#render` and serialized it with
`Telemetry::RequestSent.from(...).to_journal`.

| 1280x800 page | PNG | base64 | Anthropic tokens |
|---|---|---|---|
| example.com | 17,561 | 23,416 | 1,366 |
| ruby-lang.org | 22,443 | 29,924 | 1,366 |
| github.com/ruby/ruby | 91,366 | 121,824 | 1,366 |
| news.ycombinator.com | 152,695 | 203,596 | 1,366 |
| en.wikipedia.org (Ruby article) | 219,188 | 292,252 | 1,366 |

Rendering one takes about 1.3s of Chromium wall time.

**Journal cost** (sum of `request_sent` lines over the session):

| Session | text only | inline image | reference image |
|---|---|---|---|
| wikipedia shot + 10 exchanges (12 requests) | 37,709 B | **3,252,954 B** (86x) | 38,963 B (+1.2KB) |
| github shot + 30 exchanges (32 requests) | 205,043 B | **3,982,920 B** (19x) | 208,577 B |

The turn records hold the image once (295KB against 2.9KB). `request_sent` holds it
on **every later request**, so it multiplies the O(n²) growth that `RequestSent`'s own
header already accepts. One screenshot per turn over a 30-turn session is
about 30 × 30/2 × 200KB ≈ **90MB of journal**. The wire payload is identical either way
(296,827 B), because the reference is resolved on the way out.

CPU is not the issue. `Canonical.normalize` of a 292KB block takes 0.01ms, `Canonical.digest`
0.6ms, and `JSON.generate` 0.15ms. The cost is bytes at rest.

**Recommendation: references on the Timeline, inline only on the wire.** That is
the prototype in `Image::Blobs`:

- **Where the blob lives:** `$XDG_STATE_HOME/lain/blobs/<hex[0,2]>/<hex>`, a sibling
  of `sessions/`, per user rather than per session. That way `lain resume`, `fork` and a child
  agent all resolve the same digests, and a screenshot taken twice is stored once.
  The Store is in-memory and the session file is the durable record, so blobs are the
  one piece of content that lives outside the NDJSON.
- **How Canonical hashes it:** it does not need to know. The reference block is
  ordinary JSON, and its `digest` field is BLAKE3 over the **raw bytes**, not over the
  base64 and not over any canonical form. The Event's digest therefore commits to the exact
  image, and the Merkle property holds (spec: different bytes give different references).
- **How an encoder resolves it:** `blobs.inline(content)` deep-maps each reference to
  `Image.block(fetch(digest))` and re-verifies the hash on read (`Corrupt` if it does not match).
  Both encoders call `Image.data`, which **raises `Unresolved`** on a reference that
  nobody resolved. Sending the turn without the image would answer a question about a picture
  the model never saw.
- **Open seam:** *who* calls `inline`. `Context#render` must stay pure, so the call
  cannot live there. The candidates are (a) `Provider#encode`, with a blob store injected into
  the provider, or (b) a request middleware between render and provider. (b) keeps
  both encoders unaware of blobs, and a unit spec can hand them inline blocks. I would pick (b).
  `request_sent` should journal the **unresolved** request, which is the whole saving,
  so the resolution step has to come after `JournalRequests`.
- **Durability caveat:** a session file is no longer self-contained. Replaying,
  exporting or sharing a session needs its blobs as well. `lain export`, if it exists, must
  bundle them. A GC policy is needed: blobs referenced by no session file.

### 3. Ollama: a `role:"tool"` message may carry `images`. No need to hoist into a user turn

Live evidence against ollama 0.32.12 with gemma4:e4b, at temperature 0 and seed 1. The raw request and response for
each probe are in `spike-images-evidence/`, with base64 elided to its length:

| Probe | Request shape | Answer | prompt_eval_count |
|---|---|---|---|
| `tool_images` | user → assistant tool_call → **`role:"tool"` + `images:[png]`** | "The codeword on the page is **PELICAN-4417** and the colour of the rectangle is **blue**." | 264 |
| `tool_no_image` (control) | same, no `images` | "The codeword on the page is \"CODEWORD\" and the colour of the rectangle is red." (made up) | 126 |
| `hoisted` | tool text, then a **user** message carrying `images` | "...PELICAN-4417 ... blue." | 291 |
| `no_vision` | qwen3:4b, user message + `images` | **HTTP 400** `{"error":{"code":400,"message":"Multimodal data provided, but model does not support multimodal requests.","type":"invalid_request_error"}}` after 2.35s (it loaded the model first) | n/a |

The codeword could not be guessed, and the control made up a wrong one, so the tool
message's image was read. The encoder therefore puts a tool_result's images on its own
tool message and does not invent a user turn. Hoisting also works, but it costs 27 more prompt
tokens and puts words in the human's mouth. For gemma4 an 800x400 image cost about
138 prompt tokens (264 − 126), which is a fixed per-image budget, not a function of pixels as it is on Anthropic.

Note for whoever runs GPU timing on this box: qwen3:4b was already resident (another
agent had loaded it) during my probes. I made 4 raw probes plus 1 end-to-end run (2 calls).

### 4. Vision is a per-model property, not one of `Provider::CAPABILITIES`

`CAPABILITIES` is per deployment ("IDENTICAL on both arms"), but one ollama
endpoint serves gemma4:e4b (`completion vision audio tools thinking`) next to
qwen3:4b (`completion tools thinking`). So the prototype adds a
`Provider::Vision` tri-state that mirrors `Provider::Serving`, and a
`#vision(model)`. Ollama computes it from `/api/show` behind the same `model_metadata?` gate as `serves?`,
so the cloud arm answers UNKNOWN without asking. Anthropic always answers SEES. The Capability::Policy
machinery (`requires`/`supports?` resolved once at launch) has no model argument,
which is why this does not fit it.

**Refuse versus degrade: recommend both, each in its own place** (`Image::Admission` prototypes the pair):

- **The primary gate is the toolset, not the wire.** Tools are capabilities: do not
  *offer* `screenshot` to a model whose `vision` is BLIND (decided at launch, like
  `trained_context_tokens`). No image is ever produced for a blind model, and the
  model is never tempted to call a tool it cannot use.
- **`:strict` is the default for images in flight.** `Admission#admit` raises `Blind`,
  naming the model and the count, before the wire. Without it ollama still refuses, but with a
  400 that names neither the model nor where the image came from, after loading a model it
  cannot use.
- **Use `:degrade` only for history after a model switch.** A session that `/model`-switched to
  a blind model still holds the earlier screenshots. Refusing every later request for them
  kills the session over images nobody is asking about. So there the images are replaced by
  `[an image (image/png) was here; qwen3:4b cannot see images, so it was withheld from this request]`
  and a `Telemetry::ImagesWithheld{model, count}` is journaled. The Timeline keeps the images,
  and only the outgoing request changes.
- UNKNOWN passes images through (the cloud arm, or ollama being down): refusing on
  UNKNOWN would refuse every arm that simply has no way to ask.

### 5. The `screenshot` tool

- Input: `url` (required), `width` (320–1920, default 1280), `height` (200–1600,
  default 800), `full_page`. Only http/https URLs are accepted; `file://` is refused
  before anything is launched.
- Command line: `chromium --headless --disable-gpu --hide-scrollbars --no-first-run --mute-audio
  --user-data-dir=<tmp>/profile --screenshot=<tmp>/shot.png --window-size=W,H <url>`,
  run through `Shell::Out` (spawn, an argv array, process-group kill, 30s timeout). It uses a fresh
  profile for every call, so no cookie or login outlives it.
- **Approval: yes (`requires_approval? = true`)**. That makes it the second gated tool after
  `bash`, and the whole-toolset partitions (`tool_surface_spec` GATED,
  `gate_spec`) had to be widened to allow it, with the argument written into
  `tool_surface_spec`. The command-string axis alone would put it at tier 2 and ungated, but the
  axis that matters here is egress. WebFetch is safe because of its structure (the host is
  checked on every hop, and the body is capped as it streams), and none of that carries over:
  the URL is checked once, and then the browser fetches every subresource, runs scripts, and follows
  redirects the process never sees. That includes 169.254.169.254 and localhost.
  `WebFetch::NonRoutable` was deliberately *not* reused. The headline use case
  is "screenshot my dev server on localhost", which it would refuse. A human
  approving the destination is the only honest control.
- **Finding: the Chromium CLI cannot report a failed navigation.** An unresolvable host, a
  refused port and an HTTP 404 all **exit 0 and write a PNG of Chromium's own error
  page** (verified; `fail_probe.sh`). The tool therefore says in its caption that the status is
  unknown, and tells the model to read the page. A real version needs the DevTools
  protocol (see open questions).
- **`full_page` is approximated** by a 4096px-tall window, because the CLI captures the window only.
  A 1280x4096 image is also scaled by Anthropic to about 490x1568, which makes text
  unreadable. Full page is a tiling problem, not a single image.
- **Bounds: pixels are what cost tokens, bytes are what cost the journal and the wire.** A
  1280x800 screenshot costs 1,366 Anthropic tokens whether its PNG is 17KB or 219KB,
  so `RESULT_BYTES` (16 KiB, derived from text bytes-per-token) is the wrong
  measure. The prototype adds `Tool::Bounds::IMAGE_BYTES = 3 MiB`. Its base64 is 4 MiB, which
  stays under Anthropic's 5MB-per-image refusal. It becomes the `screenshot` row in
  CEILINGS, enforced by `Bounds::Artifact` on the PNG bytes, and it refuses without a preview, naming
  "a smaller width and height". The viewport limits in `Input` bound pixels, and therefore tokens.
  **Proposal for the real chunk:** a CEILINGS row stays *per tool*, but an image-bearing
  tool gets **two** bounds: a byte ceiling (IMAGE_BYTES) and a pixel ceiling
  (`w*h`, which predicts tokens: Anthropic ≈ w·h/750 after scaling the long edge to 1568). The text part stays
  under RESULT_BYTES. A discipline-spec gap turned up here: `byte_limits` reads
  `.limit` off any `Bounds::Artifact` regardless of its `unit`, so an
  `Artifact.new(limit: 1_000_000, unit: "pixels")` would be counted as a byte ceiling.
- Registration cascade: adding a file under `lib/lain/tools/` requires updates to
  `ToolRegistry::BUILDERS`, the `parallel_safety` partition (FALSE_TOOLS), `tool_surface`
  GATED, the `gate_spec` partition, and `Bench::Harness::READERS` (it writes only its own
  tmpdir). The bounds discipline spec forbids a CEILINGS row for an unshipped tool, so the
  row and the registration have to land together.

### 6. Anthropic path

It is verified by unit specs with no live call. The encoder passes blocks through as-is, so an image
block reaches `wire_payload` JSON unchanged at the top level and **inside a
tool_result's content** (built through the real `Tool::Result` →
`ResultBlock.of` → `Request` path). A neutral cache marker on an image block
translates to `cache_control` as it does anywhere else. The `anthropic` SDK's param model also
converts the same message list into `ToolResultBlockParam` with
`[TextBlockParam, ImageBlockParam]` content (`sdk_probe.rb`), so the SDK oracle
path accepts it. No live Anthropic call was made.

## Places that assume text only (not fixed)

Line numbers refer to `main` at ec396926, which is also the patched copy, because none of these files is touched by the patch.
The survey was a read-only sweep, and each hit below was read.

**The five that matter most**

- `lib/lain/compaction/strategy/summarizing.rb:179`: the summarizer's prompt is
  `Canonical.dump(messages)`, so an image reaches the summarizer as about 300KB of base64 *text*.
  `compaction/tool_messages.rb:137` classifies a user turn carrying an image as conversational,
  so `SummarizeConversation` routes it into that same dump.
- `lib/lain/compaction/head.rb:78` feeds `need.rb:71`: the compaction trigger is
  `Canonical.dump(...).bytesize` against a default of 262,144 bytes (`cli/backend.rb:73`),
  so **one Wikipedia screenshot fires compaction by itself**. The 1 MiB hard cap
  (`cli/backend.rb:74`, `scheduler.rb:152`, `source.rb:703,739`) means 3–4 screenshots
  force a warm compaction. `ContextWindow::Occupancy` uses real usage and is unaffected.
- `lib/lain/telemetry/request_sent.rb:52-54`: every request journals the whole `cache_payload`,
  which is the multiplication measured above.
- `lib/lain/agent.rb:382` (`stranded_prompt?`) and `compaction/source/held_cut.rb:277`
  (`ask_index`): both require every block to be text. An unanswered `[text, image]` prompt is
  not folded, so the next prompt commits as a second consecutive user turn. A held cut keeps an older
  text-only turn as "the ask". Also, `Agent#ask` (`agent.rb:252`) accepts only text,
  so a human-supplied image needs a new entry path anyway.
- `lib/lain/frontend/neovim/request_buffer.rb:115` and `neovim/buffers.rb:303-306`: the
  `lain://request` and `lain://diff` buffers pretty-print the payload, so the base64 lands as one
  line of about 400KB in an editable, resendable buffer, and the diff repeats it.

**Compaction and summaries**

- `compaction/summary_snapshot.rb:127`: only a tool_result whose content is a String gets a summary.
  A `[text, image]` result renders "(elided -- no summary held)", which drops the caption as well.
- `summary_snapshot.rb:244,253` and `strategy/elide.rb:75`: the "N bytes" attestations count base64.
  They are misleading but harmless.
- `lib/lain/consolidation.rb:211-215` and `cli/improve.rb:131-136`: a closed `case` keeps
  only text and tool_use, so images disappear from the clerk's transcript without any notice.
- `oracle/handoff.rb:187-190`: a top-level image becomes `[image]`, which is fine. A nested one reads as
  "N bytes, elided", with N counting base64.

**Estimates built from bytes**

- `compaction/scheduler.rb:211,286-296` and `proxy_bytes.rb:59,67`: savings are journaled at 4 bytes per token.
  Dropping one image reads as about 75k tokens saved, when Anthropic bills about 1.4k. This is telemetry only.
- `plan/seam_decision.rb:81-82`: the same conversion is used inside a cost comparison.
- `context/compact.rb:81`: its threshold is measured in the same bytes.
- `middleware/request_budget.rb:173-176`: `fixed_tokens` splits the provider's count by byte share.
  Base64 shrinks the apparent system and tools share, which suppresses the "larger context" advice.

**Matching patterns over content**

- `context/compact.rb:121` and `context/dedupe_tool_calls.rb:46`: user-supplied protect patterns
  are run against `Canonical.dump(message)`, base64 included. That means a regex pass over 300KB, and a short
  pattern can match base64 noise.
- `session_record/scribe.rb:326` (`child_turn`) and `tool/result_block.rb:248-270` handle images correctly.

**Display**

- `frontend/tty.rb:246` prints only `response.text` and never shows tool results, so images never reach the TTY.
- `frontend/neovim/buffers.rb:186-190`: the timeline preview drops the image from `[text, image]`
  without any notice, shows `(image)` for an image-only turn, and shows a tool_result turn as `(tool_result)`. The
  screenshot's caption is visible in no view. The Lua runtime (`runtime/20_buffers.lua:174`, filetype
  markdown) has no image-aware logic.
- `cli/watch.rb:248-250` and `neovim/journal_view.rb:44-46` render message records and ToolOutput,
  and are not affected.

**Secret middleware** (no problems found)

- `middleware/redact_secret_reads.rb:68,412,455-461` guards only `read_file` and fails closed on
  a result with no readable text. `withhold_automatic_output.rb:144` and `withhold_secret_paths.rb:113-153`
  never see images. The credential scanner (`Regions.detect`) is fed only text.

**Everything else**

- `context/message_envelope.rb:42-48` via `context/recall.rb:64-69`: an image-only user turn has no
  query text, so recall silently queries with an *older* turn's text.
- `bench/live_replay.rb:33-35`: `ask_text` takes the first text block, so replays drop images and skip
  image-only prompts.
- `cli/goal_driver.rb:46-48,414` matches prompt text only. It is harmless.
- These read a child's result text and would drop images, which is fine while children return text:
  `approval/auto_surface.rb:104`, `approval/gate/adjudicator.rb:517`, `isolation/worker_handoff.rb:197`,
  `review/critique.rb:208`, `review/docent.rb:601`, `cli/command/meta.rb:208`.
- `response.rb:49` and `provider/.../chat/response_parsing.rb:47`: text only, but assistants do not emit images.

## Video, briefly

`ffmpeg`/`ffprobe` n9.0.1 are installed. A `video_frames` tool would run
`ffprobe` for the duration, then `ffmpeg -i in.mp4 -vf "fps=N/duration,scale=768:-1" frame%03d.png`
to take N evenly spaced frames, and return them as N image blocks, each preceded by a
`t=12.4s` text block. Alternatively it would return one **contact sheet**
(`-vf "fps=...,scale=384:-1,tile=4x3"`) as a single image, with the timestamps drawn on it by
`drawtext`. On Anthropic both cost pixels: 12 frames at 768x432 is about 5.3k tokens, and a
1536x1296 sheet of the same frames is about 2.6k tokens at half the resolution. The contact sheet is
the better default for "what happens in this clip", and individual frames are better for "read the text at 0:42".
Either way, video has the byte problem the digest reference solves, multiplied by N,
so it should not be attempted before blobs land. Anthropic caps a request at 100 images
(20 on claude.ai), and ollama vision models vary. gemma4 also lists `audio`,
which is a separate axis entirely.

## Open questions

1. Who resolves blob references: a request middleware after `JournalRequests` (preferred), or
   `Provider#encode` with an injected store? Either way `request_sent` should record
   references and the wire should carry base64. Does replay then need the blob dir as well as
   the session file? (Yes. How is a session with its blobs exported or shared?)
2. Blob GC and quotas: per-user store, reference-counted by scanning session files?
3. DevTools protocol over the Chromium CLI: a CDP client (for example the `ferrum` gem, pure
   Ruby, no node) gives the navigation status (so a failure becomes `is_error`), true
   full-page capture (`captureBeyondViewport`), wait-for-network-idle, `clip` to an
   element, and a device scale factor. It is a new dependency, and a long-lived browser process
   would belong **out of process** by the Rust placement rule ("async, I/O-bound, or
   isolation-relevant"), which makes lain-core the natural host.
4. Should `screenshot` refuse the metadata ranges outright even with approval (169.254/16 and
   friends), and allow loopback? That needs a split `NonRoutable`.
5. Occupancy: every bytes-based token estimate will read an image as tens of thousands of
   "tokens" (292KB of base64 / 4 ≈ 73k). Should `ProxyBytes` learn about image blocks
   (count `anthropic_tokens`, or a per-provider figure: gemma4 was about 138 tokens/image), or should
   occupancy come only from the provider's reported `input_tokens`?
6. `Canonical.normalize` interns every String with `-@`. Is a 300KB interned
   base64 String collected once unreferenced? The `Bounds` comment says `-@` interns "for
   the life of the process". Holding references on the Timeline makes this moot.
7. What does the human see? The cockpit and nvim panes are text. Options: a
   `[image 1280x800 png 219KB blake3:4ce4…]` line, a file path under the blob dir that
   nvim can `:edit`, or kitty/sixel inline rendering in the TTY pane.

## Recommended shape for a /create-plan chunk

**"Images as content" — four waves:**

1. **Value and storage (leaf).** `Lain::Image` (block, sniff, each_in, data) and
   `Image::Blobs` at `Paths#blobs_dir`, with GC out of scope. A request middleware
   `ResolveImages` placed after `JournalRequests`. Acceptance: the journal carries a
   reference, the wire carries base64, and an Event digest changes when the image bytes change.
2. **Encoders and vision.** The Ollama `images` field (tool messages included), `Image::Unresolved`
   raised in both encoders, `Provider::Vision` and `#vision(model)`, and `Image::Admission`
   (strict by default, degrade after a model switch) with `Telemetry::ImagesWithheld`. An Anthropic
   wire spec, plus one `:api_integration` example that sends a tiny PNG in a tool_result.
3. **Text-only sweep.** Fix the places listed above in priority order: occupancy
   estimate, compaction or summarizer transcript, stranded-prompt fold, display in the cockpit, nvim
   and `lain watch`, and secret-redaction middleware skipping base64. Each is its own card with a spec
   that feeds it an image block.
4. **The tool.** `screenshot`, ideally on CDP (status, full page, clip) and out of process
   in lain-core, gated, with pixel and byte bounds and offered only when `vision != BLIND`. Add a
   `planning/qa/scenarios/` entry: screenshot a local page, ask about it, switch to a
   blind model, and confirm that degrade journals `images_withheld`.

Waves 1 and 2 are small and mostly done in this patch. Wave 3 is where the risk is.
Wave 4 is independent of 3 if the tool is registered last.
