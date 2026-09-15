# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # All three REQUIRED, and that is the whole reason the guard exists: every
      # field is coerced with `to_s`, so a nil would journal `""` -- a record
      # that looks like evidence and names nothing.
      class ApprovalPending < Declarative::Carrier
        attribute :requester
        attribute :tool
        attribute :tool_use_id
        validates :requester, presence: { message: "must name who the call was asked for, got nil" }
        validates :tool, presence: { message: "must name the gated tool, got nil" }
        validates :tool_use_id, presence: { message: "must name the gated call, got nil" }
      end
    end

    # A gated tool call parked awaiting a verdict, and the reason it exists
    # beside `approval_decision`: a decision-only stream can say what was
    # approved but never that something is WAITING, which is the one state a
    # human is actually asked to act on.
    #
    # A separate value object rather than the {Approval::Queue::Pending} itself,
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
    # to keep out of the journal. Id in, payload out.
    ApprovalPending = Data.define(:requester, :tool, :tool_use_id, :humans_only) do
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
        new(requester: pending.requester, tool: pending.tool, tool_use_id: pending.tool_use_id,
            humans_only: pending.humans_only?)
      end

      # Interned rather than `dup.freeze`d: these three values repeat on every
      # park of a session, so two equal records share one String rather than
      # holding two copies of the same bytes.
      def initialize(requester:, tool:, tool_use_id:, humans_only: false)
        Carriers::ApprovalPending.check!(requester:, tool:, tool_use_id:)

        super(requester: -requester.to_s, tool: -tool.to_s, tool_use_id: -tool_use_id.to_s,
              humans_only: humans_only == true)
      end
    end
  end
end
