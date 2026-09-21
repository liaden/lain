# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Tells the human that a turn wrote where this snapshot's root does not
      # reach, so those paths were not recorded and `/undo` cannot put them
      # back. Without this the omission is only a journal line, and the undo
      # reports "no file needed putting back" over a file that is still
      # changed. {SnapshotDegraded}'s shape and tokens -- the sibling notice,
      # for the other reason a turn's changes are not reversible.
      class SnapshotNarrowed
        def initialize(event) = @event = event

        def line_shaped? = true

        # @param theme [Frontend::Theme]
        # @return [String] one attributed line: how much went unrecorded, and
        #   where the snapshot reached
        def render(theme)
          "#{theme.paint(:label, "[snapshot]")} #{theme.paint(:warning, detail)}"
        end

        private

        # "went unrecorded" rather than a "wasn't"/"weren't" the count would
        # have to choose between: one verb that agrees with either number.
        def detail
          "#{counted} outside #{@event.root} went unrecorded, so this turn's changes there can't be undone"
        end

        # A human reads this line, and "1 paths" reads as a bug in the line.
        def counted = "#{@event.dropped} path#{"s" if @event.dropped != 1}"
      end
    end
  end
end
