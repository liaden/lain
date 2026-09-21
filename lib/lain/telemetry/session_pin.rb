# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A pin record must name the turn it pins and say WHICH WAY the pin
      # moved, as a real boolean -- `presence:` would silently reject `false`,
      # which is exactly the retraction this record exists to express (the
      # same reasoning {RequestSent}'s `stream` carries).
      class SessionPin < Declarative::Carrier
        attribute :digest
        attribute :pinned
        validates :digest, presence: { message: "must name the turn it pins, got nil" }
        validates :pinned, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end

    # One pin transition, recorded so a `--resume` rebuilds the pin-set. A LOG
    # line, not a set member: `pinned` carries the DIRECTION, because a pin
    # followed by an unpin must rebuild as not pinned and a shape that could
    # only say "pinned" could not express the retraction at all.
    # {SessionRecord::Replay} folds these in recorded order, so the last
    # transition for a digest wins by construction.
    #
    # `digest` names a committed Turn, never a path: pins protect turns from
    # compaction, and the digest is what a compaction source matches on.
    # Emitted by {Session} as it records, never by the Agent or a tool.
    SessionPin = Data.define(:digest, :pinned) do
      include Journalable

      def initialize(digest:, pinned:) = super(**Carriers::SessionPin.settle!(digest:, pinned:))
    end
  end
end
