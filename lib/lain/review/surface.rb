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
    # Eight messages, each a plain method a duck-typed surface answers:
    #
    #   present(changeset, scope:)    render this changeset, at this scope
    #   focus                         put the human in front of what was drawn
    #   annotate(anchor, text, kind:) place a note at a position
    #   mark(hunk_key, state)         set a hunk's reviewed state
    #   thread(anchor)                open/return the conversation at a position
    #   verdict                       ask the human for their decision
    #   settle(verdict)               say the review has landed on this verdict
    #   refuse(message)               decline the review, naming why
    #
    # == Why `focus` is not part of `present`
    #
    # They differ in how often they are allowed to happen, which is the whole
    # of it. `present` runs on EVERY redraw -- a mark redraws a row, a scope
    # toggle redraws the sidebar, {Handover::Redraw} calls it after a gesture --
    # and a redraw that moved the human would yank them out of the chat pane
    # mid-sentence every time they marked a hunk. `focus` happens ONCE, when a
    # round is opened, because that is the moment lain handed them something and
    # asked them to work on it.
    #
    # The editor half already draws exactly this line and names it in those
    # terms: `41_layout.lua` has `review_place` ("MOVES NOBODY, ever") and
    # `review_layout` ("The ONLY entry point that takes focus"), with the second
    # one reachable from Lua and called by nothing in Ruby -- so a `/survey`
    # built the review tabpage, drew into it, and left the human in the session
    # tab to go and find it. The port was where the distinction had nowhere to
    # live.
    #
    # == Why `verdict` and `settle` are two messages and not one
    #
    # They travel in opposite directions and neither can be inferred from the
    # other. `verdict` ASKS -- it goes out when there is no judgement yet, and
    # it is a QUERY, which is the whole reason the port has nowhere to put its
    # refusal. `settle` SAYS ONE LANDED -- it goes out after {Session#submit}
    # has journaled a judgement the policy admitted, and it carries the word
    # inward, so a String coming back is unambiguously a refusal and it joins
    # the command law rather than `verdict`'s exemption
    # (`spec/support/shared_examples/review_surface.rb`, law #5).
    #
    # It exists because the review's ONE TERMINAL gesture was the only one that
    # acknowledged nothing: `:LainReviewVerdict approve` journaled correctly and
    # printed nowhere, while `mark` and `refuse` both said so in words. A human
    # who makes the gesture that ends the review and is answered with silence
    # reads it as broken -- which is exactly how the previous, genuinely broken
    # version of that command read.
    #
    # It is a PUSH and not a return value, and that is forced rather than
    # chosen: {Review::Handover#wrote_verdict} answers `nil` for "taken",
    # because its return value is what the editor's `:w` succeeds or fails
    # with. There is no room in that answer for a sentence, so the sentence has
    # to leave by the surface.
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
        focus: [],
        annotate: [%i[req anchor], %i[req text], %i[keyreq kind]],
        mark: [%i[req hunk_key], %i[req state]],
        thread: [%i[req anchor]],
        verdict: [],
        settle: [%i[req verdict]],
        refuse: [%i[req message]]
      }.transform_values { |shape| shape.map(&:freeze).freeze }.freeze

      # How much of a `Hunk` key {Surface::Neovim#mark} and {Surface::Text#mark}
      # show a human, and the one place that decision is made -- see F5's
      # grounding in `planning/qa-findings-research-2026-08.md`. A hunk key is
      # a 64-hex-character content digest behind a SCHEME prefix
      # (`Hunk::CONTENT_SCHEME`/`Hunk::SPAN_SCHEME`, `review/hunk.rb`), and no
      # path reaches either adapter's `#mark` to show a file name instead --
      # `Session#mark` (`review/session.rb`) forwards only the key and the
      # state.
      #
      # {preview} lives HERE, at the port, rather than once per adapter,
      # because "how much of a key a human is shown" is a property of the
      # SEAM both adapters implement -- the same argument {MESSAGES} makes
      # for the port's shape -- and because two independent copies is
      # exactly what let them silently disagree once: a review-panel
      # mutation probe on an earlier draft of this card set the two
      # adapters' preview lengths apart and nothing failed.
      #
      # {DIGEST_PREVIEW_LENGTH} follows the house convention for a
      # shortened content digest in a human-readable message --
      # `cli/command/pin.rb`: `"pinned #{digest[0, 19]}..."`, and
      # `Event#to_s`'s `"#{digest[0, 19]}..."`, both 12 hex digits behind a
      # 7-character `"blake3:"` prefix. Ours has no fixed-width prefix (the
      # scheme name varies, see the SPLIT paragraph below), so the number
      # that carries over is the 12 hex digits, not the 19. The trailing
      # `...` carries over unchanged: it is what tells a reader they are
      # looking at a prefix and not the whole thing -- an earlier draft of
      # this constant showed 8 digits with no ellipsis, which gave neither
      # signal. (`Isolation::Worktree::Handback#fingerprint` and
      # `Review::Delta::...#fingerprint` also cut to 12 hex digits, but for
      # a git REFNAME, not a human message, so they drop the ellipsis --
      # a different consumer, not a second convention to reconcile with.)
      #
      # 12 digits is 48 bits. `Bounds::DEFAULT_MAX_FILES` (300) and
      # `DEFAULT_MAX_LINES` (30,000) cap what a survey admits at all, and
      # even at 10,000 hunks -- a couple of orders of magnitude past
      # `DEFAULT_MAX_FILES`, and the size a review-panel probe actually
      # measured against -- a birthday collision on an 8-digit (32-bit)
      # prefix runs about 1.2%; on 12 digits it is about 2e-7. The four
      # extra digits cost four characters, and the longest rendered message
      # (`hunk-content-v1:` plus 12 hex digits plus `...` plus
      # ` is now unreviewed`) is still 49, under AC1's 60-character bar.
      #
      # SPLIT on the scheme boundary, never a flat slice off the front of
      # the whole key: a flat cut hands the CONSTANT scheme prefix
      # priority over the digest, so a longer scheme name (`hunk-span-v1:`,
      # or some future `hunk-content-v2:`) would silently shrink the
      # entropy budget with nothing failing. Splitting means every scheme
      # keeps exactly {DIGEST_PREVIEW_LENGTH} hex digits of digest,
      # whatever its own name's length.
      DIGEST_PREVIEW_LENGTH = 12

      # @param hunk_key [String] `Review::Hunk`'s content or span key
      # @return [String] `hunk_key` unchanged if its digest is already no
      #   longer than {DIGEST_PREVIEW_LENGTH} (every fixture key in this
      #   suite is), or `<scheme>:<DIGEST_PREVIEW_LENGTH hex digits>...`
      def self.preview(hunk_key)
        scheme, digest = hunk_key.split(":", 2)
        return hunk_key if digest.nil? || digest.length <= DIGEST_PREVIEW_LENGTH

        "#{scheme}:#{digest[0, DIGEST_PREVIEW_LENGTH]}..."
      end

      # The port's ANSWER convention, enforced at the one call where an adapter
      # breaking it is unrecoverable -- {check!}'s sibling, and here for
      # {check!}'s reason. That one refuses a candidate that lies about its
      # SHAPE, before construction; this one absorbs a candidate that lies
      # about DECLINING IN WORDS, at the single message where the lie costs
      # more than the message is worth.
      #
      # {Session#submit} is that message's caller. The acknowledgement runs
      # after the judgement is DURABLE, `#submit` is the round's terminal act,
      # and a second attempt is refused as `AlreadySettled` -- so an exception
      # escaping it reaches {Handover#wrote_verdict}'s rescue and comes back as
      # the sentence a human reads as "your verdict did not land", over a
      # verdict that did, with the baton never settled and no way to say it
      # again. That is a worse lie than the silence the acknowledgement was
      # added to remove, so this is the one place the port stops trusting an
      # adapter's promise and enforces it instead.
      #
      # Both shipped adapters try to keep the promise; neither can be relied on
      # to. `Surface::Text`'s sink answers `IOError`, and
      # `Frontend::Neovim::RenderInlet#refusable` converts only
      # `ClosedQueueError` and `ThreadError`, so anything else off the RPC path
      # escapes too.
      #
      # WIDE deliberately, and the cost is named rather than hidden: an adapter
      # BUG (a `NoMethodError`) is absorbed here as well. {check!} catches only
      # part of that, and the part it catches is SHAPE -- a correctly-shaped
      # adapter broken INSIDE `settle` passes it cleanly. A real
      # {Surface::Neovim} holding a nil `rpc` is exactly that adapter: it
      # answers all seven messages at the right arities, `check!` blesses it,
      # and this method then returns `nil` in silence.
      #
      # SO THE RESIDUAL IS AN F4 REGRESSION THAT CANNOT ANNOUNCE ITSELF: the
      # human makes the terminal gesture, the verdict lands, and nothing is
      # printed -- the precise defect the acknowledgement was added to remove.
      # It is accepted anyway, because the alternative is the strictly worse
      # failure this method exists to prevent (a durable verdict reported as
      # refused, with no way to say it again). Recorded so that "the
      # acknowledgement is silent" is diagnosed as a broken adapter rather than
      # as a missing feature.
      #
      # Not narrowable, either: an adapter's I/O error classes cannot be
      # enumerated from here, so a hand-written list would reopen the hole this
      # closes. `StandardError` and not `Exception` -- `SystemExit` and
      # `Interrupt` must still propagate, which `spec/lain/review/surface/
      # null_spec.rb`'s `.acknowledge` group pins.
      #
      # What does bound the residual is the layer above: a structurally broken
      # adapter is refused earlier and far louder, by {check!} at wiring time
      # and by `spec/support/shared_examples/review_surface.rb`.
      #
      # @param surface [#settle] the adapter this round draws on
      # @param verdict [String] the verdict, as journaled
      # @return [Object, nil] whatever the surface answered, or nothing when it
      #   broke its promise -- indistinguishable on purpose, because the caller
      #   discards both: it is a fact about the editor, not about the round
      def self.acknowledge(surface, verdict)
        surface.settle(verdict)
      rescue StandardError
        nil
      end

      # @param candidate [#present, #annotate, #mark, #thread, #verdict, #settle, #refuse]
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
