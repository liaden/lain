# frozen_string_literal: true

module Lain
  class Tool
    module Bounds
      WalkLimit = Data.define(:entries, :bytes)

      # Bounds the cost of finding rows, where {WalkCap} bounds the rows returned,
      # so a secretly huge tree ends in a named stop. It never learns a total.
      # Reopened because a constant written in the `Data.define` block would
      # land on {Bounds}.
      #
      # @!attribute entries
      #   @return [Integer] files and directories one walk may list
      # @!attribute bytes
      #   @return [Integer] bytes one search may read
      class WalkLimit
        DEFAULT = new(entries: 20_000, bytes: 200 * 1024 * 1024)

        # Both counts are what the walk demanded, so a figure past the limit
        # means a stop: the walk counts the entry it refused, and a read counts
        # the file whose size would not fit.
        #
        # @param listed [Integer] entries the walk counted
        # @param read_bytes [Integer] bytes read, plus the file refused for size
        # @return [String, nil] nil when neither limit was passed
        def notice(listed:, read_bytes:)
          stops = []
          stops << "listing stopped at #{entries} entries" if listed > entries
          stops << "reading stopped at #{bytes} bytes" if read_bytes > bytes
          return if stops.empty?

          "... #{stops.join("; ")}; narrow the path or the pattern"
        end
      end
    end
  end
end
