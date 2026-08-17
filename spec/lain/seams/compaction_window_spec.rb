# frozen_string_literal: true

require "json"
require "stringio"

# F3, end to end, over the path QA actually broke: a real {Lain::CLI::Backend}
# resolves the run's window book, hands it to the real {Lain::Compaction::Source}
# it builds, and a real {Lain::Agent} accounts real turns against it.
#
# The defect: `--model qwen3:4b` matches nothing in the Anthropic-shaped
# {Lain::ContextWindow::DEFAULTS}, so the book fell to
# {Lain::ContextWindow::CONSERVATIVE_FALLBACK}'s 8,192 while the server was
# serving 32,768. Turns at 75-78% of the real window read as ~300% of the guess,
# `:approaching_window` fired, and lain rewrote its own history three times --
# irreversibly, and lossily, each time.
#
# It lives here rather than in `spec/lain/cli/backend_spec.rb` because no single
# subject owns it: the bug was in what the Backend's book means to the Need
# three objects downstream, and every double between them is a place it could
# hide. Nothing is doubled below except the model itself.
RSpec.describe "a guessed context window never authorises a rewrite", :seam do
  # Nothing resident: the ordinary state of a box with no runner up, and the
  # answer that leaves the shipped table's fallback in charge. This is the
  # `/api/ps` shape `spec/support/ollama_probe.rb` already defaults to, said
  # here so the premise of the whole file is visible in it.
  before do
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("models" => [])
    )
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  # `--compact-keep 2` so a handful of turns leaves a droppable head; every
  # other knob is the shipped default. The messages are LONG on purpose: an
  # elision line attests each message it replaces in ~230 bytes, so a history of
  # short replies is one a rewrite would grow, and the scheduler's own floor --
  # not provenance -- would be what declined it.
  #
  # The PROVIDER is a parameter, not a constant, because the two arms below are
  # about different provider wirings and an ollama-wired Backend cannot speak
  # for what an Anthropic run does. `--provider anthropic` resolves a real
  # {Lain::Provider::Anthropic} whose `#context_window_tokens` is the base
  # class's nil -- which is the whole premise of the published arm, and is
  # exercised rather than assumed only when that provider is the one built.
  def backend_for(model:, provider: "ollama")
    Lain::CLI::Backend.new(provider:, model:, max_tokens: 1024, compact_keep: 2)
  end

  # A real Agent over the run's REAL pipeline source, which is what
  # {Lain::CLI::CompactionMount} builds on the chat path.
  def account(backend, input_tokens:, turns: 3)
    responses = Array.new(turns) do
      text_response("a considered answer " * 400, usage: Lain::Usage.new(input_tokens:))
    end
    agent = Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses:), toolset: Lain::Toolset.new([]),
      context: backend.context(system_override: "a system prompt"), journal:,
      pipeline_source: backend.pipeline_source(cache_profile: backend.provider.cache_profile, journal:)
    )
    turns.times { |index| agent.ask("turn #{index}") }
    agent
  end

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def decisions = records.select { |record| record["type"] == "compaction_decision" }
  def signals = decisions.flat_map { |record| record["signals"] }

  # 7_500 is over 0.9 of the 8,192 guess and under 0.9 of every real entry in
  # the shipped table -- the exact band QA's run sat in.
  describe "an ollama model no shipped table carries" do
    before { account(backend_for(model: "qwen3:4b"), input_tokens: 7_500) }

    it "measures against the conservative fallback, and says so in the record" do
      expect(decisions.map { |record| record["window_tokens"] }.uniq)
        .to eq([Lain::ContextWindow::CONSERVATIVE_FALLBACK])
    end

    # Not vacuous: the ratio really is crossed. Without this the example below
    # would pass on a run that never got near the threshold at all.
    it "crosses the trigger ratio it is not allowed to act on" do
      used = decisions.filter_map { |record| record["used_tokens"] }

      expect(used).to include(7_500)
      expect(used.max).to be >= (Lain::ContextWindow::CONSERVATIVE_FALLBACK * 0.9)
    end

    it "never journals the approaching-window signal" do
      expect(signals).not_to include("approaching_window")
    end

    it "never rewrites history off it" do
      expect(decisions.map { |record| record["compacted"] }.uniq).to eq([false])
      expect(records.map { |record| record["type"] }).not_to include("compaction")
    end

    # A denied trigger and a trigger that never fired journal the same empty
    # signal list, and they mean opposite things -- 92% full and refused,
    # against 0.75% full and unremarkable. The record has to say which, or the
    # rewrite QA watched happen becomes a rewrite that silently stops
    # happening, equally invisibly. This is the field that says it.
    it "records that the window was a guess, so a denial is legible" do
      expect(decisions.map { |record| record["provenance"] }.uniq).to eq(["guessed"])
    end
  end

  # The control, and the regression the review panel caught. The variable is
  # the PROVIDER WIRING and the model it resolves -- and it is built through
  # `--provider anthropic` rather than by handing an ollama-wired Backend a
  # claude model name, because the claim being made is about what an Anthropic
  # run measures against. {Lain::Provider#context_window_tokens} is nil for
  # every provider but ollama, so a shipped-table hit is what such a run has;
  # suppressing it would switch `:approaching_window` off for every hosted arm
  # in silence. Wiring it the other way would have proved the ollama path
  # twice and the Anthropic path not at all.
  describe "an Anthropic-wired run on a model the shipped table publishes" do
    before do
      with_env("ANTHROPIC_API_KEY" => "sk-test") do
        account(backend_for(model: "claude-opus-4-5", provider: "anthropic"), input_tokens: 190_000)
      end
    end

    # The premise, asserted rather than assumed: this provider reports no
    # served window, so the table is genuinely what answered.
    it "resolves through the shipped table because the provider serves no window" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(model: "claude-opus-4-5", provider: "anthropic").provider
      end

      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.context_window_tokens("claude-opus-4-5")).to be_nil
    end

    it "measures against the published window" do
      expect(decisions.map { |record| record["window_tokens"] }.uniq).to eq([200_000])
    end

    it "records the window as published, not measured-or-not" do
      expect(decisions.map { |record| record["provenance"] }.uniq).to eq(["published"])
    end

    it "still journals the approaching-window signal" do
      expect(signals).to include("approaching_window")
    end

    it "still rewrites history off it" do
      expect(decisions.map { |record| record["compacted"] }).to include(true)
    end
  end
end
