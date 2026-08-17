# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # What a `<CR>` on a `lain://review` row actually reaches (T32a): the
      # object that turns "open this file at this line" into the diff PAIR, by
      # reading the file's old side off the changeset the round was opened on and
      # posting `open_changeset` down the render inlet.
      #
      # It is {ReviewView}'s `changesets:` collaborator, and until it existed
      # that seam was {ReviewView::Unwired} in every real process -- so `<CR>`
      # refused, no diff buffer was ever created, and because `47_diff.lua`'s
      # `pair()` is what stamps `lain_review_side`/`_revision`/`_path` onto those
      # buffers, `:LainNote` had nowhere to place a note either. The whole chain
      # open -> diff buffers -> annotate -> settle was blocked at its first link,
      # by this object's absence rather than by anything the editor could not do.
      #
      # == Why this is not {Review::Surface::Neovim}
      #
      # That surface's class doc names the reason and it is a lifetime: `open` is
      # driven by a gesture arriving ARBITRARILY LATER than the `present` that
      # drew the row, so answering one means HOLDING a changeset, which is the
      # one state a surface built to translate-and-forget must not keep. This
      # object is defined by keeping exactly that and nothing else.
      #
      # {#reviewing} is how it arrives -- from whoever opened the round, through
      # {ReviewView#reviewing} -- rather than through the constructor, because
      # the editor and its views are built when the frontend attaches and a
      # review is opened long afterwards, often several times in one session.
      # The reference is read once into a local at the top of {#open}, so a round
      # replaced mid-gesture resolves the whole gesture against the changeset it
      # started with; this is {Neovim#bind_changeset_review}'s pattern and its
      # thread reasoning, one collaborator over.
      #
      # == Every refusal is a SENTENCE, and each one is its own
      #
      # {ReviewView#offer} reads a String as "nothing opened, here is why" and
      # anything else as "it opened", so nothing here may raise -- this runs on
      # the fiber serving the editor's commands, and an exception there is an
      # editor session ended over one keystroke.
      #
      # Four things can go wrong and they are four sentences, because the human
      # can do something different about each: nothing has been drawn yet, the
      # row names a file this changeset does not carry (a gesture against a
      # rendering the round has moved past), the file is binary, and the base
      # cannot produce an old side. The last is the one worth spelling out --
      # posting an empty old side instead would draw every line of the file as
      # ADDED, which renders perfectly and is a review of a changeset nobody
      # wrote.
      #
      # == Opening a row is what READS the file, and this is where that happens
      #
      # A survey is chunked lazily -- {Review::LazyFile} parses a file the first
      # time somebody asks it for hunks, and `#chunked?` is what every later
      # question about markability keys on. Nothing else on this path asks: every
      # file of a {Review::Source::Corpus} is `added`, so
      # {Review::Changeset#old_side} answers `[]` off `old_path` alone, and the
      # gesture that put the file on the human's screen used to leave it
      # reporting that nobody had read it. Its row then carried no hunk key, and
      # `x`, `:LainReviewMark` and every verdict refused a file the human was
      # looking at -- not because it has no hunk, but because nobody asked.
      #
      # So this object sends {Review::Changeset#read}. Not {ReviewView}, and the
      # distinction is load-bearing rather than tidy: B19 (`b45553e`) removed the
      # view's accidental forcing of every file at RENDER time, which is what
      # made drawing a fifty-file survey free, and `review_view_spec.rb` pins it
      # with an entry whose `#hunks` raises. The read belongs to the gesture that
      # opens ONE file, which is this one.
      #
      # == It cannot post an argument `47_diff.lua` refuses
      #
      # That module refuses, by name, an ABSOLUTE path (its old side's buffer
      # name embeds the path verbatim, so one would fall outside
      # `lain://review/OLD/`), a missing revision, and an `old_lines` entry
      # carrying a newline. None is
      # reachable from here, and not by checking for them: the path posted is the
      # one the CHANGESET carries (an argument that is not one of those finds no
      # file and never gets that far), the revisions are the source's own
      # resolved shas, and the lines come from {Review::Changeset#old_side},
      # which splits on newlines and so cannot produce one containing one.
      class ChangesetDiff
        # Before any round: a gesture cannot reach this in an editor that has
        # drawn a sidebar, since drawing one is what supplies the changeset --
        # but a null that answers a lie is worse than a nil check, so it says
        # what is true rather than blaming the row.
        NOTHING_DRAWN = "no changeset has been drawn into this editor, so there is no diff for a row to open"

        # The row named a file this changeset does not carry. Reachable for real:
        # a rendering the human is still looking at can outlive the round that
        # drew it, and the honest answer is that the row names nothing HERE.
        UNKNOWN_FILE = "%s is not a file in the changeset under review, so there is no diff to open for it"

        # A binary file's old side is bytes, not lines, and the new side is a
        # file nvim renders as binary. The sidebar row is still real and still
        # markable, which is what the second clause points at.
        BINARY = "%s is binary, so there is no line-by-line diff to open -- the sidebar row still marks"

        # The diff says this file has an old side and the object database cannot
        # produce it -- a garbage collection, a shallow clone, a fetch that did
        # not bring the base. Named with the revision, because that is the thing
        # somebody has to go and find.
        NO_OLD_SIDE = "the old side of %<path>s is not in this repository at %<base>s, so the diff would " \
                      "show every line of it as new"

        # @param rpc [#open_changeset] the editor's render inlet
        #   ({RenderInlet}), which answers a refusal sentence or nothing
        def initialize(rpc:)
          @rpc = rpc
          @changeset = nil
        end

        # The round this editor is now drawing. Sent by whoever opened it, on
        # every round, and REPLACING rather than accumulating: a second review in
        # one editor opens rows of the second changeset, and a gesture against
        # the first one's rendering is refused by name above.
        #
        # @param changeset [#file, #old_side, #read, #base_ref, #head_ref] the
        #   {Review::Changeset} the round was opened on -- never the session,
        #   which would put a mutable aggregate behind a keystroke
        # @return [void]
        def reviewing(changeset)
          @changeset = changeset
          nil
        end

        # @param path [String] the file the row names, as {ReviewView} read it
        #   off the changeset it drew: RELATIVE, and to the root the editor
        #   resolves against ({ROOT} in `47_diff.lua`, the directory nvim was
        #   started in). A diff source spells that repository-relative because
        #   git does; {Review::Source::Corpus} spells the same thing by naming
        #   its files from the project it was surveyed in, which is why a survey
        #   of a subdirectory does not open `greeter.rb` at the project root.
        #   The contract is the ROOT, not the vocabulary of any one source.
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

        # The read is registered by an open the inlet ACCEPTED, and nowhere
        # else. Its refusal -- a detached editor, a full queue -- means the pair
        # was never even enqueued, and a file credited as read that never
        # appeared is a row the human may mark without having seen anything.
        #
        # Accepted is not DRAWN, and the gap is real rather than pedantic:
        # {RenderInlet} queues and something drains later, so a detach between
        # the two leaves a read registered for a pair no editor ever showed. The
        # exposure is the rail's own and predates this line -- every gesture on
        # it reports success at acceptance -- and post-then-read is still the
        # right order, because the alternative is reading the file before
        # knowing whether anything will draw it.
        #
        def drawn(changeset, file, line)
          old_lines = changeset.old_side(file)
          return format(NO_OLD_SIDE, path: file.path, base: changeset.base_ref) if old_lines.nil?

          refusal = @rpc.open_changeset(file.path, old_lines, line, revisions(changeset))
          registered(changeset, file) if refusal.nil?
          refusal
        end

        # Registering the read reaches the DISK, which this path never did for a
        # survey: {Review::Source::Corpus::Reading#content} is a deliberately
        # un-memoized `File.binread`, so a file deleted or made unreadable
        # between the walk and the `<CR>` raises here -- measured, `Errno::ENOENT`
        # straight out of {#open}.
        #
        # That would end the editor session over one keystroke, which is the one
        # thing this class's own contract forbids ({ReviewView#offer} reads any
        # non-String as "it opened", and `CLI::HumanReplies::Gestures` rescues
        # only NoMethodError). So the failure is absorbed and the file stays
        # UNREAD -- the pair still draws, and its row goes on saying "open it
        # with <CR> first", which is the honest state for a file that is no
        # longer there.
        #
        # It cannot become a fifth refusal sentence: the pair is already
        # enqueued, so answering a String would report "nothing opened" while
        # the editor draws it. `SystemCallError` and not a blanket rescue --
        # every `Errno::*` is one, and a NoMethodError from a bad chunker is a
        # defect that must still be loud.
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
