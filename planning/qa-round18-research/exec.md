# Round 18 research — exec backends, bash output, transport failure

Tree: `/home/tara/dev/lain` at `90f081b9`. Read-only: code, `git log`/`git show`, planning docs, the fork
reports under `~/tmp/lain-qa-round18/records/`. Nothing was run except `git` and `grep`, plus reading the
installed `mixlib-shellout-3.4.10` gem source.

Abbreviations:
- **plan** = `planning/specs/chunk-qa-round17-the-record-the-human-the-window.md`
- **mixlib** = `~/.local/share/mise/installs/ruby/4.0.6/lib/ruby/gems/4.0.0/gems/mixlib-shellout-3.4.10/lib/mixlib/shellout/unix.rb`

Card references (T1, T3, T24) are round-17 discharge cards. A different chunk's card is named as such.

---

## F139 — a timed-out `--exec docker` command leaks its container

### 1. Mechanism, re-verified

**The path.**
- `Exec::Docker#call` (`lib/lain/exec/docker.rb:121-125`) wraps the whole `docker run …` argv as a
  one-stage TERM, `command: [argv(...)]`, and hands it to its inner `Exec::Local`.
- `Local#call` (`exec/local.rb:55-62`) sends any non-String command to `#pipe`
  (`local.rb:80-85`), so it reaches `Shell::Pipeline`. **The docker client never goes through
  mixlib or through `Shell::Out`.**

**The kill.**
- `Pipeline::Run#collect` (`shell/pipeline.rb:368-376`) rescues its own `Timeout` and calls
  `#terminate` (`:410-414`).
- `#terminate` sends TERM to the client's process group (`Process.kill(name, -thread.pid)`, `:418`),
  joins for `@grace` (`DEFAULT_GRACE = 3.0`, `:136`), then sends KILL to whatever is still alive.
- `Pipeline::Timeout` is re-raised as `Exec::Timeout` (`local.rb:83-84`).
- `Tools::Bash#timed_out` renders `command timed out after Ns: …` (`tools/bash.rb:325-327`).

**The container.**
- `RUN = [CLI, "run", "--rm", "--quiet"]` (`docker.rb:40`). There is no `--init`, `--name`, `--cidfile`
  or `--sig-proxy` flag, and no post-timeout `docker kill`/`rm` anywhere in `docker.rb`.
- The docstring at `docker.rb:111-115` reads: "`docker run` proxies signals to the container's PID 1
  in non-TTY mode, so the ordinary TERM reaches the command; a container that ignores TERM outlives
  the client's KILL, a leak this backend names rather than manages."

**What the finding gets right.** The leak mechanism and the wrong docstring are as the finding
states. The fork evidence (shell T-M2, subag SB6) is a live reproduction plus a lain-free control:
TERM is proxied to PID 1 and ignored, and KILL to the client is never proxied.

**Where the finding and the fork reports are imprecise.**
1. **The grace constant.** The fork report names the grace as `Shell::Out::GRACE`. On this path it is
   `Shell::Pipeline::DEFAULT_GRACE` (`pipeline.rb:136`). `Shell::Out` is not on the path. Both are
   3.0 s, so the conclusion stands.
2. **"`--rm` never fires" is incomplete as causation.**
   - The subag fork's own `podman inspect` showed `HostConfig.AutoRemove=true` (SB6).
   - `--rm` is container configuration that fires when the container *exits*, not a duty of the live
     client. This is documented docker/podman behaviour, not verified on this box.
   - So the leak is precisely that **PID 1 never exits**. A command that ends on its own is removed
     when it ends:
     - `sleep 600` would self-remove at 600 s;
     - `tail -f` never ends.
   - "Indefinitely" is therefore true for non-terminating commands, and "until the command's own end"
     for the rest.
   - The repo's own seam spec relies on this without asserting it: `spec/lain/exec/docker_spec.rb:658-660`
     times out `sleep 30` at 1 s, and that container outlives the example by about 29 s.
3. **The model-facing text is false under docker too, and the finding does not mention it.**
   - `Bash::Input`'s `timeout` description: "Seconds to allow before the command's whole process
     group is killed" (`bash.rb:130-131`).
   - `#description`: "The command's whole process group is killed if it runs past its timeout"
     (`bash.rb:218-219`).
   - Under docker only the *client's* group is killed. This is SB6's "a process that lives on is
     reported as ended".

### 2. Most recent relevant changes

**No round-17 card touched `exec/docker.rb` or `shell/pipeline.rb`.** T1's fix round expanded into
`exec/local.rb` and `exec/core.rb` only (below, under F200). `git log` on `docker.rb`:

| commit | date | what it did |
|---|---|---|
| `6ab98dd2` | 2026-08-23 | "exec: a docker backend, refused at launch and reaching the tool". **Origin** of `--rm`, of the TERM-proxy docstring, and of the timeout seam spec (`git log -L111,116` and `-S` on the spec example). |
| `2071f088` | 2026-08-26 | Comment trim only: "which is a leak this deliberately-bare backend names" became "a leak this backend names". |
| `c43d088c`, `0e8d8e67` | 2026-08-23 | `UserMapping`/`Prober` (round-9 F57) and `--quiet`. Not timeout-related. |
| `280b0c44` | 2026-08-26 | `#takes_term?`. Not timeout-related. |
| `75b26bc8` | 2026-09-14 | `Effect::Handler` split; a comment-reference touch only. |

### 3. Why it is this way

