# frozen_string_literal: true

module Lain
  module Telemetry
    # The bench arms a run without a session header was started with, written once at
    # the top of its journal so the file says what it measured.
    RunArms = Data.define(:arms) do
      include Journalable

      def initialize(arms:) = super(arms: Ractor.make_shareable(arms.to_h { |name, value| [name.dup, value.dup] }))
    end
  end
end
