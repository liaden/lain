# frozen_string_literal: true

require "json"
require "stringio"

# When no cut can make room, a handoff writes one state document and the ask is
# answered anyway -- over the objects a live chat really wires, with nothing
# doubled between them: a real {Lain::Agent} with its real
# {Lain::Compaction::Source}, the real {Lain::Middleware::RequestBudget} in a
# real model phase, a real {Lain::Session} journaling to a real
# {Lain::Journal}, and the handoff tier as a real {Lain::Oracle::Model} behind
# the real {Lain::Oracle::Recorded::Journaling} wrapper.
#
# The two providers are recorded: the chat one refuses exactly as ollama does
# once it is asked not to truncate (a {Lain::WindowExceeded} carrying the
# provider's own count), and the summarizer one answers the handoff schema.
# What the refusal keys on is the HISTORY -- so the retry succeeds only if the
# handoff really replaced it, and never because the ask was reworded.
module HandoffSeam
  # The text that makes the prompt too big, so an example can say the history
  # is GONE from the retried render rather than merely smaller.
  MARKER = "HISTORY-MARKER"

  # The recorded runner refuses a render of this many messages or more: the
  # keep_last tail alone overflowing the context it loaded, which is the case
  # no cut can answer -- an advance may drop nothing inside keep_last, and
  # there is only ever one cut to collapse.
  REFUSES_AT = 5

  # The state the summarizer writes back. Deliberately carries none of
  # {MARKER}: the retried render passes only because the history is gone.
  ANSWER = { "goal" => "finish the parser", "progress" => "the lexer lands and its specs pass",
             "files_and_decisions" => "lexer.rb; hand-rolled, no regexes",
             "open_todos" => "the parser and its error messages",
             "next_step" => "write parser.rb over the lexer's token stream" }.freeze

  # A provider whose answer depends on what it was asked, the way a recorded
  # one does. The chat arm refuses while the history is still in the prompt;
  # the summarizer arm answers the handoff schema. It is told apart by a phrase
  # from the FIXED half of the template -- a section heading would vanish with
  # its slot on a session that had no summaries or no pins.
  class Recorded
    class Refusal < Lain::Error
      include Lain::WindowExceeded
    end

    attr_reader :requests

    def initialize(refusing:)
      @refusing = refusing
      @requests = []
    end

    def complete(request)
      @requests << request
      text = Lain::Canonical.dump(request.messages)
      return summary if text.include?("no longer fits its context window")
      raise refusal if @refusing && request.messages.size >= REFUSES_AT

      Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 40, output_tokens: 2))
    end

    def supports?(_capability) = false

    def cache_profile = Lain::CacheProfile::NO_CACHING

    private

    def refusal
      Refusal.new("request (9000 tokens) exceeds the available context size",
                  prompt_tokens: 9000, window_tokens: 8192, source: "ollama")
    end

    def summary
      Lain::Response.new(content: [{ "type" => "text", "text" => JSON.generate(ANSWER) }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 30, output_tokens: 20))
    end
  end

  # A tier whose reply no decoder can read: the local endpoint answering prose
  # where the schema was asked for, which is the failure the `oracle_failed`
  # record exists to name.
  class Prosaic < Recorded
    private

    def summary
      Lain::Response.new(content: [{ "type" => "text", "text" => "Sure! Here is a summary of the work." }],
                         stop_reason: :end_turn, usage: Lain::Usage.new(input_tokens: 30, output_tokens: 9))
    end
  end
end

