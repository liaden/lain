# frozen_string_literal: true

require "tmpdir"

module Lain
  module Bench
    # Three memory arms over a staleness fixture, each question asked of a fresh {LiveReplay} agent:
    # `memory_on` has the manifest and the memory tools, `memory_off` is the control with neither,
    # and `eager_write` is `memory_on` told to write after every answer. A stale leak is an answer
    # that repeats the old fact, and drift is an answer holding the substring the fixture names, so
    # no model grades another.
    #
    # Under a `confirm:` every request is counted through the provider and priced at most first, as
    # a live compaction sweep is, and each question then runs under a dollar ceiling of
    # {CompactionSweep::Live::CEILING} times its projection.
    class MemorySweep
      ARMS = %w[memory_on memory_off eager_write].freeze

      # What the scan found before this bench measured it, kept beside the measurement.
      PRIOR = "eager write: +15% cost, p 0.015 (scan item 106)"

      # A run with nowhere to send its questions.
      class Unsendable < Error; end

      # The table, raised because a question stopped before it was answered; money may have been spent.
      class Halted < Error; end

      # A question that was not answered, and why.
      Stop = Data.define(:ask, :note)

      DOLLAR_HALT = "not run: an earlier question passed its dollar ceiling"
      STOPS = [Budget::Exceeded, Provider::HTTP::PriceTierGuard::Refused].freeze

      SYSTEM = "Answer the question in one sentence."
      EAGER_SYSTEM = "#{SYSTEM} After every answer, call memory_write to record what you learned.".freeze
      COLUMNS = ["arm", "stale leak", "freshness", "drift", "n", "cost/question", "ci95", "median", "min",
                 "max", "note"].freeze
      NO_CELL = "-"
      private_constant :DOLLAR_HALT, :STOPS, :SYSTEM, :EAGER_SYSTEM, :COLUMNS, :NO_CELL

      # @param fixture [Fixture]
      # @param provider [Provider] answers every arm; counts tokens too under `confirm`
      # @param model [String] the model the provider is asked for and the cost is priced as
      # @param price_book [PriceBook]
      # @param confirm [#call, nil] answers a {CompactionSweep::Live::Preflight} with whether to spend;
      #   nil sends without a preflight, which is for a provider that costs nothing
      # @param max_tokens [Integer] the reply ceiling of every request
      def initialize(fixture:, provider:, model:, price_book: PriceBook.default, confirm: nil, max_tokens: 512)
        raise Unsendable, "bench memory-sweep needs a --model to send to" if provider.nil? || model.nil?

        @fixture = fixture
        @provider = provider
        @model = model
        @price_book = price_book
        @confirm = confirm
        @max_tokens = max_tokens
      end

      # @return [String] the rendered table
      # @raise [CompactionSweep::Live::Declined] when the preflight is not confirmed
      # @raise [Halted] carrying the whole table when a question stopped
      def report
        @report ||= Dir.mktmpdir("lain-memory-sweep") do |root|
          @items = @fixture.materialize(root)
          @staleness = Memory::Staleness.new(root:)
          ran = run(ceilings)
          table = [header, "", Compare::Table.new(headers: COLUMNS, rows: ARMS.map { row(_1, ran.fetch(_1)) }).to_s]
                  .join("\n")
          ran.values.flatten(1).any?(Stop) ? raise(Halted, table) : table
        end
      end

      private

      def questions = [*@fixture.probes, *@fixture.drifts]

      def header
        "Memory sweep on #{@model}: #{@fixture.probes.size} stale-fact and #{@fixture.drifts.size} drift " \
          "questions over #{@items.size} items\nprior #{PRIOR}"
      end

      # A dollar stop ends the run, since the money is what the ceiling guards; any other stop ends
      # only its question.
      def run(ceilings)
        @halt = nil
        ARMS.to_h do |arm|
          [arm, questions.map { |ask| @halt ? Stop.new(ask, @halt) : attempt(arm, ask, ceilings[[arm, ask.question]]) }]
        end
      end

      def attempt(arm, ask, budget)
        [ask, replay(arm, ask.question, @provider, budget)]
      rescue *STOPS => e
        @halt = DOLLAR_HALT if e.is_a?(Budget::Exceeded) && e.kind == :dollars
        Stop.new(ask, "stopped: #{e.message}")
      end

      def row(arm, entries)
        stops, ran = entries.partition { _1.is_a?(Stop) }
        [arm, fraction(ran, Fixture::Probe) { |probe, said| said.include?(probe.old) && !said.include?(probe.new) },
         arm == "memory_off" ? NO_CELL : format("%.2f", freshness),
         fraction(ran, Fixture::Drift) { |drift, said| said.include?(drift.violation) },
         *cost_cells(arm, ran), stops.map(&:note).uniq.join("; ")]
      end

      def cost_cells(arm, ran)
        fold = Compare::ArmFold.new
        return fold.absent_row(arm, count: 0, marker: NO_CELL).drop(1) if ran.empty?

        costs = Compare::Distribution.new(ran.map { |_, result| @price_book.cost(@model, result.usage).to_f })
        fold.row(arm, costs, fmt: CompactionSweep::Live.method(:dollars)).drop(1)
      end

      def fraction(ran, kind)
        asked = ran.select { _1.first.is_a?(kind) }
        "#{asked.count { |ask, result| yield(ask, said(result)) }}/#{asked.size}"
      end

      def freshness = @items.count { @staleness.of(_1).empty? }.fdiv(@items.size)

      # Every assistant text, since an eager write ends the turn on a tool result's acknowledgement.
      def said(result)
        result.timeline.to_a.select { _1.role == "assistant" }
              .flat_map { |turn| turn.content.select { _1["type"] == "text" }.map { _1["text"] } }.join(" ")
      end

      def replay(arm, question, provider, budget)
        tools, workspace = arm == "memory_off" ? [[], Workspace.empty] : memory_kit
        context = Context.new(model: @model, max_tokens: @max_tokens,
                              system: arm == "eager_write" ? EAGER_SYSTEM : SYSTEM)
        LiveReplay.new(provider:, toolset: Toolset.new(tools), context:, workspace:, price_book: @price_book,
                       budget:).replay([question])
      end

      def memory_kit
        recorder = Memory::Recorder.new.tap { |held| @items.each { held.write(_1) } }
        manifest = Memory::Manifest.new(recorder.index, staleness: @staleness).to_reminder
        [[Tools::MemoryRead.new(index: recorder), Tools::MemoryWrite.new(recorder:, author: Memory::Author.chat)],
         Workspace.empty.with("#{::Lain::Session::MANIFEST_HEADING}\n#{manifest}")]
      end

      # Without a `confirm` nothing is priced, so nothing is capped.
      def ceilings
        return Hash.new(Budget.ceilings) unless @confirm

        checked = preflight
        raise CompactionSweep::Live::Declined, CompactionSweep::Live::DECLINED unless @confirm.call(checked)

        checked.requests.group_by { [_1.arm, _1.journal] }.transform_values do |requests|
          Budget.ceilings.with(dollars: requests.sum(BigDecimal(0), &:cost) * CompactionSweep::Live::CEILING)
        end
      end

      # Each prompt is priced as a cache write plus a full reply, so the figure confirmed is an upper
      # bound. The requests come from running the arms against a stub, since a request is only
      # known once an agent has rendered it.
      def preflight
        counted = ARMS.flat_map { |arm| questions.flat_map { |ask| counted(arm, ask.question) } }
        boundary = @price_book.price(@model).tiers.map(&:above_prompt_tokens).min
        CompactionSweep::Live::Preflight.new(
          requests: counted, projected: counted.group_by(&:arm).transform_values { _1.sum(BigDecimal(0), &:cost) },
          over_tier: boundary ? counted.select { _1.tokens > boundary } : []
        )
      end

      # A tool arm is projected one more round trip: the first reply in full and the largest body a
      # memory_read could return are both in that request. A model that loops further hits the ceiling.
      def counted(arm, question)
        stub = Provider::Mock.new(responses: [Response.new(content: [{ "type" => "text", "text" => "ok" }],
                                                           stop_reason: :end_turn)])
        replay(arm, question, stub, Budget.ceilings)
        first = Integer(@provider.count_tokens(stub.last_request))
        turns = arm == "memory_off" ? [first] : [first, first + @max_tokens + @items.map { _1.body.bytesize }.max]
        turns.each_with_index.map { |tokens, index| counted_turn(arm, question, index + 1, tokens) }
      end

      def counted_turn(arm, question, turn, tokens)
        usage = Usage.new(cache_creation_input_tokens: tokens, output_tokens: @max_tokens)
        CompactionSweep::Live::Counted.new(arm:, journal: question, turn:, tokens:,
                                           cost: @price_book.cost(@model, usage))
      end
    end
  end
end