**The round-8 chunk's T2** (`planning/archive/chunk-qa-round8-cancellation-and-environment.md:272-335`)
set the frame: "**Deliberately bare.** One `docker run --rm` per command, the project mounted, the
scrubbed environment passed through. No image building, no lifecycle, no daemon reuse, no networking
policy. The point is a second backend that genuinely differs, not a container story."
- Its ACs cover hostname, mount, scrub, launch refusal and default. **None covers timeout or cleanup.**
- The only timeout assertion ever written is the seam example "raises the seam's one Timeout when the
  command outlives its deadline". It checks the raise and not container absence, and it skips
  without docker.

**In-code statements of intent that bear on a fix:**
- `docker.rb:33-34`: "`--rm` because nothing here names, reuses or reaps a container, so nothing may
  leave one behind." The intent is *no container left behind*. The timeout path breaks that promise.
- `docker.rb:111-115`: the leak was **consciously accepted** ("names rather than manages"), on the
  premise that a TERM-ignoring container is the exception. That premise is false for PID 1 without
  an init.
- `docker.rb:64-66` (`exec:` param): "the deadline, the process-group kill, the live sinks and the
  {Timeout} mapping are one implementation, not three."
- `docker.rb:102-105`: the argv refuses `--env-file` because it "would be a second copy with a
  temp-file lifecycle this backend has no business owning". The same argument applies to `--cidfile`.
- `docker.rb:238-251` (`Prober`): the probe uses "`--version` and never `info`: the version line
  contacts NO daemon, so the question costs one local process and cannot hang the way `docker info`
  can against a remote `DOCKER_HOST`." It is also bounded (`TIMEOUT = 10`, taking the smaller of that
  and the caller's deadline).

**The QA scenario never looked for it.** `planning/qa/scenarios/subagents-and-backends.md:230-232`
(added in `07e0bef2`, round 9): "**The timeout kills the client.** Drive `sleep 600` against the
deadline and confirm the named `Timeout` rather than a hang." Round 17 did not drive it
(round-17 findings coverage row: "the docker timeout (`sleep 600`) not driven (budget)").

**No human ruling** on container lifecycle exists in the round-8 or round-17 plans or in
`planning/archive/chunk-shell-term-approval.md`. That doc treats docker only for the pipe fallback.

### 4. Classification

**(c) pre-existing, never touched by the chunk.** The leak was named and accepted in `6ab98dd2` on a
false premise, so the acceptance does not survive the evidence. It is not a considered (d): nobody
ruled on the facts as measured.

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **"Deliberately bare"** (round-8 T2; `docker.rb:5-8`). `--init` in `RUN` is a flag and stays bare.
  Naming a container and running `docker kill`/`rm -f` on timeout is lifecycle management. That is a
  scope change to put to the human, not a card default.
- **If a cleanup command is added:**
  - it contacts the daemon and can hang against a remote `DOCKER_HOST` (the `Prober` rationale);
  - so it needs its own small bounded deadline, and must run through the same injected `exec:` so the
    operator's `DOCKER_HOST` reaches it;
  - `--cidfile` reintroduces the temp-file lifecycle `docker.rb:102-105` rejects, and `--name` does
    not.
- **`Docker` is frozen** (`docker.rb:80`), and the only mutable state is `UserMapping`
  (`docker.rb:191-198`). A per-run container name must be per call, not held on the object.
- **Keep the one kill implementation** (`docker.rb:64-66`). A docker-side kill belongs after the inner
  backend raises `Exec::Timeout`. It must not be a second deadline loop.
- **`--init` alone does not cover a command that traps or ignores TERM itself.** The fork's control:
  `timeout -s KILL` with `--init` still leaked. The docstring must be corrected either way, and so
  must `bash.rb:130-131` and `:218-219` if the claim stays false under docker.
- **Specs that pin the current argv:**
  - `spec/lain/exec/docker_spec.rb:177-181` asserts `argv.first(3) == %w[docker run --rm]`, which
    constrains *where* `--init` may go;
  - `:193-198` asserts `--quiet` and the image-then-entrypoint tail;
  - `:658-660` (the `:seam` timeout);
  - the round-8 escalation rule: `:seam` docker specs must **skip, not fail**, without a client, and
    must never pull an image (`docker_spec.rb:11-58`).
- **`CROSSES`, the `UserMapping` inversion for rootless podman (F57), and "a container is not a
  sandbox"** (round-8 T2's escalation trigger) are not to be relitigated.

**Open questions for the human:**
1. May the bare backend own a container's end: `--name` plus a bounded `docker kill`/`rm -f` on
   timeout? Or only `--init`, with the residual TERM-trapping leak named honestly?
2. Is `catatonit`/`docker-init` availability on the operator's client acceptable as a hard
   dependency of `--exec docker`? The fork verified `--init` on this box's podman only.
3. Should a timeout under docker tell the model that the container may still be running, if a leak
   stays possible?

---

## F200 — `bash` buffers all output before the 128 KiB bound

### 1. Mechanism, re-verified

**The finding's mechanism is correct.** Every arm retains the whole capture before
`Tools::Bash.render_output` measures it:

| arm | where the bytes accumulate |
|---|---|
| **String arm** (`Exec::Local#shell`, `local.rb:71-78`) | mixlib `read_stdout_to_buffer` appends every 4 KiB chunk (`READ_SIZE = 4096`) to `@stdout` and also to `live_stdout` (mixlib `:291-294`). |
| **Term arm** (`Local#pipe` → `Shell::Pipeline::Run#read_chunk`, `pipeline.rb:401-408`) | appends every 64 KiB chunk to `@buffers[stream]` and to the sink. |
| **Daemon arm** (`Exec::Core#call`, `exec/core.rb:60-67`) | "this arm buffers everything until the reply" (`core.rb:43-46`). The Rust drain is "EAGAIN-bounded but not byte-bounded" (`crates/lain-core/src/exec.rs:224`). |

