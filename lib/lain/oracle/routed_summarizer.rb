# frozen_string_literal: true

module Lain
  module Oracle
    # The tier that consults the project's OWN summarizers before spending a
    # model call. It answers the same `#ask(inputs) -> Promise` / `#model` /
    # `#usage` trio {Model} and {Heuristic} do, so {Oracle::Eager} -- and
    # everything downstream of it -- cannot tell which tier produced a summary.
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

      # @param inner [#ask] the model-backed tier a miss falls through to --
      #   {Recorded::Journaling} over {Model} in live use
      # @param catalog [#for] the project's declared summarizers
      #   ({Summarizer::Catalog}); an empty one simply never matches
      # @param definition [Oracle::Definition] validates a CUSTOM answer
      # @param slot [Symbol] which input slot carries the source
      def initialize(inner:, catalog:, definition: Summarize.definition(tier: TIER), slot: Eager::DEFAULT_SLOT)
        @inner = inner
        @catalog = catalog
        @definition = definition
        @slot = slot
      end

      # @param inputs [Hash] the question's slot values; the source slot holds a
      #   {Summarizer::Result} when the mount threaded a tool name, and bare
      #   text otherwise
      # @return [Lain::Promise] resolving to the validated typed answer
      # @raise [InvalidAnswer] a custom summarizer answered with something the
      #   schema refuses -- blank text most of all, since a blank summary would
      #   REPLACE the result it compressed
      def ask(inputs = {})
        source = inputs.fetch(@slot)
        custom(source) || @inner.ask(inputs.merge(@slot => text_of(source)))
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
      # nothing was suitable, the source carried no tool name, or user code
      # blew up -- a broken summarizer costs its own tier, never the summary.
      def custom(source)
        # Routing needs a tool name and only a {Summarizer::Result} carries one,
        # so bare text goes straight to the model tier -- where it went before
        # this tier existed. A mount that FORGOT the name fails loudly where the
        # name actually is: {Effect::Handler::Summarizing::Observer#observe}
        # requires it as an argument.
        return nil unless source.respond_to?(:tool_name)

        answered = compacted(source)
        answered && @definition.answer(summary: string_from(*answered))
      end

      # The `[summarizer, value]` pair a summarizer ANSWERED with, or nil when
      # none did. The wrapper is what keeps "produced nothing" distinguishable
      # from "produced nil": a value a summarizer returned goes on to the
      # schema, which refuses blank loudly, while a summarizer that RAISED
      # falls through silently. {Summarizer::Catalog#for} raises whatever a
      # user `suitable?` raises and says so, so the scan is inside the rescue
      # too -- a raising first declaration would otherwise take out the turn.
      #
      # `ScriptError` is named beside `StandardError` because
      # {Summarizer::Base} raises exactly `NotImplementedError` -- a
      # ScriptError, NOT a StandardError -- for a declaration whose method is
      # not written yet. A half-written `.lain/summarizers.rb` is the state the
      # DSL is in while it is being authored, so it is the likeliest failure
      # there is, and a bare `rescue StandardError` lets it kill the turn.
      def compacted(source)
        summarizer = @catalog.for(source)
        [summarizer, summarizer.compact(source)] if summarizer
      rescue ScriptError, StandardError
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
