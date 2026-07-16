# frozen_string_literal: true

module Lain
  # TL-2, the proof half of the collapse: Turn IS Event(kind: :turn). This
  # facade keeps the exact public surface (`Turn.new`, ROLES, InvalidRole) while
  # every value underneath is the one event primitive -- the full suite passing
  # against it is the isomorphism proof. The cut half removes this constant and
  # points callers at {Event.turn} directly.
  class Turn
    ROLES = Event::ROLES
    InvalidRole = Event::InvalidRole

    class << self
      def new(role:, content:, parent: nil, meta: {}, correlation: nil)
        Event.turn(role:, content:, parent:, meta:, correlation:)
      end
    end
  end
end
