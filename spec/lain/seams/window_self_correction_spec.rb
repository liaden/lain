# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# End to end, over the wiring the defect was measured on: a real
# {Lain::CLI::Backend} resolves the run's window book from a real `--num-ctx`
# and a real (stubbed-at-the-socket) ollama, the real turn stack
# {Lain::CLI::Wiring} builds re-resolves it, and a real
# {Lain::Compaction::Source} journals what it divided by.
#
# The defect: an operator's `--num-ctx` is a REQUEST, not a measurement. With
# nothing resident the provider answers nil, `.compact` dropped it, and the
# operator's number became the whole book tagged PROBED -- the tier whose
# docstring says "the server said so". `--num-ctx 999999` on a model trained to
# 262,144 journaled `window=999999 provenance="probed"` while ollama served
# 262,144.
#
# It lives here rather than in `spec/lain/cli/backend_spec.rb` because no single
# subject owns it: the number is resolved in one object, tagged in a second,
# refreshed by a third and spent by a fourth, and the two claims below -- that a
# guess never authorises a rewrite, and that it stops being a guess -- are only
# true of the four together. Nothing is doubled but the model.
RSpec.describe "a --num-ctx window self-corrects once its runner is resident", :seam do
  let(:model) { "qwen3:4b" }
  let(:num_ctx) { 16_384 }
  # SMALLER than `--num-ctx`, which is the case that moves both halves of the
  # answer at once: `Provider::Ollama#context_window_tokens`' own docstring
  # requires the caller to take the `min`, so a runner left at 8,192 by `ollama
  # run` or a sibling session is what the run must divide by until it reloads.
  # Were it larger, the `min` would keep the number at `--num-ctx` and only the
  # provenance would move -- true, and half the property.
  let(:stale_runner) { 8_192 }
  let(:input_tokens) { 15_000 }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # How long every `/api/ps` probe takes, as the window book's clock sees it.
  # Injected rather than measured, so the budget it charges never depends on how
  # loaded the box running the spec is.
  let(:probe_seconds) { 0.0 }

  # Nothing resident: the ordinary state of a box whose runner has not loaded
  # yet, and the premise of the whole file. Registered per example so a later
  # registration wins, exactly as every spec wanting a resident runner relies
  # on (see spec/support/ollama_probe.rb).
  def nothing_resident
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate("models" => [])
    )
  end

  def runner_resident(context_length: stale_runner)
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("models" => [{ "name" => model, "model" => model,
                                         "context_length" => context_length }])
    )
  end

  # The trained maximum, so this is a launch the ceiling check actually let
  # through rather than one that never reached it.
  def trained(context_length: 262_144)
    stub_request(:post, %r{/api/show}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("model_info" => { "general.architecture" => "qwen3",
                                            "qwen3.context_length" => context_length })
    )
  end

  def backend
    @backend ||= priced(Lain::CLI::Backend).new(provider: "ollama", model:, max_tokens: 1024,
                                                num_ctx:, compact_keep: 2)
  end

  # {Lain::CLI::Backend#context_window} exactly, with the probe clock injected.
  # Every other part of the run -- the provider, the book, its sharing -- is the
  # real one.
  def priced(backend_class)
    seconds = probe_seconds
    Class.new(backend_class) do
      define_method(:context_window) do
        @context_window ||= begin
          now = 0.0
          book = Lain::CLI::Backend::WindowBook.new(backend: self, clock: -> { now += seconds })
          Lain::CLI::Backend::WindowBook::Live.new(source: book)
        end
      end
    end
  end

  # THE REAL TURN STACK, from the object that wires one for a live chat, over
  # the run's own book. Rebuilding the composition here would prove that this
  # file can compose a middleware, which is not the claim.
  def turn_stack
    Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new,
                          status_feed: instance_double(Lain::StatusFeed),
                          project: Lain::Project.new(root: Dir.pwd, cwd: Dir.pwd, kind: :project,
                                                     detected_by: :flag))
                     .send(:turn_phase, -> {}, backend.context_window)
  end

  # The response ECHOES the model, as a real provider's does, because that is
  # the string {Lain::StatusFeed#occupancy_of} divides by while
  # {Lain::Agent#occupancy} divides by `context.model` -- the two-surface split
  # {Lain::CLI::Backend::WindowBook::Served} names in its own docstring, and the
  # one this file's last example is about.
  def scripted_model
    Lain::Provider::Mock.new(responses: Array.new(16) do
      text_response("a considered answer " * 200, model:, usage: Lain::Usage.new(input_tokens:))
    end)
  end

  def agent(sink: journal)
    @agent ||= Lain::Agent.new(
      provider: scripted_model, toolset: Lain::Toolset.new([]), journal: sink, turn_middleware: turn_stack,
      context: backend.context(system_override: "a system prompt"),
      pipeline_source: backend.pipeline_source(cache_profile: backend.provider.cache_profile, journal:),
      context_window: backend.context_window
    )
  end

  # Three, not one: the decision on turn zero has no last-turn usage to divide,
  # so a single-turn run journals a decision whose `used_tokens` is nil and
  # proves nothing about a denominator.
  def converse(turns, sink: journal)
    turns.times { |index| agent(sink:).ask("turn #{index}") }
  end

  def records = journal_io.string.each_line.filter_map { |line| Lain::Journal.parse(line) }
  def decisions = records.select { |record| record["type"] == "compaction_decision" }
  def measured = decisions.reject { |record| record["used_tokens"].nil? }

  describe "the first resolution, before the model is loaded" do
    before do
      trained
      nothing_resident
      converse(3)
    end

    # The number stands: discarding a plausible `--num-ctx` would over-report
    # 4x on the ordinary `--num-ctx 32768` case, and the operator did ask for
    # this window.
    it "divides by the --num-ctx the operator asked for" do
      expect(decisions.map { |record| record["window_tokens"] }.uniq).to eq([num_ctx])
    end

    # And it is a GUESS, which is the whole card: nobody measured it. The
    # provenance field is what makes a denied trigger legible rather than
    # merely absent.
    it "records that window as a guess, not as something the server said" do
      expect(decisions.map { |record| record["provenance"] }.uniq).to eq(["guessed"])
    end

    # Not vacuous: the ratio really is crossed, so the example below is about a
    # refusal rather than about a turn that was never near the threshold.
    it "crosses the trigger ratio it is not allowed to act on" do
      expect(measured).not_to be_empty
      expect(measured.map { |record| record["used_tokens"] }.max).to be >= (num_ctx * 0.9)
    end

    it "rewrites no history off it" do
      expect(decisions.map { |record| record["compacted"] }.uniq).to eq([false])
      expect(records.map { |record| record["type"] }).not_to include("compaction")
    end
  end

  # The self-correction. A runner appears -- loaded by this run's own first
  # request, or by a sibling session -- and the next re-resolution is the one
  # that upgrades the book. Nothing rewinds: the earlier decisions stay in the
  # record as the guesses they were.
  #
  # TWO turns before the runner appears models a runner arriving one iteration
  # late. A server answering "nothing resident" spends none of the re-asking
  # budget, so how late it may arrive is unbounded; the group re-asked for ten
  # turns below holds that up.
  describe "once the model becomes resident and reports its served window" do
    before do
      trained
      nothing_resident
      converse(2)
      runner_resident
      agent.ask("a later turn")
    end

    it "records the served window as probed on the later turn" do
      expect(decisions.last["window_tokens"]).to eq(stale_runner)
      expect(decisions.last["provenance"]).to eq("probed")
    end

    it "leaves the earlier turns' records exactly as they were written" do
      expect(decisions.first["window_tokens"]).to eq(num_ctx)
      expect(decisions.first["provenance"]).to eq("guessed")
    end

    # The identity half of the arrangement, which the refresh must not break:
    # three readers dividing by three numbers is the failure
    # {Lain::CLI::Backend#context_window}'s memo exists to prevent, and it is
    # the OBJECT that is memoized, not the answer inside it.
    it "corrects the book the whole run already shares, not a second one" do
      expect(backend.context_window.resolve(model).window_tokens).to eq(stale_runner)
      expect(backend.context_window).to be(backend.context_window)
    end

    # And it stops. A measured window is the best answer this book can hold, so
    # re-resolving it would spend a round trip per turn to learn nothing --
    # which is what `spec/lain/seams/recorded_run_spec.rb`'s single recorded
    # `/api/ps` for a two-turn run depends on.
    # The registry is reset rather than counted from zero: the global stub in
    # spec/support/ollama_probe.rb means this file never starts on a clean
    # slate, and an absolute count would encode how many turns the `before`
    # above happened to take.
    it "stops probing once the answer is measured" do
      WebMock::RequestRegistry.instance.reset!

      agent.ask("one more turn")

      expect(a_request(:get, %r{/api/ps})).not_to have_been_made
    end
  end

  def resident_body(context_length)
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("models" => [{ "name" => model, "model" => model, "context_length" => context_length }]) }
  end

  # A server that answers "nothing resident" quickly is cheap to ask and may
  # load the runner on any later turn: evicted by a summarizer on another model,
  # or re-keyed by a sibling command. So it is asked for as long as the answer
  # is a guess -- the measured failure was a session launched during a reload
  # that asked four times, stopped, and divided by 8,192 while ollama served
  # 32,768.
  describe "a server with nothing resident, re-asked until a model loads" do
    let(:num_ctx) { nil }
    let(:served) { 32_768 }
    let(:probe_seconds) { 0.001 }

    before do
      trained
      stub_request(:get, %r{/api/ps})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => [])).times(10)
        .then.to_return(resident_body(served))
      converse(11)
    end

    it "becomes authoritative at the window the runner reports" do
      expect(backend.context_window.resolve(model)).to be_authoritative
      expect(backend.context_window.window_tokens(model)).to eq(served)
      expect(decisions.last).to include("window_tokens" => served, "provenance" => "probed")
    end

    it "rewrites no history off the guesses it made while waiting" do
      expect(decisions.map { |record| record["compacted"] }.uniq).to eq([false])
    end
  end

  # An ollama started after lain refuses the connection in about a millisecond,
  # so those probes cost nothing and the window is learned once it is up.
  describe "a refused connection, then a resident model" do
    let(:num_ctx) { nil }
    let(:probe_seconds) { 0.001 }

    before do
      trained
      stub_request(:get, %r{/api/ps}).to_raise(Faraday::ConnectionFailed).times(4).then.to_return(resident_body(32_768))
      converse(4)
    end

    it "learns the window after three turns of refusals" do
      expect(backend.context_window.resolve(model)).to be_authoritative
      expect(backend.context_window.window_tokens(model)).to eq(32_768)
    end
  end

  # A server that answers, but slowly, costs every agent-loop iteration what
  # it takes -- so it is charged like a host that never answers at all.
  describe "a slow server with nothing resident" do
    let(:probe_seconds) { 0.25 }

    before do
      trained
      nothing_resident
      converse(10)
    end

    it "stops being asked after the launch probe and REASK_LIMIT slow re-asks" do
      expect(a_request(:get, %r{/api/ps}))
        .to have_been_made.times(1 + Lain::CLI::Backend::WindowBook::Live::REASK_LIMIT)
    end
  end

  # The cost ceiling, which is the half of "it re-resolves" a user actually
  # feels. `--num-ctx` alone is GUESSED and a model the shipped table does not
  # carry can only ever settle by a runner answering -- so a host that never
  # answers has a book that can never settle, and the trigger fires once per
  # ITERATION of the agent loop rather than once per user ask. Unbounded, that
  # is a probe per tool call for the whole session: 2.003s each against a
  # black-holed host, measured, so a ten-tool-call turn paid +20s.
  describe "a book that can never settle, on a host that never answers" do
    let(:probe_seconds) { Lain::Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS }

    before do
      trained
      stub_request(:get, %r{/api/ps}).to_timeout
      converse(10)
    end

    it "stops probing after the launch probe and REASK_LIMIT timed-out re-asks" do
      expect(a_request(:get, %r{/api/ps}))
        .to have_been_made.times(1 + Lain::CLI::Backend::WindowBook::Live::REASK_LIMIT)
    end

    # It gave up on LEARNING, not on measuring: the run keeps dividing by the
    # window the operator asked for, and keeps calling it a guess.
    it "keeps the guess it has, and keeps calling it one" do
      expect(decisions.last["window_tokens"]).to eq(num_ctx)
      expect(decisions.last["provenance"]).to eq("guessed")
    end

    # The consequence that actually matters. Exhausting the budget is giving up
    # on learning, never a promotion: the window is still a guess, so
    # `:approaching_window` is still withheld and no history is rewritten.
    it "still authorises no rewrite, however many times it gave up" do
      expect(decisions.map { |record| record["compacted"] }.uniq).to eq([false])
      expect(records.map { |record| record["type"] }).not_to include("compaction")
    end
  end

  # The invariant the refresh is bounded BY. A book whose answer can move is
  # only safe while every reader inside one turn sees the same move, which is
  # what the once-per-turn trigger buys and what re-resolving per read would
  # destroy.
  describe "the three readers, within one turn" do
    around { |example| Dir.mktmpdir("lain-window-seam") { |dir| @state_dir = dir and example.run } }

    let(:input_tokens) { 4_000 }
    let(:state_path) { File.join(@state_dir, "state.json") }
    let(:status_feed) { Lain::StatusFeed.new(path: state_path, context_window: backend.context_window) }

    before do
      trained
      runner_resident
      converse(2, sink: Lain::CLI::JournalTee.new(journal, status_feed))
    end

    def published = JSON.parse(File.read(state_path))

    it "report one window: the prompt line, the published state and the compaction decision" do
      decided = measured.last["used_tokens"].fdiv(measured.last["window_tokens"])

      expect(agent.occupancy).to eq(decided)
      expect(published["occupancy"]).to eq(decided)
    end

    it "divide by the window the server reported, on its own authority" do
      expect(measured.last["window_tokens"]).to eq(stale_runner)
      expect(measured.last["provenance"]).to eq("probed")
    end
  end

  # The invariant the two producers jointly own, on the shape that reaches it.
  # The block above asserts the same equality, but it converses at 4,000 input
  # tokens -- a reading both producers take -- so it stays green through any
  # divergence in the guard. A turn reporting no input tokens is the one input
  # that separates them, and each producer decides independently whether to
  # take it: {Lain::Agent::Accounting} from a real {Lain::Usage}, the feed from
  # the String-keyed hash off the journal.
  describe "a turn that reports no input tokens, across both producers" do
    around { |example| Dir.mktmpdir("lain-window-seam") { |dir| @state_dir = dir and example.run } }

    let(:input_tokens) { 4_000 }
    let(:state_path) { File.join(@state_dir, "state.json") }
    let(:status_feed) { Lain::StatusFeed.new(path: state_path, context_window: backend.context_window) }

    # A measured turn, then one billing output with no input -- what an ollama
    # body missing `prompt_eval_count` decodes to, and what a stream truncated
    # before its counts arrived produces.
    def scripted_model
      measured = text_response("a considered answer " * 200, model:, usage: Lain::Usage.new(input_tokens:))
      output_only = Lain::Usage.new(input_tokens: 0, output_tokens: 250)
      unmeasured = text_response("and another", model:, usage: output_only)
      Lain::Provider::Mock.new(responses: [measured, unmeasured])
    end

    before do
      trained
      runner_resident
      converse(2, sink: Lain::CLI::JournalTee.new(journal, status_feed))
    end

    def published = JSON.parse(File.read(state_path))

    it "leave one reading standing rather than one of them forgetting" do
      expect(agent.occupancy).to eq(published["occupancy"])
    end

    it "hold the reading the measured turn established, not a fresh zero" do
      expect(published["occupancy"]).to eq(measured.last["used_tokens"].fdiv(measured.last["window_tokens"]))
      expect(published["occupancy"]).to be_positive
    end

    it "say the turn went unmeasured, since suppression is otherwise invisible" do
      expect(published["unmeasured_turns"]).to eq(1)
    end
  end

  # A refusal for not fitting the context names the context the server loaded,
  # so it vouches for the window the way `/api/ps` does. Over the wiring a live
  # chat builds: the real ollama provider and its error mapping, the model phase
  # and turn stack {Lain::CLI::Wiring} composes, a real {Lain::StatusFeed} on the
  # tee. Nothing is resident, so until the refusal the window is a guess.
  describe "an over-window refusal, over a guessed window" do
    around { |example| Dir.mktmpdir("lain-window-seam") { |dir| @state_dir = dir and example.run } }

    let(:refused_at) { 32_768 }
    let(:state_path) { File.join(@state_dir, "state.json") }
    let(:status_feed) { Lain::StatusFeed.new(path: state_path, context_window: backend.context_window) }
    let(:chronicle) do
      Lain::CLI::Chronicle.new(journal: Lain::CLI::JournalTee.new(journal, status_feed),
                               journal_path: "window-vouch-seam.ndjson")
    end

    def backend
      @backend ||= begin
        provider = Lain::Provider::Ollama.new(config: zero_retry_config)
        Class.new(priced(Lain::CLI::Backend)) { define_method(:provider) { |**| provider } }
             .new({ provider: "ollama", model:, max_tokens: 64 })
      end
    end

    def answer(body)
      text = JSON.generate(body["messages"])
      return refusal if text.include?("DOES-NOT-FIT")

      reply = { "model" => model, "message" => { "role" => "assistant", "content" => "settled" }, "done" => true,
                "done_reason" => "stop", "prompt_eval_count" => 2_000, "eval_count" => 1 }
      { status: 200, headers: { "Content-Type" => "application/x-ndjson" }, body: "#{JSON.generate(reply)}\n" }
    end

    def refusal
      inner = { "error" => { "code" => 400, "type" => "exceed_context_size_error", "n_prompt_tokens" => 40_000,
                             "n_ctx" => refused_at, "message" => "request exceeds the available context size" } }
      { status: 400, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("error" => JSON.generate(inner)) }
    end

    def ask
      @ask ||= begin
        wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:,
                                       status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
        recorder, session = wiring.run_state(nil)
        agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
        Lain::CLI::Repl::Ask.new(agent:, tty: nil, chronicle:)
      end
    end

    def hud = JSON.parse(File.read(state_path))["hud"]

    def critique_budget
      Lain::Review::Critique::Budget.for(window: backend.context_window, model:, max_tokens: 512, prelude: "")
    end

    before do
      nothing_resident
      stub_request(:post, %r{/api/chat}).to_return { |request| answer(JSON.parse(request.body)) }
    end

    it "marks the HUD's occupancy as measured against a guess" do
      ask.attempt("hello")

      expect(hud).to match(/ ctx:~\d+% /)
    end

    it "makes the book authoritative at the refused window, and /critique is no longer unvouched" do
      ask.attempt("hello")
      expect { critique_budget }.to raise_error(Lain::Review::Critique::Refused, /guessed/)

      ask.attempt("DOES-NOT-FIT")

      expect(backend.context_window.resolve(model)).to be_authoritative
      expect(backend.context_window.window_tokens(model)).to eq(refused_at)
      expect(critique_budget.window_tokens).to eq(refused_at)
    end

    it "drops the HUD's guess mark on the next measured turn" do
      ask.attempt("hello")
      ask.attempt("DOES-NOT-FIT")

      ask.attempt("and again")

      expect(hud).to match(/ ctx:\d+% /)
    end
  end
end
