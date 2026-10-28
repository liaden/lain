# frozen_string_literal: true

require "bigdecimal"
require "delegate"

module Lain
  module Bench
    class CompactionSweep
      # The sweep's arms sent to a real model, which spends money. No paid request is sent until a
      # preflight has counted every request the arms would send through the free count endpoint,
      # priced it at most, listed each one over the model's price tier, and been confirmed. The
      # preflight renders each lane offline, so a summarizer would be asked then; the CLI therefore
      # takes only recorded answers under --live.
      #
      # Each arm over each journal then runs under a dollar ceiling of {CEILING} times its
      # projection, and the price-tier guard approves at most as many crossings in a lane as the
      # preflight listed for it. A lane that stops is reported with what it spent and why; a lane
      # past its dollar ceiling stops every later lane too.
      #
      # The model's answers replace the recorded ones, so a lane's chain is its own after the first
      # reply that differs; its tools answer from the recording, and a call the recording never made
      # is answered with an error rather than run.
      class Live
        CEILING = BigDecimal("1.5")
        DECLINED = "no paid request was sent: the preflight was not confirmed (pass --yes to accept it without " \
                   "a terminal); only the free token counts were made"
        COLUMNS = ["arm", "journal", "requests sent", "projected", "spent", "ceiling", "note"].freeze
        FAILED_HALT = "not run: an earlier lane failed"
        # A lane with no counted request has no projection to cap, so it may spend nothing.
        NO_REQUESTS = Budget.ceilings.with(dollars: BigDecimal(0))
        private_constant :COLUMNS, :FAILED_HALT, :NO_REQUESTS

        # The human did not confirm the preflight.
        class Declined < Error; end

        # A lane stopped on something no ceiling or guard planned for. The message is the whole table,
        # then the lane and its error, so a defect is never read as a clean run.
        class Failed < Error; end

        # The stops a run is built to make: a ceiling or the progress breaker, never a defect.
        PLANNED_STOPS = %i[dollars stuck iterations].freeze
        private_constant :PLANNED_STOPS

        # One request the preflight counted: its lane, its 1-based place in the journal's calls, its
        # prompt tokens, and its projected cost. No digest: the live chain diverges from the counted
        # one, so a crossing is allowed by its lane's count, never by matching a request.
        Counted = Data.define(:arm, :journal, :turn, :tokens, :cost)

        Preflight = Data.define(:requests, :projected, :over_tier)

        # What the arms would spend: every counted request, the projected cost by arm, and the
        # requests over the price tier. Reopened so the text a human confirms is read off the value.
        class Preflight
          # @return [BigDecimal]
          def total = projected.values.sum(BigDecimal(0))

          # @return [String]
          def question = "spend about #{Live.dollars(total)}, capped at #{Live.dollars(total * CEILING)}? [y/N]"

          # @param arm [String]
          # @param journal [String]
          # @return [Integer] how many crossings that lane may make
          def allowance(arm, journal) = over_tier.count { _1.arm == arm && _1.journal == journal }

          # @return [String] the projection by arm, the total, and the requests over the tier
          def report
            ["Live preflight: #{requests.size} requests counted, priced at most: each prompt as a cache write " \
             "and a full max_tokens reply", *projected.map { |arm, cost| "  #{arm}: #{Live.dollars(cost)}" },
             "  total: #{Live.dollars(total)}", *tier_lines].join("\n")
          end

          private

          def tier_lines
            return ["No request crosses its price tier."] if over_tier.empty?

            ["Over the price tier, so billed whole at the tier rate:",
             *over_tier.map { "  #{_1.arm}, #{File.basename(_1.journal)}, turn #{_1.turn}: #{_1.tokens} tokens" },
             *over_tier.group_by { [_1.arm, _1.journal] }.map { |lane, crossing| allowed(*lane, crossing.size) }]
          end

          def allowed(arm, journal, count)
            "  #{arm}, #{File.basename(journal)}: up to #{count} #{count == 1 ? "request" : "requests"} " \
              "over the tier allowed"
          end
        end

        # What one lane spent, and why it stopped if it did. `halt` is what later lanes are told
        # when this one stops them all.
        Row = Data.define(:arm, :journal, :sent, :projected, :spent, :ceiling, :note, :halt, :failure)
        private_constant :Row

        # The confirmation the exe hands in: the preflight is always shown, `--yes` accepts it, a
        # terminal is asked, and anything else declines.
        class Prompt
          # @param yes [Boolean] accept without asking
          # @param terminal [Boolean] whether a human can answer
          # @param say [#call] shows the preflight
          # @param ask [#call] asks the question, answering true for yes
          def initialize(yes:, terminal:, say:, ask:)
            @yes = yes
            @terminal = terminal
            @say = say
            @ask = ask
          end

          # @param preflight [Preflight]
          # @return [Boolean] whether to spend
          def call(preflight)
            @say.call(preflight.report)
            @yes || (@terminal && @ask.call(preflight.question)) || false
          end
        end

        # @param figure [Numeric]
        # @return [String]
        def self.dollars(figure) = format("$%.4f", figure)

        # @param sweep [CompactionSweep] whose lanes are run
        # @param provider [Provider] counts through `count_tokens`, then sends
        # @param confirm [#call] answers a {Preflight} with whether to spend
        # @param model [String] the model every request is sent as
        # @param hold [Provider::HTTP::PriceTierGuard::Hold] the hold the provider's guard asks about a
        #   crossing; required, since a run whose guard asks some other hold has no backstop
        # @param price_book [PriceBook]
        # @param journal [#<<] where each lane and its replay are recorded
        def initialize(sweep:, provider:, confirm:, model:, hold:, price_book: PriceBook.default,
                       journal: Channel::Null.instance)
          @sweep = sweep
          @provider = provider
          @confirm = confirm
          @model = model
          @hold = hold
          @price_book = price_book
          @journal = journal
        end

        # Counts and prices every request; sends none.
        #
        # @return [Preflight]
        # @raise [Unanswered] when a model arm lacks a recorded summary it needs
        def preflight
          priced.preflight
        end

        # @return [String] what each lane sent and spent beside its projection and ceiling, and why
        #   any lane stopped
        # @raise [Declined] when the preflight is not confirmed
        # @raise [Failed] carrying that same table when a lane stopped on an unplanned error
        def run
          checked = preflight
          ceilings = priced.ceilings

          halt = nil
          rows = lanes.map do |lane|
            (halt ? not_run(lane, checked, halt) : replayed(lane, checked, ceilings)).tap { halt ||= _1.halt }
          end
          failure = rows.filter_map(&:failure).first
          failure ? raise(Failed, "#{table(rows)}\n#{failure}") : table(rows)
        end

        private

        def lanes = @lanes ||= @sweep.lanes

        def priced
          @priced ||= PricedRun.new(counted: lanes.flat_map { counted(_1) }, price_book: @price_book, model: @model,
                                    confirm: @confirm, unit: "lane")
        end

        # Each prompt is priced as a cache write, the dearer of its two input rates, so the figure a
        # human confirms is an upper bound whatever the cache does.
        def counted(lane)
          lane.requests(@model).each_with_index.map do |request, index|
            tokens = Integer(@provider.count_tokens(request))
            usage = Usage.new(cache_creation_input_tokens: tokens, output_tokens: request.max_tokens)
            Counted.new(arm: lane.label, journal: lane.path, turn: index + 1, tokens:,
                        cost: @price_book.cost(@model, usage))
          end
        end

        def projected(lane, checked)
          checked.requests.select { _1.arm == lane.label && _1.journal == lane.path }
        end

        def replayed(lane, checked, ceilings)
          mine = projected(lane, checked)
          backstop = backstop(checked, lane)
          source = lane.source
          budget = budget(mine.size, ceilings.fetch([lane.label, lane.path], NO_REQUESTS))
          stop = stopped(lane) { replay(lane, backstop, source, budget) }
          row(lane, backstop, mine.sum(BigDecimal(0), &:cost), stop, budget).with(note: note(stop, source.missed))
        end

        def row(lane, backstop, projected, stop, budget)
          Row.new(arm: lane.label, journal: lane.path, sent: backstop.sent, projected:, spent: backstop.spent,
                  ceiling: budget.dollars, note: nil, halt: halt_for(stop), failure: failure(lane, stop))
        end

        # Bound one lane at a time, so an approval never carries past the lane's own allowance.
        def backstop(checked, lane)
          Backstop.new(@provider, allowance: checked.allowance(lane.label, lane.path), price_book: @price_book,
                                  model: @model)
                  .tap { @hold.bind(_1, carry: false) }
        end

        def not_run(lane, checked, halt)
          projected = projected(lane, checked).sum(BigDecimal(0), &:cost)
          Row.new(arm: lane.label, journal: lane.path, sent: 0, projected:, spent: BigDecimal(0),
                  ceiling: projected * CEILING, note: halt, halt:, failure: nil)
        end

        # Any error, a defect included, becomes the lane's row, so the table and what was spent are
        # never lost with it; a defect's backtrace goes to the journal.
        def stopped(lane)
          yield
          nil
        rescue StandardError => e
          @journal << { "type" => "compaction_sweep_live_stop", "arm" => lane.label, "journal" => lane.path,
                        "error" => e.class.name, "message" => e.message, "backtrace" => Array(e.backtrace).first(10) }
          e
        end

        # A price-tier refusal, the progress breaker and a step limit end only their lane; a dollar
        # ceiling or a failure nobody planned for ends the run.
        def halt_for(stop)
          priced.halt_for(stop) || (FAILED_HALT if unplanned?(stop))
        end

        def unplanned?(stop)
          return false if stop.nil? || stop.is_a?(Provider::HTTP::PriceTierGuard::Refused)

          !(stop.is_a?(Budget::Exceeded) && PLANNED_STOPS.include?(stop.kind))
        end

        def failure(lane, stop)
          "#{lane.label}, #{File.basename(lane.path)} failed: #{stop.class}: #{stop.message}" if unplanned?(stop)
        end

        def note(stop, missed)
          [("stopped: #{stop.is_a?(Error) ? stop.message : "#{stop.class}: #{stop.message}"}" if stop),
           ("#{missed} cuts skipped: no recorded answer" if missed.positive?)].compact.join("; ")
        end

        def replay(lane, provider, source, budget)
          recording = lane.recording
          @journal << { "type" => "compaction_sweep_live_lane", "arm" => lane.label, "journal" => lane.path,
                        "ceiling" => budget.dollars.to_s("F") }
          LiveReplay.new(provider:, toolset: RecordedTools.of(recording), context: recording.context.with_model(@model),
                         journal: @journal, workspace: recording.workspace, price_book: @price_book,
                         pipeline_source: source, budget:)
                    .replay(LiveReplay.prompts_from(recording.timeline))
        end

        # The recorded call count bounds the steps too, with room for a model that takes more.
        def budget(calls, ceilings)
          ceilings.with(iterations: [calls * 2, Budget::DEFAULT_ITERATIONS].max)
        end

        def table(rows)
          ["Live compaction sweep on #{@model}, each lane capped at #{CEILING.to_s("F")} times its projection", "",
           Compare::Table.new(headers: COLUMNS, rows: rows.map { cells(_1) })].join("\n")
        end

        def cells(row)
          [row.arm, File.basename(row.journal), row.sent.to_s,
           *[row.projected, row.spent, row.ceiling].map { Live.dollars(_1) }, row.note]
        end

        # The provider a lane sends through, which tallies what the lane spent. It is also the
        # price-tier hold's queue, approving up to the lane's allowance of crossings and no more.
        class Backstop < SimpleDelegator
          attr_reader :sent, :spent

          def initialize(provider, allowance:, price_book:, model:)
            super(provider)
            @allowance = allowance
            @price_book = price_book
            @model = model
            @approved = 0
            @sent = 0
            @spent = BigDecimal(0)
          end

          def complete(request, **)
            __getobj__.complete(request, **).tap do |response|
              @sent += 1
              @spent += @price_book.cost(@model, response.usage)
            end
          end

          # @return [Boolean] whether the lane still has a crossing the preflight allowed it
          def ask_decision(_decision)
            return false if @approved >= @allowance

            @approved += 1
            true
          end
        end
        private_constant :Backstop

        # The recorded tools. Each call is answered with the next result the recording holds for the
        # same name and input, in the order they were recorded; past the last, or for an input the
        # recording never saw, with an error. Tools are capabilities and cannot be rebuilt from a
        # journal, and running the project's own would make a lane's results differ from the
        # recording's for no reason the sweep measures.
        module RecordedTools
          UNRECORDED = "no recorded result for this call; a live sweep answers only calls the recording made"

          # @param recording [Session::Recording]
          # @return [Toolset]
          def self.of(recording)
            answers = answers(recording.timeline.to_a.flat_map(&:content))
            Toolset.new(recording.toolset.to_schema.map { Replayed.new(_1, answers) })
          end

          def self.answers(blocks)
            calls = blocks.select { _1["type"] == "tool_use" }.to_h { [_1["id"], key(_1["name"], _1["input"])] }
            blocks.select { _1["type"] == "tool_result" }.group_by { calls[_1["tool_use_id"]] }
                  .transform_values { |results| results.map { result(_1) } }
          end

          def self.result(block)
            block["is_error"] ? Tool::Result.error(block["content"]) : Tool::Result.ok(block["content"])
          end

          def self.key(name, input) = Canonical.digest([name, input])
          private_class_method :answers, :result

          # One recorded tool, wearing its recorded schema.
          class Replayed < Tool
            def initialize(schema, answers)
              super()
              @schema = schema
              @answers = answers
              @served = Hash.new(0)
            end

            def name = @schema.fetch("name")

            def description = @schema.fetch("description")

            def input_schema = @schema.fetch("input_schema")

            def strict? = @schema.fetch("strict", true)

            protected

            def perform(input, _context)
              key = RecordedTools.key(name, input)
              served = @served[key]
              @served[key] += 1
              @answers.fetch(key, []).fetch(served) { Tool::Result.error(UNRECORDED) }
            end
          end
        end
        private_constant :RecordedTools
      end
    end
  end
end
