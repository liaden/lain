# frozen_string_literal: true

module Lain
  module Telemetry
    # A `grep` or `ast_search` result whose rows had regions of one file
    # masked: which file, how many regions the rows showed, and how many of
    # those were already released. Counts, never bytes, as {ReadRedacted}.
    #
    # Its own record rather than a `read_redacted`, because
    # {SessionRecord::Replay} folds every `read_redacted` into the masked
    # read-set, and a search reads no file whole: folded as a mask, one grep
    # would leave every file it matched unwritable after a resume. Replay
    # folds this record into nothing.
    #
    # Checked by {Carriers::ReadRedacted}, whose fields and bounds it shares.
    SearchRedacted = Data.define(:tool_use_id, :path, :regions, :released) do
      include Journalable

      def initialize(tool_use_id:, path:, regions:, released:)
        Carriers::ReadRedacted.check!(path:, regions:, released:)

        super(tool_use_id: -tool_use_id.to_s, path: -path.to_s, regions: regions.to_i, released: released.to_i)
      end
    end
  end
end
