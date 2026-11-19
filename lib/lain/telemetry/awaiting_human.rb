# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require "time"

module Lain
  module Telemetry
    module Carriers
      # Every field but `kind` is untyped because interning would turn the nil
      # of a field a kind does not carry into "", a value that names nothing.
      # The approval identifiers are checked before `ref`, so a nameless call
      # is refused for the field a reader of the call knows it by.
      class AwaitingHuman < Declarative::Carrier
        KINDS = %w[approval gate question].freeze

        attribute :kind, :lain_interned
        attribute :ref
        attribute :deadline
        attribute :summary
        attribute :requester
        attribute :tool
        attribute :tool_use_id
        attribute :humans_only, default: false
        attribute :notes, default: -> { [] }
        attribute :input_digest
        attribute :deferred, default: false
        attribute :epic_slug
        attribute :stage
        attribute :issue_id
        attribute :sha
        attribute :question_key
        attribute :spawn
        validates :kind, inclusion: { in: KINDS, message: "must be approval, gate or question, got %<value>s" }
        validates :requester, presence: { message: "must name who the call was asked for, got nil" }, if: :approval?
        validates :tool, presence: { message: "must name the gated tool, got nil" }, if: :approval?
        validates :tool_use_id, presence: { message: "must name the gated call, got nil" }, if: :approval?
        validates :ref, presence: { message: "must name what is waited on, got nil" }
        validates :summary, presence: { message: "must say what the human is asked, got nil" }

        def approval? = kind == "approval"
      end
    end

    # A human is being waited on: a parked tool call, a gate, or the model's
    # own question. One record for all three so a reader counting what is
    # waiting folds one type against its closing records, `approval_decision`,
    # `gate_decision` and `questions_consumed`, each paired on `ref`.
    #
    # `deadline` is the wall-clock moment the wait is denied unanswered, nil
    # when no clock ends it. `deferred` marks a gate parked for the morning
    # review: it is written after the denial that closed its gate, and only
    # the sign-off queue reads it, by the address its gate fields carry.
    #
    # An approval's `tool_use_id` is not unique to one park: a `read_file` of a
    # gated file parks at the path gate and again at the release, so within an
    # id the records pair IN ORDER.
    #
    # @!attribute [r] kind
    #   @return [String] approval, gate or question
    # @!attribute [r] ref
    #   @return [String] the call id, the artifact digest or the question digest
    # @!attribute [r] deadline
    #   @return [String, nil] ISO 8601, UTC
    # @!attribute [r] summary
    #   @return [String] what the human is asked
    # @!attribute [r] question_key
    #   @return [String, nil] what the waits of one question share, so a reader
    #     counts a wave asked as one question once
    # @!attribute [r] spawn
    #   @return [String, nil] the digest of the :spawn a child's wait belongs to; nil for the main chat's
    AwaitingHuman = Data.define(:kind, :ref, :deadline, :summary, :requester, :tool, :tool_use_id, :humans_only,
                                :notes, :input_digest, :deferred, :epic_slug, :stage, :issue_id, :sha,
                                :question_key, :spawn) do
      include Journalable

      # The parked call's `input` and its `outstanding` regions are ABSENT and
      # must stay absent: both may carry credential bytes, and the only thing
      # keeping them out of the Journal is that this list does not name them.
      # No test would catch the field being added, because every test asserts
      # the fields that ARE listed. `input_digest` names the bytes without
      # carrying them, and a decision's `tool` is its kind. The command's text
      # reaches the record by one route only, `summary`, which holds just
      # `summary_face`: masked, then cut.
      #
      # @param pending [Approval::Parked::Queue::Pending]
      # @return [AwaitingHuman]
      def self.approval(pending)
        new(kind: "approval", ref: pending.tool_use_id, deadline: pending.deadline, summary: pending.summary_face,
            requester: pending.requester, tool: pending.tool, tool_use_id: pending.tool_use_id,
            humans_only: pending.humans_only?, notes: pending.notes, input_digest: pending.input_digest,
            spawn: pending.spawn)
      end

      # A part second is rounded up, so a deadline never reads earlier than the
      # clock that enforces it.
      #
      # @param seconds [Numeric, nil] how long until the wait is denied unanswered
      # @param from [Time] when it opened
      # @return [String, nil]
      def self.deadline(seconds, from:) = seconds && (from + seconds.ceil).utc.iso8601

      # The first sentence of a question's first line, bounded: a gate's prompt
      # carries its reply instructions, which say nothing about what is waiting.
      #
      # @param question [String]
      # @return [String]
      def self.lead(question)
        line = question.to_s.strip.lines.first.to_s.chomp
        (line[/\A.*?[?.!](?=\s|\z)/] || line).truncate(120, omission: "...")
      end

      def initialize(kind:, ref:, summary:, deadline: nil, requester: nil, tool: nil, tool_use_id: nil,
                     humans_only: false, notes: [], input_digest: nil, deferred: false, epic_slug: nil, stage: nil,
                     issue_id: nil, sha: nil, question_key: nil, spawn: nil)
        named = { ref:, deadline:, summary:, requester:, tool:, tool_use_id:, input_digest:, epic_slug:, stage:,
                  issue_id:, sha:, question_key:, spawn: }.transform_values { |value| value.presence && -value.to_s }
        super(**Carriers::AwaitingHuman.settle!(kind:, humans_only: humans_only == true, deferred: deferred == true,
                                                notes: notes.map { -_1.to_s }, **named))
      end

      def to_journal
        omitting_defaults(super, Carriers::AwaitingHuman, :requester, :tool, :tool_use_id, :humans_only, :notes,
                          :input_digest, :deferred, :epic_slug, :stage, :issue_id, :sha, :question_key, :spawn)
      end
    end
  end
end
