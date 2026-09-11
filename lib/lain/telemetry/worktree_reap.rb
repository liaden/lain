# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A reap record lands on one of the two things the reaper does, to one of
      # the three kinds of thing it may touch, and says which one and why.
      class WorktreeReap < Declarative::Carrier
        attribute :action
        attribute :subject
        attribute :name
        attribute :reason
        validates :action, inclusion: { in: %i[reaped kept], message: "must be one of reaped/kept, got %<value>s" }
        validates :subject, inclusion: { in: %i[worktree anchor branch],
                                         message: "must be one of worktree/anchor/branch, got %<value>s" }
        validates :name, presence: { message: "must name the worktree or ref, got %<value>s" }
        validates :reason, presence: { message: "must say why, got %<value>s" }
      end
    end

    # One decision of {Isolation::Gc}'s: a checkout, a worker anchor or a
    # marked working branch, reaped or kept, and why. `name` is the checkout's
    # path (lain's own state dir, as on {IsolationLease}) or the ref's full
    # name. `anchors` names the refs a kept checkout's work was moved onto
    # before the checkout went, so the record says where the work now lives.
    WorktreeReap = Data.define(:action, :subject, :name, :reason, :anchors) do
      include Journalable

      def initialize(action:, subject:, name:, reason:, anchors: [])
        action = action.to_sym
        subject = subject.to_sym
        Carriers::WorktreeReap.check!(action:, subject:, name:, reason:)

        super(action:, subject:, name: -name.to_s, reason: -reason.to_s,
              anchors: Freezable::Fields.pinned_each(anchors))
      end

      def reaped? = action == :reaped
    end
  end
end