**The bound.** `render_output` computes `stdout.bytesize + stderr.bytesize` and asks
`OUTPUT_BOUND.admits?` only after the backend returns (`bash.rb:163-168`).

**Two things the finding does not name:**
1. **The timeout path copies the capture again, inside the backend.**
   - mixlib builds `CommandTimeout`'s message with `format_for_exception`, which interpolates
     `stdout.strip` and `stderr.strip`: mixlib `shellout.rb:240-251`, raised at `unix.rb:120`.
   - `Pipeline::Run#captured` interpolates both buffers (`pipeline.rb:431-435`), and
     `Exec::Core#killed` does the same (`core.rb:~107-113`).
   - T1's `timeout_report` comment, "the output bound first, so a huge capture is never copied or
     validated" (`bash.rb:319-324`), holds only from `Bash` onward. The copy has already happened in
     the exception message.
2. **The live sink is bounded; the capture is not.**
   - `Sink::IOAdapter` pushes one `ToolOutput` event per chunk onto the invocation's channel
     (`sink.rb:37-42, 96-102`).
   - A blocking `Channel` holds at most `DEFAULT_CAPACITY = 1024` events (`channel.rb:66`), which is
     about 4 MiB (string arm) or 64 MiB (term arm) of chunks.
   - So the 1.13 GB measured is dominated by the capture buffers, not the display path. That is an
     inference from the constants, not measured.
   - Whether "retained after" is a live reference or allocator/GC high-water was **not established**
     by the fork or here.

`cat huge.log`, auto-approved by `composed_term`, is a verdict-allow term, so it took the term arm.
The human-approved `head -c … | tr` is also a term of two `STDIN_SAFE` stages. Both therefore
measured `Pipeline::Run`'s buffers.

### 2. Most recent relevant changes

| commit | date | what it did |
|---|---|---|
| `3ceec114` | 2026-08-18 | "tool: add Bounds, with two shapes on a stated boundary". "The refusal decides from a size alone and never holds the bytes, so a caller can answer from File.size or a streaming counter." |
| `036e6ec0` | 2026-08-18 | "tools: refuse a whole artifact too big to read, before reading it". Introduced `OUTPUT_BOUND`, and put the bash bound in `render_output`. |
| `cf3505a3` | 2026-09-14 | **T1.** Added `Tool::ResultBlock::Text` reading of both streams after the size check (`bash.rb:170-172`), `timeout_report` (`:325-337`), and `.b` on the mixlib command (`local.rb:66-72`) and on `Core#killed` (`core.rb:99-113`). **No change to capture or retention.** |

`git log -S OUTPUT_BOUND` on `tools/bash.rb` returns exactly `036e6ec0` and `cf3505a3`.

### 3. Why it is this way

**`036e6ec0`'s commit message is explicit about both halves:**
- "The refusal is decided from File.size before any read, so an oversized file costs no memory to
  decline -- measured 0 kB peak RSS over a 512 MiB file."
- "bash's bound lives in render_output so both arms and the daemon refuse byte-identically."
- **Memory was measured for `read_file` only.** For bash the placement was chosen for parity, and its
  memory cost was never examined.

**In-code rationale that a fix collides with directly** (`bash.rb:138-146`): "The one place BOTH exec
arms turn captures into a {Tool::Result}, shared so the differential's byte-identity cannot drift out
from under its specs. {OUTPUT_BOUND} is applied HERE for that reason: a ceiling checked per arm would
be two ceilings that happen to agree today, and the daemon arm would have a third or none."
- "The exit status rides in the refusal's SUBJECT rather than being dropped, because it is the one
  fact a truncation would have preserved and the model usually asked the question to learn it."
- "The HUMAN still sees every byte: both arms stream through {Sink::IOAdapter} as output is
  produced… a refusal is about what the MODEL is handed" (`bash.rb:148-152`).

**`Tool::Bounds` anticipates the streaming shape and names a precedent** (`tool/bounds.rb:68-76`):
"a caller decides from `File.size` before opening the file, or from a running counter mid-stream --
the shape {Tools::WebFetch}'s byte cap already uses to abort a socket read rather than buffer 5 MiB
and measure it." Bash never adopted the running counter.

**T1** (plan lines 545-633) was scoped to encoding. Its "Bash" paragraph routes the timeout and
exec-error messages through the text boundary "since they embed the same bytes". Its fix-round
expansion is logged at plan lines 362-365: "A timeout of a non-ASCII command makes mixlib's timeout
message raise an encoding error, and `Exec::Core#killed` builds its message the same way.
`exec/local.rb` and `exec/core.rb` are added to T1's fix round as a deliberate scope expansion." Size
and memory were never in T1's scope.

**The scenario never claimed otherwise for bash.** `planning/qa/scenarios/failure-injection.md:426-428`:
"**The decision precedes the read.** An oversized **file** must be refused from its size". The fork
adds bash as a new §8 row (scenario correction owed).

**No human ruling** exists on bash's memory bound. The round-16 plan
(`chunk-qa-round16-identity-and-what-a-tool-may-return.md:147-151, 1063-1067`) records bash as
"bounded" and `core_exec` as `DELEGATED` to `Bash::OUTPUT_BOUND`. It treats the bound as a token
bound, not a memory one.

