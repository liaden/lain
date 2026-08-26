# frozen_string_literal: true

module Lain
  module Review
    # The seam between the review model and whatever renders a changeset for a
    # human -- {Surface::Neovim}, {Surface::Text}, and {Surface::Null}, this
    # chunk's instance of {CLAUDE.md}'s Null Object rule, which is what lets
    # every review-model spec run without spawning an editor.
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
    # A surface holds NO review state of its own, and that is a promise of the
    # PORT rather than one adapter's discipline: the session is the aggregate,
    # which is what lets a surface be swapped or dropped mid-review with nothing
    # lost and no message depending on another having run first.
    # `spec/support/shared_examples/review_surface.rb` holds every adapter to
    # the same law; read its own doc for what it does and does NOT prove.
    #
    # Three arguments this port settled live in `docs/review.md` under "The
    # surface port": why `focus` is not part of `present`, why `verdict` and
    # `settle` are two messages, and what `present`'s `changeset` argument
    # answers (`#files`, `#partitions`, `#sides`, and why the session builds it).
    #
    # == Why `check!` is a duck probe, not a base class
    #
    # A surface is never required to subclass anything -- forcing one would make
    # {Surface::Text} (a plain renderer over a {Lain::Sink}) inherit machinery it
    # does not need just to prove it belongs. {check!} is instead a lightweight
    # collaborator check callers run where a surface is handed in, the same shape
    # {CLI::CompactionStrategy#live_tier} runs against its `tier:` collaborator.
    # {Effect::Handler} was checked and does NOT already own this convention:
    # `#handles?`/`#perform` is internal dispatch on a CLOSED effect algebra a
    # handler chooses to interpret, never a check that an externally supplied
    # collaborator answers a full duck.
    #
    # {check!} was widened past a bare `respond_to?` reject after a review-panel
    # probe showed the original blessed a candidate with every message present
    # but the WRONG ARITY. {MESSAGES} is now the single place the port's shape is
    # stated; the shared examples used to keep a second copy, never reconciled.
    module Surface
      # A candidate surface does not fully, publicly, and correctly answer
      # the port.
      class Incomplete < Error; end

      # The port's messages and each one's exact `Method#parameters` shape, in
      # the order the class doc lists them. `check!` and
      # `spec/support/shared_examples/review_surface.rb` both read this Hash
      # rather than keeping a second copy.
      #
      # Compared through {shape_of}, never `==` against this Hash directly: what
      # the port constrains is each argument's KIND and, for a keyword, its NAME
      # -- a keyword IS its name at every call site, while a positional's is
      # private to the method. Pinning positional names refused
      # `def thread(_anchor)` as the wrong shape, which is a rename, not a
      # defect. The names stay because this Hash is also the port's
      # documentation; only the comparison relaxes.
      #
      # DEEPLY frozen: `.freeze` on the outer Hash alone leaves the
      # `%i[req changeset]`-shaped inner Arrays mutable, and
      # `MESSAGES[:present] << :whatever` would mutate the one shape `check!`
      # and the shared example group both trust.
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
      # show a human, decided once at the port rather than per adapter: two
      # independent copies is exactly what let the two adapters' preview lengths
      # silently disagree under a mutation probe. A hunk key is a 64-hex content
      # digest behind a scheme prefix (`review/hunk.rb`), and no path reaches
      # either `#mark` to show a file name instead -- `Session#mark` forwards
      # only the key and the state.
      #
      # 12 hex digits follows the house convention for a shortened digest in a
      # human-readable message (`cli/command/pin.rb`, `Event#to_s`) minus their
      # fixed-width `"blake3:"` prefix, which ours has no equivalent of. The
      # trailing `...` is what tells a reader they are looking at a prefix; an
      # earlier draft showed 8 digits with no ellipsis and gave neither signal.
      #
      # 12 digits is 48 bits. At 10,000 hunks -- two orders of magnitude past
      # `Bounds::DEFAULT_MAX_FILES` -- a birthday collision on an 8-digit
      # (32-bit) prefix runs about 1.2%; on 12 it is about 2e-7. The longest
      # rendered message is 49 characters, under the 60-character bar.
      #
      # SPLIT on the scheme boundary, never a flat slice off the front of the
      # whole key: a flat cut gives the CONSTANT scheme prefix priority over the
      # digest, so a longer scheme name would silently shrink the entropy budget
      # with nothing failing.
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
      # breaking it is unrecoverable. {check!} refuses a candidate that lies
      # about its SHAPE, before construction; this absorbs one that lies about
      # DECLINING IN WORDS.
      #
      # {Session#submit} is the caller. The acknowledgement runs after the
      # judgement is DURABLE, `#submit` is the round's terminal act, and a second
      # attempt is refused as `AlreadySettled` -- so an exception escaping here
      # reaches {Handover#wrote_verdict}'s rescue and comes back as the sentence
      # a human reads as "your verdict did not land", over a verdict that did,
      # with no way to say it again. Both shipped adapters try to keep the
      # promise and neither can be relied on to: `Surface::Text`'s sink answers
      # `IOError`, and `Frontend::Neovim::RenderInlet#refusable` converts only
      # `ClosedQueueError` and `ThreadError`.
      #
      # WIDE deliberately, with the cost named rather than hidden: an adapter BUG
      # (a `NoMethodError`) is absorbed too, and {check!} does not catch that --
      # a correctly-shaped adapter broken INSIDE `settle` passes it cleanly, and
      # a real {Surface::Neovim} holding a nil `rpc` is exactly that. So the
      # residual is a regression that cannot announce itself: the human makes the
      # terminal gesture, the verdict lands, and nothing is printed -- the precise
      # defect the acknowledgement was added to remove. Accepted anyway, because
      # the alternative is the strictly worse failure above, and recorded so that
      # "the acknowledgement is silent" is diagnosed as a broken adapter rather
      # than a missing feature. Not narrowable either: an adapter's I/O error
      # classes cannot be enumerated from here. `StandardError` and not
      # `Exception` -- `SystemExit` and `Interrupt` must still propagate, which
      # `spec/lain/review/surface/null_spec.rb` pins.
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
      # KIND, and a keyword's NAME. A positional's name is dropped -- it never
      # appears at a call site (see {MESSAGES}). `**` and `&` are not in this
      # port at all, so a candidate carrying one lands in `wrong_shape` on kind
      # alone. Takes a `Method`/`UnboundMethod` or a {MESSAGES} value, so both
      # sides of a comparison are normalized by the same code.
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
      # `Class.new do ... end` double), and `candidate.class` alone prints a
      # bare memory address that names nothing a reader can act on.
      def self.candidate_name(candidate)
        candidate.class.name || "an anonymous class"
      end
      private_class_method :candidate_name
    end
  end
end

# The port's own value, ahead of every adapter: it belongs to none of them.
require_relative "surface/message"
require_relative "surface/null"
require_relative "surface/text"
# LAST, and the one entry here with a load-order reason: this adapter names
# `Frontend::Neovim::ReviewView` as its default collaborator, which resolves
# only because `lain.rb` loads `lain/frontend` before `lain/review`.
require_relative "surface/neovim"
