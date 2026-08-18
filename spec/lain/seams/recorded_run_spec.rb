# frozen_string_literal: true

require "json"
require "tmpdir"

# ONE whole run, recorded at the HTTP boundary and replayed offline: a real
# {Lain::CLI::Backend} and the real {Lain::CLI::Wiring} assemble a real
# {Lain::Agent}, which asks a question, dispatches a real tool, and answers --
# with nothing between it and ollama but VCR.
#
# It is the layer T13 cannot reach. `spec/lain/provider/ollama_recorded_spec.rb`
# records the PROVIDER, so it proves decode; this records the RUN, so it proves
# that the loop, tool dispatch, the session record and compaction's accounting
# still agree with each other. Nothing below is doubled. The only stand-ins are a
# throwaway project directory and a throwaway XDG_STATE_HOME, so the run's reads
# and its session record land somewhere the example owns.
#
# Recorded 2026-08-17 against ollama on this box, qwen3:4b (the arm's
# DEFAULT_MODEL, and the model T13 recorded against).
#
# == What reds this file, what merely ROTS it, and why re-recording is the repair
#
# The obvious guess is wrong and worth correcting up front: an unrelated prompt
# edit does NOT red this spec. Requests are not matched (see below), so a rewritten
# system prompt or a re-worded tool description changes what is SENT and nothing
# about what replays. What it changes is whether the recorded answer is still the
# answer this run would get -- so the cassette rots silently rather than failing,
# and the fixture drifts from the thing it claims to be a recording of.
#
# What actually reds it is a change in what lain DOES with those bytes, or in what
# it ASKS with them: an NDJSON decode regression, a usage that stops decoding, a
# loop that stops dispatching the tool or mis-correlates its id, a message or a
# system prompt or the toolset that stops reaching the wire, a session record that
# loses a type or its close, a window book that stops reporting a probed window.
# Fifteen mutants of exactly those shapes each red between one and eight of the
# nine examples below, and none of them passes silently. That is the whole
# intended signal, and it is small on purpose.
#
# So re-recording is a REPAIR, not a bug hunt. After one, the pinned reply and the
# pinned reply alone will have moved; read the diff, update {REPLY}, and move on.
# The one thing it may not become is routine. If this cassette has to be
# re-recorded to make an unrelated card's specs pass, it has stopped pinning
# orchestration and started pinning prose, and it should be narrowed or deleted
# rather than refreshed again.
#
# The ritual, which is T13's and is fiddlier than one line suggests:
#
#   1. WARM THE RUNNER FIRST, or the whole cassette is worthless -- see the
#      `/api/ps` section below. Against a cold server the probe records
#      `{"models":[]}`, which is the empty default the global stub already gives:
#      the run then replays denominated by CONSERVATIVE_FALLBACK, which is F3
#      itself, greenly.
#
#        curl -s http://localhost:11434/api/chat \
#          -d '{"model":"qwen3:4b","messages":[{"role":"user","content":"hi"}],"stream":false}'
#
#      Send NO `num_ctx`, here or in the run: it reloads the runner at a
#      different window and the `/api/ps` recording then disagrees with the chat
#      one (the stale-runner trap, references/ollama/api-show-and-context.md).
#   2. Delete `spec/fixtures/vcr_cassettes/ollama_run_tool_loop.yml`.
#      `:new_episodes` records only requests the file does not already answer,
#      and every request here matches one it does, so re-recording over a live
#      file is a silent no-op.
#   3. Record through ONE example, by name:
#
#        LAIN_RECORD=ollama LAIN_SPEC_BUDGET=600 bundle exec rspec \
#          spec/lain/seams/recorded_run_spec.rb -e "answers with the recorded reply"
#
#      One, because `config.order = :random` otherwise decides which example's
#      run reaches the server first, and because the watchdog's default budget is
#      not a model-load budget. Nothing else may be running: a RECORDING cassette
#      permits real connections to every host, not merely this one.
#
#      And know what a recording pass IS: the toolset below is the REAL one, so
#      qwen3 is handed the live `bash`, `write_file`, `edit_file` and `subagent`
#      behind the real gate, in the recorder's own tree. Replay only ever
#      dispatches the `read_file` the cassette recorded, so the committed file is
#      safe -- but the recording itself is a real agent with real capabilities,
#      and the prompt is kept to one unambiguous instruction partly for that
#      reason.
#   4. `records: :ollama` above is not decoration. Without it the cassette
#      defaults to owner `:anthropic`, `LAIN_RECORD=ollama` earns it `:none`, and
#      the recording silently does not happen.
#
# == WHY EXACTLY ONE `/api/ps`, for a run of two turns
#
# `Provider::Ollama#context_window_tokens` is deliberately un-memoised and T13's
# header says an N-turn cassette wants N probes. That is true of a cassette
# driven at the PROVIDER. It is not true here, and the difference is the wiring:
# there is one caller of that method in lib/ ({Backend::WindowBook#book}),
# reached through {Backend#context_window}, which memoizes the BOOK -- and
# {Backend::WindowBook::Live} stops re-resolving the moment its answer is
# authoritative. This cassette's `/api/ps` names a resident runner, so the very
# first resolution is PROBED and settles; the turn stack's
# {Middleware::ResolveWindow} then asks nothing on either turn.
#
# T6 made that a live guard rather than a property of a memo. A book that kept
# re-resolving after it had a measured answer would probe once per turn, and
# THIS FILE is where that fails loudly: the second probe finds the cassette
# already consumed and raises mid-run. Take a sudden `VCR::Errors::
# UnhandledHTTPRequestError` on `/api/ps` here as "something started asking
# again", not as a recording problem.
#
# So the number to count is BACKEND CONSTRUCTIONS, not turns. A second Backend --
# a subagent spawn, a second run in one example -- is a second probe, and it
# would raise: once a cassette owns `/api/ps` it owns it for good, and the global
# empty-models stub no longer answers (spec/support/ollama_probe.rb). Under-
# recording raises loudly mid-run; over-recording is merely dead weight, since an
# unplayed interaction is asserted by nothing.
#
# == WHAT A GREEN REPLAY DOES AND DOES NOT PROVE
#
# `match_requests_on: %i[method uri]`, deliberately (vcr_configuration.rb). Every
# turn here is `POST /api/chat`, so turn N replays turn N's recorded answer
# REGARDLESS OF WHAT THE AGENT ACTUALLY ASKED.
#
# The boundary that draws is NOT cassette-versus-record, which is where the first
# edition of this comment put it and was wrong. It is **what the run SENT against
# what the run DID** -- and a session record, however honest, only ever witnesses
# the second.
#
# Measured rather than reasoned. Three textbook orchestration regressions --
# dropping the last message before it reaches the wire, rendering no system prompt
# at all, sending `tools: []` -- each leave a PERFECTLY CORRECT session record.
# The tool is still dispatched, its result still journaled under the right id, the
# turn chain still closed on the right head. All three replayed green to the end,
# including the example named for dispatching the tool. A diverged loop most
# certainly can produce a clean record.
#
# So the SEND side is asserted too, and it needs no new instrument: the run
# already journals `request_sent` carrying the full rendered payload --
# `messages`, `system`, `tools`. The two examples that read it are what turn those
# three mutants red, one example each, and they are the reason this file can claim
# anything about the conversation rather than only about its bookkeeping.
#
# The claim in the other direction was wrong too, and is worth correcting because
# it undersells the record: a run that fed back the WRONG tool result does NOT
# replay green. `read_file`'s bytes travel in the journaled tool_result, so
# truncating them reds the dispatch example. Only what never reached the WIRE was
# ever invisible here.
#
# == WHAT THIS CANNOT CATCH, said here so nobody trusts it further
#
# WebMock hands a stubbed body back as ONE CHUNK
# (spec/lain/provider/ollama/streamed_failure_spec.rb:5-9; lain.gemspec:77-80
# makes the same point about VCR storing a body as one blob). So a regression
# that split an NDJSON line across two TCP reads, or spliced a retried attempt's
# bytes onto an abandoned one's, replays green here forever. F7b and F7c need a
# real severable socket and belong to T10 and T12. An example here implying
# otherwise would be worse than no example.
#
# == Hygiene
#
# The cassette is named `ollama_run_tool_loop.yml` so the guard group at the
# bottom of spec/lain/provider/ollama_recorded_spec.rb sweeps it -- that group
# globs every `ollama_*.yml`, so this file adds no guard of its own and the
# repository rule stays in one place. The GATE is still `before_record` in
# spec/support/vcr_configuration.rb; the sweep is the backstop, it is fail-open,
# and it does not run during a recording pass. Read the cassette by eye before
# committing it.
module T14RecordedRun
  module_function

  # Ollama's own default, and what the committed cassette's URIs say. Passed
  # explicitly rather than left to the default so a reader can see the two agree,
  # and because under `match_requests_on: %i[method uri]` the recorded URI is
  # what replay matches on.
  API_BASE = "http://localhost:11434"
  MODEL = Lain::Provider::Ollama::DEFAULT_MODEL

  # What `/api/ps` said the resident runner was being served with at recording
  # time -- the same figure T13 recorded, from the same box and the same runner.
  # It is asserted below as the DENOMINATOR the run's compaction accounting used,
  # which is the whole of why this cassette records a probe at all.
  SERVED_CONTEXT_TOKENS = 32_768

  # The one file the run's tool reads. Written into a throwaway project per
  # example, so the tool has something real to open and the answer has somewhere
  # to come from that is not the prompt. Deliberately NOT a file in this
  # repository: the recorded answer would then move whenever that file did.
  NOTES = "# Cartogram\n\nA study bench for agent harnesses.\n"

  # Terse to the point of being curt, and that is the whole reason for it. A
  # streamed NDJSON body is ONE JSON OBJECT PER TOKEN, so the reply's token count
  # IS the cassette's size -- and qwen3:4b is a Thinking finetune with no ceiling
  # to hold it: {Provider::Ollama::Encoding} renders no `num_predict`, so
  # `max_tokens` below bounds nothing on this arm.
  #
  # What bounds it is how much there is to deliberate about. Measured against the
  # live server at temperature 0, one instruction at a time, thinking on:
  #
  #     "read_file NOTES.md"                                  173 tokens
  #     "read_file NOTES.md and report its title."            599
  #     "read_file NOTES.md, then name the project."          800
  #     "Use the read_file tool ... reply with only the ..."  734
  #
  # Every added clause is something to weigh, and it is paid for in cassette
  # bytes. The bare form still calls the tool -- which is all this run needs of
  # the first turn -- and the second turn's answer is then the model's own
  # reading of the file rather than a sentence this prompt dictated.
  #
  # `/no_think` in the prompt does NOT work here and was measured before being
  # rejected: ollama's qwen3 template ignores it when tools are present, and the
  # only switch that lands is the wire's own `think: false`, which rides
  # `Request#extra` and has no CLI flag to reach it through. Adding one to make a
  # spec cheaper would be the tail wagging the dog.
  PROMPT = "read_file NOTES.md"

  # The recorded reply, verbatim and whitespace included -- the model's own
  # bytes, not a shape this spec asked for. It quotes {NOTES} back, which is the
  # tell that the tool's result really did reach the second turn: the model was
  # never sent that text in a prompt, it was handed it as a tool_result.
  #
  # An equality, never a pattern, for T13's reason: an ollama server is listening
  # on this port throughout, and a 4B model reproducing a paragraph
  # token-for-token is not a thing that happens. Equality is what proves the bytes
  # came off the file.
  REPLY = <<~TEXT.chomp
    The content of `NOTES.md` is:

    ```
    # Cartogram

    A study bench for agent harnesses.
    ```
  TEXT

  # What one replayed run leaves behind: the Response the Agent answered with,
  # and the session record it wrote. Both, because the reply alone cannot carry
  # the claim (see the header).
  Run = Data.define(:answer, :records, :line_count)

  # A throwaway XDG_STATE_HOME so the session record lands in the tmpdir rather
  # than in the machine's real state directory, and a throwaway project so the
  # tool's read resolves somewhere this example owns.
  def drive
    Dir.mktmpdir("lain-t14-state") do |state|
      Dir.mktmpdir("lain-t14-project") do |project|
        File.write(File.join(project, "NOTES.md"), NOTES)
        journaled(state) { |chronicle| ask(chronicle, state, project) }
      end
    end
  end

  # A REAL chronicle, not the Null: "the session records a close" is an assertion
  # about a file, and {CLI::Chronicle::Null#close} writes nothing to one.
  #
  # `ensure` closes it on every path, including the raise an unrecorded request
  # produces -- which flushes the record and returns the fd rather than leaking it
  # into the next example. It does NOT preserve the journal for inspection, and an
  # earlier edition of this comment claimed it did: {#drive}'s `Dir.mktmpdir` block
  # removes the whole tree on the way out, so a failed run leaves no file behind.
  # That is deliberate rather than a gap -- the RSpec failure names the missing
  # interaction precisely, which is the diagnosis a half-written journal would
  # only corroborate -- but it is not what the word "ensure" promises on its own.
  def journaled(state)
    paths = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => state })
    chronicle = Lain::CLI::Chronicle.for(enabled: true, paths:)
    path = chronicle.journal_path
    answer = begin
      yield chronicle
    ensure
      chronicle.close(reason: :exit)
    end
    Run.new(answer:, records: records_in(path), line_count: File.readlines(path).size)
  end

  # The whole point of the card, in one method: the Agent is assembled by the
  # production wiring over a production {CLI::Backend}, so the provider, the
  # window book, the compaction mount and the toolset are the ones a real
  # `lain chat` builds. A hand-built Agent would cover the loop and skip all
  # four -- and the wiring is exactly where F3 lived.
  def ask(chronicle, state, project)
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:,
                                   status_feed: Lain::StatusFeed.new(path: File.join(state, "state.json")),
                                   project: Lain::Project.new(root: project, cwd: project,
                                                              kind: :project, detected_by: :flag))
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    agent.ask(PROMPT)
  end

  # temperature 0 and a fixed seed so a re-recording lands near the same bytes,
  # and NO `--num-ctx`: sending one reloads the runner at a different window and
  # makes the chat recording disagree with the `/api/ps` one.
  def backend
    Lain::CLI::Backend.new(provider: "ollama", model: MODEL, api_base: API_BASE,
                           max_tokens: 512, temperature: 0, seed: 1)
  end

  # {Lain::Journal.records}' skipping contract is not wanted here: an unparseable
  # line must be COUNTABLE, because "every line parses" is one of the claims.
  def records_in(path) = File.readlines(path).filter_map { |line| parse(line) }

  def parse(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def turns(run) = run.records.select { |record| record["type"] == "turn" }
  def blocks(run) = turns(run).flat_map { |record| record["content"] }
  def decisions(run) = run.records.select { |record| record["type"] == "compaction_decision" }

  # What each turn SENT, in render order -- the half a body-blind replay cannot
  # see. {Middleware::JournalRequests} writes one per round trip, and its
  # `payload` is the rendered Request itself, so `messages`, `system` and `tools`
  # are the literal wire content and not a summary of it.
  def payloads(run)
    run.records.select { |record| record["type"] == "request_sent" }.map { |record| record["payload"] }
  end

  # Every block of every message in one payload, flattened. A message's `content`
  # is a String on a plain user turn and an Array of blocks once tools are in
  # play, so both shapes have to survive the walk -- and `grep(Hash)` is what
  # keeps a String from being asked for a `["type"]`.
  def sent_blocks(payload) = payload["messages"].flat_map { |message| Array(message["content"]) }.grep(Hash)
end

RSpec.describe "a whole recorded run", :seam, records: :ollama,
                                              vcr: { cassette_name: "ollama_run_tool_loop" } do
  # ONE run per example, not one per file: a cassette is inserted per example and
  # its interactions are consumed as they play, so a run shared across examples
  # would be replayed from an exhausted file. Each example therefore drives the
  # whole thing again -- three HTTP interactions, no network -- which is also what
  # makes each of them a genuinely independent replay.
  subject(:run) { T14RecordedRun.drive }

  # {MODEL}, not the literal the cassette happens to hold: bump
  # `Provider::Ollama::DEFAULT_MODEL` and the run would ask for a new model while
  # the recording kept answering `qwen3:4b`, which a literal would call a pass.
  #
  # The usage is pinned for its own reason. Rewriting both recorded token counts
  # to 1 reds nothing without it, so a usage-decode regression would leave every
  # occupancy and every compaction threshold in the run wrong, greenly.
  it "answers with the recorded reply" do
    expect(run.answer.text).to eq(T14RecordedRun::REPLY)
    expect(run.answer.model).to eq(T14RecordedRun::MODEL)
    expect(run.answer).to stop_with(:end_turn)
    expect([run.answer.usage.input_tokens, run.answer.usage.output_tokens]).to eq([3_446, 367])
  end

  # AC2, and the first assertion the cassette cannot fake: a tool_result is
  # written by the RUN, from bytes the run read off the disk, and the id
  # correlating it is the one the recorded turn asked with. A loop that dispatched
  # nothing, or dispatched and dropped the answer, records neither -- and one that
  # dispatched and truncated the bytes reds here, which is the half of the
  # divergence question a session record CAN answer.
  #
  # The id equality is belt-and-braces rather than the load-bearing check:
  # `Ollama::Encoding` recovers a tool_result's name from the prior call's id, so
  # forcing a mis-correlation reds six of seven examples on `names.fetch` raising
  # first. It is kept because it states the invariant at the place a reader looks
  # for it.
  it "dispatched the tool, and fed the file's real bytes back under the call's own id" do
    call = T14RecordedRun.blocks(run).find { |block| block["type"] == "tool_use" }
    result = T14RecordedRun.blocks(run).find { |block| block["type"] == "tool_result" }

    expect(call.values_at("name", "input")).to eq(["read_file", { "path" => "NOTES.md" }])
    expect(result["tool_use_id"]).to eq(call["id"])
    expect(result["content"]).to eq(T14RecordedRun::NOTES)
    expect(result["is_error"]).to be(false)
  end

  # The send side, which nothing else here can see. `request_sent` holds the
  # rendered payload, so this is the conversation the model was ACTUALLY asked --
  # and a loop that dropped the last message before the wire reds here while
  # leaving every other example in this file green (measured).
  it "asked the second turn with the whole conversation, tool result included" do
    payloads = T14RecordedRun.payloads(run)
    call = T14RecordedRun.blocks(run).find { |block| block["type"] == "tool_use" }
    results = T14RecordedRun.sent_blocks(payloads.last).select { |block| block["type"] == "tool_result" }

    expect(payloads.size).to eq(2)
    expect(payloads.last["messages"].map { |message| message["role"] }).to eq(%w[user assistant user])
    expect(results.map { |block| block.values_at("tool_use_id", "content") })
      .to eq([[call["id"], T14RecordedRun::NOTES]])
  end

  # The other two send-side regressions, and both are invisible to the record: a
  # blank system prompt and an empty `tools` array each leave a flawless session
  # record and a green replay.
  #
  # Deliberately NOT a count. Pinning `tools.size == 20` would red this file the
  # day an unrelated card adds a twenty-first tool, which is the escalation
  # trigger this card was given -- "re-recorded to make somebody else's specs
  # pass" is the same failure wearing a different hat. What is asserted is that
  # the run offered SOMETHING, offered the same something twice, and offered the
  # tool it went on to dispatch.
  it "offered a system prompt and the run's own toolset on every request" do
    payloads = T14RecordedRun.payloads(run)
    offered = payloads.map { |payload| payload["tools"].map { |tool| tool["name"] } }

    expect(offered.uniq.size).to eq(1)
    expect(offered.first).to include("read_file")
    expect(payloads.map { |payload| Array(payload["system"]).sum { |block| block["text"].to_s.length } })
      .to all(be_positive)
  end

  # The tool ran through the real {Effect::Handler::Live} behind the run's real
  # gate, so it also announced its read to the session -- which is a different
  # record, written by a different collaborator, naming the file on disk.
  it "records the read against the session, not only against the turn" do
    reads = run.records.select { |record| record["type"] == "session_read" }

    expect(reads.map { |record| File.basename(record["path"]) }).to eq(["NOTES.md"])
  end

  # AC3. `line_count` against the parsed count is the non-vacuous half: the
  # Journal is NDJSON and one stray byte of interleaved output makes exactly one
  # line unparseable, which is the failure output discipline exists to prevent.
  it "leaves a session record whose every line parses and which closes" do
    expect(run.records.size).to eq(run.line_count)
    expect(run.records.first["type"]).to eq("session")
    expect(run.records.last.values_at("type", "reason")).to eq(%w[session_closed exit])
  end

  # The turn chain, end to end: four turns, each naming its parent, closing on
  # the head the record was closed at. This is the orchestration claim -- it is
  # written from the run's own Timeline and a replayed body cannot supply it.
  it "commits a parented chain of turns whose head is the one it closes on" do
    turns = T14RecordedRun.turns(run)
    closed = run.records.last

    expect(turns.map { |turn| turn["role"] }).to eq(%w[user assistant user assistant])
    expect(turns.map { |turn| turn["parent"] }).to eq([nil, *turns[0..-2].map { |turn| turn["digest"] }])
    expect(closed["head"]).to eq(turns.last["digest"])
  end

  # F3, over the path QA broke, with the denominator coming off the wire. The
  # cassette's `/api/ps` is what makes this assertable: with no recorded probe the
  # global empty-models stub answers, the book falls to
  # {ContextWindow::CONSERVATIVE_FALLBACK}, and the run is accounted at 8,192 --
  # the exact defect this chunk exists to fix, replaying green forever. So this
  # example is also what proves the recorded probe was made and won.
  it "denominates its compaction accounting by the window the server said it was serving" do
    decisions = T14RecordedRun.decisions(run)

    # One per turn, so the count is also the statement that both turns were
    # accounted -- a `uniq` over an empty list satisfies nothing.
    expect(decisions.size).to eq(2)
    expect(decisions.map { |record| record["window_tokens"] }.uniq)
      .to eq([T14RecordedRun::SERVED_CONTEXT_TOKENS])
    expect(decisions.map { |record| record["provenance"] }.uniq).to eq(["probed"])
    # The NUMERATOR, pinned beside the denominator it is divided by. The leading
    # nil is the first turn, decided before any usage exists to decide on; 3,401
    # is what the recorded round trip reported. Without this a usage-decode
    # regression leaves the accounting wrong and this example green, since a
    # provenance and a window can both be right about a number nobody measured.
    expect(decisions.map { |record| record["used_tokens"] }).to eq([nil, 3_401])
  end

  # The other half of "the cassette is the boundary", copied from T13 because the
  # claim is the same one and it is worth making per cassette: an ollama server is
  # listening on exactly this host and port throughout, and a request this file
  # does not hold still cannot leave the machine.
  it "refuses a request the cassette does not hold, rather than reaching the live server" do
    expect(VCR.current_cassette.recording?).to be(false)

    expect { Net::HTTP.get(URI("#{T14RecordedRun::API_BASE}/api/version")) }
      .to raise_error(VCR::Errors::UnhandledHTTPRequestError)
  end
end