### 4. Classification

**(c) pre-existing, and T1 did not touch retention.** It rests on a deliberate *placement* decision
(one ceiling in `render_output` for byte-identity) whose memory consequence was never weighed. It is
not a regression of T1.

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **Byte-identical refusals across the term, string and daemon arms.** Pinned by:
  - `spec/lain/tools/bash_spec.rb:600-610` ("refuses byte-identically on either arm");
  - `:612-620` ("refuses through the shared rendering the daemon arm also calls");
  - `:312` (byte-identical content on either arm);
  - `:949` (byte-identical UTF-8 blocks).

  A per-arm counter is exactly what `bash.rb:140-142` argues against. The fix must keep **one**
  decision owner, for example a bounded capture object every arm fills, with `render_output` still
  the one renderer. It must also say what happens on the daemon arm, which cannot stop retaining
  without a Rust change (`exec.rs:224`; `docs/rust-bindings.md` governs that).
- **The exit status must survive**, pinned by `bash_spec.rb:562-567` ("keeps the exit status a refused
  command reported", `…; exit 3`). **Killing the group at bound + 1**, one of the finding's fix
  shapes, would replace the command's status with a signal and break this. **"Stop retaining, keep
  draining"** preserves it.
- **The exact size in the refusal** (`bash_spec.rb:555-560`: `(ceiling + 1024).to_s`) requires counting
  every byte even after retention stops.
- **The pipe must keep being drained.** A child blocked on a full pipe waits out the whole timeout
  (`shell/out.rb:65-70` states the analogous hazard).
- **The human still sees every byte** (`bash.rb:148-152`). The live sink must keep receiving past the
  bound, or that documented divergence becomes a ruling.
- **Timeout reports quote the capture.** A bounded capture changes what `Timeout` messages carry.
  `bash_spec.rb:911-917` pins that "a timeout message over the output bound" is kept out of the
  result.
- **Stdout and stderr are counted together** (`bash_spec.rb:582-587`).
- **T1's text boundary order:** size first, then text (`bash.rb:163-176`). Do not relitigate T1's
  refuse-by-name.
- **The `:core` tier** is excluded by default. Any daemon-arm parity must be driven with
  `rake core:build` (CLAUDE.md, integration check 2 in the plan).

**Open questions for the human:**
1. Is a daemon-arm capture bound in scope, or is the daemon arm accepted as unbounded, as its live
   sinks already are ("an inherent asymmetry… an accepted one", `core.rb:43-46`)?
2. Should retention stop at the bound while the human's live stream continues unbounded? If yes, the
   `Channel` backpressure (a 1024-event blocking queue) becomes the only memory bound on the display
   side.
3. Should the fix spec assert RSS after `GC.start`, since the round could not tell retention from
   high-water?

---

## F202 — a transport-failed ask leaves its user turn on the head

### 1. Mechanism, re-verified

**The finding's citation is correct**: only `WindowExceeded` withdraws.
- `Agent#ask` (`lib/lain/agent.rb:232-240`) commits the user text, then runs inside
  `withdrawing(before, asked)`.
- `withdrawing` (`agent.rb:336-341`) rescues `WindowExceeded` only, and resets the head only
  `if @timeline.equal?(asked)`.
- A transport failure is `Provider::Ollama::APIError`, rooted at `Lain::Error` through
  `ErrorWrapping.under(Lain::Error)` (`provider/ollama.rb:66-67`). It is not a `WindowExceeded`, so it
  propagates with the user turn committed.
- `Repl::Ask#attempt` returns it as a value (`cli/repl/ask.rb:47-51`). `#record_interruption` then
  `catch_up`s, which journals the stranded user turn, and writes `run_interrupted torn` naming it as
  head (`ask.rb:74-77`).
- The next `ask` commits a second user turn on top, and both are rendered.

**One correction to the harm as stated.** "Two consecutive user turns" is **not** a wire violation.
`Context::Conversation`'s invariant 2 is deliberately "No two adjacent non-user messages", and
`context/conversation.rb:34-38` says `%w[user assistant user user]` "is the ordinary shape of a tool
round". The real harm is that the abandoned text is re-sent, and answered, beside the new prompt.

### 2. Most recent relevant changes

| commit | date | what it did |
|---|---|---|
| `4cf30b98` | 2026-09-14 | **T24**, "window: ollama refuses an over-window prompt instead of truncating it". Introduced `withdrawing`, the `before`/`asked` capture in `#ask`, `Lain::WindowExceeded` (`lib/lain/error.rb`), `Accounting#observe_refusal`, and `RequestBudget`. |
| `04a9d40a` | 2026-09-14 | **T3.** `answer_stranded(:unknown)` before the user commit (`agent.rb:235`), and `answer_errored` on a post-commit budget failure (`:525-539`). It repairs an unanswered `tool_use`, not a user turn. |
| `bad757a6` / `7caaa5fc` | 2026-07-10 | The original "commit the user turn, then run" ordering. `git log -L232,240` reaches these as the origin of the commit-before-run shape. |

### 3. Why it is this way

**T24's card body (plan lines 2425-2534) is stale.** It still describes the pre-send estimate, the
calibration and the truncation witness. The live design is only in the Execution log (plan lines
432-447):
- "**Ruling.** Send `"truncate": false` to ollama. The server then refuses an over-window prompt with
  HTTP 400 carrying the exact prompt count and context size…"
- "**Also dropped:** the refused prompt's user turn does not stay on the head, and the calibration and
  the ratio witness are gone."
- "AC1, AC3 and AC5 are restated to match." The restated ACs do not appear in the card; they live in
  the specs.

**The reason withdrawal is licensed**, as stated in code:
- `lib/lain/error.rb` (`WindowExceeded` doc): "No model evaluated the prompt and nothing was
  generated, which is what lets an ask withdraw the turn that sent it."
- `agent.rb:221-227`: "WITHDRAWN: no model saw it… The Timeline stays lossless -- the turn is still in
  the Store -- and only while that text is still the head: a tool round that ran before a later
  refusal in the same ask is work that happened, and stays."

**The scope was narrowed deliberately, and a spec pins it.** `spec/lain/agent_spec.rb:1029-1034`:
"leaves any other failure's prompt committed, as it always has". It asserts a bare
`Lain::Error.new("provider down")` leaves `%w[user]`.
- That spec is the only recorded statement of the decision. It gives no reason beyond "as it always
  has", and the Execution log does not discuss transport failures.
- The same describe block also pins:
  - the tool-round-stays rule (`:1017-1026`);
  - the head-restore (`:986-996`);
  - no stacking (`:998-1006`).

**Why "no model saw it" is not knowable for a transport failure, in the repo's own words:**
- `cli/resend_bridge.rb:29-36`: "at-least-once-send / exactly-once-commit. A raise out of the
  overridden run may have restored an edit that DID reach the wire… The notice DISTINGUISHES a
  pre-wire failure from a wire failure, because claiming provider ambiguity for a send that provably
  never left the process is a lie."
- `provider/ollama.rb:52-58`: "a lost local round trip costs a retry, a lost metered one is SPENT".
  A retry rotates the WAL frame.
- Four attempts are made (`max_retries: 3`, `failure-injection.md:109-111`). Earlier attempts may
  have streamed tokens before the sever.

**The scenario is wrong for chat.** `failure-injection.md:119` ("four attempts, `end of file
reached`, **no turn committed**") comes from round 15's table
(`qa-findings-round15-2026-08-27.md:247`), which also recorded "2 × `run_interrupted`". FI-4 shows a
user turn *is* committed in a chat. The fork is right that this predates T24.

### 4. Classification

**(b) a gap left outside T24's scope, knowingly.** The spec names "any other failure" and keeps it.
The rationale for excluding transport failures is not written down. Part of it is also **(e)**: the
`failure-injection` §1b text "no turn committed" is wrong for a chat.

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **T24's rule that only the asked text is withdrawn, and only while it is still the head**
  (`agent.rb:339`; `agent_spec.rb:1017-1026`). A tool round that ran stays.
- **The Timeline stays lossless.** Withdrawal moves the head; the turn stays in the Store
  (`agent_spec.rb:986-996`).
- **`agent_spec.rb:1029-1034` pins the current behaviour.** Changing it is a deliberate reversal of a
  T24 decision and must say so.
- **"No model saw it" is not provable after a wire attempt** (`resend_bridge.rb:29-36`, the WAL/spool
  rotation). A rule withdrawing on any transport failure asserts a fact the harness cannot know. The
  finding's own narrower shape ("a `Lain::Error` from the provider phase with no stream started")
  needs a pre-wire versus wire distinction that must be carried out of the provider. It does not exist
  on the error today, and `ResendBridge` draws it separately.
- **Journal ordering.**
  - `Ask#record_interruption` calls `catch_up` *after* `Agent#ask` returns, so a withdrawal inside
    `Agent#ask` never reaches the scribe. `JournalTurns` skips `catch_up` on a raise
    (`middleware/journal_turns.rb:13-15`).
  - Any fix must keep the withdrawal before `catch_up`, or `SessionRecord::Scribe` raises `Diverged`
    ("appends, never rewrites").
- **`SessionRecord::Salvage`** (`session_record/salvage.rb:15-22`) targets the last `request_sent` not
  superseded by `turn_usage` or `rewound`. A withdrawal writes neither.
  - If a crash follows a failed ask whose WAL holds a complete frame, a resume could salvage a
    response onto a head that no longer carries its prompt.
  - T24 already has this exposure, but a 400 leaves no complete frame; a transport failure might.
- **T3's `answer_stranded` ordering at the top of `#ask`** (`agent.rb:234-235`) must survive.

**Open questions for the human:**
1. Should a transport-failed ask withdraw its prompt, given the harness cannot prove no model saw it
   (and a metered provider may have billed it)? Or keep it committed and change only what the next
   ask does: fold it, refuse to stack, or tell the human it will be re-sent?
2. If withdrawal is wanted only for provably pre-wire failures (connection refused, DNS), is carrying
   `ResendBridge`'s pre-wire/wire distinction onto the provider error in scope?
3. Should `failure-injection` §1b be corrected to "a user turn IS committed" now, independent of the
   fix?

---

## F147 (exec half) — `Mixlib::ShellOut` rewinds a shared regular-file stdin

The REPL researcher owns the input-reader side. This section covers only the subprocess half.

### 1. Mechanism, re-verified

**The cited line is exact.** In mixlib's forked child, `configure_subprocess_file_descriptors` does
`stdin_pipe.last.close; STDIN.reopen stdin_pipe.first` (mixlib `unix.rb:231-238`). The fork is at
`unix.rb:324-327`, inside `run_command`'s `fork_subprocess` (`:95`).

**The seek-back.** `IO#reopen` on a read-buffered `STDIN` moves the shared file offset back, and a
fork shares the file description with the parent. The C-level step (Ruby's unread-buffer seek inside
`IO#reopen`) was **not read here**. The finding's lain-free repro (`L1 L2 L3 L2 L3`) and its
pipe/no-ShellOut controls are consistent with it.

**The Ruby spawners do not reopen.**
- `Shell::Pipeline::Run#options` passes `in: File::NULL` to `Open3.pipeline_r` (`pipeline.rb:358-360`).
- `Shell::Out::SPAWN` does the same through `Process.spawn` (`shell/out.rb:57-63`).
- Both redirect at the fd level in the spawned child, so they are not exposed.

**Mixlib callers in `lib/` (grep):**
- `exec/local.rb:23` (bash's string arm);
- `workspace/snapshot/scope/shadow_git.rb:114` and `shadow_git/repository.rb:44`;
- `isolation/compose.rb:177`, `isolation/db_index.rb:80`;
- `review/source/github_pr.rb:253`, `review/source/local_branch.rb:71`, `cli/command/review_submit.rb:59`;
- `frontend/tty.rb:881` (`TmuxMessage`), `cli/up.rb`.

**Which caller fired in R4 is not determined.**
- `echo one` is a literal term and plausibly took the term arm, which does not reopen.
- The default `accept_edits` posture uses `snapshot_scope: :shadow_git` (`mode/posture.rb:113-114`),
  which shells git through mixlib around each turn.
- So "every ShellOut caller triggers it" is the right framing. Attributing R4 to bash's own call is
  unverified.

### 2. Most recent relevant changes

| commit | date | what it did |
|---|---|---|
| `fb6e3a1b` | 2026-07-10 | "Tools::Bash: tier-3 free-form shell tool via Mixlib::ShellOut". Origin of mixlib on the string arm. |
| `210ad08d` | 2026-08-23 | `Exec::Local` extracted (round-8 chunk). |
| `f68c1286` | 2026-08-02 | The shadow git scope, on mixlib. |
| `1a70dd7f` | 2026-08-05 | "shell: one command, spawned rather than forked". Introduced `Shell::Out` with `in: File::NULL`, for fork cost, not stdin. |
| `cf3505a3` | 2026-09-14 | **T1** changed only `command.b` in `Local#shell` (`local.rb:66-72`). No stdin change. |

**No round-17 card addressed stdin replay.** It is logged as a follow-up found by T29's drives (plan
lines 478-480): "`lain chat` with stdin redirected from a regular file re-reads earlier prompts in a
loop once a prompt triggers a `bash` call. `/dev/null`, a pipe and a TTY are fine."

### 3. Why it is this way

**`Shell::Out` was deliberately not made a general mixlib replacement.** `shell/out.rb:22-26`: "It
answers the calls that pass an argv array and read three values back. Callers wanting mixlib's
`cwd:`, `input:`, `live_stdout:` or its `CommandTimeout` class keep mixlib." Bash's string arm needs
`cwd:`, `live_stdout:`/`live_stderr:` and `CommandTimeout`, so by that rule it stays on mixlib.
`Exec::Local`'s `shell_out_factory` seam is spelled against mixlib's keyword surface
(`local.rb:17-23`).

**The stdin rationale in both spawners rests on a premise about mixlib that is incomplete.**
- `pipeline.rb:352-357` and `shell/out.rb:59-62`: "`in:` is `/dev/null` because the child would
  otherwise inherit lain's stdin and read the human's keystrokes -- mixlib hands its child an
  immediately-closed pipe… so all three arms agree."
- That is true of what the *child* reads. It misses the reopen's side effect on the *parent's*
  regular-file offset.

**The mixlib gem's own comment** on the reopen: "HACK: for some reason, just STDIN.close isn't good
enough when running under ruby 1.9.2" (`unix.rb:234-235`).

### 4. Classification

**(c) pre-existing, never touched by the chunk.** It is also **(b)** in that T29 found the symptom and
it was recorded as a follow-up, outside every card.

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **Bash's two-arm byte-identity**, including the timeout message shape (`bash_spec.rb:312`, `:949`,
  `:87-95` "maps CommandTimeout…", `:911-917`).
  - Replacing mixlib on the string arm with a spawn-based runner needs `cwd:`, live sinks, a
    process-group TERM→3 s→KILL, and a `CommandTimeout`-equivalent message that `Exec::Local` maps to
    `Exec::Timeout` (`local.rb:76-77`).
  - `Shell::Pipeline::Run` already has all of those for a term. `Shell::Out` has none of the sinks
    (`out.rb:22-26`), so extending `Shell::Out` contradicts its stated scope and needs a ruling.
- **`local_spec.rb` and `bash_spec.rb` inject `shell_out_factory:` lambdas** (for example
  `local_spec.rb:24, 114, 130`; `bash_spec.rb:66, 78, 91, 268, 288, 355, 759`) with mixlib's signature.
  A different runner changes that seam.
- **A narrower fix is to stop the parent being exposed** rather than replace every mixlib caller: an
  unbuffered non-TTY reader (REPL side), or re-seating the parent's stdin before a chat starts. That
  is the other researcher's half, and the two halves must be decided together.
- **"A process boundary is not a security boundary"** and the mixlib `setsid`/process-group claims
  (`bash.rb:46-54`) must stay true of whatever replaces it.

**Open questions for the human:**
1. Fix at the reader (one place) or at every mixlib caller (about ten sites, several not bash)?
2. If bash's string arm leaves mixlib, is `Shell::Pipeline`'s run machinery (a one-stage
   `["sh", "-c", cmd]` term) acceptable as the string arm's runner? It would blur the documented
   "term arm never reaches a shell" split in `bash.rb:11-34`.

---

## F205 (LOW) — a transport-failed `bench record` has no session header

### 1. Mechanism, re-verified

**Correct as stated.**
- `RunRecorder#record` (`bench/cli/run_recorder.rb:42-57`) opens the journal, writes `@attribution`
  (`slot_fills`), then `run_and_write`.
- `run_and_write` (`:62-66`) runs `@prompts.each { agent.ask(prompt) }`, and only afterwards calls
  `Session.write`. That call writes the `session` header and the turn records
  (`bench/session.rb:171-175`).
- A raise from `agent.ask` skips `Session.write`, and the `ensure` closes the journal (`:53-55`).
- The file holds `slot_fills` plus whatever the model phase journaled (`request_sent`).
- `Session::Loader` raises `Corrupt, "no \"session\" header record to rebuild a context from"`
  (`bench/session/loader.rb:202`).

**Two consequences the finding does not name:**
1. **Re-recording to the same path is refused.** `record` raises `Refusal` when the path exists
   (`run_recorder.rb:43-44`, pinned by `spec/lain/bench/cli/run_recorder_spec.rb:29`). A retry of the
   same `bench record … --out <dir>` refuses on `1.ndjson`. This is read from code, not driven.
2. **Later runs are not attempted.** `bench/cli.rb:325` maps `(1..runs)` and the first raise stops
   the map.

### 2. Most recent relevant changes

| commit | date | what it did |
|---|---|---|
| `1e6701d0` | 2026-07-15 | "bench: sweep, deterministic five-arm retrieval eval (recall@k)". Origin of the header-after-run order (`git log -L62,66`). |
| `1a0c52ce` | 2026-09-14 | "give the bench the harness it was built to measure". Added `tools:`/`instrumentation:` and did not change the order. Not a round-17 card. |

No round-17 card touched `run_recorder.rb`. Its only mention in the plan is T9's review follow-up
(plan line 371: `RunRecorder` never journals `capability_degraded`).

### 3. Why it is this way

- **The header must follow the run.** `bench/session.rb:196`: "`head` anchors the whole turn chain",
  and the header records the final head. `run_recorder.rb:48-50`: `Session::Loader` "reads by record
  TYPE, not file position", which is why appending the header last is legal.
- **A partial recording is refused on purpose.** `bench/session.rb:143-146`: "A recording whose
  baseline outnumbers the DAG's assistant turns holds a failed attempt (a request_sent with no
  following turn_usage), and DryReplay's 1:1 guard raises on it -- loudly, by design."
