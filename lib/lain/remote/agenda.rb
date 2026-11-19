# frozen_string_literal: true

require "active_support/core_ext/object/deep_dup"
require "time"

module Lain
  module Remote
    # Everything waiting on a human, as one list a remote surface can follow:
    # the parked tool calls, the deferred epic gates and the open ask_human
    # questions. It polls each owner rather than folding the journal, because a
    # parked call's input is never journaled, and every answer goes back to the
    # owner that would take it at the desk.
    #
    # Ids are minted here, once per item, because a `tool_use_id` can park twice.
    class Agenda
      SURFACE = "remote"

      # A gate deferred for sign-off has no asking agent of its own.
      GATE_REQUESTER = "epic gate"

      # `releases` is how many sensitive regions a yes would release, a count
      # and never the regions, so a surface off this box can leave the item out.
      # Only a parked call can release any; the other kinds carry 0. A gate's
      # `digests` are its rows' artifact digests, which name the revision a
      # yes approves; empty for the unreadable-journal item.
      ParkedCall = Data.define(:id, :requester, :tool, :input, :cwd, :why, :asked_at, :releases)
      GateQuestion = Data.define(:id, :requester, :epic, :stage, :issues, :question, :asked_at, :releases, :digests)
      Question = Data.define(:id, :requester, :question, :options, :asked_at, :releases)

      # The route is held beside the frozen item, because an answer must reach
      # the owner object the item was read from, not one looked up again.
      Entry = Data.define(:item, :route)

      # The id is minted only on first sight, so an item keeps its id across polls.
      Sighting = Data.define(:key, :build, :route) do
        def entry(id) = Entry.new(item: Ractor.make_shareable(build.call(id)), route:)
      end

      # @param queue [Enumerable<Approval::Parked::Queue::Pending>] the parked calls
      # @param gates [#each, #approve, #deny] the deferred gate rows ({Gates}); each answer names who gave it
      # @param replies [#waiting, #answer] the open human questions, and their answer path, which
      #   answers whether this answer won and journals who gave it ({CLI::HumanReplies})
      # @param wall [#call] the time of day, stamped on a call when first seen
      def initialize(queue:, gates:, replies:, wall: -> { Time.now })
        @sources = [Calls.new(queue, wall), Waves.new(gates, wall), Questions.new(replies)]
        @live = {}
        @minted = 0
        @log = []
      end

      # @return [Array<ParkedCall, GateQuestion, Question>] frozen, oldest first
      def snapshot = refresh.values.map(&:item).freeze

      # Applying the result to the snapshot taken at `cursor` gives the current
      # snapshot: add `added`, then drop every id in `settled`.
      #
      # @param cursor [Integer] a generation this agenda has answered; 0 is the empty agenda
      # @return [Array(Integer, Array, Array<String>)] the current generation, the items added
      #   since `cursor` and still waiting, and the ids that waited at `cursor` and no longer do
      # @raise [ArgumentError] for a cursor this agenda never answered
      def delta_since(cursor)
        refresh
        raise ArgumentError, "cursor #{cursor.inspect} is not in 0..#{@log.size}" unless (0..@log.size).cover?(cursor)

        window = @log.drop(cursor)
        added = window.flat_map(&:first)
        settled = window.flat_map(&:last).to_set
        added_ids = added.to_set(&:id)
        [@log.size, added.reject { settled.include?(_1.id) }.freeze,
         settled.reject { added_ids.include?(_1) }.freeze].freeze
      end

      # @param id [String] an id this agenda minted
      # @param answer [Approval::Verdict::Base, Hash{String=>Approval::Verdict::Base}, String]
      #   a verdict for a call; a verdict, or one per issue id, for a gate; text for a question
      # @param surface [String] who answered, as the escalation record names it
      # @return [Boolean] false when the item was settled elsewhere first
      # @raise [ArgumentError] for an id this agenda never minted, an answer of the wrong shape,
      #   or the item standing in for a gate journal that cannot be read
      def answer(id, answer, surface: SURFACE)
        raise ArgumentError, "no agenda item #{id.inspect} was ever listed" unless minted?(id)

        entry = refresh.values.find { _1.item.id == id }
        entry ? entry.route.call(answer, surface) : false
      end

      private

      def minted?(id) = id.to_s.match?(/\A\d+\z/) && id.to_i.between?(1, @minted)

      def refresh
        seen = @sources.flat_map(&:sightings).to_h { [_1.key, _1] }
        settled = @live.keys - seen.keys
        fresh = seen.except(*@live.keys).values
        record(fresh.map { |sighting| mint(sighting) }, settled.map { @live.delete(_1).item.id })
        @live
      end

      def mint(sighting)
        @minted += 1
        @live[sighting.key] = sighting.entry(@minted.to_s)
        @live[sighting.key].item
      end

      def record(added, settled)
        @log << [added.freeze, settled.freeze].freeze unless added.empty? && settled.empty?
      end

      # The parked calls still undecided. A call is first seen when it parks, so
      # that moment stands in for the queue's monotonic one.
      class Calls
        def initialize(queue, wall)
          @queue = queue
          @wall = wall
        end

        def sightings
          @queue.reject(&:decided?).map do |pending|
            Sighting.new(key: [:call, pending.object_id], build: ->(id) { item(id, pending) },
                         route: ->(verdict, surface) { pending.decide(verdict, surface:, authority: :human) })
          end
        end

        private

        def item(id, pending)
          ParkedCall.new(id:, requester: -pending.requester.to_s, tool: -pending.tool.to_s,
                         input: pending.input.deep_dup, cwd: -pending.cwd.to_s, why: pending.notes.join("\n"),
                         asked_at: @wall.call.dup, releases: pending.outstanding.count)
        end
      end

      # The deferred gates, one item per epic and stage, so a wave is one
      # question with an issue list. An issue's newest parked revision stands for
      # the key, so a desk decision on an older one leaves the item as it was; a
      # newer revision is a new item.
      class Waves
        # A deferred gate already waits, so a hold would answer nothing and the phone would show it landed.
        HOLD_REFUSAL = "a gate cannot be held: it already waits for an answer, so approve or deny it"

        def initialize(gates, wall)
          @gates = gates
          @wall = wall
        end

        # A journal the gate fold refuses must not blind the calls and questions
        # beside it, so the refusal is listed as the one gate item a human can read.
        def sightings
          @gates.each.group_by { [_1.epic, _1.stage] }.map { |(epic, stage), rows| sighting(epic, stage, rows) }
        rescue JournalUnreadable => e
          [Sighting.new(key: [:unreadable, e.message], build: ->(id) { unreadable(id, e.message) },
                        route: ->(_answer, _surface) { raise ArgumentError, unanswerable(e.message) })]
        end

        private

        def sighting(epic, stage, rows)
          newest = newest_per_key(rows)
          Sighting.new(key: [:gate, epic, stage, *newest.map(&:digest)], build: ->(id) { item(id, newest) },
                       route: ->(answer, surface) { decide(rows, answer, surface) })
        end

        # A row is parked oldest first within its partition, so the last of a key is its newest revision.
        def newest_per_key(rows) = rows.group_by { key_of(_1) }.values.map(&:last)

        # Not false: false says another surface answered first, and this item stays listed.
        def unanswerable(message)
          "this item reports a gate journal that cannot be read, and no answer reaches a gate through it: #{message}"
        end

        def unreadable(id, message)
          GateQuestion.new(id:, requester: GATE_REQUESTER, epic: "", stage: "", issues: [], question: message,
                           asked_at: @wall.call.dup, releases: 0, digests: [])
        end

        def item(id, rows)
          GateQuestion.new(id:, requester: GATE_REQUESTER, epic: rows.first.epic, stage: rows.first.stage,
                           issues: rows.map { key_of(_1) }.uniq, question: rows.filter_map(&:question).uniq.join("\n"),
                           asked_at: rows.map(&:asked_at).min, releases: 0, digests: rows.map(&:digest))
        end

        # An epic-wide stage has no issue, so the stage's own name is the key
        # an answer cites, and the app's map over the issues reaches it.
        def key_of(row) = row.issue || row.stage

        # Approvals go first because only an approval can refuse (its epic may
        # not open): a refusal then lands before any denial is journaled,
        # though the approvals before it stay journaled. A row the desk answered
        # first is no longer parked, so the answer is false even when rows
        # before it were already written.
        def decide(rows, answer, surface)
          newest = newest_per_key(rows)
          ordered(verdicts(rows, answer, newest)).each do |row, verdict|
            settle(row, verdict, surface, required: newest.include?(row))
          end
          true
        rescue CLI::EpicQueue::UnknownDigest
          false
        end

        # An older revision the desk already decided is nothing left to answer; only the newest must land.
        def settle(row, verdict, surface, required:)
          @gates.public_send(verdict.approved? ? :approve : :deny, row.digest, reason: verdict.note,
                                                                               answered_by: surface)
        rescue CLI::EpicQueue::UnknownDigest
          raise if required
        end

        def ordered(verdicts) = verdicts.partition { |_row, verdict| verdict.approved? }.flatten(1)

        # Refused rather than taken: an answer that decides nothing reads as
        # landed, and the item would then wait with no surface able to answer it.
        # An approval of the newest revision supersedes the older ones in the fold, so only a denial,
        # which supersedes none, is journaled for each.
        def verdicts(rows, answer, newest)
          raise ArgumentError, "a gate answer names no issue; answer #{keys(rows)}" if answer == {}

          pairs = paired(rows, answer).reject { |row, verdict| verdict.approved? && newest.exclude?(row) }
          raise ArgumentError, HOLD_REFUSAL if pairs.any? { |_row, verdict| verdict.held? }

          pairs
        end

        def paired(rows, answer)
          return rows.map { [_1, Approval::Verdict.coerce(answer)] } unless answer.is_a?(Hash)

          answer.flat_map { |key, verdict| keyed(rows, key, verdict) }
        end

        def keyed(rows, key, verdict)
          found = rows.select { key_of(_1) == key }
          raise ArgumentError, "issue #{key.inspect} is not in this gate (#{keys(rows)})" if found.empty?

          found.map { [_1, Approval::Verdict.coerce(verdict)] }
        end

        def keys(rows) = rows.map { key_of(_1) }.uniq.join(", ")
      end

      # Keyed by digest, not by arrival: a reply handed back for being too long
      # re-arrives under the same digest and is still one question.
      class Questions
        def initialize(replies) = @replies = replies

        def sightings
          @replies.waiting.map do |asked|
            Sighting.new(key: [:question, asked.digest], build: ->(id) { item(id, asked) },
                         route: ->(text, surface) { @replies.answer(text!(text), asked.digest, answered_by: surface) })
          end
        end

        private

        def text!(answer)
          return answer if answer.is_a?(String)

          raise ArgumentError, "a question is answered with text, got #{answer.class}"
        end

        def item(id, asked)
          Question.new(id:, requester: -asked.from.to_s, question: -asked.question.to_s, options: [],
                       asked_at: asked.asked_at.dup, releases: 0)
        end
      end

      # The deferred gate rows `lain epic queue` lists, read from the same
      # session journals, and answered through {CLI::EpicQueue} so a sign-off
      # here journals what `lain epic approve|deny` journals.
      class Gates
        Row = Data.define(:digest, :epic, :stage, :issue, :question, :asked_at)

        TYPES = [Epic::SignoffQueue::JOURNAL_TYPE, CLI::EpicQueue::PARKED_TYPE].freeze

        # @param paths [Paths]
        # @param root [String] the project root whose session journals hold the gates
        def initialize(paths:, root:)
          @paths = paths
          @root = root
        end

        # @return [Enumerator<Row>] every parked or held gate, oldest first within a partition
        def each(&block)
          records = CLI::SessionJournals.of(@paths, @root, types: TYPES, damage: CLI::SessionJournals::Tolerate).to_a
          waits = waits(records)
          first = first_decided(records)
          queue = Epic::SignoffQueue.from_journal(records)
          [*queue.to_a, *Epic::Signoff.from_journal(records).held_items].map do |item|
            row(item, waits[address_of(item)], first.fetch(address_of(item)))
          end.each(&block)
        end

        # A fresh {CLI::EpicQueue} per answer: it reads its fold once per instance.
        def approve(digest, reason: nil, answered_by: CLI::EpicQueue::HUMAN)
          epic_queue.approve(digest, reason:, answered_by:)
        end

        def deny(digest, reason: nil, answered_by: CLI::EpicQueue::HUMAN)
          epic_queue.deny(digest, reason:, answered_by:)
        end

        private

        def epic_queue = CLI::EpicQueue.new(paths: @paths, root: @root)

        def waits(records)
          Journal.records(records, type: CLI::EpicQueue::PARKED_TYPE)
                 .select { _1["kind"] == "gate" && _1["deferred"] == true }.to_h { [address(_1, "ref"), _1] }
        end

        # A gate parked with no wait journaled is dated by its own first decision.
        def first_decided(records)
          Journal.records(records, type: Epic::SignoffQueue::JOURNAL_TYPE).each_with_object({}) do |record, first|
            key = address(record, "artifact_digest")
            first[key] = [first[key], Time.iso8601(record["ts"])].compact.min
          end
        end

        def row(item, wait, decided)
          Row.new(digest: item.artifact_digest, epic: item.epic_slug, stage: item.stage, issue: item.issue_id,
                  question: item.question || wait&.dig("summary"),
                  asked_at: wait ? Time.iso8601(wait["ts"]) : decided)
        end

        def address(record, digest) = [record[digest].to_s, record["epic_slug"].to_s, record["stage"].to_s]

        def address_of(item) = [item.artifact_digest, item.epic_slug, item.stage]
      end
    end
  end
end
