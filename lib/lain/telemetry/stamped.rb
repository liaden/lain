# frozen_string_literal: true

module Lain
  module Telemetry
    # A record copied onto a run journal shared by every arm, naming the arm and
    # task it came from. The record cannot know either, so the stamp is the
    # wrapper's rather than a field on each record type.
    Stamped = Data.define(:record, :arm, :task) do
      def to_journal = record.to_journal.merge("arm" => arm, "task" => task)
    end

    class Stamped
      # Stamps every record pushed through it onto the run journal.
      Sink = Data.define(:journal, :arm, :task) do
        def <<(record) = journal << Stamped.new(record:, arm:, task:)
      end
    end
  end
end
