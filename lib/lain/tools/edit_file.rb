# frozen_string_literal: true

require_relative "../session"
require_relative "../tool"

module Lain
  module Tools
    # Structured, direct-Ruby `str_replace` edit: replaces `old_string` with
    # `new_string` at `path`, no subprocess -- the model has no command string
    # to interpolate, matching {ReadFile}'s reasoning for why a mutating
    # operation is still lowest-risk done as a structured call rather than
    # shelled out to `sed`/`patch`.
    #
    # The read-before-write contract is the point of this tool: `perform`
    # never runs unless {Lain::Session#read?} already says `path` was read
    # this session, enforced by {Tool::Contracts} rather than an `if` inside
    # `#perform` -- the invariant is structural, not merely hoped for.
    #
    # Occurrences are counted with overlap ("aa" occurs twice in "aaa"), so
    # "exactly once" means what the model reads it to mean.
    class EditFile < Tool
      # The wire shape: the path to edit, the exact text to find, and its
      # replacement.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to edit.", required: true
        field :old_string, :string, description: "Exact text to replace. Must occur exactly once in the file.",
                                    required: true
        field :new_string, :string, description: "Text to replace old_string with.", required: true
      end

      input_model Input

      # Named so the composed violation ("precondition failed for edit_file:
      # #{this}") reads as the fact the model needs -- that the session never
      # saw this file -- rather than as a bare contract label. `input.path`
      # (the coerced Tool::Input, not a Hash) is what {Tool#call} hands
      # contracts: see tool.rb:117-119.
      requires("path was never read this session") do |input, invocation|
        session_of(invocation).read?(input.path)
      end

      def name = "edit_file"

      def description
        "Replaces old_string with new_string in the file at path. " \
          "old_string must occur exactly once in the file's current contents " \
          "-- zero or multiple occurrences is refused as an error result, " \
          "never a guess. The file must have been read with read_file " \
          "earlier this session; editing a file that was never read is " \
          "refused."
      end

      protected

      def perform(input, invocation)
        path = input.path
        contents = File.read(path)
        occurrences = occurrences_of(input.old_string, contents)
        return Tool::Result.error(ambiguity_message(occurrences, path)) unless occurrences == 1

        # A block-form replacement, not `sub(pattern, new_string)`: the two-arg
        # form interpolates `\1`-style back-references out of new_string even
        # though old_string is a literal String with no capture groups, so a
        # model-supplied new_string containing a literal backslash-digit would
        # be silently mangled. The block's return value is used verbatim.
        File.write(path, contents.sub(input.old_string) { input.new_string })
        # A successful edit changed the file under this path -- the read-set
        # entry is refreshed so a later edit_file call still sees it as read.
        session_of(invocation).record_read(path)
        Tool::Result.ok("replaced 1 occurrence of old_string in #{path}")
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not edit #{path}: #{e.message}")
      end

      private

      # Mirrors ReadFile#session_of: the session rides the documented-nullable
      # {Tool::Invocation#context}, coalesced to the Null session in this one
      # named place so neither the contract predicate nor #perform ever guards
      # on nil.
      def session_of(invocation)
        invocation&.context || Session::Null.instance
      end

      # `String#scan` counts non-overlapping matches, which would call "aa" in
      # "aaa" unique and edit on a false premise; walking `index` forward by one
      # counts every window. `take_while` stops at the first nil, so the
      # produce block never sees one.
      def occurrences_of(needle, haystack)
        Enumerator.produce(haystack.index(needle)) { |at| haystack.index(needle, at + 1) }
                  .take_while(&:itself)
                  .size
      end

      def ambiguity_message(occurrences, path)
        "old_string occurs #{occurrences} times in #{path}; it must occur exactly once. " \
          "File left unchanged."
      end
    end
  end
end
