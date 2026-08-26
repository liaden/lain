# frozen_string_literal: true

# The EAGER summarizer tier: which provider it fires through, whether that fire
# reaches the Journal, and -- the part a sibling card can break silently -- that
# it still refuses to QUEUE for provider capacity.
#
# The two `#tier` methods on this object and on {Lain::CLI::Backend::SpanSummarizer}
# call the same `#summarizer_provider` with deliberately OPPOSITE `queue:`
# answers, and collapsing that distinction is the defect's own mechanism: the
# eager oracle would start waiting on the turn that produced the tool result it
# is summarizing. So both are pinned, each in its own file.

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module SummarizerSpecSupport
  # Exactly the four messages {Lain::CLI::Backend::Summarizer} declares it
  # depends on, and nothing else -- so an example fails if the subject reaches
  # for a fifth. `journal` is writable because the run's real journal is
  # late-bound: {Lain::CLI::Backend} does not know its destination until
  # `#pipeline_source` runs, which nothing orders against `#tool_observer`.
  class BackendDouble
    attr_reader :queue_answers, :summarizer_model, :summarizer_max_tokens
    attr_accessor :journal

    def initialize(provider:, journal:, summarizer_model: "qwen3:4b", summarizer_max_tokens: 256)
      @provider = provider
      @journal = journal
      @summarizer_model = summarizer_model
      @summarizer_max_tokens = summarizer_max_tokens
      @queue_answers = []
    end

    def summarizer_provider(queue: true)
      @queue_answers << queue
      @provider
    end
  end
end

RSpec.describe Lain::CLI::Backend::Summarizer do
  let(:journal) { RecordingChannel.new }

  let(:reply) do
    Lain::Response.new(model: "qwen3:4b", stop_reason: :end_turn,
                       content: [{ "type" => "text", "text" => %({"summary":"three files, one stale"}) }],
                       usage: Lain::Usage.new(input_tokens: 40, output_tokens: 12))
  end

  let(:provider) { Lain::Provider::Mock.new(responses: [reply]) }
  let(:backend) { SummarizerSpecSupport::BackendDouble.new(provider:, journal:) }

  def oracle = described_class.new(backend:).oracle

  def summarize(built = oracle) = Sync { built.ask(source: "a long tool result").await }

  def requests = journal.events.grep(Lain::Telemetry::RequestSent)

  describe "the record an eager summary leaves" do
    # The acceptance criterion: the round trip an oracle spends is
    # invisible in the Journal today, because Oracle::Model calls #complete
    # directly and no middleware stack sits anywhere near it.
    it "journals a request_sent whose digest is the request the tier actually sent" do
      summarize

      expect(requests.map(&:digest)).to eq([provider.last_request.digest])
    end

    it "carries the cache_payload and prefix chain, which no wire-level observer could rebuild" do
      summarize

      sent = provider.last_request
      expect(requests.last).to have_attributes(payload: sent.cache_payload, prefix_digests: sent.prefix_digests)
    end

    # The oracle_answer record is {Oracle::Recorded::Journaling}'s, and it must
    # still land alongside: the request is the ATTEMPT, the answer is what it
    # bought, and a request_sent with no following oracle_answer is how a failed
    # oracle reads.
    it "leaves the attempt and the answer, in that order" do
      summarize

      expect(journal.events.map(&:class)).to eq([Lain::Telemetry::RequestSent, Lain::Telemetry::OracleAnswer])
    end

    # Late binding is why {Summarizer::RunJournal} exists at all: nothing orders
    # {Backend#tool_observer} -- which builds this oracle -- against
    # {Backend#pipeline_source}, which is where the run's journal gets bound. A
    # wrap that captured its destination eagerly would hold Channel::Null for
    # the whole run: every summary answered, none recorded, nothing raised.
    it "resolves the run's journal per record, not at construction" do
      built = oracle
      bound = RecordingChannel.new
      backend.journal = bound

      summarize(built)

      expect(bound.events.grep(Lain::Telemetry::RequestSent).size).to eq(1)
    end
  end

  # The collision between the two findings, pinned -- and it is a CHANGE to the
  # journal's observable shape, not a restatement of it.
  #
  # `oracle/eager.rb` said for a long time that a failed fire "journals nothing
  # (a journaling tier never reached its write)". Recording the request
  # made that false: {Lain::Provider::Journaled} cuts its record BEFORE dispatch,
  # while the capacity gate sits INSIDE `Ollama#complete` (`ollama.rb:188`). So a
  # summary skipped for capacity -- that very case -- now leaves an attempt where
  # it used to leave silence. Two doctrine comments were false with nothing red
  # to catch them, which is the exact shape this work exists to end; they are
  # corrected, and this is what would go red if they drifted back.
  describe "an eager fire the endpoint refuses for capacity" do
    # A REAL gate on a REAL provider, because the ordering claim is about where
    # the gate sits relative to the record, and a double raising Busy from
    # #complete would assert that ordering by construction instead of observing
    # it. A per-example endpoint keeps the process-global Admission registry from
    # becoming shared state between examples.
    let(:endpoint) { "http://127.0.0.1:11434/#{SecureRandom.hex(4)}" }

    # `queue: false` is what {Summarizer#tier} asks `#summarizer_provider` for,
    # so a busy endpoint REFUSES this caller rather than queueing it -- the skip
    # {Lain::Oracle::Eager}'s task boundary contains. No HTTP is stubbed and none
    # is needed: the refusal happens before the block the slot would have run.
    let(:provider) { Lain::Provider::Ollama.new(api_base: endpoint, queue: false) }

    # Holding the slot in the SAME fiber rather than racing a sleeping holder
    # against a sleeping caller: `try_enter` refuses immediately instead of
    # blocking, so there is no re-entrancy hang to dodge and no timing to lose
    # under load (docs/toolchain-traps.md's load-induced-flake list is full of the other
    # shape).
    def fire_against_a_held_slot(eager)
      Sync do
        Lain::Provider::Admission.for(endpoint:).enter do
          eager.fire("source-digest", "a long tool result")&.wait
        end
      end
    end

    it "leaves the attempt and no answer, because the gate refuses after the record is cut" do
      eager = Lain::Oracle::Eager.new(oracle:)

      fire_against_a_held_slot(eager)

      expect(journal.events.map(&:class)).to eq([Lain::Telemetry::RequestSent])
    end

    it "still holds no summary: the record is an attempt, never a result" do
      eager = Lain::Oracle::Eager.new(oracle:)

      fire_against_a_held_slot(eager)

      expect(eager.held("source-digest")).to be_nil
    end
  end

  # The escalation trigger, pinned. `queue: false` is asked for in exactly one
  # place, and `oracle/eager.rb:45-47` promises the turn that produced a tool
  # result never waits on its summary.
  describe "willingness to wait for capacity" do
    it "still declines to queue after the provider is wrapped" do
      oracle

      expect(backend.queue_answers).to eq([false])
    end
  end
end
