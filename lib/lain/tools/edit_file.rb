# frozen_string_literal: true

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

      # THREE contracts, not one, because {Lain::Session} answers three
      # different refusals and a single message could only name one of them.
      # Order is declaration order, and it matters: a masked read is ALSO a
      # partial one, and a partial read is ALSO not a complete one, so the
      # narrowest cause has to be tested first or every masked file would be
      # refused as though it had merely been windowed -- or worse, as though it
      # had never been read.
      #
      # That wrong message is not cosmetic. A model told "path was never read
      # this session" about a file it just read re-reads it, gets the same
      # masked projection, is refused identically, and loops -- with the one
      # move that would actually work (asking for the regions to be released)
      # never suggested. Naming the real cause is what breaks the loop.
      #
      # Named so the composed violation ("precondition failed for edit_file:
      # #{this}") reads as the fact the model needs rather than as a bare
      # contract label. `input.path` (the coerced Tool::Input, not a Hash) is
      # what {Tool#call} hands contracts: see tool.rb:117-119.
      # The message names NO remedy, because there is none within the session,
      # and every softer wording tried so far was false.
      #
      # "Ask for those regions to be released, then read it again" was advice
      # the model cannot act on. "A human must release those regions" reads as
      # a remedy and is false in both halves: a re-read never re-asks anybody
      # ({Middleware::RedactSecretReads} remembers the decline, so no second
      # prompt is ever raised), and even a human who releases every region out
      # of band leaves this refusal standing, because the masked set is add-only
      # by {Lain::Session::ReadSet}'s design.
      #
      # So it says the true thing: this is permanent for the session. A model
      # given any hint of a move takes it, and here every move is a loop.
      requires("path was read only in part this session -- sensitive regions were masked out of what " \
               "you saw, so editing it would clobber bytes you never read. Nothing in this session " \
               "will lift that, and re-reading will not: report it and do something else") do |input, invocation|
        !session_of(invocation).masked_read?(resolved_path(input, invocation))
      end

      # The other cause {Lain::Session#partially_read?} covers, and the mirror
      # image of the one above: here the missing bytes are missing because the
      # model asked for a window, so the refusal DOES name a remedy and the
      # remedy is real. {Lain::Session::ReadSet} is add-only and monotone, so a
      # later whole read upgrades this path and the same edit then lands.
      #
      # This is the case that used to answer "path was never read this session"
      # -- a message that sends the model back to read the file, get the same
      # window it asked for, and be refused identically. Naming the window is
      # what turns that loop into one more move.
      #
      # It is also what keeps a bound on the unwindowed read survivable: a
      # window covering the whole file records a COMPLETE read (see
      # {Tools::ReadFile::Window}), so a file too large to read in one go is
      # still reachable and still editable. {Tools::WriteFile} is not the
      # escape hatch -- its overwrite contract asks {Lain::Session#read?} too.
      requires("only a window of path was read this session -- an offset/limit read showed you part of " \
               "the file, so editing it would clobber lines you never saw. Read it again with no offset " \
               "and no limit, or with a window covering the whole file, then edit") do |input, invocation|
        !session_of(invocation).partially_read?(resolved_path(input, invocation))
      end

      requires("path was never read this session") do |input, invocation|
        session_of(invocation).read?(resolved_path(input, invocation))
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
        path = resolved_path(input, invocation)
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
        # entry is refreshed so a later edit_file call still sees it as read,
        # and the write-set records it as this session's snapshot scope
        # ({Workspace::Snapshot}: write-set only, the documented bash gap).
        session_of(invocation).record_read(path).record_write(path)
        Tool::Result.ok("replaced 1 occurrence of old_string in #{path}")
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not edit #{path}: #{e.message}")
      end

      private

      # A relative path resolves against the session's WorkerEnv cwd (Dir.pwd
      # under the default, so byte-identical to the pre-WorkerEnv raw path); the
      # RESOLVED absolute path is what the read-before-write contract, the read,
      # the write, and the read-set all agree on, whatever spelling the model
      # sent.
      def resolved_path(input, invocation)
        File.expand_path(input.path, session_of(invocation).worker_env.cwd)
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