- **An occupied path refuses on purpose.** `run_recorder.rb:36-39`: "Journal.open appends, a second
  header in one file would destroy both sweeps' loadability, and the existing bytes cost real money."
- **No ruling exists** on what a failed run should leave behind.

### 4. Classification

**(c) pre-existing, never touched by the chunk.**

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **Session format:** exactly one `session` header per file (`Corrupt` on more than one, `session.rb:56-65`).
  `head` must match the rebuilt chain.
- **Do not overwrite an occupied path** (`run_recorder_spec.rb:29`).
- **Writing a header over a partial Timeline in an `ensure`** yields a file that loads but whose
  `dry_replay` raises "by design" (`session.rb:143-146`). Variance readers would then see a partial
  run.
  - F201, same file family: a zero-usage run already averages in as 0.
  - A fix should decide whether a failed run is excluded, flagged, or not written.
- **F201 (FI-5)** touches the same `RunRecorder`/provider-journal wiring. Plan them together.

**Open questions for the human:**
1. On a failed run: delete the partial file, rename it aside (for example `1.failed.ndjson`), or
   write a header marking it failed?
2. Should `bench record` continue to the remaining `-n` runs after one fails?

---

## F189 (LOW) — the ceiling stop journals `run_interrupted reason: "torn"`

### 1. Mechanism, re-verified

