# frozen_string_literal: true

module Lain
  module Review
    # The seam between the review model and whatever renders a changeset for a
    # human. A plain buffer today ({Surface::Neovim}, T19), a table of text
    # ({Surface::Text}, T9), tomorrow something else -- the port is what lets
    # the UI be rebuilt without touching the model. {CLAUDE.md}'s Null Object
    # rule names {Sink::Null} as the exemplar; {Surface::Null} is this chunk's
    # instance of it, so every review-model spec below the surface runs
    # without spawning an editor.
    #
    # A surface holds NO review state of its own. {Surface::Neovim}'s own card
    # is where that is enforced, but it is a promise of the PORT, not one
    # adapter's private discipline: the session (T13), not the surface, is the
    # aggregate, which is what lets a surface be swapped or dropped mid-review
    # with nothing lost and no message depending on another having run first.
    # `spec/support/shared_examples/review_surface.rb` is where the SHAPE of
    # each message and that ordering promise are checked once so every
    # adapter is held to the same law -- see that file's own doc for exactly
    # what it does and does NOT prove; a review-panel pass on this card found
    # its first cut proved less than its doc claimed, and both were fixed
    # together.
    #
    # Six messages, each a plain method a duck-typed surface answers:
    #
    #   present(changeset, scope:)    render this changeset, at this scope
    #   annotate(anchor, text, kind:) place a note at a position
    #   mark(hunk_key, state)         set a hunk's reviewed state
    #   thread(anchor)                open/return the conversation at a position
    #   verdict                       ask the human for their decision
    #   refuse(message)               decline the review, naming why
    #
    # == What `present`'s `changeset` argument answers
    #
    # `Lain::Review::Changeset` (T7) and `Lain::Review::Marks` (T8) had not
    # landed when {Surface::Text} was written, so the duck `present` actually
    # needs is stated ONCE here rather than in each adapter's own doc -- the
    # drift {MESSAGES} exists to prevent for a message's SHAPE applies just as
    # much to what one argument of one message answers, and a second adapter
    # inventing its own reading (T19) is exactly that drift.
    #
    # `changeset.files` answers an Enumerable of file entries (`#path`,
    # `#state` -- one of `Review::FILE_STATES`) for the FLAT scope,
    # `:cumulative`. `changeset.partitions` answers an Enumerable of group
    # entries (`#label`, `#files` -- same file-entry shape) for every GROUPED
    # scope, whichever {Review::Partition::Strategy} produced them.
    #
    # A surface that draws more than a path and a glyph needs more than that,
    # and {Frontend::Neovim::ReviewView} is where the additional members and
    # their reasons are stated -- including the two a LAZY source makes
    # necessary (`#chunked?` on a file, `#counted?` on a group), which are how a
    # surface tells "there is nothing here" from "nobody has looked yet"
    # WITHOUT reading the corpus it is drawing.
    #
    # It reads `#partitions` and not `#by_commit`, and the rename is the
    # contract rather than a spelling: grouping-by-commit is one strategy on
    # that axis, so a surface that named it would be a surface that could only
    # ever render one. A group answers `#label` -- what heads it -- because a
    # directory has no subject and a commit's sha is not what a heading shows.
    # `#partitions` takes no argument HERE: whoever built the view chose the
    # strategy, and a renderer re-partitioning what it was handed could draw
    # rows the session never marked.
    #
    # Neither `Changeset` nor `Marks` alone answers this: a changeset (T7) is
    # files/hunks/anchorable lines with no notion of review state, and marks
    # (T8) derives that state from hunks with no notion of files-as-such. The
    # object that answers `#files`/`#partitions` above has to be built by
    # JOINING the two -- T13's session is the one place both are held
    # together, so it is T13's job to produce it (from a real `Changeset`'s
    # structure and `Marks`' derived tri-state per file), not either T7 or T8
    # alone, and not a surface reaching for both on its own.
    #
    # == Why `check!` is a duck probe, not a base class
    #
    # A surface is never required to subclass anything -- forcing one would
    # make {Surface::Text} (a plain renderer over a {Lain::Sink}) inherit
    # machinery it does not need just to prove it belongs. {check!} is instead
    # a lightweight collaborator check callers can run at the point a surface
    # is handed in, the same shape {CLI::CompactionStrategy#live_tier} already
    # runs against its `tier:` collaborator: reject what does not answer,
    # raise naming what's missing. This card's escalation trigger asks
    # specifically whether {Effect::Handler} already owns this convention --
    # it does not: `Handler#handles?`/`#perform` is internal dispatch on a
    # CLOSED effect algebra a handler chooses to interpret, never a check
    # that an externally supplied collaborator answers a full duck.
    # {CLI::CompactionStrategy} is the one real precedent, so this reuses its
    # shape rather than adding a second, competing one.
    #
    # {check!} was widened past a bare `respond_to?` reject after a
    # review-panel probe (`probe_check.rb`) showed the original version
    # blessed a candidate with every message present but the WRONG ARITY --
    # exactly the shape {CLI::CompactionStrategy#live_tier} exists to refuse
    # BEFORE construction rather than let die inside the first real call.
    # {MESSAGES} is now the single place the port's shape is stated; the
    # spec above used to keep its own second copy, checked but never
    # reconciled against this one.
    module Surface
      # A candidate surface does not fully, publicly, and correctly answer
      # the port.
      class Incomplete < Error; end

      # The port's messages, and each one's exact `Method#parameters` shape,
      # in the order the class doc above lists them. `check!` and
      # `spec/support/shared_examples/review_surface.rb` both read this Hash
      # rather than keeping their own copy of the shape.
      #
      # Compared through {shape_of}, never `==` against this Hash directly:
      # what the port actually constrains is each argument's KIND and, for a
      # keyword, its NAME -- a keyword IS its name at every call site, while a
      # positional's is private to the method. Pinning positional names refused
      # `def thread(_anchor)` as "the wrong shape", which is a rename, not a
      # defect; a T19 review panel hit it writing a probe. The names below stay
      # because this Hash is also the port's documentation -- they say what each
      # argument MEANS -- and only the comparison relaxes.
      #
      # DEEPLY frozen (CLAUDE.md's rule for every value object here): `.freeze`
      # on the outer Hash alone leaves the `%i[req changeset]`-shaped inner
      # Arrays mutable, and `MESSAGES[:present] << :whatever` would then mutate
      # the one shape `check!` and the shared example group both trust.
      MESSAGES = {
        present: [%i[req changeset], %i[keyreq scope]],
        annotate: [%i[req anchor], %i[req text], %i[keyreq kind]],
        mark: [%i[req hunk_key], %i[req state]],
        thread: [%i[req anchor]],
        verdict: [],
        refuse: [%i[req message]]
      }.transform_values { |shape| shape.map(&:freeze).freeze }.freeze

      # @param candidate [#present, #annotate, #mark, #thread, #verdict, #refuse]
      # @return [void]
      # @raise [Incomplete] naming what is wrong -- a message not answered at
      #   all, one answered only PRIVATELY (present, but not callable the way
      #   the port needs), or one answered PUBLICLY with the wrong shape.
      #   Kept apart rather than folded into one "does not answer" verdict:
      #   a defined-but-private or defined-but-wrong-arity method both used
      #   to read as "you forgot to write this" when the candidate had not.
      def self.check!(candidate)
        absent, private_only, wrong_shape = sort_candidate(candidate)
        return if absent.empty? && private_only.empty? && wrong_shape.empty?

        raise Incomplete, incomplete_message(candidate, absent:, private_only:, wrong_shape:)
      end

      # What the port constrains about one message's arguments: every one's
      # KIND, and a keyword's NAME. A positional's name is dropped, because it
      # is the method's own business and never appears at a call site -- see
      # {MESSAGES}. `**` and `&` are not in this port at all, so a candidate
      # carrying one lands in `wrong_shape` on kind alone.
      #
      # Takes a `Method`/`UnboundMethod` or a {MESSAGES} value, so the two
      # sides of every comparison are normalized by the same code rather than
      # by two readings of one rule.
      # @return [Array<Array<Symbol>>]
      def self.shape_of(parameters)
        parameters = parameters.parameters if parameters.respond_to?(:parameters)
        parameters.map { |kind, name| kind == :keyreq ? [kind, name] : [kind] }
      end

      # @return [Array(Array<Symbol>, Array<Symbol>, Array<Symbol>)] messages
      #   `candidate` does not answer at all, answers only PRIVATELY
      #   (`respond_to?(message, true)` but not the public form), and
      #   answers PUBLICLY but with a shape ({shape_of}) that does not match
      #   {MESSAGES}.
      def self.sort_candidate(candidate)
        MESSAGES.each_with_object([[], [], []]) do |(message, shape), (absent, private_only, wrong_shape)|
          if candidate.respond_to?(message)
            wrong_shape << message unless shape_of(candidate.method(message)) == shape_of(shape)
          elsif candidate.respond_to?(message, true)
            private_only << message
          else
            absent << message
          end
        end
      end
      private_class_method :sort_candidate

      def self.incomplete_message(candidate, absent:, private_only:, wrong_shape:)
        clauses = [
          [absent, "does not answer %s"],
          [private_only, "answers %s only privately, never publicly"],
          [wrong_shape, "answers %s with the wrong shape"]
        ].filter_map { |names, template| format(template, names.join(", ")) unless names.empty? }

        "#{candidate_name(candidate)} #{clauses.join("; ")}; a review surface must publicly answer " \
          "the full #{MESSAGES.keys.join(", ")} port, each with its documented shape"
      end
      private_class_method :incomplete_message

      # `candidate.class.name` is `nil` for an anonymous class (every
      # `Class.new do ... end` test double), and `candidate.class` alone
      # prints a bare memory address (`#<Class:0x...>`) that names nothing a
      # reader can act on -- both read as noise, not as "here is what was
      # handed in".
      def self.candidate_name(candidate)
        candidate.class.name || "an anonymous class"
      end
      private_class_method :candidate_name
    end
  end
end

# The port's own value, ahead of every adapter: it belongs to none of them,
# and it is what a rendered conversation is made of on both sides of the seam.
require_relative "surface/message"
require_relative "surface/null"
require_relative "surface/text"
# LAST, and it is the one entry here with a load-order reason: this adapter
# names `Frontend::Neovim::ReviewView` as its default collaborator, which
# resolves only because `lain.rb` loads `lain/frontend` before `lain/review`.
require_relative "surface/neovim"
