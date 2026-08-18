# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# T6, end to end, over the wiring the defect was measured on: a real
# {Lain::CLI::Backend} resolves the run's window book from a real `--num-ctx`
# and a real (stubbed-at-the-socket) ollama, the real turn stack
# {Lain::CLI::Wiring::AgentBuild} builds re-resolves it, and a real
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
    @backend ||= Lain::CLI::Backend.new(provider: "ollama", model:, max_tokens: 1024,
                                        num_ctx:, compact_keep: 2)
  end

  # THE REAL TURN STACK, from the module that wires one for a live chat, over
  # the run's own book. Rebuilding the composition here would prove that this
  # file can compose a middleware, which is not the claim.
  def turn_stack
    Lain::CLI::Wiring::AgentBuild.turn_phase(Lain::CLI::Chronicle::Null.new, -> {}, backend.context_window)
  end

  # The response ECHOES the model, as a real provider's does, because that is
  # the string {Lain::StatusFeed#occupancy_of} divides by while
  # {Lain::Agent#occupancy} divides by `context.model` -- the two-surface split
  # {Lain::CLI::Backend::WindowBook::Served} names in its own docstring, and the
  # one this file's last example is about.
  def scripted_model
    Lain::Provider::Mock.new(responses: Array.new(8) do
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
  # LATE, and that is the point of the number. The minimal real sequence needs
  # only one: ollama fixes a runner's context at LOAD time and this run's own
  # first request is what loads it, so `converse(1)` would land the upgrade on
  # the SECOND re-ask and would pass under a
  # {Lain::CLI::Backend::WindowBook::Live::REASK_LIMIT} of 2. Waiting one turn
  # longer lands it on the THIRD, which is exactly the slack that constant is
  # sized for -- so this group is what holds the limit up from BELOW (drop it to
  # 2 and these examples red), while the never-settle group holds it from above.
  #
  # An earlier edition of this comment called two turns "the real sequence".
  # That was wrong, and worth leaving a marker on: this card's whole subject is
  # comments that quietly stopped being true, and its fix round wrote one.
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

  # The cost ceiling, which is the half of "it re-resolves" a user actually
  # feels. `--num-ctx` alone is GUESSED and a model the shipped table does not
  # carry can only ever settle by a runner answering -- so a box where ollama
  # never answers has a book that can never settle, and the trigger fires once
  # per ITERATION of the agent loop rather than once per user ask. Unbounded,
  # that is a probe per tool call for the whole session: 2.003s each against a
  # black-holed host, measured, so a ten-tool-call turn paid +20s.
  describe "a book that can never settle" do
    before do
      trained
      nothing_resident
      converse(5)
    end

    it "stops probing rather than paying a round trip per turn forever" do
      expect(a_request(:get, %r{/api/ps})).to have_been_made.times(4)
    end

    # It gave up on LEARNING, not on measuring: the run keeps dividing by the
    # window the operator asked for, and keeps calling it a guess.
    it "keeps the guess it has, and keeps calling it one" do
      expect(decisions.last["window_tokens"]).to eq(num_ctx)
      expect(decisions.last["provenance"]).to eq("guessed")
    end

    # The consequence that actually matters, asserted HERE rather than left to
    # the first group -- which exhausts the budget only because it happens to
    # converse three times, an incidental dependency between two groups that
    # would break the moment either turn count moved. Exhausting the budget is
    # giving up on learning, never a promotion: the window is still a guess, so
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
end