**Correct.**
- `Budget#check_iterations!` raises `Budget::Exceeded < Error` (`agent/budget.rb:12, 26-30`), and so
  does `#check_tokens!` (`:33-37`).
- `Ask#attempt` returns it as a value. `#refuse` calls `record_interruption(reason_for(error))`, and
  `reason_for` is `stalled?(error) ? :stalled_stream : :torn` (`cli/repl/ask.rb:83`).
- `RunInterrupted::REASONS = %i[interrupted grace_expired stalled_stream torn]`
  (`telemetry/session_lifecycle.rb:81`). There is no ceiling member.

**The same `torn` also covers these, today:**
- the T24 over-window refusal (`RequestBudget::OverWindow < Lain::Error`);
- a transport give-up (F202);
- a post-commit `ToolDelivery` tear after T3's repair;
- any other `Lain::Error`.

So `torn` is not specific to tears anywhere, not only at the ceiling.

### 2. Most recent relevant changes

| commit | date | what it did |
|---|---|---|
| `4dabad38` | 2026-08-23 | "record: say why a run was interrupted". Introduced `REASONS`, `reason_for` and the stall classifier. |
| `8e3f4b38`, `2071f088` | 2026-08-26 | Comment edits only. |

No round-17 card touched `ask.rb` or `session_lifecycle.rb`.
- T3 changed what the head *is* at a ceiling stop: answered, not a dangling `tool_use`.
- Round 18 confirmed that F89 holds ("a ceiling stop now leaves the head on an answered
  `tool_result`").

### 3. Why it is this way

**The residue was chosen deliberately.** `session_lifecycle.rb:67-76`: "`:torn` is the honest residue
and the default, because it is the only thing every stopped run is known to have in common: a record
built with no classification says the unclassified thing rather than borrowing a narrower one it
cannot support."

**The ceiling is pinned to `torn` in a spec.** `spec/lain/cli/repl/ask_spec.rb:99-103`, "still says
torn for a refusal that is nobody's stall", uses
`Budget::Exceeded.new("loop ran 25 iterations, ceiling is 25")` and expects `reason: :torn` (added in
`4dabad38`).

**The same commit states a purpose the ceiling case contradicts.**
- `ask.rb:78-82`: "the distinction it owed a reader is whether the MODEL went quiet or the HARNESS
  stopped. Both used to land as the same bare run_interrupted, untriageable from the file."
- A ceiling is the harness stopping, and it shares `torn` with a genuine tear.

**Round 14 observed the shape and did not flag it.** `qa-findings-round14-2026-08-27.md:301-304`
recorded `run_interrupted reason="torn"` at the ceiling as a pass ("better than documented").

### 4. Classification

**(d) by design, pinned by a spec, with a ruling owed.** The pinned choice predates the scenario
evidence that `torn` is now overloaded, and it conflicts with `ask.rb:78-82`'s own stated goal.

### 5. Constraints and open questions

**Constraints a fix must respect:**
- **`RunInterrupted::REASONS` is a closed, loud enum** pinned in `spec/lain/telemetry_spec.rb:687-710`,
  including the exact error message listing the members.
- **The Conductor spends one reason on two records.** `INTERRUPT_REASONS = %i[interrupted grace_expired]`
  must be in both `SessionClosed::REASONS` and `RunInterrupted::REASONS` (`cli/conductor.rb:34-38`).
  A new run-only reason must not enter `INTERRUPT_REASONS`.
- **Old journals** carry `torn` for ceilings. Reconstruction goes through `reason!` with
  nil-tolerance (`session_lifecycle.rb:83-90`), so a new member is additive.
- **QA scenarios read `run_interrupted reason=torn` + head `tool_use` as the F88/F89 detector**
  (`failure-injection.md:412`, `rails-blog.md:124`). A new ceiling reason does not break that
  detector, but any reader counting `torn` changes meaning.
- **Classify by type, never by message string.** `ask.rb:84-90` rules out message matching:
  "Matching on the message string is not an alternative: the text is the provider's to change."
- **`ask_spec.rb:99-103` must be deliberately rewritten**, not deleted.

**Open questions for the human:**
1. Add `:ceiling` (or `:budget`) to `RunInterrupted::REASONS`? And should `:over_window` and a
   transport give-up get names too, or stay in `torn`?
2. Should `RunInterrupted`'s doc ("stopped before its response committed", `session_lifecycle.rb:47`)
   be reworded, since a ceiling stop has committed responses?

---

## Cross-finding

**Shared root causes:**
1. **"The exec seam's contract ends at the capture."**
   - F139 and F200 are both about what an `Exec` backend owns *after* the bytes and the deadline:
     - F139: whether the process (the container) is actually gone;
     - F200: whether the capture is bounded while it is gathered.
   - Both sit on a documented decision to keep one implementation in one place:
     - the kill in `Shell::Pipeline`, "one implementation, not three" (`docker.rb:64-66`);
     - the bound in `render_output` for byte-identity (`bash.rb:138-142`).
   - Both fixes must add a responsibility without splitting that single owner.
   - F147's exec half is the third symptom: the "all three arms agree" comments (`pipeline.rb:352-357`,
     `out.rb:59-62`) describe the child's stdin and miss a parent side effect.
