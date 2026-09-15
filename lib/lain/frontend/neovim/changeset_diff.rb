# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # What a `<CR>` on a `lain://review` row actually reaches: the object that
      # turns "open this file at this line" into the diff PAIR, by reading the
      # file's old side off the changeset the round was opened on and posting
      # `open_changeset` down the render inlet.
      #
      # NOT {Review::Surface::Neovim}, and the reason is a LIFETIME: `open` is
      # driven by a gesture arriving ARBITRARILY LATER than the `present` that
      # drew the row, so answering one means HOLDING a changeset -- the one state
      # a surface built to translate-and-forget must not keep. This object is
      # defined by keeping exactly that and nothing else.
      #
      # {#reviewing} is how the changeset arrives, rather than the constructor,
      # because the editor and its views are built when the frontend attaches
      # and a review is opened long afterwards, often several times per session.
      # The reference is read once into a local at the top of {#open}, so a round
      # replaced mid-gesture resolves the whole gesture against the changeset it
      # started with.
      #
      # EVERY REFUSAL IS A SENTENCE. {ReviewView#offer} reads a String as
      # "nothing opened, here is why" and anything else as "it opened", so
      # nothing here may raise -- this runs on the fiber serving the editor's
      # commands, and an exception there ends an editor session over one
      # keystroke. Five things can go wrong and the human can do something
      # different about each. The last two are worth spelling out: posting an
      # empty side instead of refusing would draw every line of the file as ADDED
      # or DELETED, which renders perfectly and is a review of a changeset nobody
      # wrote.
      #
      # OPENING A ROW IS WHAT READS THE FILE. A survey is chunked lazily, and
      # `#chunked?` is what every later question about markability keys on;
      # every file of a {Review::Source::Corpus} is `added`, so
      # {Review::Changeset#old_side} answers `[]` off `old_path` alone and the
      # gesture that put the file on the human's screen used to leave it
      # reporting that nobody had read it -- `x`, `:LainReviewMark` and every
      # verdict then refused a file the human was looking at. So this object
      # sends {Review::Changeset#read}, and NOT {ReviewView}: forcing every file
      # at RENDER time is what made drawing a fifty-file survey expensive, and
      # `review_view_spec.rb` pins the laziness with an entry whose `#hunks`
      # raises. The read belongs to the gesture that opens ONE file.
      #
      # IT CANNOT POST AN ARGUMENT `47_diff.lua` REFUSES. That module refuses, by
      # name, an ABSOLUTE path (its old side's buffer name embeds the path
      # verbatim, so one would fall outside `lain://review/OLD/`), a missing
      # revision, and a line of either side carrying a newline. None is reachable
      # from here, and not by checking for them: the path posted is the one the
      # CHANGESET carries (anything else finds no file and never gets that far),
      # the revisions are the source's own resolved shas, and the lines come
      # from {Review::Changeset#old_side} and {Review::Changeset#new_side}, which
      # split on newlines and so cannot produce one containing one.
      class ChangesetDiff
        # Before any round. Unreachable in an editor that has drawn a sidebar,
        # since drawing one is what supplies the changeset -- but a null that
        # answers a lie is worse than a nil check.
        NOTHING_DRAWN = "no changeset has been drawn into this editor, so there is no diff for a row to open"

        # The row named a file this changeset does not carry. Reachable for real:
        # a rendering the human is still looking at can outlive the round that
        # drew it.
        UNKNOWN_FILE = "%s is not a file in the changeset under review, so there is no diff to open for it"

        # A binary file's old side is bytes, not lines. The sidebar row is still
        # real and still markable, which is what the second clause points at.
        BINARY = "%s is binary, so there is no line-by-line diff to open -- the sidebar row still marks"

        # The diff says this file has an old side and the object database cannot
        # produce it -- a gc, a shallow clone, a fetch that did not bring the
        # base. Named with the revision, the thing somebody has to go and find.
        NO_OLD_SIDE = "the old side of %<path>s is not in this repository at %<base>s, so the diff would " \
                      "show every line of it as new"

        # Its twin, reached only when the checkout does not hold the head and the
        # head's copy is what would have been drawn instead.
        NO_NEW_SIDE = "the new side of %<path>s is not in this repository at %<head>s, and the checkout " \
                      "is not that revision, so there is nothing true to show opposite the old side"

        # @param rpc [#open_changeset] the editor's render inlet
        #   ({RenderInlet}), which answers a refusal sentence or nothing
        def initialize(rpc:)
          @rpc = rpc
          @changeset = nil
        end

        # REPLACING rather than accumulating: a second review in one editor opens
        # rows of the second changeset, and a gesture against the first one's
        # rendering is refused by name above.
        #
        # @param changeset [#file, #old_side, #new_side, #checked_out?, #sides, #read, #base_ref, #head_ref]
        #   the {Review::Changeset} the round was opened on -- never the session,
        #   which would put a mutable aggregate behind a keystroke
        # @return [void]
        def reviewing(changeset)
          @changeset = changeset
          nil
        end

        # @param path [String] the file the row names: RELATIVE, to the root the
        #   editor resolves against ({ROOT} in `47_diff.lua`, the directory nvim
        #   was started in). A diff source spells that repository-relative
        #   because git does; {Review::Source::Corpus} names its files from the
        #   project it was surveyed in, which is why a survey of a subdirectory
        #   does not open `greeter.rb` at the project root. The contract is the
        #   ROOT, not the vocabulary of any one source.
        # @param line [Integer] the new-side line to land the cursor on
        # @return [String, nil] the reason nothing opened, or nothing
        def open(path, line)
          changeset = @changeset
          return NOTHING_DRAWN if changeset.nil?

          file = changeset.file(path)
          return format(UNKNOWN_FILE, path) if file.nil?
          return format(BINARY, path) if file.binary?

          drawn(changeset, file, line)
        end

        private

        # The read is registered by an open the inlet ACCEPTED, and nowhere else:
        # a refusal means the pair was never enqueued, and a file credited as
        # read that never appeared is a row the human may mark without having
        # seen anything.
        #
        # Accepted is not DRAWN -- {RenderInlet} queues and something drains
        # later, so a detach between the two leaves a read registered for a pair
        # no editor showed. That exposure is the rail's own; post-then-read is
        # still the right order, because the alternative is reading the file
        # before knowing whether anything will draw it.
        def drawn(changeset, file, line)
          old_lines = changeset.old_side(file)
          return format(NO_OLD_SIDE, path: file.path, base: changeset.base_ref) if old_lines.nil?

          pair = [file.path, old_lines, line, revisions(changeset)]
          return posted(changeset, file, pair) if on_disk?(changeset, file)

          new_lines = changeset.new_side(file)
          return format(NO_NEW_SIDE, path: file.path, head: changeset.head_ref) if new_lines.nil?

          posted(changeset, file, [*pair, new_lines])
        end

        def posted(changeset, file, arguments)
          refusal = @rpc.open_changeset(*arguments)
          registered(changeset, file) if refusal.nil?
          refusal
        end

        # The file on disk IS the new side when the round presents no old side
        # at all -- a survey is of the tree as it stands, and its source has no
        # revision to compare a checkout against -- or when the checkout holds
        # the head unmodified. Anywhere else the disk is bytes nobody is
        # reviewing, and a note anchored there names a line the head may not hold.
        def on_disk?(changeset, file) = changeset.sides != Lain::Review::SIDES || changeset.checked_out?(file)

        # Registering the read reaches the DISK:
        # {Review::Source::Corpus::Reading#content} is a deliberately un-memoized
        # `File.binread`, so a file deleted or made unreadable between the walk
        # and the `<CR>` raises here -- measured, `Errno::ENOENT` straight out of
        # {#open} -- and that would end the editor session over one keystroke.
        # So the failure is absorbed and the file stays UNREAD: the pair still
        # draws, and its row goes on saying "open it with <CR> first".
        #
        # It cannot become a fifth refusal sentence: the pair is already
        # enqueued, so answering a String would report "nothing opened" while the
        # editor draws it. `SystemCallError` and not a blanket rescue -- every
        # `Errno::*` is one, and a NoMethodError from a bad chunker must stay
        # loud.
        def registered(changeset, file)
          changeset.read(file)
        rescue SystemCallError
          nil
        end

        # A map rather than two positionals, because the pair is two commit-ish
        # Strings that look alike and mean opposite sides. String keys: the lua
        # half indexes `revisions["old"]` and `revisions["new"]`, and a Symbol
        # would arrive as a key nothing reads.
        def revisions(changeset) = { "old" => changeset.base_ref, "new" => changeset.head_ref }
      end
    end
  end
end