RSpec.describe "a handoff when no cut can make room", :seam do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:session) { Lain::Session.new(journal:) }
  let(:toolset) { Lain::Toolset.new([]) }
  let(:context) { Lain::Context.new(model: "qwen3:4b", max_tokens: 64, system: "a system prompt") }
  let(:provider) { HandoffSeam::Recorded.new(refusing: true) }
  let(:summarizer) { provider }

  # The real oracle wiring `CLI::Backend#handoff_oracle` builds: a model tier
  # over the handoff definition, wrapped in the recorder that journals both the
  # answer and the failure.
  def handoff_tier
    definition = Lain::Oracle::Handoff.definition
    inner = Lain::Oracle::Model.new(definition:, provider: summarizer, model: "qwen3:4b", max_tokens: 512)
    Lain::Oracle::Recorded::Journaling.new(inner:, definition:, journal:)
  end

  # `compact_keep` at its shipped twenty, which is what makes this the case the
  # fallback exists for: a short session has no droppable head at all, so no
  # advance and no collapse can make room.
  def source(fallback:, keep_last: 20)
    Lain::Compaction::Source.new(
      need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
      cold: Lain::Compaction::Cold.new(cache_profile: Lain::CacheProfile::NO_CACHING, journal:),
      hard_cap: 1_000_000, keep_last:, journal:, fallback:,
      context_window: Lain::ContextWindow.new(windows: { "qwen3" => 8192 })
    )
  end

  def handing_off = source(fallback: Lain::Compaction::Source::Fallback.new(tier: method(:handoff_tier)))

  def refusing_still = source(fallback: Lain::Compaction::Source::Fallback::None)

  def agent(pipeline_source)
    budget = Lain::Middleware::RequestBudget.new(journal:, compaction: pipeline_source)
    Lain::Agent.new(provider:, toolset:, context:, session:, journal:, pipeline_source:,
                    model_middleware: Lain::Middleware::Stack.new([budget]))
  end

  # Two exchanges, none of them droppable under keep_last twenty. The next
  # render is the first the recorded runner will not take.
  def fill(chat)
    2.times { |index| chat.ask("#{HandoffSeam::MARKER} question #{index}: #{"the lazy dog slept. " * 20}") }
  end

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }

  def of_type(type) = records.select { |record| record["type"] == type }

  def rendered_text(request)
    Lain::Canonical.dump(request.messages)
  end

  describe "a tail that fills the window is handed off and the ask answered" do
    it "commits one handoff cut, journals one summarizer call, and answers the ask" do
      built = handing_off
      chat = agent(built)
      fill(chat)

      answer = chat.ask("so what is left to do?")

      expect(answer.text).to eq("settled")
      expect(of_type("compaction_cut").map { |cut| cut["kind"] }).to eq(["handoff"])
      expect(of_type("oracle_answer").size).to eq(1)
      expect(built).to be_handed_off
    end

    it "sends a render holding the five state headings in place of the history" do
      chat = agent(handing_off)
      fill(chat)

      chat.ask("so what is left to do?")

      sent = rendered_text(provider.requests.last)
      expect(sent).to include("Goal", "Progress", "Files and decisions", "Open todos", "Next step")
      expect(sent).to include("finish the parser")
      expect(sent).not_to include(HandoffSeam::MARKER)
    end

    it "keeps the ask itself, so the answer is to the question that was asked" do
      chat = agent(handing_off)
      fill(chat)

      chat.ask("so what is left to do?")

      expect(rendered_text(provider.requests.last)).to include("so what is left to do?")
      expect(chat.timeline.to_a.last.role).to eq("assistant")
    end

    # There is no estimate before a send: the first request of the ask is the
    # refused one, and only its refusal triggers the fallback.
    it "fires only after a prompt has been refused" do
      chat = agent(handing_off)
      chat.ask("#{HandoffSeam::MARKER} first")

      expect(of_type("compaction_cut")).to be_empty
    end
  end

  describe "a resume renders the handoff" do
    # The live render's chain and the record it left, so an example can
    # re-render it under any `--compact-keep` a resume might be given.
    def handed_off_chat
      chat = agent(handing_off)
      fill(chat)
      chat.ask("so what is left to do?")
      [chat.timeline.rewind(1), provider.requests.last.messages]
    end

    def resumed(line, keep_last:)
      session = Lain::SessionRecord::Replay.new(journal_io.string.each_line).session
      built = source(fallback: Lain::Compaction::Source::Fallback::None, keep_last:)
      [built.context_for(base: context, timeline: line, usage: nil, session:)
            .render(timeline: line, toolset:, workspace: Lain::Workspace.empty).messages, session]
    end

    it "renders byte-identically to the live render, without asking the summarizer again" do
      line, live = handed_off_chat
      calls = provider.requests.size

      messages, session = resumed(line, keep_last: 20)

      expect(session.compaction_cuts.map(&:kind)).to eq(["handoff"])
      expect(Lain::Canonical.dump(messages)).to eq(Lain::Canonical.dump(live))
      expect(provider.requests.size).to eq(calls)
    end

    # The guarantee the boundary exemption replaces. A handoff collapses the
    # keep_last tail ON PURPOSE, so a resume under ANY `--compact-keep` has to
    # render it -- reverting the `holds?` half would drop the cut at a wider
    # keep, and reverting the `refuse_past` half would raise at every keep.
    [1, 2, 4, 8, 12, 20, 100].each do |keep|
      it "renders the same bytes at --compact-keep #{keep} as the live render sent" do
        line, live = handed_off_chat

        messages, session = resumed(line, keep_last: keep)

        expect(session.compaction_cuts.map(&:kind)).to eq(["handoff"])
        expect(Lain::Canonical.dump(messages)).to eq(Lain::Canonical.dump(live))
      end
    end
  end

  describe "with the fallback off" do
    it "leaves the refusal standing, with no handoff cut and no summarizer call" do
      built = refusing_still
      chat = agent(built)
      fill(chat)

      expect { chat.ask("so what is left to do?") }
        .to raise_error(Lain::Middleware::RequestBudget::OverWindow, /9000/)
      expect(of_type("compaction_cut")).to be_empty
      expect(of_type("oracle_answer")).to be_empty
      expect(built).not_to be_handed_off
    end
  end

  # Project memory and compaction are different subsystems with different
  # records, and neither reads the other. A state document is a compaction
  # replacement: it lives in a `compaction_cut` and nowhere else.
  describe "a handoff never writes project memory" do
    it "leaves no memory record behind, only the cut" do
      chat = agent(handing_off)
      fill(chat)
      chat.ask("so what is left to do?")

      expect(records.map { |record| record["type"] }).not_to include("memory_write", "memory_root", "memory_loaded")
      expect(of_type("compaction_cut").size).to eq(1)
    end
  end

  describe "a failed handoff" do
    let(:provider) { HandoffSeam::Prosaic.new(refusing: true) }

    it "journals oracle_failed, commits no cut, and refuses in words naming /rewind" do
      chat = agent(handing_off)
      fill(chat)

      refusal = nil
      begin
        chat.ask("so what is left to do?")
      rescue Lain::Middleware::RequestBudget::OverWindow => e
        refusal = e
      end

      expect(of_type("oracle_failed").map { |record| record["error_class"] })
        .to eq(["Lain::Oracle::UndecodableAnswer"])
      expect(of_type("compaction_cut")).to be_empty
      expect(refusal.message).to include("/rewind")
    end
  end
end
