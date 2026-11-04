# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A stop must name the spawn its resume continues and the head it continues from.
      class ChildStopped < Declarative::Carrier
        attribute :spawn, :lain_interned
        attribute :label, :lain_interned
        attribute :role, default: nil
        attribute :head, :lain_interned
        attribute :lease_path, default: nil
        attribute :ceiling, default: nil
        attribute :reason, :lain_interned
        attribute :snapshot, default: nil
        attribute :task, :lain_interned, default: ""
        attribute :parent, default: nil
        attribute :kept, default: false
        validates :spawn, presence: { message: "must name the :spawn the stopped child ran under, got nil" }
        validates :head, presence: { message: "must name the head the child stopped at, got nil" }
        validates :ceiling, numericality: { only_integer: true, allow_nil: true,
                                            message: "must be the iteration ceiling it ran under, got %<value>s" }
      end
    end

    ChildStopped = Data.define(:spawn, :label, :role, :head, :lease_path, :ceiling, :reason, :snapshot, :task,
                               :parent, :kept)

    # A child that stopped before it answered, recorded so a restarted run can
    # resume it: the live run held it only in memory. `snapshot` is a commit of
    # its checkout's working state, first parent HEAD, because a run that never
    # closed may leave that checkout for the reaper. `task` is the prompt
    # itself, since the `:spawn` holds only its digest. `parent` is the chain
    # the child stopped under, and only that chain's spawner resumes it; `kept`
    # says it worked in a directory only its own run confines.
    #
    # `reason` is not checked against {REASONS}, so the registry sweeps can
    # build this record from generic dummies. Reopened for the constants, since
    # one declared inside a `Data.define` block lands in the enclosing module.
    class ChildStopped
      include Journalable

      REASONS = %w[iterations transport interrupted].freeze

      def initialize(spawn:, label:, head:, reason:, role: nil, lease_path: nil, ceiling: nil, snapshot: nil,
                     task: "", parent: nil, kept: false)
        super(**Carriers::ChildStopped.settle!(
          spawn:, label:, head:, reason:, ceiling:, task:, kept: kept ? true : false,
          role: role&.then { -_1.to_s }, lease_path: lease_path&.then { -_1.to_s },
          snapshot: snapshot&.then { -_1.to_s }, parent: parent&.then { -_1.to_s }
        ))
      end
    end
  end
end
