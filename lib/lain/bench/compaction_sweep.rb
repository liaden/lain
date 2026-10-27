# frozen_string_literal: true

module Lain
  module Bench
    # Recorded sessions replayed under each compaction arm, offline. Every recorded model call
    # is re-rendered through the arm's own derived chain: a cut fires when the droppable head past
    # the cut that holds passes a byte budget, and it is kept only when it shrinks what the turn
    # would otherwise send, as a live chat keeps one. The cache cost is simulated from the
    # re-rendered prefixes, since the recorded usage belongs to the prefixes that were sent.
    #
    # Model arms never invent an answer. Under the recorded summarizer they answer from the
    # journal's own `oracle_answer` records, and an arm missing any answer it needs is reported
    # as such, with no figures. A summarizer handed in instead is asked for every span, which on
    # a local model is a long job.
    #
    # The recorded assistant turns after a cut were written from the uncompacted context, so what
    # this measures is what each arm would have sent, never how the model would then behave.
    class CompactionSweep
      DEFAULT_ARMS = %w[eager elide elide-tools summarizing summarize-conversation truncate-cumulative
                        summarizing-flat].freeze
      EAGER = Telemetry::Compaction::EAGER_CONTROL_ARM
      MODEL_ARMS = %w[summarizing summarize-conversation summarizing-flat].freeze
      DEFAULT_PRICE_AS = "claude-haiku-5-5"
      DEFAULT_BUDGET = ::Lain::CLI::Backend::DEFAULT_BYTE_THRESHOLD
      NO_ANSWERS = "no recorded answers"
      LEGEND = ["Cache cost is simulated from re-rendered prefixes at #{ProxyBytes::BYTES_PER_TOKEN} bytes a token.",
                "request bytes: the canonical bytes of every re-rendered request, summed over calls and journals.",
                "rebilled tokens: a request's prefix (tools, system, then messages) after the first byte that " \
                "differs from the request before it.",
                "kept verbatim: the planted claim reaches the last request in a user message outside the recap; " \
                "kept in recap: it reaches it inside the recap."].freeze
      COLUMNS = ["arm", "placement", "n", "request bytes", "cuts", "mid-task rate", "rebilled tokens (est.)",
                 "rebilled cost (est.)", "cause", "kept verbatim", "kept in recap", "note"].freeze
      private_constant :COLUMNS

      # No used tokens are passed, so the byte budget is the only signal that can fire and the
      # window decides nothing.
      UNREAD_WINDOW = ContextWindow::CONSERVATIVE_FALLBACK
      private_constant :UNREAD_WINDOW

      # A module-scope lambda for {Compaction::Source}'s reason: one built in a method would carry
      # this object into a pipeline that must be shareable.
      HOLD = lambda do |replay, provider|
        Ractor.make_shareable(->(workspace) { replay >> Context.combinator_for(provider, workspace) })
      end
      private_constant :HOLD

      # One arm under one placement, summed over every journal. Every figure is nil when `note`
      # says the arm could not be measured. `planted` counts the journals that carry a planted
      # claim; of those, `kept_verbatim` reached the last request in a non-recap user block and
      # `kept_in_recap` reached it inside a recap block.
      Row = Data.define(:arm, :placement, :n, :request_bytes, :cuts, :mid_task_rate, :rebilled_tokens,
                        :rebilled_cost, :causes, :kept_verbatim, :kept_in_recap, :planted, :note)

      UNMEASURED = Row.members.drop(2).to_h { |member| [member, nil] }.merge(note: NO_ANSWERS).freeze
      private_constant :UNMEASURED

      # What one arm measured over one journal.
      Measure = Data.define(:request_bytes, :cuts, :mid_task_cuts, :waste, :survived, :recapped)
      private_constant :Measure

      # @param journals [Array<String>] session files; the recordings load from them, and so do
      #   the recorded answers a model arm replays
      # @param arms [Array<String>] names from {DEFAULT_ARMS}
      # @param price_as [String] the model every simulated cache write is priced as
      # @param placements [Array<String>] names {Compaction::Recap.for} knows
      # @param price_book [PriceBook]
      # @param summarizer [Symbol, #call] `:recorded`, or a factory `->(definition) { tier }`
      #   whose tier answers `#ask`, `#model` and `#usage`
      # @param budget [Integer] head bytes past the held cut that fire a cut
      # @param planted [Array<PlantedClaims::Fixture>] the claim each planted journal carries
      # @param keep_last [Integer] trailing messages a cut never touches
      # @param journal [#<<] where a handed-in summarizer's answers land, so a later recorded sweep
      #   replays them through `recorded`
      # @param recorded [Array<String>] journals whose `oracle_answer` records every swept journal
      #   also answers from, such as the one an earlier sweep's summarizer wrote
      # @raise [ArgumentError] on an unknown arm or placement, or none of either
      def initialize(journals:, arms:, price_as:, placements: %w[framed], price_book: PriceBook.default,
                     summarizer: :recorded, budget: DEFAULT_BUDGET, planted: [],
                     keep_last: ::Lain::CLI::Backend::DEFAULT_KEEP_LAST, journal: Channel::Null.instance, recorded: [])
        @arms = known_arms(arms.uniq)
        @placements = known_placements(placements.uniq)
        @journals = journaled(journals, recorded)
        @journal = journal
        @price_as = price_as
        @price_book = price_book
        @summarizer = summarizer
        @budget = budget
        @need = Compaction::Need.new(byte_threshold: budget)
        @claims = planted.to_h { |fixture| [File.expand_path(fixture.path), fixture.claim] }
        @keep_last = keep_last
      end

      # @return [Array<Row>] one per arm and placement, in the order asked
      def rows = @rows ||= @arms.product(@placements).map { |arm, placement| row(arm, placement) }

      # @return [String] the header, the simulation note and the table
      def report
        @report ||= [header, *LEGEND, "", Compare::Table.new(headers: COLUMNS, rows: rows.map { cells(_1) })]
                    .join("\n")
      end

      private

      def named(names, what)
        raise ArgumentError, "no #{what} to sweep" if names.empty?

        names
      end

      def journaled(journals, recorded)
        answers = recorded.flat_map { |path| Journal.records(File.foreach(path), type: "oracle_answer").to_a }
        journals.map { |path| File.expand_path(path) }.uniq.map { |path| Journaled.new(path, answers) }
      end

      def known_placements(placements) = named(placements, "placements").each { Compaction::Recap.for(_1) }

      def known_arms(arms)
        unknown = named(arms, "arms") - DEFAULT_ARMS
        return arms if unknown.empty?

        raise ArgumentError, "unknown arm #{unknown.first.inspect}; the arms are #{DEFAULT_ARMS.join(", ")}"
      end

      def row(arm, placement)
        measures = @journals.map { |journal| measured(journal, arm, placement) }
        return Row.new(arm:, placement:, **UNMEASURED) if measures.any?(&:nil?)

        Row.new(arm:, placement:, **cut_figures(measures), **waste_figures(measures), **planted_figures(measures),
                note: nil)
      end

      def cut_figures(measures)
        cuts = measures.sum(&:cuts)
        { n: measures.size, request_bytes: measures.sum(&:request_bytes), cuts:,
          mid_task_rate: cuts.zero? ? nil : measures.sum(&:mid_task_cuts).fdiv(cuts) }
      end

      def waste_figures(measures)
        wastes = measures.map(&:waste)
        { rebilled_tokens: wastes.sum(&:rebilled_tokens),
          rebilled_cost: wastes.sum(Friction::CacheWaste::Dollars.zero, &:rebilled_cost),
          causes: wastes.map(&:causes).inject({}) { |sum, each| sum.merge(each) { |_, a, b| a + b } } }
      end

      def planted_figures(measures)
        planted = measures.reject { _1.survived.nil? }
        { kept_verbatim: planted.count(&:survived), kept_in_recap: planted.count(&:recapped), planted: planted.size }
      end

      # @return [Measure, nil] nil when a model arm lacked an answer it needed
      def measured(journal, arm, placement)
        policy = Policy.for(arm, journal, @summarizer, @journal)
        derived = Compaction::Source::Derived.new(keep_last: @keep_last, strategy: policy.strategy,
                                                  placement: Compaction::Recap.for(placement),
                                                  journal: edges = Edges.new)
        walked = walk(journal, derived, policy, edges)
        policy.answered? ? measure(journal, walked) : nil
      end

      # The cut that holds, carried from one recorded call to the next as a live chat holds it.
      def walk(journal, derived, policy, edges)
        journal.timelines.each_with_object(Walked.new) do |timeline, state|
          walked = Compaction::Derivation::Walk.of(timeline)
          held = derived.held(timeline, walk: walked, cut: state.seam)
          advanced = advance(derived, timeline, walked, held, policy)
          state.cut(advanced.seam, mid_task: edges.last.mid_task) if advanced
          state.requests << render(journal.recording, advanced || held, timeline)
        end
      end

      def advance(derived, timeline, walked, held, policy)
        seam = held.seam
        head = Compaction::Head.new(messages: walked.messages.drop(floor(walked, seam)), keep_last: @keep_last)
        return if head.empty? || !@need.check(head_bytes: head.bytesize, window_tokens: UNREAD_WINDOW).needed?

        outcome = derived.over(timeline, walk: walked, pins: Context::PinnedMessages::NONE, cut: seam,
                                         snapshot: policy.snapshot(head.messages))
        outcome unless outcome.refused? || outcome.seam.equal?(seam) || !shrinks?(outcome, held, walked)
      end

      def floor(walked, seam)
        seam.digest.nil? ? 0 : walked.turns.index { |turn| turn.digest == seam.digest } + 1
      end

      def shrinks?(outcome, held, walked)
        before = held.refused? ? walked.messages : held.messages
        Canonical.dump(outcome.messages).bytesize < Canonical.dump(before).bytesize
      end

      def render(recording, outcome, timeline)
        base = recording.context
        context = outcome.refused? ? base : base.with_pipeline(HOLD.call(outcome.replay, base.pipeline_provider))
        context.render(timeline:, toolset: recording.toolset, workspace: recording.workspace)
      end

      def measure(journal, walked)
        requests = walked.requests
        Measure.new(request_bytes: requests.sum { Canonical.dump(_1.cache_payload).bytesize },
                    cuts: walked.cuts, mid_task_cuts: walked.mid_task_cuts,
                    waste: Friction::CacheWaste::Simulated.new(requests, price_as: @price_as,
                                                                         price_book: @price_book),
                    survived: survived(@claims[journal.path], requests.last),
                    recapped: recapped(@claims[journal.path], requests.last))
      end

      # nil when the journal carries no planted claim.
      def survived(claim, request)
        return if claim.nil?

        carriers(claim, request).any? { |block| !Compaction::Recap.block?(block) }
      end

      def recapped(claim, request)
        return false if claim.nil?

        carriers(claim, request).any? { |block| Compaction::Recap.block?(block) }
      end

      def carriers(claim, request)
        request.messages.select { |message| message["role"] == "user" }
               .flat_map { |message| Array(message["content"]) }
               .select { |block| Canonical.dump(block).include?(claim) }
      end

      def header
        summarizer = @summarizer == :recorded ? "recorded" : "local"
        journals = @journals.one? ? "1 journal" : "#{@journals.size} journals"
        "Compaction sweep: #{journals}, budget #{@budget} bytes, keep #{@keep_last}, " \
          "priced as #{@price_as}, summarizer #{summarizer}"
      end

      def cells(row)
        return [row.arm, row.placement, *Array.new(COLUMNS.size - 3, "-"), row.note] if row.note

        [row.arm, row.placement, row.n.to_s, row.request_bytes.to_s, row.cuts.to_s, *cost_cells(row),
         *planted_cells(row), ""]
      end

      def cost_cells(row)
        [row.mid_task_rate ? format("%.2f", row.mid_task_rate) : "-", row.rebilled_tokens.to_s,
         dollars(row.rebilled_cost), cause_cell(row.causes)]
      end

      def planted_cells(row)
        return %w[- -] if row.planted.zero?

        ["#{row.kept_verbatim}/#{row.planted}", "#{row.kept_in_recap}/#{row.planted}"]
      end

      def dollars(figure)
        figure.complete? ? format("$%.6f", figure.amount) : "unpriced"
      end

      def cause_cell(causes)
        return "-" if causes.empty?

        causes.map { |cause, count| "#{Friction::BreakCause::LABELS.fetch(cause, cause.to_s.tr("_", " "))} #{count}" }
              .join(", ")
      end

      # One session file, loaded once for every arm that replays it, with the answers recorded
      # beside it in other journals.
      class Journaled
        attr_reader :path

        def initialize(path, answers)
          @path = path
          @answers = answers
        end

        def recording = @recording ||= Session.load(@path)

        def entries = @entries ||= Journal.records(File.foreach(@path)).to_a + @answers

        # Each recorded model call's prefix, in order.
        def timelines = @timelines ||= recording.dry_replay.each_step.map(&:timeline)
      end
      private_constant :Journaled

      # One replay's running state: the seam that holds, what each call sent, and the cuts taken.
      class Walked
        attr_reader :seam, :requests, :cuts, :mid_task_cuts

        def initialize
          @seam = Compaction::Derivation::UNCUT
          @requests = []
          @cuts = 0
          @mid_task_cuts = 0
        end

        def cut(seam, mid_task:)
          @seam = seam
          @cuts += 1
          @mid_task_cuts += 1 if mid_task
        end
      end
      private_constant :Walked

      # How one arm collapses a span over one journal, and whether it had every answer it needed.
      # `snapshot` is read only by the eager arm, whose strategy is the run's own tool-result tier.
      class Policy
        attr_reader :strategy

        def self.for(arm, journal, summarizer, answers_to)
          case arm
          when EAGER then eager(journal, summarizer, answers_to)
          when *MODEL_ARMS then modelled(arm, journal, summarizer, answers_to)
          else new(strategy: ::Lain::CLI::CompactionStrategy.resolve(arm))
          end
        end

        # The live chat journals its eager answers through the same wrap, so a recorded sweep reads
        # back exactly what a summarizer handed in here wrote.
        def self.eager(journal, summarizer, answers_to)
          definition = Oracle::Summarize.definition
          oracle = if summarizer == :recorded
                     Oracle::Recorded.from_journal(journal.entries, definition:)
                   else
                     Oracle::Recorded::Journaling.new(inner: summarizer.call(definition), definition:,
                                                      journal: answers_to)
                   end
          answers = EagerAnswers.new(journal, oracle)
          new(strategy: nil, eager: answers, answered: -> { answers.answered? })
        end

        def self.modelled(arm, journal, summarizer, answers_to)
          misses = Misses.new(loud: summarizer != :recorded)
          answering = ->(definition) { tier(definition, journal, summarizer) }
          strategy = ::Lain::CLI::CompactionStrategy.resolve(arm, sink: misses, tier: answering, journal: answers_to)
          new(strategy:, answered: -> { misses.none? })
        end

        # A recorded tier answers `#ask` alone; the strategy resolver reads the full live duck.
        def self.tier(definition, journal, summarizer)
          return summarizer.call(definition) unless summarizer == :recorded

          RecordedTier.new(Oracle::Recorded.from_journal(journal.entries, definition:))
        end
        private_class_method :eager, :modelled, :tier

        def initialize(strategy:, eager: Compaction::Source::NoSummaries, answered: -> { true })
          @strategy = strategy
          @eager = eager
          @answered = answered
        end

        def snapshot(messages) = Compaction::SummarySnapshot.take(messages:, eager: @eager)

        def answered? = @answered.call
      end
      private_constant :Policy

      # {Oracle::Recorded} in the live-tier duck. It spends nothing, so its usage is empty.
      class RecordedTier
        def initialize(recorded)
          @recorded = recorded
        end

        def ask(inputs = {}) = @recorded.ask(inputs)

        def model = "recorded"

        def usage = {}
      end
      private_constant :RecordedTier

      # The sink a summarizing strategy reports a span it could not collapse to. Under the recorded
      # summarizer that is a span with no recorded answer; a summarizer handed in that cannot answer
      # is a failure, raised with its own error rather than read as an unanswered arm.
      class Misses
        def initialize(loud:)
          @loud = loud
          @count = 0
        end

        def puts(line)
          raise Error, line if @loud

          @count += 1
        end

        def none? = @count.zero?
      end
      private_constant :Misses

      # The eager tier's summaries, asked once per tool result the way a chat's routed summarizer
      # falls through to its model: keyed by the result's digest, with the text in the slot, and only
      # for a result inside the model tier's size window. The project's own declared summarizers
      # are not consulted. A result with no recorded answer is a miss the snapshot attests, as a
      # summary still in flight is.
      class EagerAnswers
        def initialize(journal, oracle)
          @journal = journal
          @oracle = oracle
        end

        def held(digest) = answers[digest]

        # A journal with no result worth a model call needs no answer to be measured.
        def answered? = results.empty? || !answers.empty?

        private

        def answers = @answers ||= results.to_h { |text| [Canonical.digest(text), asked(text)] }.compact

        def asked(text)
          @oracle.ask(Oracle::Eager::DEFAULT_SLOT => text).await
        rescue Oracle::Recorded::Unrecorded
          nil
        end

        def results = @results ||= eligible

        def eligible
          EventLog::Messages.project(@journal.recording.timeline.to_a)
                            .flat_map { |message| Array(message["content"]) }
                            .select { |block| block["type"] == "tool_result" && !block["is_error"] }
                            .map { |block| block["content"] }.grep(String).uniq.select { |text| worth_a_call?(text) }
        end

        def worth_a_call?(text)
          bytes = text.bytesize
          bytes > Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES && Oracle::RoutedSummarizer::INPUT_BOUND.admits?(bytes)
        end
      end
      private_constant :EagerAnswers

      # The last derivation edge, read for whether a cut landed mid-task.
      class Edges
        attr_reader :last

        def <<(event)
          @last = event if event.is_a?(Telemetry::ContextDerived)
          self
        end
      end
      private_constant :Edges
    end
  end
end
