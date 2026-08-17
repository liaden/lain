# frozen_string_literal: true

module Lain
  module Oracle
    # The tier that consults the project's OWN summarizers before spending a
    # model call. It answers the same `#ask(inputs) -> Promise` / `#model` /
    # `#usage` trio {Model} and {Heuristic} do, so {Oracle::Eager} -- and
    # everything downstream of it -- cannot tell which tier produced a summary.
    #
    # It also owns the SIZE gate, because it is the object that knows which
    # tier pays for a result. The catalog is free, so every result is offered to
    # it; {MODEL_THRESHOLD_BYTES} guards only the fallthrough.
    #
    # A matched summarizer answers THROUGH the same {Definition} the model tier
    # validates against, so a custom answer is a schema-validated typed answer
    # with a `.summary` String, never raw user text: that is the boundary
    # {Compaction::SummarySnapshot} reads across, and it is what keeps a
    # summarizer from handing {Context::Compact} anything but a String.
    #
    # WHERE IT SITS. Outermost, wrapping {Recorded::Journaling}, which wraps
    # {Model}. Two consequences, both intended:
    #
    #   * a custom answer never reaches the journalling wrap, so it is never
    #     recorded as an oracle call some model was billed for;
    #   * a fallen-through answer is journalled exactly once, by the inner wrap,
    #     under the model tier's own model and usage.
    #
    # The order is also forced: {Recorded::Journaling} defines neither `#model`
    # nor `#usage`, so nesting the other way round would raise the moment it
    # journalled.
    class RoutedSummarizer
      # The tier symbol the custom answer's {Definition} is addressed under.
      #
      # `:heuristic`, NOT a new symbol: {Definition#digest} folds `tier:`, so a
      # novel symbol would be a novel oracle address. `:heuristic` is the
      # existing name for exactly this -- a deterministic, model-free answer to
      # this same question -- and reusing it keeps `:model` and `:heuristic`
      # addressing separately, which oracle/summarize_spec.rb pins. Nothing
      # journals under this address anyway (a custom answer is deliberately not
      # recorded), so no existing {Recorded} journal moves.
      TIER = :heuristic

      # The size a tool result must EXCEED to be worth a model call.
      #
      # It is a COST policy, which is why it lives here rather than at the
      # mount that fires: this is the object that knows which tier pays. The
      # catalog above it costs no tokens, no latency and no network, so it is
      # consulted for every result; only the fallthrough has to clear this. The
      # two were once gated together, one layer up, and that made a project's
      # own `.lain/summarizers.rb` dead for every ordinary tool result.
      #
      # == It gates a ROUTED source alone, and #ask can therefore answer nil
      #
      # A source carrying a tool name is what {Effect::Handler::Summarizing
      # ::Observer} fires unbidden, once per tool call, and it reaches
      # {Oracle::Eager}, whose `#held` ALREADY means "no summary" by nil. So a
      # decline there costs a caller nothing: it renders as the attested elision
      # line a miss always rendered.
      #
      # Bare text is not gated, because gating it would change what `#ask`
      # PROMISES a caller who is not the Eager. Such a caller does
      # `ask(...).await.summary`, and a nil answer is a `NoMethodError` there,
      # not a graceful miss.
      #
      # ⚠️ **THAT CALLER EXISTS**: {Compaction::Strategy::Summarizing#asked}
      # (`compaction/strategy/summarizing.rb:212`) does exactly that and rescues
      # {Lain::Error} only, so a declined ask would take out the derivation
      # rather than leave a span uncollapsed. It is inert TODAY only because
      # {CLI::Backend::SpanSummarizer} hands it a bare {Oracle::Model} rather
      # than this tier. **Rewiring that strategy onto this object requires
      # teaching `#asked` about a nil answer first.**
      MODEL_THRESHOLD_BYTES = 4096

      # @param inner [#ask] the model-backed tier a miss falls through to --
      #   {Recorded::Journaling} over {Model} in live use
      # @param catalog [#for] the project's declared summarizers
      #   ({Summarizer::Catalog}); an empty one simply never matches
      # @param definition [Oracle::Definition] validates a CUSTOM answer
      # @param slot [Symbol] which input slot carries the source
      # @param threshold_bytes [Integer] see {MODEL_THRESHOLD_BYTES}
      def initialize(inner:, catalog:, definition: Summarize.definition(tier: TIER), slot: Eager::DEFAULT_SLOT,
                     threshold_bytes: MODEL_THRESHOLD_BYTES)
        @inner = inner
        @catalog = catalog
        @definition = definition
        @slot = slot
        @threshold_bytes = threshold_bytes
      end

      # @param inputs [Hash] the question's slot values; the source slot holds a
      #   {Summarizer::Result} when the mount threaded a tool name, and bare
      #   text otherwise
      # @return [Lain::Promise] resolving to the validated typed answer, or to
      #   nil when nothing was suitable and the source is too small to be worth
      #   a model call (see {MODEL_THRESHOLD_BYTES})
      # @raise [InvalidAnswer] a custom summarizer answered with something the
      #   schema refuses -- blank text most of all, since a blank summary would
      #   REPLACE the result it compressed
      def ask(inputs = {})
        source = inputs.fetch(@slot)
        # Routing needs a tool name and only a {Summarizer::Result} carries one,
        # so bare text goes straight to the model tier, question untouched --
        # where it went before this tier existed, and where a caller reading
        # `.summary` off the answer still finds one (see
        # {MODEL_THRESHOLD_BYTES}). A mount that FORGOT the name fails loudly
        # where the name actually is: {Effect::Handler::Summarizing::Observer
        # #observe} requires it as an argument.
        #
        # `inputs` UNTOUCHED, deliberately: a source answering `#text` but not
        # `#tool_name` is not something this tier can route, so it reaches
        # {Definition#render}'s named {Prompt::NonStringSlot} rather than being
        # quietly unwrapped into a question nothing asked for. Latent -- only
        # {Summarizer::Result} answers either message today -- and the louder
        # of the two behaviours.
        return @inner.ask(inputs) unless routed?(source)

        custom(source) || fallthrough(inputs, source)
      end

      # Uniform with {Heuristic}, and unconditional. This object never calls a
      # provider: a custom answer costs nothing, and a fallen-through answer's
      # spend is journalled by the inner wrap against the tier that actually
      # paid it, so reporting it again here would double-count. Delegating
      # would ALSO raise, since {Recorded::Journaling} answers neither message.
      def model = nil
      def usage = {}

      private

      # nil means "no custom answer", and the fallthrough is the whole point:
      # nothing was suitable, or user code blew up -- a broken summarizer costs
      # its own tier, never the summary.
      def custom(source)
        answered = compacted(source)
        answered && @definition.answer(summary: string_from(*answered))
      end

      # The model tier, or nothing at all. A routed source under the threshold
      # is a result the free tier declined and the model tier is not worth
      # spending on, so this answers a resolved Promise holding nil rather than
      # asking: {Oracle::Eager} awaits whatever a tier answers, and an absent
      # summary is ALREADY what {Oracle::Eager#held} means by a miss. A decline
      # therefore reads downstream exactly like a fire still in flight -- an
      # elision line in the compacted render, attested, with nothing raised.
      #
      # `is_a?(String)` and not a bare `bytesize`: a source answering
      # `#tool_name` but not `#text` has no bytes to weigh, and gating on one
      # would kill it with a bare NoMethodError from in here. Passed ON instead,
      # it reaches {Definition#render}, whose {Prompt::NonStringSlot} names both
      # the slot and the problem. Latent -- only {Summarizer::Result} satisfies
      # the duck today -- but the loud refusal is the one that already existed.
      def fallthrough(inputs, source)
        text = text_of(source)
        return declined if text.is_a?(String) && text.bytesize <= @threshold_bytes

        @inner.ask(inputs.merge(@slot => text))
      end

      def declined = Promise.new.tap { |promise| promise.resolve(nil) }

      def routed?(source) = source.respond_to?(:tool_name)

      # The `[summarizer, value]` pair a summarizer ANSWERED with, or nil when
      # none did. The wrapper is what keeps "produced nothing" distinguishable
      # from "produced nil": a value a summarizer returned goes on to the
      # schema, which refuses blank loudly, while a summarizer that RAISED
      # falls through silently. {Summarizer::Catalog#for} raises whatever a
      # user `suitable?` raises and says so, so the scan is inside the rescue
      # too -- a raising first declaration would otherwise take out the turn.
      #
      # THREE families, and the two beside `StandardError` are both authoring
      # states of a half-written `.lain/summarizers.rb` -- the state the DSL is
      # in while it is being written, so the likeliest failure there is.
      # `ScriptError` because {Summarizer::Base} raises exactly
      # `NotImplementedError` for a method not written yet; `SystemStackError`
      # because a predicate that calls itself recurses without bound, and it
      # descends straight from `Exception` rather than from either of the other
      # two. Every tool result runs these predicates now, not just the ones over
      # {MODEL_THRESHOLD_BYTES}, so a list one entry short kills a turn on an
      # ordinary `bash` result.
      #
      # A predicate that does not TERMINATE is the one failure no rescue can
      # reach; see {Summarizer}'s docs for that uncontained mode.
      def compacted(source)
        summarizer = @catalog.for(source)
        [summarizer, summarizer.compact(source)] if summarizer
      rescue ScriptError, StandardError, SystemStackError
        nil
      end

      # OUTSIDE the rescue above, deliberately: a summarizer that returned the
      # wrong TYPE answered, and answered wrongly, which is loud -- unlike one
      # that blew up, which falls through.
      #
      # `field :summary, :string` COERCES rather than refuses, so a typo'd
      # `compact` returning an Object would slip through as
      # `"#<Object:0x00007f...>"` -- a DIFFERENT string every run, and that
      # string REPLACES the tool result in the rendered prompt. That is
      # nondeterministic prompt bytes, which breaks both invariants
      # {Canonical} exists to hold at once: a bench arm that cannot be
      # reproduced, and a cache prefix that never hits, with nothing raised.
      # The declaration is named because it is the user's own file at fault.
      def string_from(summarizer, value)
        return value if value.is_a?(String)

        raise InvalidAnswer, "summarizer #{summarizer.name.inspect} returned a #{value.class} from #compact; " \
                             "a summary must be a String -- it replaces the tool result in the prompt verbatim"
      end

      # {Definition#render} refuses a non-String slot ({Prompt::NonStringSlot}),
      # and the model tier's question must stay byte-identical to what it was
      # before this tier existed -- a journal replay keys on it.
      def text_of(source) = source.respond_to?(:text) ? source.text : source
    end
  end
end
