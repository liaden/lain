# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # All three REQUIRED, and that is the whole reason the guard exists: every
      # field is coerced with `to_s`, so a nil would journal `""` -- a record
      # that looks like evidence and names nothing.
      class ApprovalPending < Declarative::Carrier
        attribute :requester, :lain_interned
        attribute :tool, :lain_interned
        attribute :tool_use_id, :lain_interned
        attribute :humans_only, default: false
        attribute :notes, default: -> { [] }
        attribute :kind, :lain_interned, default: "tool"
        attribute :input_digest, default: nil
        validates :requester, presence: { message: "must name who the call was asked for, got nil" }
        validates :tool, presence: { message: "must name the gated tool, got nil" }
        validates :tool_use_id, presence: { message: "must name the gated call, got nil" }
        validates :requester, :tool, :tool_use_id, raw_present: { only_false: true, message: "must not be false" }
      end
    end

    # A gated tool call parked awaiting a verdict, and the reason it exists
    # beside `approval_decision`: a decision-only stream can say what was
    # approved but never that something is WAITING, which is the one state a
    # human is actually asked to act on.
    #
    # A separate value object rather than the {Approval::Parked::Queue::Pending} itself,
    # which holds an injected clock and a decision it exists to have mutated --
    # coordination state that can never be `Ractor.shareable?`.
    #
    # `tool_use_id` is the CORRELATION KEY onto the gated call, and the
    # `approval_decision` that settles it carries the same id, so a reader pairs
    # the two rather than counting them. The id is not unique to one park: a
    # `read_file` of a gated file parks at the path gate and again at the
    # release, one after the other, so within an id the records pair IN ORDER.
    #
    # `humans_only` says whether only a person may decide the call, which is why
    # an automatic surface was never offered it.
    #
    # The Pending's `input` is deliberately left off: tool arguments are
    # unbounded and may carry exactly the credential bytes {WriteRefused} exists
    # to keep out of the journal. Id in, payload out; `input_digest` names the
    # bytes without carrying them, and is absent for a decision that is no call.
    ApprovalPending = Data.define(:requester, :tool, :tool_use_id, :humans_only, :notes, :kind, :input_digest) do
      include Journalable

      # Built from the parked {Approval::Parked::Queue::Pending} at admit time, so the
      # queue names the fields once and this record owns the projection.
      #
      # ⚠️ `outstanding` is ABSENT and must stay absent. A {Pending} carries the
      # sensitive regions a yes would release, bytes and all
      # ({Approval::Parked::Queue::Outstanding}), and the ONLY thing keeping them out of
      # the Journal is that this hand-maintained list does not name them. Adding
      # the field -- for a HUD, for a replay, for symmetry -- writes real
      # credentials to disk, and no test would catch it, because every test here
      # asserts the fields that ARE listed. {Approval::Parked::Queue::Pending#to_journal} carries
      # the identical hazard and the identical note.
      def self.from(pending)
        new(requester: pending.requester, tool: pending.tool, tool_use_id: pending.tool_use_id,
            humans_only: pending.humans_only?, notes: pending.notes, kind: pending.kind,
            input_digest: pending.input_digest)
      end

      # The three identifiers are interned by the carrier: they repeat on every
      # park of a session, so two equal records share one String.
      def initialize(requester:, tool:, tool_use_id:, humans_only: false, notes: [], kind: "tool", input_digest: nil)
        super(**Carriers::ApprovalPending.settle!(
          requester:, tool:, tool_use_id:, humans_only: humans_only == true, kind:,
          notes: notes.map { -_1.to_s }, input_digest: input_digest&.then { -_1.to_s }
        ))
      end

      # Each absent when it says nothing, so a tool call nobody noted journals as it always did.
      def to_journal = omitting_defaults(super, Carriers::ApprovalPending, :notes, :kind, :input_digest)
    end
  end
end
