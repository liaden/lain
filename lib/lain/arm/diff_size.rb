# frozen_string_literal: true

module Lain
  class Arm
    # How much a run wrote, counted from the FILE blocks the grader saw, so a block
    # the parser cannot read (a malformed END, or no END) is not counted.
    DiffSize = Data.define(:files, :lines) do
      # @param timeline [#to_a] the run's turns
      # @return [DiffSize]
      def self.of(timeline)
        written = Bench::ArmSweep.trajectory(timeline).files
        new(files: written.size, lines: written.values.sum { |body| body.lines.size })
      end
    end
  end
end
