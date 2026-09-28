# frozen_string_literal: true

module Lain
  module CLI
    # Turns the CLI flags into the two collaborators a run needs a CHOICE about --
    # which Provider backend, and the Context carrying the model and the sampler
    # params (temperature/seed) that ride Request#extra. A plain object, not a bag
    # of methods on the Thor executable: BOTH the chat and bench-record paths
    # resolve `--provider` through this one seam, so they agree on what a
    # provider name means.
    #
    # Errors here are Lain's, not Thor's: an unknown provider raises
    # {UnknownProvider} (a {Lain::Error}), which the exe layer maps to a
    # Thor::Error. Thor never crosses into lib/ (output/error discipline).
    class Backend
      # A missing key used to backtrace as {Provider::HTTP::ConfigurationError}
      # -- a plain StandardError, so it skipped the exe's `rescue Lain::Error`
      # and dumped a raw trace naming "Transport", an internal collaborator.
      # Named refusal, checked BEFORE construction.
      class MissingAPIKey < Error; end

      # A memoized factory answers its FIRST caller's arguments forever. The run
      # has one wiring site, so that is a cache hit; a SECOND, differing call
      # would hand back a {Compaction::Source} still bound to the first journal,
      # and every per-turn decision would land in `Channel::Null` with nothing
      # raising and nothing missing from the record's shape.
      class Rebound < Error; end

      # A summarizer ceiling of zero or less. Loud, because every other layer is
      # deaf to it: `0` is TRUTHY, so {#knob}'s `||` does not fall back for it;
      # `Request#max_tokens` only does `Integer()`, with no range check; the
      # provider 400s; and {Oracle::Eager}'s task boundary swallows that BY
      # DESIGN, leaving "compaction quietly stopped summarizing" as the only
      # symptom. A {Lain::Error} for {MissingAPIKey}'s reason: a bad flag reaches
      # the operator cleanly only if the exe's `rescue Lain::Error` can see it.
      class InvalidCeiling < Error; end

      # Loud for {InvalidCeiling}'s reason plus one peculiar to this flag: Thor
      # fills a `type: :string` option whose value was forgotten with the
      # option's own NAME, so `--keep-alive --model x` would send the literal
      # `"keep_alive"`. Numeric siblings inherit a check from `type: :numeric`.
      class InvalidKeepAlive < Error; end

      # This class's fifth error, {InvalidEndpoint}, lives beside the
      # {Endpoint} that raises it.

      # The sampler keys only an ollama arm reads. A chat on any other arm
      # sends none of them, because {Provider::AnthropicEncoding} forwards any
      # `extra` key it does not know onto a wire that defines none of these.
      OLLAMA_ONLY_KEYS = %w[seed num_batch num_ctx].freeze

      # Of those, the two that KEY a runner rather than shape an answer: a
      # request whose value differs from the loaded runner's reloads the model.
      # This set, and not the one above, is what a secondary tier may carry --
      # `seed` would move its answers.
      #
      # `keep_alive` is not here either: a request carrying none leaves an
      # existing pin alone (probed -- docs/providers/ollama.md), so a tier
      # repeating it could only CHANGE the residency, never preserve it.
      RUNNER_KEYS = %w[num_batch num_ctx].freeze

      # ollama's own server default (512) undercorrects llama.cpp's actual
      # default (2048); {Provider::Ollama::Encoding::SAMPLER_KEYS} carries the
      # measured cost of staying at 512. Every other sampler knob reaches the
      # wire only when a flag or the environment set it; this is the one
      # {#sampler_extra} sends on every ollama chat regardless, because unlike
      # temperature or seed it changes nothing about the answer, only how fast
      # it arrives.
      DEFAULT_NUM_BATCH = 2048

      # Go's duration grammar, which ollama parses a STRING `keep_alive` with.
      KEEP_ALIVE_DURATION = /\A[-+]?(0|((\d+(\.\d+)?|\.\d+)(ns|us|µs|μs|ms|s|m|h))+)\z/

      # The providers `--provider` selects between. The unknown-name guard names
      # this set, matching Capability::Policy.for's voice.
      PROVIDERS = %w[anthropic ollama ollama-cloud].freeze

      # Which of those the SUMMARIZER tier defaults to. Local, because an eager
      # summary fires once per large tool result and paying frontier-model
      # tokens to compress one costs more than resending it. A default, not a
      # law: `--summarizer-provider` overrides it either way, which is why the
      # tier is journalled.
      DEFAULT_SUMMARIZER_PROVIDER = "ollama"

      # Compaction's knobs, in {Compaction::Head}'s canonical-byte proxy. They
      # live HERE rather than as Thor defaults so there is one authority: an
      # unset flag arrives as nil and falls through to these.
      #
      # 256 KiB of droppable head is roughly 64k tokens -- big enough that a
      # working session is never rewritten for nothing, small enough that it is
      # the trigger that actually fires under Anthropic's 1M window (where
      # {Need::ApproachingWindow} would not fire until ~900k). The hard cap is
      # 4x that: below it a WARM cache defers, because a cache read costs ~0.1x
      # what the rewrite costs.
      DEFAULT_BYTE_THRESHOLD = 262_144
      DEFAULT_HARD_CAP = 1_048_576

      # Trailing messages a compaction never touches. Twenty is about the last
      # ten exchanges: enough that the model keeps the thread of what it is
      # doing, since everything ahead survives only as summary or attestation.
      DEFAULT_KEEP_LAST = 20

      # What `--compact-fallback` chooses between once no cut can make room:
      # replace the history before the current ask with one state document and
      # answer the ask, or let the refusal stand. ON by default, because the
      # alternative is a session that can no longer be spoken to.
      HANDOFF_FALLBACK = "handoff"
      COMPACT_FALLBACKS = [HANDOFF_FALLBACK, "none"].freeze
      DEFAULT_COMPACT_FALLBACK = HANDOFF_FALLBACK

      # A `--compact-fallback` outside {COMPACT_FALLBACKS}. Refused at
      # construction, for {InvalidCeiling}'s reason: a fallback that silently
      # resolved to "none" would show up only as an ask that died where it
      # should have been kept.
      class UnknownFallback < Error; end

      # {Compaction::Scheduler} prices EVERY compacting turn, and the bench's
      # shared {PriceBook} raises on a model it has no list price for -- right
      # for a cost bench, fatal here, where it would turn the first compaction
      # of an ollama chat into a crash mid-conversation. `--model` is free-form,
      # so this is not only the local-provider case.
      #
      # So compaction gets its own book: the same DEFAULTS, degrading to zero.
      # Nothing a bench reads is under-reported -- `cost_saved` and `cost_spent`
      # annotate a decision already made on BYTES -- and the degrading is not
      # SILENT, since {Telemetry::Compaction} carries a model beside the figures.
      #
      # Read that record's `model` through its `#priced?`, though, and not as
      # "the tier these dollars are quoted in": it means one of three things
      # (see {Telemetry::Compaction}'s header), and this fallback's own zero is
      # the case neither of the other two covers -- `priced?` true and the
      # figure never measured.
      #
      # No `.freeze`: PriceBook freezes itself and its map at construction.
      COMPACTION_PRICES =
        PriceBook.new(fallback: Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0))

      # Both summarizer flags are refused HERE, at construction, rather than
      # where the tier is built. `--provider` refuses on every run because
      # {#provider} always runs; the summarizer's would not, because under
      # `--no-compact` {#tool_observer} answers the Null and {#summary_oracle}
      # is never built -- so a typo was accepted in exactly one configuration.
      # Construction is the single path every command takes.
      #
      # The keys below are the whole surface this class reads out of Thor's flag
      # set; `exe/lain` remains the authority on each flag's spelling, default and
      # help text.
      #
      # @param options [Hash] Thor's parsed flag set for the invoked command
      # @param root [String] the PROJECT's root, which is what {#library} reads
      #   `.lain/skills` and `.lain/slots` from. REQUIRED, and that is the
      #   point: defaulted to the working directory it read whatever tree the
      #   shell was standing in, so `lain chat --root` resolved a Project every
      #   other collaborator honoured and the system prompt ignored. Required
      #   means every caller states one, which is what makes the next omission
      #   impossible rather than merely unlikely.
      # @param profile [RunProfile] the provider, model, endpoint and runner
      #   knobs, carrying which of them were typed. Every command hands in the
      #   one it resolved; left out, it is read off `options`, where every field
      #   holding a value counts as typed. A keyword, so a caller passing both
      #   writes the option hash in braces and neither can be taken for the other.
      # @option options [String] :provider name of the chat tier's provider
      # @option options [String] :model model id for the chat tier
      # @option options [String] :api_base base URL override, ollama only
      # @option options [Integer] :max_tokens ceiling on a chat completion
      # @option options [Float] :temperature sampler temperature, 0 for determinism
      # @option options [Integer] :seed sampler seed, paired with temperature 0
      # @option options [Integer] :num_batch prompt batch size, ollama only
      # @option options [Integer] :num_ctx context length for the request, ollama only
      # @option options [String] :keep_alive how long the runner stays loaded, ollama only
      # @option options [Boolean] :compact whether history compaction runs at all
      # @option options [String] :compact_strategy which strategy collapses a span
      # @option options [Integer] :compact_bytes head size that triggers a compaction
      # @option options [Integer] :compact_cap hard ceiling a compaction must reach
      # @option options [Integer] :compact_keep turns held back from collapsing
      # @option options [String] :compact_fallback what happens when no cut can make room
      # @option options [String] :summarizer_provider provider for the summarizer tier
      # @option options [String] :summarizer_model model id for the summarizer tier
      # @option options [Integer] :summarizer_max_tokens ceiling on a summarizer answer
      def initialize(options, root:, profile: RunProfile.from_options(options))
        @options = options
        @root = root
        @run_profile = profile
        summarizer_name
        summarizer_max_tokens
        compact_fallback
        # BOTH arms, built for their refusals and dropped: `--summarizer-provider
        # ollama-cloud` is the same credential on the same wire as `--provider`,
        # and the summarizer flags refuse at construction whatever `--no-compact`
        # says, so `lain up` cannot open a pane that dies at the first
        # compaction. It also evaluates {#api_base} on the way in, so that flag
        # stays validated for EVERY provider.
        [profile.provider, summarizer_name].each { |name| ollama_tier(name) }
        # `--num-ctx`'s SHAPE only: the trained-maximum half needs a probe, and
        # a constructor that probes is one {ChatLaunch#preflight} cannot run.
        # Still AFTER {#api_base}, unchanged: a base URL the probe will talk to
        # has to be a usable one before a window is judged against it.
        num_ctx_request.requested
        keep_alive
      end

      # `flag` names WHICH flag was wrong: `--provider` and
      # `--summarizer-provider` are two different mistakes to make, and a
      # refusal that named neither would send the operator to the wrong one.
      # A class method, so a caller that builds no Backend -- a dry run, which
      # must read no key -- still refuses a typo by name.
      #
      # @param name [String, nil]
      # @param flag [String]
      # @return [String] the name, known
      # @raise [UnknownProvider]
      def self.validated(name, flag = "provider")
        return name if PROVIDERS.include?(name)

        raise UnknownProvider, "unknown #{flag} #{name.inspect}, expected one of #{PROVIDERS.inspect}"
      end

      # Anthropic is env-configured and reads its own credentials, so no flag
      # threads through here; the two ollama arms are {OllamaTier}'s whole
      # subject, since "which server, whose key, which default model" differs
      # between them. An unknown name fails loudly as {UnknownProvider}, naming
      # the valid set.
      #
      # The hosted name means a RAW (vendored-transport) provider here, for
      # uniform retry telemetry over one Faraday stack. The official-SDK class
      # is the `#encode` differential ORACLE and lives in spec/support, so no
      # run constructs it and the `anthropic` gem is not a runtime dependency.
      #
      # @param name [String] WHICH provider to build, already validated against
      #   PROVIDERS -- the chat's by default. {#summarizer_provider} passes its
      #   own name here rather than carrying a second copy of this case, so the
      #   two flags cannot come to disagree about what a provider name means.
      #   The ollama arm keys off {OllamaTier::NAMES} rather than a literal for
      #   that same reason: `--provider ollama-cloud` is a name, not a boolean,
      #   which is what lets `bench arms` and `bench record` reach it through
      #   the `provider:` their closed flag maps already forward.
      # @param spool [#open_frame] the chronicle's response spool -- a real
      #   {Provider::ResponseWal} only when journaling is on
      #   ({CLI::Chronicle::Null} answers {Provider::Spool::Null}, never nil, so
      #   this is never an `if spool` guard).
      # @param channel [Lain::Channel] where a raw provider's retry and
      #   stream_started events land -- chat's live TTY Channel, so a stream
      #   start reaches the frontend and {Frontend::Decorators::ProviderRetry}
      #   paints a retry storm as it happens rather than leaving a blank screen.
      #   Defaults to the Null instance, so headless and bench events land
      #   nowhere.
      # @param queue [Boolean] the caller's willingness to WAIT for
      #   {Provider::Admission} to free a slot; not a property of the endpoint.
      #   Every arm takes it now, so it is forwarded unconditionally.
      # @param journal [#<<] where the provider's own records land -- a wait,
      #   a truncated stream. This run's {#journal} by default, resolved per
      #   event; a command that records each run into its own file hands in a
      #   destination that follows the run instead.
      def provider(name: provider_name, spool: Provider::Spool::Null.new, channel: Channel::Null.instance, queue: true,
                   journal: run_journal)
        case name
        when *OllamaTier::NAMES then ollama_tier(name).provider(channel:, queue:, journal:, spool:)
        else anthropic_provider(spool, channel, journal, queue:, flag: OllamaTier.flag_for(chat: chat_name?(name)))
        end
      end

      # The summarizer tier's provider, resolved through {#provider}'s validated
      # set. Deliberately handed neither the chat's spool nor its channel: an
      # oracle round trip is not a turn, so it belongs in neither the response
      # WAL a replay reads back as turns nor the live stream the frontend paints.
      # `queue:` is passed THROUGH rather than decided here, because
      # {Backend::Summarizer} and {Backend::SpanSummarizer} need opposite
      # answers; each says why at its own `#tier`.
      def summarizer_provider(queue: true) = provider(name: summarizer_name, queue:)

      # `--summarizer-model`, defaulting to the CHAT's model when both tiers
      # name one provider and to the summarizer provider's own default when they
      # do not.
      #
      # What FORCED the rule is local: one GPU holds one resident model, so an
      # unpinned summarizer on the chat's own provider evicts the chat model at
      # every compaction and the next turn reloads it -- **84.0s against 7.5s**,
      # measured. The rule fires for anthropic-on-anthropic too, where nothing is
      # resident and the reason is plainer: one provider is one model namespace,
      # and inheriting is at worst neutral, since the hosted provider's own
      # default is already its top tier.
      #
      # Across providers neither argument survives -- no shared residency, no
      # shared namespace, and a model id that does not parse on the other side
      # -- so `--provider anthropic` must not name the local tier's model.
      def summarizer_model = @options[:summarizer_model] || tier_default_model

      # `--summarizer-max-tokens`. A summary that runs out of ceiling is a
      # truncated summary, and a truncated summary REPLACES the result it
      # compressed, so the knob is worth exposing rather than inheriting the
      # chat's, which is sized for a turn rather than for a paragraph.
      #
      # Non-positive is refused rather than measured (see {InvalidCeiling} for
      # what stays silent otherwise). Both ceiling flags reach {Ceiling}, so
      # there is one place either can go wrong.
      def summarizer_max_tokens
        Ceiling.new(flag: "--summarizer-max-tokens",
                    value: knob(:summarizer_max_tokens, Oracle::Model::DEFAULT_MAX_TOKENS)).tokens
      end

      # {#tier_options} for the summarizer tier, at the endpoint its own arm
      # dials. Both {Summarizer} and {SpanSummarizer} read it.
      def summarizer_options
        tier_options(provider: summarizer_name, model: summarizer_model,
                     api_base: ollama_base(summarizer_name))
      end

      # The sampler options a SECONDARY model request may carry -- a summary, a
      # span collapse, a secret-read judgement.
      #
      # Only {RUNNER_KEYS}, and only when the tier is the chat's own ollama
      # runner: same arm, same endpoint, same model. There a request with a
      # different `num_batch` does not merely run differently, it RELOADS the
      # runner, and the chat's next turn reloads it back: 29.4s of oracle wall
      # against 1.6s, measured under LAIN_NUM_BATCH. On a different model the
      # chat's `num_ctx` would force that tier's own reload instead, so nothing
      # is carried. The chat's temperature and seed never are: they would move
      # the judge's verdicts and the summaries, which no runner needs.
      #
      # Endpoints compare as the arm's default when no base is given, with a
      # trailing slash stripped, and otherwise by spelling: `localhost` is not
      # `127.0.0.1`, since it may resolve to ::1 where another listener sits.
      # A miss costs one reload; the opposite mistake asks a tier under knobs
      # nobody chose.
      #
      # @param provider [String] which arm the tier dials, as `--provider`
      #   spells it; only the chat's own ollama arm can share its runner
      # @param model [String] the model the tier asks
      # @param api_base [String, nil] the base the tier's arm dials; nil is its
      #   arm's own default
      # @return [Hash{String=>Object}] frozen; empty unless the runner is shared
      def tier_options(provider:, model:, api_base: nil)
        shared = shares_chat_runner?(provider, model, api_base)
        (shared ? sampler_extra.slice(*RUNNER_KEYS) : {}).freeze
      end

      # The provider, model, endpoint, runner knobs and residency this run was handed, as
      # the one value a session header records. Every model-access read below
      # goes through it, so what is recorded is what was used.
      #
      # @return [RunProfile]
      attr_reader :run_profile

      # Where this run's records land. Bound by the first {#pipeline_source}
      # call (the run has exactly one wiring site) and the Null channel until
      # then, so a path that never wires compaction -- bench, `--no-journal` --
      # reads a destination rather than a nil to guard.
      def journal = @journal || Channel::Null.instance

      # `--model` defaults to the SELECTED provider's own default (resolved here,
      # not in the Thor flag, whose default is fixed at load before `--provider`
      # is known). Sampler params ride Request#extra via the Context. The system
      # prompt renders from the loaded {#slots} unless a caller overrides it --
      # bench record's `--system` flag is the one caller that does.
      #
      # `--context-pipeline` is resolved here, so a typo refuses wherever a
      # context is first built -- the pre-flight included -- and an unset flag
      # builds the Context it always did.
      def context(system_override: nil)
        ContextPipeline.named(@options[:context_pipeline])
                       .context(model:, max_tokens:, extra: sampler_extra, system: system_override || slots.render)
      end

      # The ONE window book this run measures occupancy against, resolved by
      # {WindowBook} out of the window the provider says it is actually SERVING
      # (see there for why the shipped table cannot answer). Read by three
      # places that must agree -- {StatusFeed}, {Compaction::Source}'s per-turn
      # threshold, and {Agent#occupancy}, the `ctx` figure in the REPL prompt
      # line -- so it is MEMOIZED: three readers dividing by three different
      # numbers is the failure this exists to prevent.
      #
      # The memo is of the OBJECT, not of the answer inside it. A run launched
      # with `--num-ctx` while nothing is resident resolves to a guess, and a
      # memoized guess is permanent. So the three readers share one
      # {WindowBook::Live}, whose answer {Middleware::ResolveWindow} re-resolves
      # once per turn until it is authoritative. Both halves are load-bearing:
      # sharing is what keeps the readers agreeing, and the once-per-turn
      # trigger is what keeps them agreeing WITHIN a turn.
      #
      # @return [WindowBook::Live]
      def context_window = @context_window ||= WindowBook::Live.new(source: WindowBook.new(backend: self))

      # `--num-ctx`, through the same {Ceiling} both `--max-tokens` flags go
      # through, and OPTIONAL: unset means "serve the model's own". What is NOT
      # a real answer is a non-positive one, and `0` is where this bit --
      # truthy, so no `||` falls back for it; sent verbatim by {#sampler_extra};
      # and then adopted as a DENOMINATOR, taking the chat out mid-turn with
      # `ArgumentError: window_tokens must be a positive Integer, got 0` from
      # inside {Compaction::Need}. `--num-ctx` is `type: :numeric` with no range
      # check and `EnvDefaults.numeric` only rejects non-numbers, so
      # `LAIN_NUM_CTX=0` in an `.envrc` was that crash for every session in the
      # directory.
      #
      # The trained-maximum ceiling too, which only a running server publishes
      # -- so {ChatLaunch#call} forces this, construction does not, and
      # `Backend.new` opens no socket. {WindowBook} then reads it every turn.
      #
      # MEMOIZED, and so is the probe inside {NumCtx}: this memo holds an
      # ACCEPTED window, that one the figure a REFUSED one is measured against.
      def num_ctx = @num_ctx ||= num_ctx_request.tokens

      # `--keep-alive`, COERCED here because its two legal spellings are two
      # JSON types: an integer becomes an Integer (seconds, -1 forever), a
      # duration stays the String Go will parse. Sending `"-1"` instead is an
      # HTTP 400 on every turn -- docs/providers/ollama.md has the probe.
      #
      # Base 10 is PINNED: `Integer()` guesses one from the prefix, so `060` --
      # a plausible minute -- read as octal 48. The other literal forms fall to
      # the duration check and are refused, since a flag that exists to reject
      # what it cannot mean must not silently read a number nobody wrote.
      #
      # Refused at CONSTRUCTION for {#api_base}'s two reasons: a mistake should
      # arrive as a named refusal rather than the server's parse error mid-turn,
      # and a stray `LAIN_KEEP_ALIVE` must refuse whatever `--provider` says.
      #
      # @return [Integer, String, nil] nil when nobody asked for a residency,
      #   which leaves ollama's own five-minute timer alone
      # @raise [InvalidKeepAlive]
      def keep_alive = run_profile.keep_alive&.then { |raw| Integer(raw, 10, exception: false) || duration(raw) }

      # `--api-base`, through {Endpoint}, and OPTIONAL the way `--num-ctx` is:
      # unset means "ollama's own default". {Endpoint} owns what an unusable one
      # is and why the obvious `URI::InvalidURIError` guard does not catch it.
      #
      # Refused at CONSTRUCTION, because {#provider} is the only other reader of
      # this flag and would not run at all for `bench record` on a non-ollama
      # provider. {#initialize} reaches it through {OllamaTier}, which takes the
      # validated value as an argument, so the eager refusal fires whatever
      # `--provider` says.
      def api_base = run_profile.api_base && Endpoint.new(flag: "--api-base", value: run_profile.api_base).url

      # `--model` resolved once, so {#context}, {WindowBook} and the compaction
      # book agree about which model this run is. {WindowBook} asks for it
      # lazily, since it must not be resolved before that object can rescue what
      # {#provider_name} raises for an option hash naming no provider at all.
      def model = run_profile.model || default_model(provider_name)

      # Which Context THIS turn renders through -- the live compaction source
      # by DEFAULT, since `lain chat` compacts unless `--no-compact` says
      # otherwise, and {Agent::PipelineSource::Null} when it does.
      #
      # MEMOIZED, unlike {#context}. The source is RUN state: {Compaction::Cold}
      # accumulates the cache warmth it has observed and {Oracle::Eager} the
      # summaries it has fired, so a source rebuilt per call would silently reset
      # both every turn and the `:cold` decision path would never fire. The first
      # call therefore BINDS the journal and the cache profile, and a differing
      # second call raises {Rebound} rather than quietly answering the first
      # binding.
      #
      # @param cache_profile [Lain::CacheProfile] the CHAT provider's own, so
      #   {Compaction::Cold} compares idle time against a TTL that exists (a
      #   TTL-less provider confirms cold off the zero cache-read alone)
      # @param journal [#<<] where the per-turn decision and the cold
      #   confirmation land
      # @param sink [Lain::Sink] where compaction reports what an operator has
      #   no other way to see: a `--compact-strategy` policy whose tier is
      #   DOWN, and a warranted compaction with nothing left to drop. It is
      #   still the one argument a caller may reasonably not have, so it keeps
      #   its Null default.
      #
      #   NOT bound by {#bind_once}, and that is now a GAP rather than the free
      #   choice it was. The justification used to be that this argument
      #   changes nothing about which Source gets built; it now decides whether
      #   the run can speak at all, so a second call with a different sink
      #   silently keeps the first and the operator goes permanently quiet with
      #   no error -- the same silence the sink was added to break.
      #   Unreachable today: {CLI::CompactionMount#source} memoizes and is the
      #   only production caller. Closing it is not a one-word change --
      #   `bind_once` compares argument VALUES and two default `Sink::Null.new`
      #   instances are not `==`, so listing `sink:` there raises {Rebound} on
      #   ordinary repeat calls until the Null answers value equality the way
      #   {ContextWindow::Occupancy::None} had to.
      # @raise [Rebound] on a second call with different arguments
      def pipeline_source(cache_profile:, journal: Channel::Null.instance, sink: Sink::Null.new)
        bind_once(:pipeline_source, cache_profile:, journal:)
        @journal = journal
        @pipeline_source ||= if compaction?
                               compaction_source(cache_profile:, journal:, sink:)
                             else
                               Agent::PipelineSource::Null
                             end
      end

      # The post-dispatch observer {Agent::ToolRunner} fires eager summaries
      # through, over the run's ONE {Oracle::Eager} -- the store
      # {#pipeline_source} snapshots.
      def tool_observer
        @tool_observer ||= if compaction?
                             Compaction::SummaryObserver.new(eager:)
                           else
                             Agent::ToolRunner::Observer::Null.new
                           end
      end

      # The run's ONE summary store, shared by {#tool_observer} (which fires
      # into it) and {#pipeline_source} (which snapshots it per turn). Two
      # instances would mean every fire landed where no render reads.
      def eager = @eager ||= Oracle::Eager.new(oracle: summary_oracle)

      # @return [Boolean] whether this run compacts at all; on unless
      #   `--no-compact` turned it off
      def compaction? = @options.fetch(:compact, true)

      # `--compact-fallback`, validated. An unset flag is the default arm, not
      # "no fallback": a run that never typed the flag still keeps its asks.
      #
      # @return [String] a member of {COMPACT_FALLBACKS}
      # @raise [UnknownFallback] on a name outside that set
      def compact_fallback
        name = @options[:compact_fallback] || DEFAULT_COMPACT_FALLBACK
        unless COMPACT_FALLBACKS.include?(name)
          raise UnknownFallback, "--compact-fallback #{name.inspect} is not one of " \
                                 "#{COMPACT_FALLBACKS.join(", ")}"
        end

        name
      end

      # The compaction section of the session header: which fallback arm and
      # which span-collapse strategy this run takes. Neither is on {RunProfile}
      # -- a profile says which model server answers, and a resumed chat
      # defaults its backend to it, while these are arms of the experiment,
      # recorded so a bench can group runs by them and read nothing else back.
      #
      # `compact_strategy` merges in only when `--compact-strategy` was given,
      # {SessionRecord.context_pipeline}'s own only-when-named idiom: an unset
      # flag is not "no strategy", it is the run's own eager tool-result tier,
      # the comparability axis's CONTROL arm, and a reader normalizes that
      # absence to it rather than this method writing the name itself. The
      # value travels VERBATIM and UNVALIDATED -- {SpanSummarizer} is the
      # object that refuses a name {CLI::CompactionStrategy} rejects, and
      # duplicating that refusal here would mean building a second resolver
      # just to check a string this one already checks for real.
      #
      # @return [Hash{String=>Object}]
      def compaction_header
        strategy = @options[:compact_strategy]
        header = { "compact_fallback" => compact_fallback }
        strategy.nil? ? header : header.merge("compact_strategy" => strategy)
      end

      # The run's ONE {Skill::Library} -- the project's skills and the prompt
      # slots they render through, read once. Owned HERE because {#context}
      # renders the slots half into the system prompt, which makes this the
      # lowest object above every reader: the repl's command surface, the skill
      # middleware, {Tools::RunSkill} and {Skill::RoleSpawn} are all wired from
      # {Wiring}, which is handed a Backend and cannot be handed a library it
      # would then have to load itself.
      #
      # Read from the root this Backend was CONSTRUCTED with, never from the
      # working directory: that is the whole of what `--root` buys, and the
      # layering is unchanged -- Wiring still receives a loaded library, and the
      # root arrives from above rather than being resolved here.
      def library = @library ||= Skill::Library.load(root: @root)

      # The loaded prompt slots -- exposed (not just the rendered String
      # {#context} produces) so a caller can emit ONE Telemetry::SlotFills built
      # from the exact slots this Backend rendered, with no second disk read.
      # The library's, so `bench record`'s attribution and the chat's system
      # prompt cannot be reading two snapshots of one tree.
      def slots = library.slots

      # The {Tool::SpawnPolicy} for a cataloged {Role}, resolved through
      # {Role::Catalog} rather than hand-assembled at the call site. A spawn seam
      # names the ROLE it wants (`:researcher`) and the catalog is the one place
      # that name's `only`-set can change, so a role's capability set cannot
      # drift between a spawn site and its definition. An uncataloged name fails
      # loudly through {Role::Catalog.fetch}, so there is no separate refusal to
      # keep in sync.
      def spawn_policy(role_name) = Role::Catalog.fetch(role_name).spawn_policy

      private

      def num_ctx_request = @num_ctx_request ||= NumCtx.new(backend: self, value: run_profile.num_ctx)

      # Refuses BEFORE construction: {Provider::Anthropic} validates the key
      # eagerly too, but as {Provider::HTTP::ConfigurationError}, which is not a
      # {Lain::Error} and so reaches the operator as a raw backtrace instead of
      # the exe's clean Thor::Error mapping.
      #
      # `flag` is whichever one SELECTED this arm, resolved by the caller that
      # knows. `--summarizer-provider anthropic` used to be refused in
      # `--provider`'s name -- a flag the operator never typed.
      def anthropic_provider(spool, channel, journal, queue: true, flag: OllamaTier::CHAT_FLAG)
        raise MissingAPIKey, "ANTHROPIC_API_KEY is not set; #{flag} anthropic needs it to build a client" \
          if ENV["ANTHROPIC_API_KEY"].to_s.empty?

        Provider::Anthropic.new(spool:, channel:, queue:, journal:)
      end

      # Where a provider's {Telemetry::ProviderWait} lands: this run's journal,
      # resolved per EVENT rather than captured here.
      #
      # {Backend::Summarizer::RunJournal}'s own reason, and it binds harder on
      # this path: `Wiring#spooled_provider` builds the chat provider inside
      # `#backing`, and {#pipeline_source} -- where {#journal} gets bound -- runs
      # a line later, through {CompactionMount}. A provider handed `journal` by
      # value would hold {Channel::Null} for the whole session: every wait
      # served, none recorded, nothing raised.
      def run_journal = Summarizer::RunJournal.new(self)

      # Validated once, so #provider and #default_model both key off a name
      # already known to be in PROVIDERS.
      def provider_name = validated(run_profile.provider, "provider")

      def summarizer_name = validated(knob(:summarizer_provider, DEFAULT_SUMMARIZER_PROVIDER), "summarizer provider")

      def validated(name, flag) = self.class.validated(name, flag)

      def tier_default_model = chat_name?(summarizer_name) ? model : default_model(summarizer_name)

      # The one unvalidated provider read in this class, and it does NOT weaken
      # {#provider_name}'s seam: equality with an already-validated name IS the
      # validation. `summarizer_name` is refused at construction if unknown, so
      # a chat name equal to it is in PROVIDERS too, and an unequal one takes
      # the other branch and is never used here. What that buys is the
      # summarizer tier still resolving for a Backend assembled from an option
      # hash naming no chat provider, rather than refusing about a flag this
      # method does not read.
      def chat_name?(name) = name == run_profile.provider

      # WHOSE arm a tier is -- which decides the flag a refusal names -- and,
      # separately, whether `--api-base` is this tier's to use. NOT the same
      # question: {OllamaTier.claims_base?} carries the case that proves it. The
      # base is filtered HERE, so the tier is never handed one it will drop.
      def ollama_tier(name) = OllamaTier.new(name:, chat: chat_name?(name), api_base: ollama_base(name))

      def ollama_base(name) = OllamaTier.claims_base?(name, run_profile.provider) ? api_base : nil

      # The ollama arms answer from {OllamaTier}'s CLASS rather than an
      # instance: this must not build a tier, read ENV, or be able to raise
      # about a missing key, since {#model} is read per turn by three
      # collaborators.
      def default_model(name)
        return OllamaTier.default_model(name) if OllamaTier::NAMES.include?(name)

        Provider::Anthropic::DEFAULT_MODEL
      end

      # `--max-tokens`, through the same {Ceiling} the summarizer tier's flag goes
      # through. Unlike {#model} there is NO default to fall back to here: every
      # command that renders a Context declares the flag with a Thor default, so a
      # nil means a caller assembled this Backend by hand and left it out.
      def max_tokens = Ceiling.new(flag: "--max-tokens", value: @options[:max_tokens]).tokens

      # The context window is not resolved PER TURN here: the Source asks
      # {#context_window} about the live Context every turn, so a `/model`
      # switch mid-session moves the threshold with it. What this method owns is
      # which BOOK answers -- the run's one provider-derived book, so the
      # threshold a journal reader sees fired and the occupancy a human reads
      # are the same division.
      #
      # `--compact-strategy` is resolved ONCE, HERE, and injected -- never
      # fetched per turn, because a model-backed strategy holds a memo whose
      # absence turns one range's two questions into two model calls.
      # {SpanSummarizer} owns what an unset flag means.
      #
      # The sink goes to BOTH -- the strategy reports a summarizer tier that is
      # down, the Source reports a warranted compaction with nothing to drop,
      # and either of them going silent leaves an operator unable to tell a stuck
      # session from a quiet one.
      def compaction_source(cache_profile:, journal:, sink:)
        Compaction::Source.new(
          need: Compaction::Need.new(byte_threshold: knob(:compact_bytes, DEFAULT_BYTE_THRESHOLD)),
          cold: Compaction::Cold.new(cache_profile:, journal:),
          hard_cap: knob(:compact_cap, DEFAULT_HARD_CAP), keep_last: knob(:compact_keep, DEFAULT_KEEP_LAST),
          eager:, journal:, model:, price_book: COMPACTION_PRICES, context_window:, sink:, fallback:,
          strategy: SpanSummarizer.resolve(backend: self, options: @options, sink:)
        )
      end

      # The handoff tier answers on the render path's LAST chance, so it is
      # built like {SpanSummarizer#tier} and not like {Summarizer#tier}: no
      # `queue: false`, because the ask is already refused and a document worth
      # waiting for is the only thing between it and failing.
      def fallback
        return Compaction::Source::Fallback::None unless compact_fallback == HANDOFF_FALLBACK

        Compaction::Source::Fallback.new(tier: method(:handoff_oracle), window: method(:handoff_window))
      end

      # The window the HANDOFF tier will be asked in -- the summarizer's model
      # through the run's own book, not the chat's. They are different models
      # by default (a frontier chat summarizing locally), and sizing the
      # question to the chat's window is how a 1M-token Anthropic run writes an
      # input no local summarizer can read.
      #
      # Resolved per call, on {#run_journal}'s reasoning: the book probes, and
      # this is asked only after a prompt has already been refused.
      def handoff_window = context_window.resolve(summarizer_model).window_tokens

      # ONE definition, two uses -- {SpanSummarizer}'s rule, and the journaling
      # wrapper is what makes a failed handoff readable: it holds the
      # definition an `oracle_failed` record names itself by.
      def handoff_oracle = @handoff_oracle ||= journaling(Oracle::Handoff.definition)

      def journaling(definition)
        provider = Provider::Journaled.new(provider: summarizer_provider, journal: run_journal)
        tier = Oracle::Model.new(definition:, provider:, model: summarizer_model,
                                 max_tokens: summarizer_max_tokens, extra: summarizer_options)
        Oracle::Recorded::Journaling.new(inner: tier, definition:, journal: run_journal)
      end

      # An unset numeric flag arrives as nil; the constant is the authority.
      def knob(flag, default) = @options[flag] || default

      # The binding half of a memoized factory (see {Rebound}). Same arguments
      # are a cache hit and pass silently; different ones name WHICH argument
      # moved, since "it was already built" is the diagnosis a caller cannot
      # make from the wrong Source it would otherwise be handed.
      #
      # Argument CLASSES, never their `#inspect`: a journal is a live sink that
      # may be holding the whole session's events, and a diagnostic that dumps
      # it is a second way to corrupt the record it is complaining about.
      def bind_once(slot, **arguments)
        bound = (@bound ||= {})
        drifted = bound[slot]&.reject { |name, value| arguments.fetch(name) == value }
        raise Rebound, rebound(slot, drifted) unless drifted.nil? || drifted.empty?

        bound[slot] ||= arguments
      end

      def rebound(slot, drifted)
        moved = drifted.map { |name, was| "#{name.to_s.tr("_", " ")} (was a #{was.class})" }.join(", ")
        "#{slot} was already built and is memoized for the run; this call would have changed #{moved}, " \
          "and the first binding is what every turn would keep using"
      end

      # The eager tier ({Oracle::Summarize}), assembled by {Summarizer} out of
      # the summarizer's OWN provider, model and ceiling. `--summarizer-provider`
      # may point it at a paid model independently of `--provider`, which is why
      # every answer it gives is journalled -- an unrecorded model call is spend
      # the bench cannot see.
      #
      # Construction opens no connection, so an absent ollama costs nothing here:
      # the fire fails inside {Oracle::Eager}'s task boundary and the compaction
      # renders an elision instead.
      #
      # {Oracle::RoutedSummarizer} goes OUTERMOST, above the journaling wrap
      # {Summarizer} builds: an answer the project's own `.lain/summarizers.rb`
      # produced cost no tokens, so it must not land on the record as a model
      # call, while a fallthrough still journals exactly once from inside.
      #
      # `Summarizer` here is {Backend::Summarizer} -- the flag resolution --
      # and `Lain::Summarizer` is the project's declared free tier. Two
      # different objects one lexical scope apart, hence the explicit root.
      def summary_oracle
        Oracle::RoutedSummarizer.new(inner: Summarizer.new(backend: self).oracle,
                                     catalog: Lain::Summarizer::Catalog.load)
      end

      # Only the sampler flags the caller actually set, String-keyed to match
      # Request's normalized `extra` and Ollama's `options`. `Hash#compact`
      # (never `select(&:itself)` or a truthiness filter) so `--temperature 0`
      # -- the determinism recipe -- and a `--seed 0` are KEPT: an unset flag
      # arrives as nil, and nil is the only absence there is here.
      #
      # `num_ctx` is resolved HERE and not defaulted inside
      # {Provider::Ollama::Encoding}, because it is tuning an operator opts
      # into: a flag nobody set must add nothing to the payload. `num_batch` is
      # the opposite case now -- {DEFAULT_NUM_BATCH} fills it in when neither a
      # flag nor the environment did, so an ollama chat always sends one. The
      # generation cap is a third case again and lives in the encoder for its
      # own reason -- every Request already declares a max_tokens, so that one
      # is on every ollama payload rather than waiting for a flag. Only an
      # ollama chat gets {OLLAMA_ONLY_KEYS}. The runner knobs come off the
      # {#run_profile} and the sampling pair off the flags.
      #
      # `keep_alive` joins outside the loop, being no SAMPLER_KEY: it lives
      # outside `options` on the wire, follows `num_ctx`'s opt-in rule rather
      # than `num_batch`'s default, and reaches only an ollama chat.
      def sampler_extra
        keys = Provider::Ollama::Encoding::SAMPLER_KEYS
        keys -= OLLAMA_ONLY_KEYS unless ollama_chat?
        runner = run_profile.to_options
        extra = keys.to_h { |key| [key, runner.fetch(key.to_sym) { @options[key.to_sym] }] }
        extra["num_batch"] = DEFAULT_NUM_BATCH if ollama_chat? && extra["num_batch"].nil?
        extra[Provider::Ollama::Encoding::KEEP_ALIVE_KEY] = keep_alive if ollama_chat?
        extra.compact
      end

      def duration(raw)
        return raw if KEEP_ALIVE_DURATION.match?(raw)

        raise InvalidKeepAlive, "--keep-alive #{raw.inspect} is neither a number of seconds nor a duration: " \
                                "-1 keeps the model resident, 0 releases it, 5m unloads it after five minutes"
      end

      def ollama_chat? = OllamaTier::NAMES.include?(run_profile.provider)

      # The chat's own endpoint is `--provider` at `--api-base`, since
      # {OllamaTier.claims_base?} always gives the chat's arm the base. Ordered
      # so {#model} is read last: it refuses an option hash naming no provider.
      def shares_chat_runner?(provider, model, base)
        ollama_chat? && provider == run_profile.provider &&
          endpoint(provider, base) == endpoint(provider, api_base) && model == self.model
      end

      def endpoint(provider, base) = (base || default_base(provider)).chomp("/")

      def default_base(provider)
        return Provider::Ollama::Deployment::CLOUD_API_BASE if provider == OllamaTier::CLOUD

        Provider::Ollama::Transport::DEFAULT_API_BASE
      end
    end
  end
end
