# frozen_string_literal: true

module Lain
  module Summarizer
    # One tool result, as a summarizer sees it: the tool that produced the text
    # and the text itself. Both, because kinds of output divide on both axes --
    # a file read is told apart by its TOOL, while a coverage report and a build
    # log are both `bash` and can only be told apart by their CONTENT. A
    # predicate given just one of the two cannot express half the catalog.
    #
    # Deeply frozen so `Ractor.shareable?(result)` holds: `Data` freezes the
    # instance but not the Strings inside it, and `Symbol#to_s` hands back a
    # MUTABLE String, so each member is frozen explicitly. The tool name is
    # interned (`-`) rather than merely frozen -- it is short and repeats on
    # every result, which is what the fstring table is for.
    Result = Data.define(:tool_name, :text) do
      def initialize(tool_name:, text:)
        super(tool_name: -tool_name.to_s, text: text.to_s.freeze)
      end
    end
  end
end
