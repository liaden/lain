# frozen_string_literal: true

module Lain
  module Tools
    # Structured, direct-Ruby `str_replace` edit, no subprocess -- the model
    # has no command string to interpolate, which is why a MUTATING operation
    # is still lowest-risk done as a structured call rather than shelled out to
    # `sed`/`patch`.
    #
    # The read-before-write contract is the point of this tool: `perform` never
    # runs unless {Lain::Session#read?} already says `path` was read this
    # session, enforced by {Tool::Contracts} rather than an `if` inside
    # `#perform` -- the invariant is STRUCTURAL, not merely hoped for.
    #
    # Occurrences are counted with overlap ("aa" occurs twice in "aaa"), so
    # "exactly once" means what the model reads it to mean.
    class EditFile < Tool
      include Tool::FileTarget

      # The wire shape: the path to edit, the exact text to find, and its
      # replacement.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to edit.", required: true
        field :old_string, :string, description: "Exact text to replace. Must occur exactly once in the file.",
                                    required: true
        field :new_string, :string, description: "Text to replace old_string with.", required: true
      end

      input_model Input

      # Resolved exactly as {#perform} resolves it, so a message names the path
      # that would have been written rather than whatever spelling the model
      # sent. {Tool::Contracts} asks this AS the tool, which is what puts
      # {Tool::FileTarget}'s private resolver in its reach.
      SUBJECT = ->(input, invocation) { target(invocation, input.path) }
      private_constant :SUBJECT

      # THREE contracts, not one, because {Lain::Session} answers three
      # different refusals and a single message could only name one of them.
      #
      # ORDER IS DECLARATION ORDER, and it matters: a masked read is ALSO a
      # partial one, and a partial read is ALSO not a complete one, so the
      # narrowest cause must be tested FIRST or every masked file would be
      # refused as though it had merely been windowed, or never been read.
      # That wrong message is not cosmetic: a model told "path was never read
      # this session" about a file it just read re-reads it, gets the same
      # masked projection, is refused identically, and LOOPS.
      #
      # This message names NO remedy, because there is none within the session
      # and every softer wording tried so far was false. "A human must release
      # those regions" is false in both halves -- a re-read never re-asks
      # anybody, since {Middleware::RedactSecretReads} remembers the decline,
      # and a human who releases every region out of band still leaves this
      # refusal standing, because the masked set is add-only by
      # {Lain::Session::ReadSet}'s design. A model given any hint of a move
      # takes it, and here every move is a loop.
      requires("%<subject>s was read only in part this session -- sensitive regions were masked out of " \
               "what you saw, so editing it would clobber bytes you never read. Nothing in this session " \
               "will lift that, and re-reading will not: report it and do something else",
               subject: SUBJECT) do |input, invocation|
        !session_of(invocation).masked_read?(target(invocation, input.path))
      end

      # The mirror image of the one above: here the missing bytes are missing
      # because the MODEL asked for a window, so the refusal does name a
      # remedy and the remedy is real -- {Lain::Session::ReadSet} is add-only
      # and monotone, so a later whole read upgrades this path.
      #
      # It is also what keeps a bound on the unwindowed read survivable: a
      # window covering the whole file records a COMPLETE read, so a file too
      # large to read in one go is still reachable and still editable.
      # {Tools::WriteFile} is not the escape hatch -- its overwrite contract
      # asks {Lain::Session#read?} too.
      requires("only a window of %<subject>s was read this session -- an offset/limit read showed you " \
               "part of the file, so editing it would clobber lines you never saw. Read it again with " \
               "no offset and no limit, or with a window covering the whole file, then edit",
               subject: SUBJECT) do |input, invocation|
        !session_of(invocation).partially_read?(target(invocation, input.path))
      end

      requires("%<subject>s was never read this session", subject: SUBJECT) do |input, invocation|
        session_of(invocation).read?(target(invocation, input.path))
      end

      def name = "edit_file"

      def description
        "Replaces old_string with new_string in the file at path. " \
          "old_string must occur exactly once in the file's current contents " \
          "-- zero or multiple occurrences is refused as an error result, " \
          "never a guess. The file must have been read IN FULL with read_file " \
          "earlier this session; editing a file that was never read is " \
          "refused, and so is editing one seen only through a window -- a " \
          "windowed read counts only when the window covered the whole file."
      end

      protected

      def perform(input, invocation)
        path = target(invocation, input.path)
        failing("edit", path) { replacing(input, invocation, path) }
      end

      private

      # A block-form replacement, not `sub(pattern, new_string)`: the two-arg
      # form interpolates `\1`-style back-references out of new_string even
      # though old_string is a literal, so a model-supplied new_string holding
      # a literal backslash-digit would be silently mangled. The block's return
      # value is used verbatim.
      def replacing(input, invocation, path)
        contents = File.read(path)
        occurrences = occurrences_of(input.old_string, contents)
        return Tool::Result.error(ambiguity_message(occurrences, path)) unless occurrences == 1

        File.write(path, contents.sub(input.old_string) { input.new_string })
        # The read-set entry is refreshed so a later edit_file call still sees
        # this path as read, and the write-set records it as this session's
        # snapshot scope ({Workspace::Snapshot}: write-set only, the documented
        # bash gap).
        session_of(invocation).record_read(path).record_write(path)
        Tool::Result.ok("replaced 1 occurrence of old_string in #{path}")
      end

      # `String#scan` counts NON-overlapping matches, which would call "aa" in
      # "aaa" unique and edit on a false premise; walking `index` forward by
      # one counts every window. `take_while` stops at the first nil, so the
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
