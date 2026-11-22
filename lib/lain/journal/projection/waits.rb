# frozen_string_literal: true

module Lain
  class Journal
    class Projection
      # Every wait on a human that no later record has closed: parked approvals, gates and the
      # model's questions. The chat's tee steps it with live objects, and a reader of a closed file
      # with lines read back leniently, where every closing record arrives as {Telemetry::Untyped},
      # so each is matched both ways.
      #
      # An approval closes on the park its decision names, since one `tool_use_id` can park twice; a
      # record from before parks carried an identity pairs on the `tool_use_id` in order. A gate or a
      # question closes on `ref`.
      # A wave asked under one `question_key` is one wait until every issue in it is decided. A
      # hold closes nothing: the work waits until the human speaks again.
      #
      # It declares no `combine`: a decision in one half closes a park in the other.
      class Waits < Projection
        # @!attribute [r] ref
        #   @return [String] the call id, the artifact or question digest, or a wave's question key
        # @!attribute [r] kind
        #   @return [String] approval, gate or question
        # @!attribute [r] agent
        #   @return [String] {MAIN}, or the digest of the spawn the wait belongs to
        # @!attribute [r] summary
        #   @return [String] what the human is asked
        Wait = Data.define(:ref, :kind, :agent, :summary)

        Ask = Data.define(:wait, :refs, :counted)
        private_constant :Ask

        Parked = Data.define(:wait, :park)
        private_constant :Parked

        MAIN = "main"

        # {Journal#encode}'s failure record, also what {Approval::Parked::Queue#degrade} writes in
        # place of a park or a decision; live it is a raw Hash.
        JOURNAL_ERROR = "journal_error"

        HOLD = Epic::GateDecision::WORDS.fetch(Approval::Verdict::Hold)
        private_constant :HOLD

        # @return [Waits]
        def self.unit = new({ approvals: [], degraded_parks: 0, asks: {} })

        # @param record [Telemetry::Journalable, Telemetry::Untyped, Approval::Parked::Queue::Pending, Hash]
        # @return [Waits] self for a record that opens or closes nothing
        def step(record)
          case record
          when Telemetry::AwaitingHuman then opened(record)
          when Approval::Parked::Queue::Pending then released(record.tool_use_id, record.park)
          when Epic::GateDecision then record.held? ? self : closed("gate", [record.artifact_digest])
          when Telemetry::QuestionsConsumed then closed("question", record.digests)
          when Telemetry::Untyped, Hash then read_back(record)
          else self
          end
        end

        # @return [Array<Wait>] approvals first, then gates and questions, each in the order opened
        def open = approvals.map(&:wait) + asks.values.map(&:wait)

        # @param agent [String] {MAIN} or a spawn's digest
        # @return [Array<Wait>]
        def open_for(agent) = open.select { |wait| wait.agent == agent }

        # @return [Integer] parked approvals, degraded parks included
        def approvals_pending = approvals.size + degraded_parks

        # @return [Integer] what the human is waited on for now, a deferred gate excluded
        def waiting = approvals_pending + asks.count { |_, ask| ask.counted }

        # @return [Array<Wait>]
        def value = open

        private

        def approvals = state.fetch(:approvals)

        def degraded_parks = state.fetch(:degraded_parks)

        def asks = state.fetch(:asks)

        def with(**changes) = self.class.new(state.merge(changes))

        # Hash and {Telemetry::Untyped} both answer `[]` by the journal's own field names.
        def read_back(record)
          case record["type"]
          when "approval_decision" then released(record["tool_use_id"], record["park"])
          when "gate_decision" then record["verdict"] == HOLD ? self : closed("gate", [record["artifact_digest"]])
          when "questions_consumed" then closed("question", Array(record["digests"]))
          when JOURNAL_ERROR then degraded(record["entry_class"])
          else self
          end
        end

        def opened(record)
          wait = Wait.new(ref: record.question_key || record.ref, kind: record.kind, agent: record.spawn || MAIN,
                          summary: record.summary)
          return asked(record, wait) unless record.kind == "approval"

          with(approvals: [*approvals, Parked.new(wait.with(ref: record.ref), record.park)])
        end

        # A deferred gate is journaled after the decision that parked it and only the morning review
        # answers it, so it is open but not counted. A live ask for the same artifact replaces it,
        # and a deferred park landing on a live ask adds nothing, which keeps the counts the feed
        # published before this fold.
        def asked(record, wait)
          key = [wait.kind, wait.ref]
          live = !record.deferred
          ask = asks[key]
          return self if ask&.counted && !live

          return with(asks: asks.merge(key => ask.with(refs: [*ask.refs, record.ref]))) if ask&.counted == live

          with(asks: asks.except(key).merge(key => Ask.new(wait:, refs: [record.ref], counted: live)))
        end

        # A decision naming no open park still releases one, because the two halves of a park can
        # come apart: the queue's degrade path writes a `journal_error` in place of either, and a
        # lost decision would hold the count high for the rest of the run. A degraded park goes
        # first, since it names nothing a later decision could match, then the oldest approval.
        def released(tool_use_id, park = nil)
          index = approval_index(tool_use_id, park)
          return with(approvals: approvals.reject.with_index { |_, at| at == index }) if index
          return with(degraded_parks: degraded_parks - 1) if degraded_parks.positive?

          with(approvals: approvals.drop(1))
        end

        # A park that names itself closes by that name; one from before parks carried one, by its call.
        def approval_index(tool_use_id, park)
          approvals.index { |approval| park && approval.park == park } ||
            approvals.index { |approval| approval.park.nil? && approval.wait.ref == tool_use_id }
        end

        def closed(kind, refs) = refs.inject(self) { |waits, ref| waits.answered(kind, ref) }

        # A degraded park names no ref or agent, so it is counted but not listed.
        def degraded(entry_class)
          case entry_class
          when Telemetry::AwaitingHuman.name then with(degraded_parks: degraded_parks + 1)
          when Approval::Parked::Queue::Pending.name then released(nil, nil)
          else self
          end
        end

        protected

        # A decision answers every deferred wait holding its ref, which counts nothing, and only the
        # first live one, which is the one wait the feed closed before this fold kept deferred gates.
        def answered(kind, ref)
          holding = asks.select { |(open_kind, _), ask| open_kind == kind && ask.refs.include?(ref) }
          first_live = holding.find { |_, ask| ask.counted }
          closing = holding.reject { |_, ask| ask.counted }.merge([first_live].compact.to_h)
          return self if closing.empty?

          with(asks: closing.inject(asks) { |rest, (key, ask)| unanswered(rest, key, ask, ref) })
        end

        private

        def unanswered(rest, key, ask, ref)
          refs = ask.refs - [ref]
          refs.empty? ? rest.except(key) : rest.merge(key => ask.with(refs:))
        end
      end
    end
  end
end
