# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A park record must name the call, the tool, and who it was asked for.
      # All three REQUIRED, and this is the whole reason the guard exists: every
      # field is a String coerced with `to_s`, so a nil would journal `""` --
      # a record that looks like evidence and names nothing, in a codebase whose
      # premise is loud failure.
      class ApprovalPending < Guard
        attribute :requester
        attribute :tool
        attribute :tool_use_id
        validates :requester, presence: { message: "must name who the call was asked for, got nil" }
        validates :tool, presence: { message: "must name the gated tool, got nil" }
        validates :tool_use_id, presence: { message: "must name the gated call, got nil" }
      end
    end

    # A gated tool call parked awaiting a verdict. The counterpart to the
    # `approval_decision` record {Approval::Queue::Pending#to_journal} builds,
    # and the reason the pair exists: a decision-only stream can say what was
    # approved but never that something is WAITING, which is the one state a
    # human is actually asked to act on. A surface that reads the journal (or a
    # status feed fed from it) counts a park here and clears it on the decision.
    #
    # A separate value object rather than the {Approval::Queue::Pending} itself:
    # a Pending holds an injected clock and a decision it exists to have
    # mutated, so it is coordination state and can never be `Ractor.shareable?`.
    # This is the frozen projection of it.
    #
    # `tool_use_id` is the CORRELATION KEY, the same field-and-not-the-payload
    # shape {WriteRefused} carries for exactly the same reason: it ties the park
    # to the one gated call it belongs to, so a reader is never left counting
    # anonymous parks. It is worth naming what it does NOT join to -- the
    # `approval_decision` record carries no id, so pending and decision still
    # pair by counting rather than by key. What this id joins to is the call
    # itself, everywhere else a `tool_use_id` already appears ({ToolOutput}, a
    # tool_result block).
    #
    # The Pending's `input` is deliberately left off: tool arguments are
    # unbounded and may carry exactly the credential bytes {WriteRefused}
    # exists to keep out of the journal -- which is the other half of why
    # {WriteRefused} is the precedent here, id in and payload out.
    #
    # Emitted by {Approval::Queue#admit}, which until now emitted nothing at all
    # -- the whole lifecycle's only observable was the post-hoc
    # `approval_decision` written in `#settle`'s ensure.
    ApprovalPending = Data.define(:requester, :tool, :tool_use_id) do
      include Journalable

      # Built from the parked {Approval::Queue::Pending} at admit time, so the
      # queue names the fields once and this record owns the projection.
      #
      # ⚠️ `outstanding` is ABSENT and must stay absent. A {Pending} carries the
      # sensitive regions a yes would release, bytes and all
      # ({Approval::Queue::Outstanding}), and the ONLY thing keeping them out of
      # the Journal is that this hand-maintained list does not name them. Adding
      # the field -- for a HUD, for a replay, for symmetry -- writes real
      # credentials to disk, and no test would catch it, because every test here
      # asserts the fields that ARE listed. {Queue::Pending#to_journal} carries
      # the identical hazard and the identical note.
      def self.from(pending)
        new(requester: pending.requester, tool: pending.tool, tool_use_id: pending.tool_use_id)
      end

      # Interned rather than `dup.freeze`d ({Effect::ToolCall}'s own idiom one
      # file over): these three values repeat on every park of a session, and
      # two equal records must share one String rather than hold two copies of
      # the same bytes.
      def initialize(requester:, tool:, tool_use_id:)
        Guards::ApprovalPending.check!(requester:, tool:, tool_use_id:)

        super(requester: -requester.to_s, tool: -tool.to_s, tool_use_id: -tool_use_id.to_s)
      end
    end
  end
end
