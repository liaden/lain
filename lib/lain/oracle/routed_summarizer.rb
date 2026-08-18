# frozen_string_literal: true

module Lain
  module Oracle
    # The tier that consults the project's OWN summarizers before spending a
    # model call. It answers the same `#ask(inputs) -> Promise` / `#model` /
    # `#usage` trio {Model} and {Heuristic} do, so {Oracle::Eager} -- and
    # everything downstream of it -- cannot tell which tier produced a summary.
    #
    # It also owns the SIZE gates -- both of them -- because it is the object
    # that knows which tier pays for a result. They are two questions, not one:
    # {MODEL_THRESHOLD_BYTES} asks whether a result is big enough to be worth a
    # model call and {INPUT_BOUND} whether it is small enough for a model to
    # serve, so together they make the model tier's window `(threshold,
    # ceiling]`. BOTH sit on the fallthrough and neither touches the catalog:
    # the free tier costs no tokens, so every result is offered to it at every
    # size.
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
      # {INPUT_BOUND} is its companion at the other end of the same window, and
      # sits on the same fallthrough for the same reason -- see its docstring
      # for why a ceiling in FRONT of the catalog was tried and reverted.
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

      # The size past which a model could not serve an input anyway, so the
      # PAID tier is not asked for it.
      #
      # == Where it sits, which one review round got wrong
      #
      # On the fallthrough, beside {MODEL_THRESHOLD_BYTES} -- NOT in front of
      # `custom(source)`. A first draft gated the catalog too, on the reasoning
      # that running every declared `suitable?` over 5 MiB is real CPU on the
      # turn's own path. Measured, that predicate costs **1.87ms** at 5 MiB
      # (1.53ms for a regex miss), against an ordinary `split("\n")` at 40ms --
      # and the hazard {Summarizer} actually documents is a predicate that
      # SPINS, 0.637s on a 17-byte result, which no size gate reaches and which
      # wants a deadline instead.
      #
      # The cost of gating early was much larger than that. An over-ceiling
      # result is one the model tier could never have served, so a project's
      # own declaration is the ONLY tier left that can answer it -- and a
      # ceiling in front of the catalog turns off exactly that one. That is the
      # regression `effect/handler/summarizing.rb:33-44` exists to prevent,
      # arriving at a different size. {CLI::Backend#summary_oracle} passes
      # neither keyword and there is no flag for either, so an affected project
      # would have had no lever at all. **A cost gate belongs on the tier that
      # costs money.**
      #
      # == It is the OPPOSITE question to the one above, and must stay a second knob
      #
      # {MODEL_THRESHOLD_BYTES} asks "is this big enough to be worth a model
      # call" and admits everything above it. This asks "is this still an
      # answer" and refuses everything above it. Folding them into one number
      # would silently change which results reach the free tier, which is the
      # regression `effect/handler/summarizing.rb:33-44` records the cost of --
      # so they are deliberately different KINDS of value (an Integer threshold
      # and a {Tool::Bounds::Artifact}) under separate keywords, and an
      # implementation that can express only one of them is wrong rather than
      # tidy.
      #
      # == Why 256 KiB
      #
      # The number comes from {Tools::WebFetch::DEFAULT_BYTE_CAP}, which is
      # 5 MiB and says so as a TRANSPORT cap -- "small enough to bound a runaway
      # or hostile response" -- three orders of magnitude above a sane
      # summarizer input. This is a twentieth of it: real article bodies run to
      # tens of KB, so 256 KiB admits every legitimate fetch and declines the
      # blob. There is a spec on that ratio, because an argument that lives only
      # in a docstring is one a mutant can move in silence. `subagent`,
      # `request_review`, `ask_human` and `run_skill` are mounted outside the
      # bounded base floor and have no cap of their own at all, so for them this
      # is the only one.
      #
      # A SANITY CHECK, not the derivation, at the other end: the live tier
      # defaults to a local model ({CLI::Backend::DEFAULT_SUMMARIZER_PROVIDER}
      # is ollama, today `qwen3:4b`), whose trained maximum is 32,768 tokens.
      # Taking the 3-4 bytes per token that `review/bounds.rb:92` uses -- and
      # labels an ESTIMATE, as this must too -- 256 KiB lands somewhere around
      # 65-87k tokens, comfortably past that maximum. So the ceiling is not
      # cutting into anything the default tier could have served; it merely
      # confirms the `web_fetch` figure is not accidentally generous.
      #
      # It is deliberately NOT derived from a model's window. The tier is
      # repointable at a frontier model with 200k tokens, and a ceiling set to
      # the smallest possible tier would decline inputs a legitimately
      # configured one reads fine. "Can this model read it" stays with
      # `--num-ctx` and the window book, which already own it.
      #
      # == Only {Tool::Bounds::Artifact#admits?} is used, and that is deliberate
      #
      # Three reasons, in ascending order of how much they decide it.
      #
      # {Tool::Bounds::Artifact#refusal} returns a {Tool::Result}, and a
      # {Tool::Result} is not what this tier answers -- {Oracle::Eager} awaits a
      # {Definition} answer or nil. {Artifact#message} then demands a
      # `narrower:` action, and there is none to name: the model did not make
      # this call, so there is no narrower call for it to make instead.
      #
      # The one that settles it: a decline rendered as prose would be a HIT.
      # {Compaction::SummarySnapshot.take} keys on the result digest and counts
      # every key it finds an answer for, so a refusal string stored as a
      # summary would report as a summary that landed -- and `hits`/`misses` is
      # the bench's only read on whether the fires are working at all. Declining
      # by nil keeps it counted as the miss it is, and
      # {Compaction::SummarySnapshot} still attests the block's type, content
      # address and byte count beside its elision line, so the size is disclosed
      # either way.
      INPUT_BOUND = Tool::Bounds::Artifact.new(limit: 256 * 1024)

      # @param inner [#ask] the model-backed tier a miss falls through to --
      #   {Recorded::Journaling} over {Model} in live use
      # @param catalog [#for] the project's declared summarizers
      #   ({Summarizer::Catalog}); an empty one simply never matches
      # @param definition [Oracle::Definition] validates a CUSTOM answer
      # @param slot [Symbol] which input slot carries the source
      # @param threshold_bytes [Integer] see {MODEL_THRESHOLD_BYTES}
      # @param input_bound [Tool::Bounds::Artifact] see {INPUT_BOUND}. A second
      #   keyword rather than a second Integer, because the two gates are not
      #   the same kind of policy and a caller moving one must not be able to
      #   move the other by accident.
      # @raise [ArgumentError] when the two gates leave no window between them
      #   -- see {#admitting}
      def initialize(inner:, catalog:, definition: Summarize.definition(tier: TIER), slot: Eager::DEFAULT_SLOT,
                     threshold_bytes: MODEL_THRESHOLD_BYTES, input_bound: INPUT_BOUND)
        @inner = inner
        @catalog = catalog
        @definition = definition
        @slot = slot
        @threshold_bytes = threshold_bytes
        @input_bound = admitting(input_bound, threshold_bytes)
      end

      # @param inputs [Hash] the question's slot values; the source slot holds a
      #   {Summarizer::Result} when the mount threaded a tool name, and bare
      #   text otherwise
      # @return [Lain::Promise] resolving to the validated typed answer, or to
      #   nil when nothing was suitable and the source is outside the model
      #   tier's window -- too small to be worth a call
      #   ({MODEL_THRESHOLD_BYTES}) or too large for one to serve
      #   ({INPUT_BOUND}). The CATALOG is never gated by either.
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

      # The model tier, or nothing at all. A routed source OUTSIDE the paid
      # window is a result the free tier declined and the model tier either is
      # not worth spending on or could not serve, so this answers a resolved
      # Promise holding nil rather than asking: {Oracle::Eager} awaits whatever
      # a tier answers, and an absent summary is ALREADY what
      # {Oracle::Eager#held} means by a miss. A decline therefore reads
      # downstream exactly like a fire still in flight -- an elision line in the
      # compacted render, attested, with nothing raised.
      #
      # BOTH gates are here and nowhere else. That is the whole siting argument
      # of {INPUT_BOUND}: `custom(source)` has already run, unbounded, so a
      # project's own summarizer sees every result at every size.
      #
      # `is_a?(String)` and not a bare `bytesize`: a source answering
      # `#tool_name` but not `#text` has no bytes to weigh, and gating on one
      # would kill it with a bare NoMethodError from in here. Passed ON instead,
      # it reaches {Definition#render}, whose {Prompt::NonStringSlot} names both
      # the slot and the problem. Latent -- only {Summarizer::Result} satisfies
      # the duck today -- but the loud refusal is the one that already existed.
      def fallthrough(inputs, source)
        text = text_of(source)
        return declined if text.is_a?(String) && !worth_a_model_call?(text.bytesize)

        @inner.ask(inputs.merge(@slot => text))
      end

      # The paid tier's window, `(threshold, ceiling]` -- open at the bottom
      # because the threshold is the size a result must EXCEED, closed at the
      # top because {Tool::Bounds::Artifact#admits?} is `<=`. One predicate for
      # the pair, so no caller can consult one gate and forget the other, and
      # {#admitting} has already guaranteed the window is non-empty.
      def worth_a_model_call?(bytes) = bytes > @threshold_bytes && @input_bound.admits?(bytes)

      def declined = Promise.new.tap { |promise| promise.resolve(nil) }

      # Refuse a pair of gates with no window between them, at CONSTRUCTION.
      #
      # Both failures below are silent otherwise, which is what makes this worth
      # a check on a study bench rather than defensive noise. A ceiling at or
      # under the threshold declines every routed source and never asks the
      # model tier: the arm runs, costs nothing, and reports 100% misses that
      # look like a tier being down. Swapping the two keywords is worse -- an
      # Integer where a bound belongs raises `NoMethodError` from inside `#ask`,
      # one fire deep, where {Oracle::Eager#fire}'s task boundary rescues it
      # under `StandardError` and it reaches nobody at all.
      #
      # {Tool::Bounds.ceiling} states the doctrine: fail where the wrong value
      # arrived, not mid tool call. Both numbers are named because both knobs
      # are, and a refusal that says only "degenerate" leaves the operator to
      # work out which of the two they got wrong. Naming them is safe here in a
      # way {Tool::Bounds::Artifact#message} is not -- these are the bounds
      # themselves, never a payload.
      def admitting(bound, threshold)
        raise ArgumentError, "input_bound must answer #admits?, got #{bound.class}" unless bound.respond_to?(:admits?)
        raise ArgumentError, empty_window(bound, threshold) unless bound.limit > threshold

        bound
      end

      def empty_window(bound, threshold)
        "input_bound's limit of #{bound.limit} bytes must EXCEED threshold_bytes of #{threshold}: " \
          "the model tier's window is (threshold, ceiling], so these two admit nothing and decline in silence"
      end

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