2. **"Why an ask stopped" is under-modelled.**
   - F202 (does the prompt stay?), F189 (what reason is journaled?) and F205 (what does a failed
     recorded run leave?) all come from one gap: the failure path distinguishes only `WindowExceeded`
     (T24) and `StalledStreamError` (`4dabad38`), and everything else is "torn, prompt committed,
     nothing else written".
   - T24 is the precedent for doing it by *type* on a duck mixed into provider errors
     (`lib/lain/error.rb`).

**Which fixes cover which findings:**
- **A typed stop classification** (a duck or enum carried on the refusal, read in one place) would feed
  both:
  - F189's journal reason;
  - F202's withdraw decision, if a pre-wire/wire distinction is added.

  It would not fix F205 by itself: `RunRecorder` never reaches `Ask`.
- **One bounded-capture object filled by every Ruby arm** (and handed to `render_output`) covers F200
  on the string and term arms. If bash's string arm were also moved off mixlib onto a spawn-based
  runner with `in: File::NULL`, the same change would remove bash's own contribution to F147. It would
  not remove shadow_git's or the other nine mixlib callers', so it is **not** a full F147 fix.
- **F139 is independent of the rest.** `--init` in `RUN`, and/or a bounded daemon-side kill, touches
  only `exec/docker.rb` and its spec. It shares no file with F200 unless the capture object changes
  `Local#pipe`'s signature.
- **F205 pairs with F201** (same `RunRecorder`/provider-journal wiring), not with F202.

**Decisions not to relitigate across the group:**
- T1's refuse-by-name text boundary and its size-then-text order.
- T3's "answer a stranded `tool_use` before the next ask".
- T24's "withdraw only the asked text, only while it is the head; the Timeline stays lossless".
- "A container is not a sandbox" (round-8 T2).
- The closed, loud reason enums.
