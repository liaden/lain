# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      CompactionPrepared = Data.define(:head_digest, :cut_digest, :idle_seconds, :cache_state) do
        include Telemetry::Journalable
      end
    end
  end
end
