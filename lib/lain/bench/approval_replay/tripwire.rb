# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # What the tripwire would have done to the sessions already recorded: each session file folded
      # through a real {Lain::Tripwire::Ledger} per rule set, and each requester it would have
      # stopped checked against the labels. A trip is false when every call that requester made is
      # labelled routine; a requester with an unlabelled or non-routine call is never called false.
      #
      # The ledger writes its `tripwire` records into a {Stack::Capture}, never back into the session
      # file it reads.
      class Tripwire
        # @!attribute signals
        #   @return [Hash{String=>Array<String>}] each falsely tripped requester's signal names
        Row = Data.define(:rules, :sessions, :tripped, :false_trips, :low, :high, :signals)

        # One session file folded under one rule set.
        Fold = Data.define(:standings, :unattributed, :calls)

        KEYS = %w[hard_stop strong medium weak].freeze
        ROUTINE = "routine"

        # @param specs [Array<String>] each a comma-separated list of `key=value` overrides of the default
        #   rules, keys out of {KEYS}
        # @return [Array<::Lain::Tripwire::Rules>] the default, then one per spec, a repeat of an earlier set dropped
        # @raise [CLI::Refusal] on a pair that is not `key=value`, an unknown or repeated key, or a value that is
        #   not a whole number of 1 or more
        def self.rules_from(specs)
          default = ::Lain::Tripwire::Rules::DEFAULT
          [default, *specs.map { override(default, _1) }].uniq
        end

        def self.override(default, spec)
          numbers = numbers_of(spec)
          points = numbers.slice(*default.points.keys.map(&:to_s)).transform_keys(&:to_sym)
          ::Lain::Tripwire::Rules.new(points: default.points.merge(points),
                                      hard_stop: numbers.fetch("hard_stop", default.hard_stop))
        end

        def self.numbers_of(spec)
          pairs = spec.split(",", -1).map { pair(_1, spec) }
          repeated = pairs.map(&:first).tally.select { _2 > 1 }.keys
          refuse("repeats #{repeated.join(", ")} in #{spec.inspect}") if repeated.any?

          pairs.to_h
        end

        def self.pair(text, spec)
          key, value = text.split("=", 2)
          refuse("cannot read #{text.inspect} in #{spec.inspect}") unless key && value && !key.empty?
          refuse("has no key #{key}") unless KEYS.include?(key)
          [key, whole(value, text)]
        end

        def self.whole(value, text)
          number = Integer(value, 10)
          refuse("needs a value of 1 or more in #{text.inspect}") if number < 1
          number
        rescue ArgumentError
          refuse("needs a whole number in #{text.inspect}")
        end

        def self.refuse(why)
          raise(CLI::Refusal, "--tripwire-rules #{why}: each is key=value, key one of #{KEYS.join(", ")}")
        end
        private_class_method :override, :numbers_of, :pair, :whole, :refuse

        # @param journals [Array<String>] session files
        # @param labels [Labels] without them ({Labels::NONE}) there is no false-trip rate
        # @param rules [Array<::Lain::Tripwire::Rules>] one row each
        def initialize(journals:, labels: Labels::NONE, rules: [::Lain::Tripwire::Rules::DEFAULT])
          @journals = journals
          @labels = labels
          @rules = rules
          @records = journals.to_h { [_1, Journal.records(File.foreach(_1)).to_a] }
          @folds = {}
        end

        # @return [Array<Row>] one per rule set, in the order given
        def rows = @rules.map { row(_1) }

        # @return [String]
        def report
          lines = ["", "tripwire replay: #{noun(@journals.size, "session")}, observe only; a trip is false when " \
                       "every call of the requester is labelled routine", *rows.flat_map { lines_of(_1) }]
          lines << "  false-trip rate needs labels: pass --labels" unless @labels.labelled?
          lines.push(*unattributed_lines, *unchecked_lines)
          "#{lines.join("\n")}\n"
        end

        private

        def row(rules)
          folds = @journals.map { fold(rules, _1) }
          false_sets = folds.map { false_requesters(_1) }
          falsely = false_sets.count(&:any?)
          interval = Compare::Stats.wilson(falsely, @journals.size) if @labels.labelled? && @journals.any?
          Row.new(rules:, sessions: @journals.size, tripped: folds.count { tripped(_1).any? },
                  false_trips: (falsely if @labels.labelled?), low: interval&.low, high: interval&.high,
                  signals: merged(false_sets))
        end

        def merged(sets) = sets.reduce({}) { |all, found| all.merge(found) { |_, a, b| (a + b).uniq.sort } }

        def fold(rules, path) = @folds[[rules, path]] ||= folded(rules, path)

        def folded(rules, path)
          captured = Stack::Capture.new
          ledger = ::Lain::Tripwire::Ledger.new(journal: captured, rules:)
          records = @records.fetch(path)
          records.each { ledger << _1 }
          requesters = captured.records.map { _1["requester"] }.uniq
          Fold.new(standings: requesters.to_h { [_1, ledger.standing(_1)] },
                   unattributed: captured.records.count { _1["requester"] == ::Lain::Tripwire::Ledger::UNKNOWN },
                   calls: Call.joined(records, session: path).group_by(&:requester))
        end

        def tripped(fold) = fold.standings.select { |_, standing| standing.stop == ::Lain::Tripwire::Rules::WOULD_STOP }

        def false_requesters(fold)
          return {} unless @labels.labelled?

          tripped(fold).select { |requester, _| routine?(fold.calls.fetch(requester, [])) }
                       .transform_values { |standing| standing.evidence.map { _1["signal"] }.uniq.sort }
        end

        def routine?(calls) = calls.any? && calls.all? { @labels.fetch(_1.digest) == ROUTINE }

        def lines_of(row)
          default = " (default)" if row.rules == ::Lain::Tripwire::Rules::DEFAULT
          head = "  hard_stop=#{row.rules.hard_stop}#{default}, points strong #{row.rules.points_for(:strong)}, " \
                 "medium #{row.rules.points_for(:medium)}, weak #{row.rules.points_for(:weak)}"
          [head, "    tripped: #{row.tripped} of #{noun(row.sessions, "session")}", *false_lines(row)]
        end

        def false_lines(row)
          return [] unless row.false_trips

          ["    false trips: #{row.false_trips} of #{noun(row.sessions, "session")}#{interval_of(row)}",
           *row.signals.map { |requester, names| "      #{requester} (#{names.join(", ")})" }]
        end

        def interval_of(row)
          return unless row.low

          low, high = Compare::Stats::Interval.new(low: row.low, high: row.high).percents
          " (#{Compare::Stats.rate_percent(row.false_trips, row.sessions)}%, 95% CI #{low}-#{high}%)"
        end

        def unattributed_lines
          count = @journals.sum { fold(@rules.first, _1).unattributed }
          return [] if count.zero?

          ["  #{noun(count, "hit")} named no requester (default rules), so #{count == 1 ? "it was" : "they were"} " \
           "attributed to \"#{::Lain::Tripwire::Ledger::UNKNOWN}\" and cannot be checked against the labels"]
        end

        # Older journals named no subagent, so unknown cannot be read as the main agent; it stays unchecked.
        def unchecked_lines
          count = @journals.count { tripped(fold(@rules.first, _1)).key?(::Lain::Tripwire::Ledger::UNKNOWN) }
          return [] if count.zero?

          ["  #{noun(count, "session")} tripped with no requester named (default rules): counted as tripped, " \
           "not checked against the labels"]
        end

        def noun(count, word) = "#{count} #{word.pluralize(count)}"
      end
    end
  end
end
