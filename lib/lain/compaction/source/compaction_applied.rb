# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      CompactionApplied = Data.define(:cut_digest, :head_digest) do
        include Telemetry::Journalable
      end
    end
  end
end
